import SwiftUI

// MARK: - Главное окно popover'а

struct ContentView: View {
    @ObservedObject var store: BenchmarksStore
    @State private var filter = ""
    @State private var sortKey: SortKey = .arena
    @State private var sortAsc = false // дефолт: Arena по убыванию

    enum SortKey: String {
        case model, provider, arena, swe, priceIn, priceOut, context

        var title: String {
            switch self {
            case .model: return "Модель"
            case .provider: return "Провайдер"
            case .arena: return "Arena"
            case .swe: return "SWE-bench"
            case .priceIn: return "$/1M in"
            case .priceOut: return "$/1M out"
            case .context: return "Контекст"
            }
        }
    }

    private var rows: [AIModel] {
        var list = store.data?.models ?? []
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q) || ($0.provider ?? "").lowercased().contains(q)
            }
        }
        return sort(list)
    }

    private func sort(_ list: [AIModel]) -> [AIModel] {
        // null-ы всегда в конец; сравнение значений по направлению сортировки
        func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
            switch (a, b) {
            case let (x?, y?):
                if x == y { return .orderedSame }
                let r: ComparisonResult = x < y ? .orderedAscending : .orderedDescending
                return sortAsc ? r : (r == .orderedAscending ? .orderedDescending : .orderedAscending)
            case (nil, nil): return .orderedSame
            case (nil, _?): return .orderedDescending // null в конец
            case (_?, nil): return .orderedAscending
            }
        }
        return list.sorted { a, b in
            let r: ComparisonResult
            switch sortKey {
            case .model:    r = compare(a.name.lowercased(), b.name.lowercased())
            case .provider: r = compare(a.provider?.lowercased(), b.provider?.lowercased())
            case .arena:    r = compare(a.arenaRating, b.arenaRating)
            case .swe:      r = compare(a.sweBenchVerified, b.sweBenchVerified)
            case .priceIn:  r = compare(a.priceInputPerMtok, b.priceInputPerMtok)
            case .priceOut: r = compare(a.priceOutputPerMtok, b.priceOutputPerMtok)
            case .context:  r = compare(a.contextLength, b.contextLength)
            }
            if r == .orderedSame {
                return (a.arenaRating ?? Int.min) > (b.arenaRating ?? Int.min)
            }
            return r == .orderedAscending
        }
    }

    private func tapHeader(_ key: SortKey) {
        if sortKey == key {
            sortAsc.toggle()
        } else {
            sortKey = key
            // текстовые — по возрастанию, числовые — по убыванию
            sortAsc = (key == .model || key == .provider)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(store: store)

            if store.state == .stale {
                StaleBanner(date: store.lastFetchDate)
            }

            TextField("Фильтр: имя или провайдер", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            TableHeader(sortKey: sortKey, sortAsc: sortAsc, onTap: tapHeader)

            Divider()

            if rows.isEmpty && store.state == .empty {
                EmptyStateView(store: store)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { m in
                            ModelRow(model: m)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 420)
            }

            Divider()

            FooterView(store: store)
        }
        .frame(width: 500)
        .background(.regularMaterial)
    }
}

// MARK: - Шапка: заголовок + свежесть источников

struct HeaderView: View {
    @ObservedObject var store: BenchmarksStore

    private func sourceLine(_ key: String, _ label: String) -> (text: String, ok: Bool)? {
        guard let s = store.data?.sources[key] else { return nil }
        let ok = s.ok ?? true
        return ("\(label): \(Format.sourceDate(s.updatedAt))", ok)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("AI Benchmarks")
                    .font(.headline)
                Spacer()
                if store.isFetching {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
                Text(store.data.map { "обновлено: \(Format.fullDate($0.generatedAt))" } ?? "нет данных")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach([("arena", "Arena"), ("swe_bench", "SWE-bench"), ("openrouter", "Цены")], id: \.0) { key, label in
                    if let line = sourceLine(key, label) {
                        Text(line.text)
                            .font(.caption2)
                            .foregroundStyle(line.ok ? Color.secondary : Color.orange)
                            .strikethrough(!line.ok, color: .orange)
                            .help(line.ok ? "Источник «\(label)» актуален" : "Источник «\(label)» недоступен — показаны последние данные")
                        if key != "openrouter" {
                            Text("·").font(.caption2).foregroundStyle(.quaternary)
                        }
                    }
                }
            }
            Text("Данные источников обновляются с задержкой до нескольких недель — показано свежайшее доступное.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Плашка «данные от {дата}» при stale-кэше

struct StaleBanner: View {
    let date: Date?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption2)
            Text("Офлайн — данные от \(date.map { Format.fullDate(ISO8601DateFormatter().string(from: $0)) } ?? "неизвестной даты")")
                .font(.caption2)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }
}

// MARK: - Заголовок таблицы с сортировкой

struct TableHeader: View {
    let sortKey: ContentView.SortKey
    let sortAsc: Bool
    let onTap: (ContentView.SortKey) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.key) { col in
                Button {
                    onTap(col.key)
                } label: {
                    HStack(spacing: 2) {
                        if col.alignment == .trailing { Spacer(minLength: 0) }
                        Text(col.key.title)
                            .font(.caption.weight(sortKey == col.key ? .semibold : .regular))
                            .foregroundStyle(sortKey == col.key ? Color.primary : Color.secondary)
                        if sortKey == col.key {
                            Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        if col.alignment == .leading { Spacer(minLength: 0) }
                    }
                    .frame(width: col.width)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    private var columns: [(key: ContentView.SortKey, width: CGFloat, alignment: Alignment)] {
        [
            (.model, 128, .leading),
            (.provider, 70, .leading),
            (.arena, 52, .trailing),
            (.swe, 66, .trailing),
            (.priceIn, 56, .trailing),
            (.priceOut, 56, .trailing),
            (.context, 52, .trailing),
        ]
    }
}

// MARK: - Строка модели

struct ModelRow: View {
    let model: AIModel

    private func cell(_ value: String?, width: CGFloat, alignment: Alignment = .trailing, mono: Bool = true) -> some View {
        Text(value ?? "—")
            .font(.system(.caption, design: .default))
            .modifier(MonoDigit(mono: mono))
            .foregroundColor(value == nil ? Color.primary.opacity(0.25) : Color.primary)
            .frame(width: width, alignment: alignment)
            .lineLimit(1)
    }

    var body: some View {
        HStack(spacing: 0) {
            cell(model.name, width: 128, alignment: .leading, mono: false)
            cell(model.provider, width: 70, alignment: .leading, mono: false)
            cell(model.arenaRating.map(String.init), width: 52)
            cell(Format.swe(model.sweBenchVerified), width: 66)
            cell(Format.price(model.priceInputPerMtok), width: 56)
            cell(Format.price(model.priceOutputPerMtok), width: 56)
            cell(Format.context(model.contextLength), width: 52)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

struct MonoDigit: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono { content.monospacedDigit() } else { content }
    }
}

// MARK: - Пустое состояние (первый запуск без кэша и сети)

struct EmptyStateView: View {
    @ObservedObject var store: BenchmarksStore

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("Нет данных")
                .font(.headline)
            Text("Не удалось загрузить бенчмарки.\nПроверьте подключение к сети.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(store.isFetching ? "Загрузка…" : "Повторить") {
                Task { await store.refresh() }
            }
            .disabled(store.isFetching)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }
}

// MARK: - Футер

struct FooterView: View {
    @ObservedObject var store: BenchmarksStore

    var body: some View {
        HStack {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh now", systemImage: "arrow.clockwise")
            }
            .disabled(store.isFetching)
            .help("Обновить данные из источника")
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .help("Завершить приложение")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
