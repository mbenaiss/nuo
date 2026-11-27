import SwiftUI

/// ⌘K: one field to jump to a bot, a conversation of any bot, a dashboard, a collection, a doc, a row or a reminder, or to run an action.
/// Local items match instantly; conversations, rows and doc contents come from the gateway search after a short pause.
struct CommandPaletteView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var query = DemoDirector.argument("-demoPaletteQuery") ?? ""
    @State private var highlighted = 0
    @State private var rowHits: [DataSearchHit] = []
    @State private var docHits: [DocSearchHit] = []
    @State private var conversationHits: [ConversationSearchHit] = []
    @FocusState private var focused: Bool
    private let home = FilesHomeStore.shared
    private let reminders = RemindersStore.shared

    struct Item: Identifiable {
        let id: String
        let section: String
        let title: String
        var subtitle: String?
        let icon: Icon
        let action: @MainActor () -> Void

        enum Icon {
            case symbol(String, Color)
            case emoji(String, String?)
        }
    }

    private var items: [Item] {
        let q = ReminderParser.fold(query.trimmingCharacters(in: .whitespaces))
        func matches(_ text: String) -> Bool { q.isEmpty || ReminderParser.fold(text).contains(q) }
        var result: [Item] = []

        for bot in bots.bots where matches(bot.config?.name ?? "") {
            result.append(Item(id: "bot.\(bot.id)", section: String(localized: "Bots"), title: bot.config?.name ?? String(localized: "Bot"), subtitle: String(localized: "New conversation"),
                               icon: .emoji(bot.config?.emoji ?? "✨", bot.config?.color)) {
                navigator.newConversation(botId: bot.id)
            })
        }
        if q.isEmpty { return result + actions(matches) }

        for hit in conversationHits.prefix(8) {
            let bot = bots.bot(id: hit.conversation.botId)
            let snippet = hit.snippet.map(ConversationSearchText.oneLine)
            result.append(Item(id: "conv.\(hit.conversation.id)", section: String(localized: "Conversations"), title: hit.conversation.title,
                               subtitle: [bot?.config?.name, snippet].compactMap { $0 }.joined(separator: " · "),
                               icon: .emoji(bot?.config?.emoji ?? "💬", bot?.config?.color)) {
                navigator.openChat(ChatSelection(botId: hit.conversation.botId, conversationId: hit.conversation.id, useDraft: hit.conversation.useDraft))
            })
        }

        for summary in home.dashboards where matches(summary.title) {
            result.append(Item(id: "dash.\(summary.slug)", section: String(localized: "Dashboards"), title: summary.title, subtitle: summary.description,
                               icon: .emoji(summary.emoji ?? "📊", nil)) {
                navigator.sidebar = .dashboards
                navigator.dashboard = summary.slug
            })
        }
        for collection in home.collections where matches(collection.label) {
            result.append(Item(id: "col.\(collection.id)", section: String(localized: "Collections"), title: collection.label, subtitle: String(localized: "\(collection.count) items"),
                               icon: .emoji(collection.emoji ?? "🗂️", nil)) {
                navigator.sidebar = .collections
                navigator.collection = collection.id
            })
        }
        for hit in rowHits.prefix(8) {
            let collection = home.collection(hit.collection)
            result.append(Item(id: "row.\(hit.collection).\(hit.row.id)", section: String(localized: "Items"), title: hit.row.title,
                               subtitle: collection?.label, icon: .emoji(collection?.emoji ?? "🗂️", nil)) {
                navigator.sidebar = .collections
                navigator.collection = hit.collection
                navigator.pendingRow = hit.row.id
            })
        }
        var docPaths = Set<String>()
        for node in home.docs where node.kind == .file && matches(node.name) {
            docPaths.insert(node.path)
            result.append(docItem(node.path, subtitle: DocNames.folder(of: node.path)))
        }
        for hit in docHits where !docPaths.contains(hit.path) {
            docPaths.insert(hit.path)
            result.append(docItem(hit.path, subtitle: hit.snippet))
        }
        for reminder in reminders.reminders where !reminder.isDone && matches(reminder.title) {
            result.append(Item(id: "rem.\(reminder.id)", section: String(localized: "Reminders"), title: reminder.title,
                               subtitle: reminder.effectiveDate.map(ReminderDateText.full), icon: .symbol("checklist", Color(hex: 0x3B82F6))) {
                navigator.focusReminder(reminder.id)
            })
        }
        return result + actions(matches)
    }

    private func docItem(_ path: String, subtitle: String?) -> Item {
        Item(id: "doc.\(path)", section: String(localized: "Docs"), title: DocNames.display(name: (path as NSString).lastPathComponent), subtitle: subtitle,
             icon: .symbol("doc.text", Color.text2)) {
            navigator.sidebar = .docs
            navigator.doc = path
        }
    }

    private func actions(_ matches: (String) -> Bool) -> [Item] {
        let all: [Item] = [
            Item(id: "act.reminder", section: String(localized: "Actions"), title: String(localized: "New reminder"), icon: .symbol("plus.circle", Color.accent)) {
                navigator.showsQuickEntry = true
            },
            Item(id: "act.today", section: String(localized: "Actions"), title: String(localized: "Today's reminders"), icon: .symbol("star.fill", Color(hex: 0xF5B400))) {
                navigator.sidebar = .reminders(.today)
            },
            Item(id: "act.schedules", section: String(localized: "Actions"), title: String(localized: "Scheduled tasks"), icon: .symbol("clock.arrow.circlepath", Color.text2)) {
                navigator.sidebar = .schedules
            },
            Item(id: "act.memory", section: String(localized: "Actions"), title: String(localized: "Bot memory"), icon: .symbol("brain", Color.text2)) {
                navigator.sidebar = .memory
            },
            Item(id: "act.bot", section: String(localized: "Actions"), title: String(localized: "New bot"), icon: .symbol("plus.square.on.square", Color.text2)) {
                navigator.showsNewBot = true
            },
        ]
        return all.filter { matches($0.title) }
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Bots, conversations, items, docs, reminders…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(list) }
                    .onKeyPress(.downArrow) { move(1, count: list.count) }
                    .onKeyPress(.upArrow) { move(-1, count: list.count) }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || list[index - 1].section != item.section {
                                Text(item.section).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, index == 0 ? 4 : 10).padding(.bottom, 2)
                            }
                            PaletteRow(item: item, highlighted: index == highlighted)
                                .id(item.id)
                                .onTapGesture {
                                    highlighted = index
                                    run(list)
                                }
                        }
                        if list.isEmpty {
                            Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, index in
                    guard list.indices.contains(index) else { return }
                    proxy.scrollTo(list[index].id)
                }
            }
            .frame(height: 380)
            Divider()
            HStack(spacing: 14) {
                Label("open", systemImage: "return")
                Label("navigate", systemImage: "arrow.up.arrow.down")
                Label("close", systemImage: "escape")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
        .frame(width: 620)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                rowHits = []
                docHits = []
                conversationHits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            async let rows = session.api.searchData(text)
            async let docs = session.api.searchDocs(text)
            async let conversations = session.api.searchConversations(text, botId: nil)
            rowHits = (try? await rows) ?? []
            docHits = (try? await docs) ?? []
            conversationHits = (try? await conversations) ?? []
        }
    }

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(highlighted) else { return }
        navigator.pendingPaletteAction = list[highlighted].action
        dismiss()
    }
}

private struct PaletteRow: View {
    let item: CommandPaletteView.Item
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(highlighted ? Color.white.opacity(0.8) : .secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .foregroundStyle(highlighted ? Color.white : Color.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case let .symbol(name, tint):
            Image(systemName: name).foregroundStyle(highlighted ? Color.white : tint)
        case let .emoji(emoji, color):
            Text(emoji).font(.system(size: 14))
                .frame(width: 24, height: 24)
                .background(Color(hexString: color ?? "") ?? Color.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
