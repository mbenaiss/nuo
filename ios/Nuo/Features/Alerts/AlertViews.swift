import SwiftUI

extension AlertDestination {
    var symbol: String {
        switch kind {
        case "conversation", "bot": "bubble.left.and.text.bubble.right"
        case "task": "clock.arrow.circlepath"
        case "reminder": "checklist"
        case "booking": "calendar.badge.clock"
        case "browser": "safari"
        case "settings": "lock.shield"
        case "link": "link"
        default: "bell"
        }
    }
}

struct AlertRow: View {
    let alert: AlertItem
    @Environment(BotsStore.self) private var bots

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.destination.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentInk)
                .frame(width: 32, height: 32)
                .background(Color.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(alert.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(alert.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(Color.text3)
                }
                if !alert.body.isEmpty {
                    Text(alert.body)
                        .font(.subheadline)
                        .foregroundStyle(Color.text2)
                        .lineLimit(4)
                }
                if let bot = alert.botId.flatMap(bots.bot(id:)) {
                    Text(verbatim: "\(bot.config?.emoji ?? "✨") \(bot.config?.name ?? "Bot")")
                        .font(.caption)
                        .foregroundStyle(Color.text3)
                }
            }
            if alert.readAt == nil {
                Circle().fill(Color.accent).frame(width: 8, height: 8).padding(.top, 6)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// One alert in full, with the screen it led to.
struct AlertDetailView: View {
    let alert: AlertItem
    let open: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(alert.title, systemImage: alert.destination.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text(alert.createdAt, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(Color.text2)
                if !alert.body.isEmpty {
                    Text(alert.body)
                        .font(.body)
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                }
                if alert.destination.kind != "home" {
                    Button("Open", systemImage: "arrow.up.forward", action: open)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Color.canvas)
    }
}

#if os(iOS)
/// Every notification the gateway sent, newest first: the ones no chat keeps can be found again here.
struct AlertsView: View {
    @State private var store = AlertsStore.shared
    @State private var confirmDeleteAll = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(store.items) { alert in
                Button {
                    Haptics.tap()
                    Task { await store.markRead(ids: [alert.id]) }
                    dismiss()
                    NotificationRouter.open(NotificationDestination(alert.destination))
                } label: {
                    AlertRow(alert: alert)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.card)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await store.delete(id: alert.id) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .overlay {
            if store.items.isEmpty {
                ContentUnavailableView(
                    store.loadError == nil ? String(localized: "No Alerts") : String(localized: "Alerts Unavailable"), systemImage: "bell.slash",
                    description: Text(store.loadError ?? String(localized: "Notifications sent by the gateway will show up here.")))
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("Actions", systemImage: "ellipsis.circle") {
                    Button("Mark All as Read", systemImage: "checkmark.circle") { Task { await store.markRead() } }
                        .disabled(store.unreadCount == 0)
                    Button("Delete Read Alerts", systemImage: "trash") { Task { await store.deleteAll(readOnly: true) } }
                        .disabled(store.readCount == 0)
                    Button("Delete All", systemImage: "trash.slash", role: .destructive) { confirmDeleteAll = true }
                        .disabled(store.items.isEmpty)
                }
            }
        }
        .confirmationDialog("Delete all alerts?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { Task { await store.deleteAll(readOnly: false) } }
        } message: {
            Text("The history is erased on all your devices.")
        }
        .task { await store.load() }
        .refreshable { await store.load() }
    }
}
#endif
