#!/usr/bin/env python3
"""AI Benchmarks collector (PRD section 5).

Pulls three public sources and emits benchmarks.json (schema 3.3):
  - OpenRouter  https://openrouter.ai/api/v1/models  (prices, context, canonical slugs)
  - LMArena     HF dataset lmarena-ai/leaderboard-dataset, config text_style_control,
                split latest, filter category == "overall"
  - SWE-bench   raw JSON data/leaderboards.json (tries main, falls back to master)

Each source is isolated in try/except: a failure only sets sources[x].ok = false.
Models are merged on the OpenRouter canonical slug via aliases.json.
Names without a match go to unmatched.json (never silently dropped).
"""

import json
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT_JSON = HERE / "benchmarks.json"
UNMATCHED_JSON = HERE / "unmatched.json"
ALIASES_JSON = HERE / "aliases.json"

ARENA_DATASET = "lmarena-ai/leaderboard-dataset"
ARENA_CONFIG = "text_style_control"
ARENA_PARQUET_URL = (
    f"https://huggingface.co/datasets/{ARENA_DATASET}/resolve/main/"
    f"{ARENA_CONFIG}/latest-00000-of-00001.parquet"
)
ARENA_TOP_N = 100  # take top-100 of the overall leaderboard

SWEBENCH_URLS = [
    "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/main/data/leaderboards.json",
    "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json",
]
SWEBENCH_COMMITS_API = (
    "https://api.github.com/repos/SWE-bench/swe-bench.github.io/commits"
    "?path=data/leaderboards.json&per_page=1"
)

OPENROUTER_URL = "https://openrouter.ai/api/v1/models"
# Fallback (verified 2026-07): LiteLLM mirror carries openrouter/* entries with
# input/output_cost_per_token and max_input_tokens. Used when openrouter.ai
# refuses the request (e.g. Cloudflare "Access denied by security policy").
OPENROUTER_FALLBACK_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
)

UA = {"User-Agent": "ai-benchmarks-collector/1.0 (+https://github.com)"}

PROVIDER_NAMES = {
    "anthropic": "Anthropic", "openai": "OpenAI", "google": "Google",
    "x-ai": "xAI", "deepseek": "DeepSeek", "meta-llama": "Meta",
    "qwen": "Qwen", "mistralai": "Mistral", "moonshotai": "Moonshot AI",
    "zai-org": "Zhipu AI", "minimax": "MiniMax", "baidu": "Baidu",
    "bytedance": "ByteDance", "gemma": "Google",
}


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def get_json(url: str, timeout: int = 60):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def get_bytes(url: str, timeout: int = 120) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


# ---------------------------------------------------------------- OpenRouter
def fetch_openrouter():
    """Returns (catalog, updated_at). catalog: slug -> dict."""
    try:
        data = get_json(OPENROUTER_URL)
        models = data["data"]
        catalog = {}
        for m in models:
            pricing = m.get("pricing") or {}

            def mtok(key):
                v = pricing.get(key)
                try:
                    return round(float(v) * 1_000_000, 6) if v not in (None, "") else None
                except (TypeError, ValueError):
                    return None

            catalog[m["id"]] = {
                "name": m.get("name") or m["id"],
                "price_input_per_mtok": mtok("prompt"),
                "price_output_per_mtok": mtok("completion"),
                "context_length": m.get("context_length"),
            }
        return catalog, now_iso()[:10], "openrouter"
    except Exception as e:
        print(f"[openrouter] direct API failed: {e}; trying LiteLLM mirror", file=sys.stderr)
        data = get_json(OPENROUTER_FALLBACK_URL, timeout=120)
        catalog = {}
        for key, m in data.items():
            if not key.startswith("openrouter/"):
                continue
            slug = key[len("openrouter/"):]
            cin, cout = m.get("input_cost_per_token"), m.get("output_cost_per_token")
            catalog[slug] = {
                "name": slug.split("/", 1)[-1],
                "price_input_per_mtok": round(cin * 1_000_000, 6) if cin is not None else None,
                "price_output_per_mtok": round(cout * 1_000_000, 6) if cout is not None else None,
                "context_length": m.get("max_input_tokens"),
            }
        if not catalog:
            raise RuntimeError("LiteLLM mirror contained no openrouter/* entries")
        return catalog, now_iso()[:10], "litellm-fallback"


