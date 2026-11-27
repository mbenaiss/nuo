import SwiftUI

/// Every conversation with every bot, found by its title or by what was said in it.
struct ConversationSearchView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ConversationSearchHit] = []
    /// The query the hits answer: until the search of what is typed comes back, no « nothing found ».
    @State private var answered = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        List {
            ForEach(hits) { hit in
                Button { open(hit) } label: { ConversationHitRow(hit: hit, bot: bots.bots.first { $0.id == hit.conversation.botId }) }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .overlay { placeholder }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Topic, word, name…")
        .searchFocused($focused)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
        .onAppear { focused = true }
        .task(id: trimmed) { await search(trimmed) }
    }

    @ViewBuilder
    private var placeholder: some View {
        if trimmed.count < 2 {
            ContentUnavailableView("Find a Conversation", systemImage: "text.magnifyingglass",
                                   description: Text("Search all your conversations, with all your bots, by title or by what was said."))
        } else if failed {
            ContentUnavailableView("Search Unavailable", systemImage: "wifi.exclamationmark", description: Text("The gateway isn't responding."))
        } else if hits.isEmpty && answered == trimmed {
            ContentUnavailableView("No Conversations", systemImage: "magnifyingglass",
                                   description: Text("No conversation mentions “\(trimmed)”. Try fewer words."))
        }
    }

    private func search(_ text: String) async {
        guard text.count >= 2 else {
            hits = []
            failed = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let found = try await session.api.searchConversations(text, botId: nil)
            guard !Task.isCancelled else { return }
            hits = found
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
        answered = text
    }

    private func open(_ hit: ConversationSearchHit) {
        Haptics.tap()
        focused = false
        dismiss()
        router.openChat(botId: hit.conversation.botId, conversationId: hit.conversation.id)
    }
}

private struct ConversationHitRow: View {
    let hit: ConversationSearchHit
    let bot: Bot?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(bot?.config?.emoji ?? "💬")
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(Color(hexString: bot?.config?.color ?? "") ?? Color.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.conversation.title).font(.body.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                Text(verbatim: "\(bot?.config?.name ?? "Bot") · \(hit.conversation.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                if let snippet = hit.snippet {
                    Text((hit.role == .user ? String(localized: "You: ") : "") + ConversationSearchText.oneLine(snippet))
                        .font(.subheadline).foregroundStyle(Color.text2).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
