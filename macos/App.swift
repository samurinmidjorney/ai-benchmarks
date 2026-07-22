import SwiftUI

@main
struct AIBenchmarksApp: App {
    @StateObject private var store = BenchmarksStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
                .onAppear {
                    // Fetch при запуске (в фоне; UI сразу показывает кэш)
                    Task { await store.refresh() }
                }
        } label: {
            Image(systemName: "chart.bar")
        }
        .menuBarExtraStyle(.window)
    }
}
