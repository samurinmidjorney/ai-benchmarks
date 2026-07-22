import Foundation

// MARK: - Codable-модели строго под схему benchmarks.json (schema_version 1)

struct BenchmarksFile: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let sources: [String: SourceInfo]
    let models: [AIModel]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case sources, models
    }
}

struct SourceInfo: Codable {
    let updatedAt: String?
    let ok: Bool?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case ok
    }
}

struct AIModel: Codable, Identifiable {
    let id: String
    let name: String
    let provider: String?
    let arenaRating: Int?
    let arenaRank: Int?
    let sweBenchVerified: Double?
    let priceInputPerMtok: Double?
    let priceOutputPerMtok: Double?
    let contextLength: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, provider
        case arenaRating = "arena_rating"
        case arenaRank = "arena_rank"
        case sweBenchVerified = "swe_bench_verified"
        case priceInputPerMtok = "price_input_per_mtok"
        case priceOutputPerMtok = "price_output_per_mtok"
        case contextLength = "context_length"
    }
}

// MARK: - Форматирование

enum Format {
    static func context(_ n: Int?) -> String? {
        guard let n = n else { return nil }
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000
            return v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))M" : String(format: "%.1fM", v)
        }
        if n >= 1_000 {
            let v = Double(n) / 1_000
            return v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))K" : String(format: "%.1fK", v)
        }
        return "\(n)"
    }

    static func swe(_ v: Double?) -> String? {
        guard let v = v else { return nil }
        return String(format: "%.1f%%", v * 100)
    }

    static func price(_ v: Double?) -> String? {
        guard let v = v else { return nil }
        return "$" + (v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(format: "%.2f", v))
    }

    /// Русская локализованная дата из "yyyy-MM-dd" (или ISO8601) — «15 июл», «сегодня».
    static func sourceDate(_ s: String?) -> String {
        guard let s = s else { return "—" }
        var date: Date?
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        date = df.date(from: s)
        if date == nil {
            let iso = ISO8601DateFormatter()
            date = iso.date(from: s)
        }
        guard let d = date else { return s }
        if Calendar.current.isDateInToday(d) { return "сегодня" }
        if Calendar.current.isDateInYesterday(d) { return "вчера" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.dateFormat = "d MMM"
        return out.string(from: d)
    }

    static func fullDate(_ s: String?) -> String {
        guard let s = s else { return "—" }
        var date: Date?
        let iso = ISO8601DateFormatter()
        date = iso.date(from: s)
        if date == nil {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            date = df.date(from: s)
        }
        guard let d = date else { return s }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.dateFormat = "d MMMM yyyy, HH:mm"
        return out.string(from: d)
    }
}
