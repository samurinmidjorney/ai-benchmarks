import Foundation

// MARK: - Хранилище: кэш + фоновая загрузка + таймер 3 часа

@MainActor
final class BenchmarksStore: ObservableObject {
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/samurinmidjorney/ai-benchmarks/main/benchmarks.json")!

    enum State: Equatable {
        case empty          // нет ни кэша, ни данных (первый запуск)
        case fresh          // данные свежие (загружены в этой сессии)
        case stale          // показываем старый кэш (сеть/JSON недоступны)
    }

    @Published private(set) var data: BenchmarksFile?
    @Published private(set) var state: State = .empty
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var isFetching = false

    private var timer: Timer?

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIBenchmarks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("benchmarks.json")
    }

    init() {
        loadCache()
        // Таймер раз в 3 часа
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: Cache

    private func loadCache() {
        guard let raw = try? Data(contentsOf: cacheURL),
              let parsed = try? JSONDecoder().decode(BenchmarksFile.self, from: raw) else {
            state = .empty
            return
        }
        data = parsed
        state = .stale
        lastFetchDate = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
    }

    // MARK: Network

    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            var req = URLRequest(url: Self.remoteURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let (bytes, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let parsed = try JSONDecoder().decode(BenchmarksFile.self, from: bytes)
            try? bytes.write(to: cacheURL, options: .atomic)
            data = parsed
            state = .fresh
            lastFetchDate = Date()
        } catch {
            // Офлайн/битый JSON — остаёмся на кэше (или в пустом состоянии)
            if data != nil {
                state = .stale
            } else {
                state = .empty
            }
        }
    }
}
