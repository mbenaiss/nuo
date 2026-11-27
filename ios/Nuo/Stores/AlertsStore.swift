import Foundation
import Observation

/// The gateway's notification history: what a notification said and where it led, kept after it left the screen.
@MainActor
@Observable
final class AlertsStore {
    static let shared = AlertsStore()

    private(set) var items: [AlertItem] = []
    private(set) var loadError: String?

    var unreadCount: Int { items.count { $0.readAt == nil } }
    var readCount: Int { items.count - unreadCount }

    @ObservationIgnored private var api: (any NuoAPI)?
    @ObservationIgnored private var listener: Task<Void, Never>?

    private init() {}

    func attach(api: any NuoAPI, transport: any LiveTransport) {
        self.api = api
        listener?.cancel()
        let events = transport.events()
        listener = Task { [weak self] in
            for await event in events {
                if case let .alert(alert) = event { self?.insert(alert) }
            }
        }
    }

    func load() async {
        guard let api else { return }
        do {
            items = try await api.alerts()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func markRead(ids: [String]? = nil) async {
        let now = Date()
        let targets = Set(ids ?? items.filter { $0.readAt == nil }.map(\.id))
        guard !targets.isEmpty else { return }
        for index in items.indices where targets.contains(items[index].id) && items[index].readAt == nil {
            items[index].readAt = now
        }
        try? await api?.markAlertsRead(ids: ids)
    }

    func delete(id: String) async {
        items.removeAll { $0.id == id }
        try? await api?.deleteAlert(id: id)
    }

    /// `readOnly`: only the alerts already read, so the unread ones stay.
    func deleteAll(readOnly: Bool) async {
        items = readOnly ? items.unread : []
        try? await api?.deleteAlerts(readOnly: readOnly)
    }

    func insert(_ alert: AlertItem) {
        items.removeAll { $0.id == alert.id }
        items.insert(alert, at: 0)
    }
}