# -------------------------------------------------------------------- Arena
def fetch_arena():
    """Returns (rows, updated_at). rows: [{model_name, organization, rating, rank}]."""
    import io

    import pyarrow.compute as pc
    import pyarrow.parquet as pq

    raw = get_bytes(ARENA_PARQUET_URL)
    table = pq.read_table(io.BytesIO(raw))
    overall = table.filter(pc.equal(table["category"], "overall")).sort_by("rank")
    n = min(ARENA_TOP_N, overall.num_rows)
    cols = {c: overall.column(c).to_pylist()[:n] for c in
            ("model_name", "organization", "rating", "rank")}
    rows = [dict(zip(cols, vals)) for vals in zip(*cols.values())]
    for r in rows:
        r["rating"] = int(round(r["rating"]))
        r["rank"] = int(r["rank"])

    updated_at = None
    try:
        info = get_json(f"https://huggingface.co/api/datasets/{ARENA_DATASET}")
        updated_at = (info.get("lastModified") or "")[:10] or None
    except Exception:
        pass
    if not updated_at:
        dates = [d for d in overall.column("leaderboard_publish_date").to_pylist()[:n] if d]
        updated_at = str(max(dates))[:10] if dates else None
    return rows, updated_at


# ---------------------------------------------------------------- SWE-bench
def fetch_swebench():
    """Returns (rows, updated_at). rows: [{name, model_tag, score}] score = 0..1."""
    data, last_err = None, None
    for url in SWEBENCH_URLS:
        try:
            data = get_json(url)
            break
        except Exception as e:
            last_err = e
    if data is None:
        raise RuntimeError(f"all SWE-bench URLs failed: {last_err}")

    verified = next(l for l in data["leaderboards"] if l["name"] == "Verified")
    best = {}  # model identity -> max score
    for r in verified["results"]:
        tags = [t[len("Model: "):].strip() for t in (r.get("tags") or []) if t.startswith("Model: ")]
        ident = tags[0] if tags else r.get("name")
        if not ident or r.get("resolved") is None:
            continue
        score = round(float(r["resolved"]) / 100.0, 4)
        if score > best.get(ident, (-1, ""))[0]:
            best[ident] = (score, r.get("name"))
    rows = [{"model_tag": k, "name": v[1], "score": v[0]} for k, v in best.items()]

    updated_at = None
    for sha in ("main", "master"):
        try:
            commits = get_json(SWEBENCH_COMMITS_API + f"&sha={sha}")
            if commits:
                updated_at = commits[0]["commit"]["committer"]["date"][:10]
                break
        except Exception:
            continue
    return rows, updated_at


# ----------------------------------------------------------------- matching
def normalize(name: str) -> str:
    s = name.lower().strip()
    s = re.sub(r"\s*\((thinking|max|high|medium|minimal|low)[^)]*\)", "", s)
    s = s.replace("-thinking", "").replace(" ", "-")
    s = re.sub(r"-\d{6,8}$", "", s)          # strip date suffixes like -20251101
    s = re.sub(r"-\d{2}k$", "", s)           # strip context suffixes like -32k
    s = re.sub(r"-(high|medium|low|xhigh|sol)(-|$)", r"\2", s)
    return s.strip("-")


def heuristic_slug(arena_name: str, organization: str, catalog) -> str | None:
    """Last-resort guess: <org>/<normalized-name> present in the OR catalog."""
    org_map = {"anthropic": "anthropic", "openai": "openai", "google": "google",
               "xai": "x-ai", "x-ai": "x-ai", "deepseek": "deepseek",
               "meta": "meta-llama", "qwen": "qwen", "alibaba": "qwen",
               "mistral": "mistralai", "moonshot": "moonshotai", "kimi": "moonshotai",
               "zhipu": "zai-org", "glm": "zai-org", "minimax": "minimax"}
    org = org_map.get((organization or "").lower())
    if not org:
        return None
    base = normalize(arena_name)
    base = re.sub(r"^" + re.escape(org.split("/")[-1]) + r"[.-]?", "", base)
    for cand in (f"{org}/{base}", f"{org}/{base.replace('-', '.', 1) if base[0].isalpha() else base}"):
        if cand in catalog:
            return cand
    return None


