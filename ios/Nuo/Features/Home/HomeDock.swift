import SwiftUI

/// Home composer. It never picks a bot on its own: the recipient is tagged explicitly (chip or "@Nom"),
/// and send and voice stay unavailable until then.
struct HomeDock: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router
    @State private var targetId: String?
    @State private var text = ""
    @State private var stash = ""
    @State private var highlight = 0
    @State private var startingVoice = false
    @State private var tags = ToolTagPalette()
    @State private var dictationKey = "home-\(UUID().uuidString)"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let query = pickerQuery {
                BotPalette(bots: matches(query), query: query, highlighted: highlight, onPick: pick)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))))
            } else if let query = tagQuery {
                let toolsStore = MachineToolsStore.shared
                ToolTagPaletteView(
                    tools: toolsStore.matches(query), query: query, highlighted: tags.highlight, config: targetBot?.config,
                    shellBots: bots.bots.filter { $0.config?.permissionPolicy == .auto }, loaded: toolsStore.loaded
                ) { tool in
                    Haptics.selection()
                    text = ToolTag.insert(tool, into: text)
                    focused = true
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))))
            }
            bar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: pickerQuery != nil)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: tagQuery != nil)
        .sensoryFeedback(.impact(weight: .light), trigger: tagQuery != nil) { _, open in open }
        .onChange(of: tagQuery) { _, _ in tags.highlight = 0 }
        .animation(.snappy(duration: 0.25), value: targetId)
        .sensoryFeedback(.impact(weight: .light), trigger: pickerQuery != nil) { _, open in open }
        .onChange(of: text) { _, value in
            highlight = 0
            if pickerQuery == nil, value.hasPrefix("@"), let (bot, rest) = resolve(value) {
                targetId = bot.id
                text = rest
                Haptics.selection()
            }
        }
        .onChange(of: bots.bots.map(\.id)) { _, ids in
            if let targetId, !ids.contains(targetId) { self.targetId = nil }
        }
        .task { await MachineToolsStore.shared.refresh(api: session.api) }
        .task {
            if let id = DemoDirector.dockBot { targetId = id }
            if let draft = DemoDirector.dockDraft {
                text = draft
                focused = true
            }
            if DictationDemo.onHome {
                let text = $text
                await DictationController.shared.start(key: dictationKey, vocabulary: [],
                                                       field: DictationField(read: { text.wrappedValue }, write: { text.wrappedValue = $0 }))
            }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { DictationController.shared.prewarm() }
        }
        .onDisappear {
            DictationController.shared.leave(dictationKey)
        }
    }

    private var dictating: Bool { DictationController.shared.isActive(dictationKey) }

    private var bar: some View {
        VStack(spacing: 6) {
            DictationNoticeLabel(key: dictationKey)
            fieldRow
            if dictating {
                DictationBar(canSend: targetBot != nil) { send() }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassSurface(radius: 32)
        .animation(.snappy(duration: 0.25), value: dictating)
    }

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            recipient
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .focused($focused)
                .foregroundStyle(Color.ink)
                .autocorrectionDisabled(text.hasPrefix("@") || tagQuery != nil)
                .textInputAutocapitalization(text.hasPrefix("@") || tagQuery != nil ? .never : .sentences)
                .frame(minHeight: 48)
                .onKeyPress(.upArrow) { pickerKey({ move(-1) }, tag: { tags.move(-1, text: text) }) }
                .onKeyPress(.downArrow) { pickerKey({ move(1) }, tag: { tags.move(1, text: text) }) }
                .onKeyPress(.tab) { pickerKey(pickHighlighted, tag: pickTag) }
                .onKeyPress(.return) { pickerKey(pickHighlighted, tag: pickTag) }
                .onKeyPress(.escape) { pickerKey({ text = stash; stash = "" }, tag: { text = String(text.dropLast((tagQuery?.count ?? 0) + 1)) }) }
            if !dictating {
                DictationButton(key: dictationKey, text: $text, vocabulary: [targetBot?.config?.name ?? ""], size: 30, compact: true,
                                finishesOnDisappear: false)
                    .padding(.bottom, 9)
                    .transition(.opacity)
                trailing
            }
        }
    }

    @ViewBuilder
    private var recipient: some View {
        if let bot = targetBot {
            Menu {
                Button(action: openPicker) { Label("Change Bot", systemImage: "arrow.left.arrow.right") }
                Button(role: .destructive) {
                    Haptics.selection()
                    targetId = nil
                } label: { Label("Remove", systemImage: "xmark") }
            } label: {
                HStack(spacing: 6) {
                    Text(bot.config?.emoji ?? "✨").font(.system(size: 18))
                    Text(bot.config?.name ?? "Bot").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.55)
                }
                .foregroundStyle(Color(hex: 0x16161A))
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .frame(height: 40)
                .background(Color(hexString: bot.config?.color ?? "") ?? Color.chip, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.08)))
                .fixedSize()
            }
            .padding(.bottom, 4)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            .accessibilityLabel(String(localized: "Recipient: \(bot.config?.name ?? "bot"). Change or remove"))
        } else {
            Button(action: openPicker) {
                Text(verbatim: "@")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(pickerQuery != nil ? Color.onInk : Color.text2)
                    .frame(width: 40, height: 40)
                    .background(pickerQuery != nil ? Color.inkFill : Color.clear, in: Circle())
                    .overlay(Circle().strokeBorder(Color.text3.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).opacity(pickerQuery != nil ? 0 : 1))
            }
            .buttonStyle(PressableStyle())
            .padding(.bottom, 4)
            .accessibilityLabel("Choose a bot")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if !messageText.isEmpty && pickerQuery == nil {
            RoundIconButton(symbol: "arrow.up", size: 48, label: String(localized: "Send")) { send() }
                .disabled(targetBot == nil)
                .opacity(targetBot == nil ? 0.35 : 1)
        } else {
            Button {
                if targetBot == nil { openPicker() } else { Task { await startVoice() } }
            } label: {
                ZStack {
                    Circle().fill(Color.inkFill)
                    if startingVoice { ProgressView().tint(Color.onInk) } else { VoiceGlyph(size: 20) }
                }
                .frame(width: 48, height: 48)
                .opacity(targetBot == nil ? 0.35 : 1)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(targetBot == nil ? String(localized: "Voice mode: choose a bot first") : String(localized: "Voice mode"))
            .disabled(startingVoice)
        }
    }

    // MARK: - State

    private var targetBot: Bot? { targetId.flatMap { bots.bot(id: $0) } }
    private var messageText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var placeholder: String {
        guard let bot = targetBot else { return bots.bots.isEmpty ? String(localized: "Create a bot first") : String(localized: "@ to choose a bot…") }
        return String(localized: "Message \(bot.config?.name ?? String(localized: "your bot"))…")
    }

    private var pickerQuery: String? {
        guard text.hasPrefix("@"), !text.contains(where: \.isWhitespace) else { return nil }
        return String(text.dropFirst()).lowercased()
    }

    private func matches(_ query: String) -> [Bot] {
        let all = bots.bots
        guard !query.isEmpty else { return all }
        func name(_ bot: Bot) -> String { (bot.config?.name ?? "").lowercased().folding(options: .diacriticInsensitive, locale: nil) }
        let folded = query.folding(options: .diacriticInsensitive, locale: nil)
        let prefix = all.filter { name($0).hasPrefix(folded) }
        let other = all.filter { !name($0).hasPrefix(folded) && (name($0).contains(folded) || ($0.config?.description ?? "").lowercased().contains(folded)) }
        return prefix + other
    }

    /// "@Nom message" → the bot named exactly `Nom` (longest name first, so "Coach perso" beats "Coach").
    private func resolve(_ value: String) -> (Bot, String)? {
        let body = value.dropFirst()
        let candidates = bots.bots.compactMap { bot in bot.config.map { (bot, $0.name) } }.sorted { $0.1.count > $1.1.count }
        for (bot, name) in candidates where !name.isEmpty {
            guard body.lowercased().hasPrefix(name.lowercased()) else { continue }
            let rest = body.dropFirst(name.count)
            guard let first = rest.first, first.isWhitespace else { continue }
            return (bot, rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func openPicker() {
        Haptics.selection()
        if !text.hasPrefix("@") {
            stash = text
            text = "@"
        }
        focused = true
    }

    private func pick(_ bot: Bot) {
        Haptics.selection()
        targetId = bot.id
        text = stash
        stash = ""
        focused = true
    }

    private func move(_ delta: Int) {
        let count = matches(pickerQuery ?? "").count
        guard count > 0 else { return }
        highlight = (highlight + delta + count) % count
    }

    private func pickHighlighted() {
        let list = matches(pickerQuery ?? "")
        guard !list.isEmpty else { return }
        pick(list[min(highlight, list.count - 1)])
    }

    private var tagQuery: String? { pickerQuery == nil ? ToolTag.query(in: text) : nil }

    private func pickerKey(_ action: () -> Void, tag: () -> Void) -> KeyPress.Result {
        if pickerQuery != nil {
            action()
            return .handled
        }
        guard tagQuery != nil else { return .ignored }
        tag()
        return .handled
    }

    private func pickTag() {
        if let value = tags.pickHighlighted(in: text) { text = value }
    }

    private func send() {
        guard let bot = targetBot, !messageText.isEmpty else { return }
        Haptics.send()
        let prompt = messageText
        text = ""
        focused = false
        Task {
            // Like a messaging app, a message to a bot continues its latest conversation.
            let latest = try? await session.api.conversations(botId: bot.id).first
            router.path.append(.chat(ChatTarget(botId: bot.id, conversationId: latest?.id, initialPrompt: prompt)))
        }
    }

    private func startVoice() async {
        guard let bot = targetBot else { return }
        Haptics.send()
        startingVoice = true
        defer { startingVoice = false }
        do {
            let conversation = try await session.api.createConversation(botId: bot.id, useDraft: false)
            router.voice = VoiceTarget(bot: bot, conversationId: conversation.id)
        } catch {
            Haptics.error()
        }
    }
}

private struct BotPalette: View {
    let bots: [Bot]
    let query: String
    let highlighted: Int
    let onPick: (Bot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send to")
                .font(.caption.weight(.bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.text3)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if bots.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.text2)
                        .frame(width: 38, height: 38)
                        .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(query.isEmpty ? String(localized: "No bots") : String(localized: "No bot “\(query)”")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                        Text("Check the name or create a bot from the home screen.").font(.caption).foregroundStyle(Color.text2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                            Button { onPick(bot) } label: { row(bot, highlighted: index == highlighted) }
                                .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: min(CGFloat(bots.count) * 60 + 8, 300))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: 24)
        .animation(.snappy(duration: 0.22), value: bots.map(\.id))
    }

    private func row(_ bot: Bot, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            BotAvatar(config: bot.config, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                name(bot.config?.name ?? "Bot")
                Text(bot.config?.description ?? "").font(.footnote).foregroundStyle(Color.text2).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "return")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.text3)
                .opacity(highlighted ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.card.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }

    private func name(_ value: String) -> Text {
        let matched = !query.isEmpty && value.lowercased().hasPrefix(query) ? String(value.prefix(query.count)) : ""
        let head = Text(matched).foregroundStyle(Color.accent)
        let tail = Text(String(value.dropFirst(matched.count))).foregroundStyle(Color.ink)
        return Text("\(head)\(tail)").font(.subheadline.weight(.semibold))
    }
}
