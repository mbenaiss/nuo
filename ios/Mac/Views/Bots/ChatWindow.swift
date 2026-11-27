import SwiftUI

/// A conversation in its own window (⇧⌘O or the conversation's context menu).
struct ChatWindow: View {
    @State var selection: ChatSelection
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            if let bot = bots.bot(id: selection.botId) {
                ChatPane(selection: selection, bot: bot, session: session, bots: bots, inWindow: true) {
                    selection = ChatSelection(botId: selection.botId)
                }
                .onConversationCreated { selection.conversationId = $0 }
                .id(selection.token)
            } else if loaded && !bots.isLoading {
                missing
            } else {
                ProgressView().task { await load() }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    /// The bot was deleted, or the list could not be fetched: a spinner would turn forever.
    private var missing: some View {
        VStack(spacing: 12) {
            WorkspaceEmptyState(
                symbol: "bubble.left.and.exclamationmark.bubble.right",
                title: bots.loadError == nil ? String(localized: "Bot not found") : String(localized: "Unable to load"),
                message: bots.loadError ?? String(localized: "This bot no longer exists: the conversation can't be opened."))
            HStack {
                Button("Close") { dismiss() }
                Button("Retry") { Task { await load(force: true) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(force: Bool = false) async {
        if force || bots.bots.isEmpty || bots.loadError != nil { await bots.load() }
        loaded = true
    }
}
