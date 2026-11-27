import SwiftUI

/// The gateway's notification history; selecting an alert marks it read and shows it in full.
struct MacAlertsList: View {
    @Environment(MacNavigator.self) private var navigator
    @State private var store = AlertsStore.shared
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.alert) {
            ForEach(store.items) { alert in
                AlertRow(alert: alert)
                    .tag(alert.id)
                    .contextMenu {
                        Button("Open") { NotificationRouter.open(NotificationDestination(alert.destination)) }
                            .disabled(alert.destination.kind == "home")
                        Divider()
                        Button("Delete", role: .destructive) { delete(alert.id) }
                    }
            }
        }
        .onDeleteCommand { if let id = navigator.alert { delete(id) } }
        .overlay {
            if store.items.isEmpty {
                ContentUnavailableView(
                    store.loadError == nil ? String(localized: "No alerts") : String(localized: "Alerts unavailable"), systemImage: "bell.slash",
                    description: Text(store.loadError ?? String(localized: "Notifications sent by the gateway will show up here.")))
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Mark All as Read", systemImage: "checkmark.circle") { Task { await store.markRead() } }
                    .disabled(store.unreadCount == 0)
                    .help("Mark All as Read")
            }
            ToolbarItem {
                Menu("Delete", systemImage: "trash") {
                    Button("Delete Read Alerts") { deleteAll(readOnly: true) }
                        .disabled(store.readCount == 0)
                    Button("Delete All…", role: .destructive) { confirmDeleteAll = true }
                }
                .disabled(store.items.isEmpty)
                .help("Delete alerts")
            }
        }
        .confirmationDialog("Delete all alerts?", isPresented: $confirmDeleteAll) {
            Button("Delete All", role: .destructive) { deleteAll(readOnly: false) }
        } message: {
            Text("The history is erased on all your devices.")
        }
        .onChange(of: navigator.alert) { _, id in
            guard let id else { return }
            Task { await store.markRead(ids: [id]) }
        }
        .task {
            await store.load()
            if navigator.alert == nil { navigator.alert = store.items.first?.id }
        }
    }

    private func delete(_ id: String) {
        navigator.alert = store.items.selection(afterDeleting: [id], selected: navigator.alert)
        Task { await store.delete(id: id) }
    }

    private func deleteAll(readOnly: Bool) {
        let deleted = Set((readOnly ? store.items.filter { $0.readAt != nil } : store.items).map(\.id))
        navigator.alert = store.items.selection(afterDeleting: deleted, selected: navigator.alert)
        Task { await store.deleteAll(readOnly: readOnly) }
    }
}
