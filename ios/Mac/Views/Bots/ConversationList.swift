import SwiftUI

/// Conversations of one bot, newest first, cached per bot so switching bots is instant.
@MainActor
@Observable
final class ConversationsStore {
    let botId: String
    private(set) var conversations: [Conversation] = []
    private(set) var loaded = false
    private(set) var error: String?
    @ObservationIgnored private var api: (any NuoAPI)?

    init(botId: String) {
        self.botId = botId
        if let cached = WorkspaceCache.shared.memoryValue([Conversation].self, Self.key(botId)) {
            conversations = cached
            loaded = true
        }
    }

    private static func key(_ botId: String) -> String { "conversations.\(botId)" }

    func attach(_ api: any NuoAPI) { self.api = api }

    func load() async {
        guard let api else { return }
        if !loaded, let cached = await WorkspaceCache.shared.value([Conversation].self, Self.key(botId)) {
            conversations = cached
            loaded = true
        }
        do {
            let fresh = try await api.conversations(botId: botId).sorted { $0.updatedAt > $1.updatedAt }
            withAnimation(.snappy(duration: 0.2)) { conversations = fresh }
            error = nil
            WorkspaceCache.shared.store(fresh, Self.key(botId))
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// Gone from the list at once; when the gateway refuses, the list is fetched again so it reappears.
    /// Returns why it failed.
    func delete(_ ids: Set<String>) async -> String? {
        guard let api else { return nil }
        withAnimation(.snappy) { conversations.removeAll { ids.contains($0.id) } }
        var failure: String?
        for id in ids {
            do {
                try await api.deleteConversation(id: id)
            } catch {
                failure = error.localizedDescription
            }
        }
        if failure == nil {
            WorkspaceCache.shared.store(conversations, Self.key(botId))
        } else {
            await load()
        }
        return failure
    }
}

struct ConversationList: View {
    let botId: String
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(MacNavigator.self) private var navigator
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var store: ConversationsStore
    @State private var search = ""
    @State private var showsSchedules = false
    @State private var deleteError: String?

    init(botId: String) {
        self.botId = botId
        _store = State(initialValue: ConversationsStore(botId: botId))
    }

    private var bot: Bot? { bots.bot(id: botId) }

    private var filtered: [Conversation] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.conversations }
        return store.conversations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var groups: [(title: String, items: [Conversation])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Conversation]] = [:]
        for conversation in filtered {
            let date = conversation.updatedAt
            let title: String
            if calendar.isDateInToday(date) { title = String(localized: "Today") }
            else if calendar.isDateInYesterday(date) { title = String(localized: "Yesterday") }
            else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { title = String(localized: "This week") }
            else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 31 { title = String(localized: "This month") }
            else { title = String(localized: "Older") }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(conversation)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        @Bindable var navigator = navigator
        ScrollViewReader { proxy in
            List(selection: selectionBinding) {
                Section {
                    header.listRowSeparator(.hidden).id(Self.top)
                }
                if store.loaded && store.conversations.isEmpty {
                    Text(store.error ?? String(localized: "No conversations yet.")).font(.callout).foregroundStyle(Color.text2)
                } else if !store.loaded {
                    SkeletonRows(count: 6)
                }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { conversation in
                            ConversationRow(conversation: conversation)
                                .tag(conversation.id)
                                .contextMenu { contextMenu(conversation) }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Conversations")
            .searchFocused($searchFocused)
            .onChange(of: navigator.searchFocus) { _, _ in searchFocused = true }
            .sheet(isPresented: $showsSchedules) {
                NavigationStack { SchedulesView(botId: botId) }.frame(minWidth: 560, minHeight: 520)
            }
            .alert("Unable to delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
            // The list stays from one bot to the next: recreating it with its search field made AppKit lay the whole
            // window toolbar out again, chat items included, on every bot opened.
            .onChange(of: botId) {
                store = ConversationsStore(botId: botId)
                search = ""
                showsSchedules = false
                deleteError = nil
                proxy.scrollTo(Self.top, anchor: .top)
            }
            .task(id: LoadKey(botId: botId, refresh: navigator.refreshTick)) {
                store.attach(session.api)
                await store.load()
            }
            .onChange(of: bot?.lastMessageAt) { _, _ in Task { await store.load() } }
        }
    }

    private static let top = "conversation-list-top"

    private struct LoadKey: Equatable {
        let botId: String
        let refresh: Int
    }

    private var selectionBinding: Binding<String?> {
        Binding {
            navigator.chat?.botId == botId ? navigator.chat?.conversationId : nil
        } set: { id in
            guard let id else { return }
            let conversation = store.conversations.first { $0.id == id }
            navigator.chat = ChatSelection(botId: botId, conversationId: id, useDraft: conversation?.useDraft ?? false)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            BotAvatar(config: bot?.config, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(bot?.config?.name ?? String(localized: "Bot")).font(.headline).foregroundStyle(Color.ink)
                if let description = bot?.config?.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(Color.text2).lineLimit(3)
                }
                HStack(spacing: 12) {
                    Button("Edit") { navigator.editor = EditorTarget(botId: botId) }
                    Button("Tasks") { showsSchedules = true }
                    Button("Memory") {
                        navigator.sidebar = .memory
                        navigator.memoryBot = botId
                    }
                }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
                .padding(.top, 3)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func contextMenu(_ conversation: Conversation) -> some View {
        Button("Open in a New Window") {
            openWindow(id: MacWindow.chat, value: ChatSelection(botId: botId, conversationId: conversation.id, useDraft: conversation.useDraft))
        }
        Divider()
        Button("Delete", role: .destructive) {
            if navigator.chat?.conversationId == conversation.id { navigator.newConversation(botId: botId) }
            Task {
                if let failure = await store.delete([conversation.id]) { deleteError = failure }
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(conversation.title.isEmpty ? String(localized: "Conversation") : conversation.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if conversation.useDraft { Badge(text: String(localized: "Draft"), tint: Color.accentInk, fill: Color.accentSoft) }
            }
            HStack(spacing: 8) {
                if let turn = session.turns.badge(for: conversation) {
                    RunningBadge()
                    Text(TurnLabels.short(phase: turn.phase, tool: turn.currentTool, detail: turn.currentToolDetail))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(conversation.updatedAt.relativeLabel).font(.caption).foregroundStyle(.secondary)
                }
                if conversation.context?.fraction != nil {
                    ContextGauge(context: conversation.context, compact: true)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
