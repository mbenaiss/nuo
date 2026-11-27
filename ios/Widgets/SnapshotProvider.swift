import Foundation
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var botId: String?

    var bot: WidgetBotItem? { snapshot.bot(id: botId) }
}

enum SnapshotLoader {
    static let refreshInterval: TimeInterval = 20 * 60

    /// Fetches bots and conversations; falls back to the last good snapshot (marked offline) when the gateway is unreachable.
    static func load() async -> WidgetSnapshot {
        guard let gateway = WidgetGateway.current() else { return .signedOut }
        do {
            async let bots = gateway.bots()
            async let conversations = gateway.conversations()
            let snapshot = WidgetSnapshot(bots: try await bots, conversations: (try? await conversations) ?? [])
            save(snapshot)
            return snapshot
        } catch WidgetGateway.Failure.unauthorized {
            return .signedOut
        } catch {
            var cached = cache() ?? WidgetSnapshot(status: .offline, bots: [], recents: [], fetchedAt: .now)
            cached.status = .offline
            return cached
        }
    }

    static func timeline(_ entry: SnapshotEntry) -> Timeline<SnapshotEntry> {
        Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(refreshInterval)))
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("widget-snapshot.json")
    }

    private static func save(_ snapshot: WidgetSnapshot) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func cache() -> WidgetSnapshot? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SnapshotEntry) -> Void) {
        if context.isPreview {
            completion(SnapshotEntry(date: .now, snapshot: .demo))
            return
        }
        Task { completion(SnapshotEntry(date: .now, snapshot: await SnapshotLoader.load())) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SnapshotEntry>) -> Void) {
        Task { completion(SnapshotLoader.timeline(SnapshotEntry(date: .now, snapshot: await SnapshotLoader.load()))) }
    }
}

struct BotSnapshotProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .demo, botId: "voyages")
    }

    func snapshot(for configuration: SelectBotIntent, in context: Context) async -> SnapshotEntry {
        if context.isPreview {
            return SnapshotEntry(date: .now, snapshot: .demo, botId: configuration.bot?.id ?? "voyages")
        }
        return SnapshotEntry(date: .now, snapshot: await SnapshotLoader.load(), botId: configuration.bot?.id)
    }

    func timeline(for configuration: SelectBotIntent, in context: Context) async -> Timeline<SnapshotEntry> {
        SnapshotLoader.timeline(SnapshotEntry(date: .now, snapshot: await SnapshotLoader.load(), botId: configuration.bot?.id))
    }
}