def main():
    aliases = json.loads(ALIASES_JSON.read_text()) if ALIASES_JSON.exists() else {}

    sources = {
        "arena": {"updated_at": None, "ok": False},
        "swe_bench": {"updated_at": None, "ok": False},
        "openrouter": {"updated_at": None, "ok": False},
    }
    catalog, arena_rows, swe_rows = {}, [], []

    try:
        catalog, sources["openrouter"]["updated_at"], via = fetch_openrouter()
        sources["openrouter"]["ok"] = True
        sources["openrouter"]["via"] = via
        print(f"[openrouter] ok via {via}: {len(catalog)} models")
    except Exception as e:
        print(f"[openrouter] FAILED: {e}", file=sys.stderr)

    try:
        arena_rows, sources["arena"]["updated_at"] = fetch_arena()
        sources["arena"]["ok"] = True
        print(f"[arena] ok: {len(arena_rows)} rows, updated {sources['arena']['updated_at']}")
    except Exception as e:
        print(f"[arena] FAILED: {e}", file=sys.stderr)

    try:
        swe_rows, sources["swe_bench"]["updated_at"] = fetch_swebench()
        sources["swe_bench"]["ok"] = True
        print(f"[swe_bench] ok: {len(swe_rows)} models, updated {sources['swe_bench']['updated_at']}")
    except Exception as e:
        print(f"[swe_bench] FAILED: {e}", file=sys.stderr)

    # Merge on canonical slug. Only models seen in Arena or SWE-bench enter the
    # table (spec 3.4/5: do not dump the whole OpenRouter catalog).
    merged: dict[str, dict] = {}
    unmatched = {"arena": [], "swe_bench": []}

    def blank(slug):
        provider_key = slug.split("/", 1)[0]
        return {
            "id": slug,
            "name": (catalog.get(slug) or {}).get("name") or slug.split("/", 1)[-1],
            "provider": PROVIDER_NAMES.get(provider_key, provider_key),
            "arena_rating": None, "arena_rank": None, "swe_bench_verified": None,
            "price_input_per_mtok": (catalog.get(slug) or {}).get("price_input_per_mtok"),
            "price_output_per_mtok": (catalog.get(slug) or {}).get("price_output_per_mtok"),
            "context_length": (catalog.get(slug) or {}).get("context_length"),
        }

    for r in arena_rows:
        slug = aliases.get(r["model_name"]) or heuristic_slug(r["model_name"], r.get("organization"), catalog)
        if not slug:
            unmatched["arena"].append({"name": r["model_name"], "rank": r["rank"], "rating": r["rating"]})
            continue
        m = merged.setdefault(slug, blank(slug))
        m["arena_rating"], m["arena_rank"] = r["rating"], r["rank"]
        if not catalog.get(slug) and r.get("organization"):
            m["provider"] = PROVIDER_NAMES.get(r["organization"].lower(), m["provider"])

    for r in swe_rows:
        slug = aliases.get(r["model_tag"]) or aliases.get(r["name"])
        if not slug:
            unmatched["swe_bench"].append({"tag": r["model_tag"], "name": r["name"], "score": r["score"]})
            continue
        m = merged.setdefault(slug, blank(slug))
        m["swe_bench_verified"] = r["score"]

    # A model stays only with at least one non-null axis value (spec 3.4).
    models = [m for m in merged.values() if any(
        m[k] is not None for k in
        ("arena_rating", "swe_bench_verified", "price_input_per_mtok", "context_length"))]
    models.sort(key=lambda m: (m["arena_rank"] is None, m["arena_rank"] or 10**9))

    out = {
        "schema_version": 1,
        "generated_at": now_iso(),
        "sources": sources,
        "models": models,
    }
    OUT_JSON.write_text(json.dumps(out, ensure_ascii=False, indent=2))
    unmatched["summary"] = {k: len(v) for k, v in unmatched.items() if isinstance(v, list)}
    UNMATCHED_JSON.write_text(json.dumps(unmatched, ensure_ascii=False, indent=2))

    print(f"models: {len(models)} | unmatched: arena={len(unmatched['arena'])} swe_bench={len(unmatched['swe_bench'])}")
    print(f"wrote {OUT_JSON} and {UNMATCHED_JSON}")


if __name__ == "__main__":
    main()
