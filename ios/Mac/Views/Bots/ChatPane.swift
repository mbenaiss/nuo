import SwiftUI
import UniformTypeIdentifiers

/// One conversation: transcript with streaming answers and cards, composer, slash and # palettes.
struct ChatPane: View {
    @State private var store: ConversationStore
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @State private var tags = ToolTagPalette()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var nearBottom = true
    /// Whether new content keeps the end on screen: dropped only when the reader scrolls up, not when an answer grows
    /// faster than the transcript follows it.
    @State private var follow = TranscriptFollow()
    @State private var scroll = TranscriptScrollTracking()
    /// Code blocks and pasted texts the reader asked to see in full, by `TranscriptRows` key.
    @State private var expansions: Set<String> = []
    @State private var codeOffsets = CodeScrollOffsets()
    @State private var showsContext = false
    @State private var showsSubagents = false
    @State private var dropTargeted = false
    /// The composer is an AppKit text view, outside the SwiftUI focus system: it reports and takes focus through this.
    @State private var composerFocused = false
    var inWindow = false
    var onNewConversation: (() -> Void)?
    private var conversationCreated: ((String) -> Void)?
    /// The pane is rebuilt for every selection, so its composer state lives here between two visits.
    @MainActor private static var stash = ConversationStash<ComposerState>(capacity: 24)

    init(selection: ChatSelection, bot: Bot, session: SessionStore, bots: BotsStore, inWindow: Bool = false, onNewConversation: (() -> Void)? = nil) {
        _store = State(initialValue: ConversationStore(
            bot: bot, conversationId: selection.conversationId, useDraft: selection.useDraft, session: session, bots: bots))
        self.inWindow = inWindow
        self.onNewConversation = onNewConversation
    }

    private static func stashKey(_ store: ConversationStore) -> String {
        ConversationStash<ComposerState>.key(conversationId: store.conversation?.id, botId: store.bot.id)
    }

    /// Taken, not read: two panes on one conversation (main window and its own window) must not both send a
    /// restored queue. Done on appear because `init` also runs for every re-render of the parent.
    private func restoreStash() {
        guard let saved = Self.stash.take(Self.stashKey(store)), store.composerState.isEmpty else { return }
        store.restore(saved)
    }

    private func saveStash() {
        let state = store.composerState
        guard !state.isEmpty else { return }
        Self.stash.put(state, for: Self.stashKey(store))
    }

    var body: some View {
        lifecycle
            .onChange(of: store.messages.count) { old, new in
                // A conversation that loads (or reloads many messages) opens on its end at once, like a new message would.
                if old == 0 || new - old > 1 {
                    jumpToBottom()
                } else if let last = store.messages.last, last.role == .user {
                    follow.returnToEnd()
                    // An animated scroll over a long message stops on the rows' estimated heights, short of the end.
                    if last.text.utf8.count > 2_000 {
                        jumpToBottom()
                    } else {
                        animateToBottom()
                    }
                } else if follow.following {
                    animateToBottom()
                }
            }
            .onChange(of: store.messages.last?.text.utf8.count) { _, _ in
                if follow.following && store.isRunning { position.scrollTo(id: transcriptEnd, anchor: .bottom) }
            }
            // The finished answer lays out once more (cards, the work summary): the end moves after the last delta.
            .onChange(of: store.isRunning) { _, running in
                if !running && follow.following { jumpToBottom() }
            }
            // Messages already in memory (a chat reopened) never go through the count change above.
            .onAppear { if !store.messages.isEmpty { jumpToBottom() } }
    }

    private var framed: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatPaneBottomBar(
                    store: store, tags: tags, composerFocused: $composerFocused, nearBottom: nearBottom,
                    onScrollToBottom: jumpToBottom)
            }
            .background(Color.canvas)
            .navigationTitle(store.config?.name ?? String(localized: "Bot"))
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .hostsFullPages()
            .environment(\.openSubagents, SubagentsOpener { showsSubagents = true })
            .environment(\.sendCardPrompt, CardPromptSender { prompt in store.send(prompt: prompt) })
            .environment(\.cardBotName, store.config?.name)
    }

    private var interactive: some View {
        framed
            .sheet(item: $store.pendingPermission) { prompt in
                MacPermissionSheet(prompt: prompt, botName: store.config?.name ?? String(localized: "The bot")) { store.answerPermission($0) }
            }
            .onDrop(of: [.image, .fileURL, .plainText], isTargeted: $dropTargeted) { providers in
                attach(providers)
                return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: store.localCommand) { _, command in
                guard let command else { return }
                store.localCommand = nil
                handle(command)
            }
    }

    private var lifecycle: some View {
        interactive
            .onAppear {
                restoreStash()
                // What a left conversation still gives back (a send that failed, the dictation's final text) goes to
                // the stash, which the next visit restores, instead of a store nobody shows.
                store.onDetachedChange = { [weak store] change in
                    guard let store else { return }
                    let key = Self.stashKey(store)
                    var state = Self.stash.take(key) ?? ComposerState()
                    state.apply(change)
                    Self.stash.put(state, for: key)
                }
                store.start()
                composerFocused = true
                #if DEBUG
                DemoChatTest.store = store
                #endif
            }
            .onDisappear {
                store.stop()
                saveStash()
            }
            .onChange(of: ObjectIdentifier(session.transport as AnyObject)) { _, _ in store.resubscribeIfTransportChanged() }
            .onChange(of: bots.bot(id: store.bot.id)) { _, bot in
                if let bot { store.update(bot: bot) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                session.handleScenePhase(active: true)
                Task { await store.reload() }
            }
            .onChange(of: store.conversation?.id) { old, new in
                if old == nil, let new { conversationCreated?(new) }
            }
            .task { await MachineToolsStore.shared.refresh(api: session.api) }
    }

    func onConversationCreated(_ action: @escaping (String) -> Void) -> ChatPane {
        var copy = self
        copy.conversationCreated = action
        return copy
    }

    private var subtitle: String {
        var parts = [store.brainLabel]
        if store.modelInfo?.efforts?.isEmpty == false { parts.append(Effort.label(store.effort)) }
        if store.useDraft { parts.append(String(localized: "Draft")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Transcript

    /// No animated scroll over a long conversation: it builds every lazy row on the way down. Rows measured while
    /// jumping change the content height, so a second jump lands exactly on the end.
    private let transcriptEnd = "transcript-end"

    /// One action for the pane's lifetime: a new one on each update would re-render every message.
    private static let openFiles = OpenURLAction { url in
        guard url.isFileURL else { return .systemAction }
        NSWorkspace.shared.open(url)
        return .handled
    }

    private func jumpToBottom() {
        scroll.corrections = 0
        scrollToEnd()
    }

    private func scrollToEnd() {
        scroll.jumpedAt = .now
        moveToEnd()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            scroll.jumpedAt = .now
            moveToEnd()
        }
    }

    /// Sets the offset on the AppKit scroll view: SwiftUI's scroll to the end marker now and then did nothing once
    /// the marker was out of the lazy stack, and when it did, rested a fraction of a point short of the content's
    /// edge, where the scroll view no longer keeps the end on screen as the content grows.
    private func moveToEnd() {
        guard let scrollView = scroll.anchor?.enclosingScrollView, let edge = scroll.edge else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { position.scrollTo(id: transcriptEnd, anchor: .bottom) }
            return
        }
        let clip = scrollView.contentView
        let offsetY = scroll.end.endOffset(for: edge)
        guard abs(clip.bounds.minY - offsetY) > 0.01 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: offsetY))
        scrollView.reflectScrolledClipView(clip)
    }

    private func animateToBottom() {
        scroll.animatedScrollEnds = .now + .milliseconds(350)
        withAnimation(.smooth(duration: 0.3)) { position.scrollTo(id: transcriptEnd, anchor: .bottom) }
    }

    /// Puts the transcript back on its end, as laid out, once the layout pass is over: it reports several transient
    /// geometries. The scroll view only keeps the end in place as the window or the bottom bar changes height when it
    /// rests exactly on it, and a jump over rows of estimated height can land short of it.
    private func settleScroll() {
        guard !scroll.settlePending else { return }
        scroll.settlePending = true
        Task { @MainActor in
            scroll.settlePending = false
            guard let edge = scroll.edge, !scroll.readerScrolling, ContinuousClock.Instant.now >= scroll.animatedScrollEnds else { return }
            guard follow.settled(on: edge, end: scroll.end) else {
                scroll.corrections = 0
                return
            }
            // Rows measured on the way change the end again; past a few jumps the layout is not settling.
            guard scroll.corrections < TranscriptScrollTracking.maxCorrections else { return }
            scroll.corrections += 1
            scrollToEnd()
        }
    }

    private func trackScroll(from old: TranscriptEdge, to new: TranscriptEdge) {
        scroll.edge = new
        if new.containerHeight != old.containerHeight || new.contentHeight != old.contentHeight { scroll.layoutMovedAt = .now }
        let layoutMoving = scroll.layoutMoving
        updateNearBottom()
        if scroll.end.isNearEnd(new) {
            if !follow.following { follow.returnToEnd() }
        } else if new.offsetY < old.offsetY - 1, follow.following, scroll.readerScrolling || !layoutMoving {
            // Measured on the offset, not the visible rect: a shorter window or a taller bar lowers the bottom of the
            // visible rect without the reader moving.
            follow.readerScrolled(to: new, end: scroll.end)
        }
        if layoutMoving { settleScroll() }
    }

    /// The end marker laid out somewhere else: rows above it measured, an answer grown, the window resized.
    private func endLaidOut(at maxY: CGFloat?) {
        guard scroll.end.maxY != maxY else { return }
        scroll.end.maxY = maxY
        scroll.layoutMovedAt = .now
        updateNearBottom()
        settleScroll()
    }

    private func updateNearBottom() {
        guard let edge = scroll.edge else { return }
        let near = scroll.end.isNearEnd(edge)
        if nearBottom != near { nearBottom = near }
    }

    private var transcriptItems: [TranscriptItem] {
        let compacting = store.isCompacting
        let live = store.liveMessageId
        return scroll.rows.items(for: store.messages.withoutTaskPrompts, liveMessageId: live, expanded: expansions) { message in
            message.notice != nil || (compacting && message.id == live && message.text.isEmpty)
        }
    }

    private var transcript: some View {
        GeometryReader { viewport in
            transcriptScroll(minHeight: viewport.size.height)
        }
    }

    private func transcriptScroll(minHeight: CGFloat) -> some View {
        ScrollView {
            transcriptContent
                // A short transcript fills the viewport and sits on the composer; shorter content would also make
                // the toolbar's scroll edge reach down to the first message and draw its rule mid-pane.
                .frame(minHeight: minHeight, alignment: .bottom)
                .coordinateSpace(.named(Self.contentSpace))
        }
        .scrollPosition($position)
        .environment(\.localFileLinker, LocalFileLinks.shared.linker(preferred: store.folder?.path))
        .environment(\.openURL, Self.openFiles)
        .modifier(MacTranscriptParts(expansions: $expansions, codeOffsets: codeOffsets))
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: TranscriptEdge.self) { TranscriptEdge($0) } action: { old, new in
            trackScroll(from: old, to: new)
        }
        .onScrollPhaseChange { _, phase in scroll.phase = phase }
        .transcriptProbe()
    }

    private static let contentSpace = "transcript-content"

    /// Each message in rows about a screen tall: a lazy stack scrolled to its end over rows several screens tall settles
    /// on estimated heights its rows never match, mid-answer or on an empty area.
    private var transcriptContent: some View {
        let answerLabels = store.answerLabels
        let replies = store.replies
        let gap = TranscriptJoint.message.spacing
        return LazyVStack(alignment: .leading, spacing: 0) {
            if store.messages.isEmpty && !store.isLoading {
                MacEmptyChat(store: store).padding(.top, 90)
            }
            ForEach(transcriptItems) { item in
                MacTranscriptRow(item: item, store: store, answeredBy: answerLabels[item.message.id], reply: replies[item.message.id])
                    .padding(.top, item.row.joint.spacing)
            }
            if store.isCompacting && store.liveMessageId == nil {
                CompactingChip().padding(.top, gap)
            } else if store.isRunning && store.liveMessageId == nil {
                WorkRow(steps: [], thoughts: nil, durationMs: nil, isLive: true, startedAt: store.turnStartedAt ?? Date())
                    .padding(.top, gap)
            }
            if store.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, store.messages.isEmpty ? 40 : 40 + gap)
            }
            // The end of the transcript as a real view: scrolling to the content's edge uses the lazy rows' estimated
            // heights and could stop past the last message, on an empty area. It also closes the content, with no
            // padding under it: a scroll that stops short of the edge is no longer held there by the bottom anchor,
            // and a window resized then left the end of the answer under the composer.
            Color.clear.frame(height: 13).padding(.top, gap).id(transcriptEnd)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.contentSpace)).maxY } action: { endLaidOut(at: $0) }
                .onDisappear { endLaidOut(at: nil) }
                .transcriptEndProbe()
        }
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .textSelection(.enabled)
        .background(EnclosingScrollAnchor { scroll.anchor = $0 })
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showsContext.toggle() } label: {
                ContextGauge(context: store.context, compact: true)
            }
            .help("Conversation context")
            .popover(isPresented: $showsContext, arrowEdge: .bottom) {
                ContextSheet(context: store.context, modelLabel: store.modelLabel, isRunning: store.isRunning) {
                    showsContext = false
                    store.compact()
                }
                .frame(width: 380, height: 420)
            }
            MacModelMenu(store: store)
            Button { showsSubagents = true } label: { Label("Subagents", systemImage: "person.2.wave.2") }
                .help("Subagents in this conversation")
                .sheet(isPresented: $showsSubagents) {
                    SubagentsView(store: store).frame(minWidth: 520, minHeight: 480)
                }
            Button { openWindow(id: MacWindow.browser) } label: { Label("Browser", systemImage: "safari") }
                .help("The browser where this bot uses your signed-in sites")
            if let onNewConversation {
                Button(action: onNewConversation) { Label("New Conversation", systemImage: "square.and.pencil") }
                    .help("New conversation (⌘N)")
            }
            if !inWindow, let id = store.conversation?.id {
                Button {
                    openWindow(id: MacWindow.chat, value: ChatSelection(botId: store.bot.id, conversationId: id, useDraft: store.useDraft))
                } label: { Label("Open in a Window", systemImage: "macwindow.on.rectangle") }
                    .help("Open in a new window (⇧⌘O)")
            }
        }
    }

    private func handle(_ command: LocalCommand) {
        switch command {
        case let .open(url):
            openURL(url)
        case .newConversation:
            onNewConversation?()
        case .voice, .barcode:
            store.dismissError()
        }
    }

    /// Files and images are attached; text dropped on the chat goes into the draft, since the composer itself leaves
    /// drops to this zone.
    private func attach(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in await MacAttachmentIntake.add([url], to: store) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // An image dragged from a web page also carries its http URL, which is not a file to read.
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await MacAttachmentIntake.add(imageData: data, to: store) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in
                        store.draft += store.draft.isEmpty || store.draft.hasSuffix("\n") || store.draft.hasSuffix(" ") ? text : " " + text
                        composerFocused = true
                    }
                }
            }
        }
    }
}

/// The transcript's last geometry and scroll phase change every frame while scrolling: kept out of the view's state so
/// that the conversation does not re-render for them.
@MainActor private final class TranscriptScrollTracking {
    var edge: TranscriptEdge?
    var end = TranscriptEndMark()
    /// A view inside the transcript's AppKit scroll view, which SwiftUI does not expose.
    weak var anchor: NSView?
    var phase = ScrollPhase.idle
    var settlePending = false
    var layoutMovedAt = ContinuousClock.Instant.now - .seconds(1)
    var jumpedAt = ContinuousClock.Instant.now - .seconds(1)
    /// Jumps to the end since the last one asked for or the last landing on it.
    var corrections = 0
    /// The animated scroll to a message just sent reports no scroll phase on the Mac.
    var animatedScrollEnds = ContinuousClock.Instant.now
    let rows = TranscriptRowCache()

    static let maxCorrections = 8

    var readerScrolling: Bool { phase == .tracking || phase == .interacting || phase == .decelerating }

    /// The layout or a jump to the end moved the transcript: an offset changing now is not the reader's doing.
    var layoutMoving: Bool {
        let now = ContinuousClock.Instant.now
        return now - layoutMovedAt < .milliseconds(250) || now - jumpedAt < .milliseconds(250)
    }
}

private struct EnclosingScrollAnchor: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        found(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// One row of the transcript: a slice of a user's bubble, part of an answer, or a notice.
private struct MacTranscriptRow: View {
    let item: TranscriptItem
    let store: ConversationStore
    let answeredBy: String?
    let reply: String?

    var body: some View {
        let message = item.message
        switch item.row.content {
        case let .user(slice):
            VStack(alignment: .trailing, spacing: 4) {
                UserBubble(message: message, slice: slice)
                if slice.isLast, let outgoing = store.outgoing, outgoing.messageId == message.id {
                    OutgoingStatus(sent: outgoing.sent)
                }
            }
        case let .assistant(part):
            AssistantMessageView(
                message: message, isLive: message.id == store.liveMessageId, startedAt: store.turnStartedAt,
                answeredBy: answeredBy, reply: reply, canAnswer: reply == nil && !store.isRunning, part: part)
        case .whole:
            if let notice = message.notice {
                NoticeChip(payload: notice).padding(.vertical, 6)
            } else {
                CompactingChip()
            }
        }
    }
}

/// Lets the transcript's rows expand a code block or a pasted text, and scroll a code block's slices together.
private struct MacTranscriptParts: ViewModifier {
    @Binding var expansions: Set<String>
    let codeOffsets: CodeScrollOffsets

    func body(content: Content) -> some View {
        content
            .environment(\.expandTranscriptPart, TranscriptExpander { key in expansions.insert(key) })
            .environment(\.codeScrollOffsets, codeOffsets)
    }
}

private extension TranscriptJoint {
    var spacing: CGFloat {
        switch self {
        case .start, .flush: 0
        case .message: 18
        case .block: 10
        case .line: TextMetrics.lineSpacing
        case .listItem: TextMetrics.listItemGap
        }
    }
}

struct MacModelMenu: View {
    let store: ConversationStore

    var body: some View {
        Menu {
            if store.switchableAgents.count > 1, let current = store.agentID {
                Picker("Agent", selection: Binding(get: { current }, set: { store.selectAgent($0) })) {
                    ForEach(store.switchableAgents) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
            if let models = store.agent?.models, !models.isEmpty {
                Picker("Model", selection: Binding(get: { store.model ?? "" }, set: { store.selectModel($0) })) {
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                if let efforts = store.modelInfo?.efforts, !efforts.isEmpty {
                    Picker("Effort", selection: Binding(get: { store.effort ?? "" }, set: { store.selectEffort($0) })) {
                        ForEach(efforts, id: \.self) { Text(Effort.label($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            } else {
                Text("No other model available")
            }
            Picker("Permissions", selection: Binding(get: { store.permissionPolicy }, set: { store.selectPermissions($0) })) {
                ForEach(PermissionPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(store.brainLabel, systemImage: "cpu")
        }
        .help("Agent, model, effort and permissions")
    }
}

private struct MacEmptyChat: View {
    let store: ConversationStore

    var body: some View {
        VStack(spacing: 14) {
            BotAvatar(config: store.config, size: 76)
            Text(store.config?.name ?? String(localized: "Bot")).font(.title.bold()).foregroundStyle(Color.ink)
            if let description = store.config?.description, !description.isEmpty {
                Text(description).font(.body).foregroundStyle(Color.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if !store.commands.isEmpty {
                HStack(spacing: 8) {
                    ForEach(store.commands.prefix(4)) { command in
                        Button("/\(command.name)") { store.draft = "/\(command.name)\(command.takesArgs ? " " : "")" }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(command.description)
                    }
                }
                .padding(.top, 4)
            }
            if store.useDraft {
                Text("You're testing the draft: unpublished changes are active in this conversation.")
                    .font(.callout)
                    .foregroundStyle(Color.accentInk)
                    .padding(12)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct MacErrorBanner: View {
    let message: String
    var onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.bad)
            Text(message).font(.callout).foregroundStyle(Color.ink).lineLimit(3)
            Spacer(minLength: 4)
            if let onRetry {
                Button("Retry", action: onRetry).controlSize(.small)
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.bad.opacity(0.3)))
    }
}

struct MacPermissionSheet: View {
    let prompt: PermissionPrompt
    let botName: String
    let onAnswer: (PermissionOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accent)
                    .frame(width: 46, height: 46)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(botName) is asking for permission").font(.callout).foregroundStyle(Color.text2)
                    Text(prompt.title).font(.headline).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                ForEach(rejects) { option in
                    Button(option.name, role: .destructive) { onAnswer(option) }
                }
                Spacer()
                ForEach(allows) { option in
                    if option.kind == "allow_once" {
                        Button(option.name) { onAnswer(option) }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(option.name) { onAnswer(option) }
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    private var allows: [PermissionOption] { prompt.options.filter { !$0.kind.hasPrefix("reject") }.sorted { $0.kind < $1.kind } }
    private var rejects: [PermissionOption] { prompt.options.filter { $0.kind.hasPrefix("reject") } }
}

/// Palettes, status and composer under the transcript. Its own view so that typing, which only changes the draft,
/// re-renders this bar and not the whole transcript.
private struct ChatPaneBottomBar: View {
    let store: ConversationStore
    let tags: ToolTagPalette
    var composerFocused: Binding<Bool>
    let nearBottom: Bool
    let onScrollToBottom: () -> Void
    @Environment(BotsStore.self) private var bots
    @State private var turnFinishedAt: Date?

    var body: some View {
        VStack(spacing: 8) {
            if let error = store.errorMessage {
                MacErrorBanner(message: error, onRetry: store.canRetry ? { store.retry() } : nil, onDismiss: { store.dismissError() })
            }
            if paletteVisible {
                CommandPalette(commands: store.paletteMatches, query: store.paletteQuery ?? "", hasCommands: true,
                               highlighted: store.paletteHighlight) { command in
                    store.pick(command)
                    composerFocused.wrappedValue = true
                }
                .frame(maxHeight: 300)
                .paletteProbe("slash")
            } else if let query = tagQuery {
                let toolsStore = MachineToolsStore.shared
                ToolTagPaletteView(
                    tools: toolsStore.matches(query), query: query, highlighted: tags.highlight, config: store.config,
                    shellBots: bots.bots.filter { $0.config?.permissionPolicy == .auto }, loaded: toolsStore.loaded
                ) { tool in
                    store.draft = ToolTag.insert(tool, into: store.draft)
                    composerFocused.wrappedValue = true
                }
                .frame(maxHeight: 300)
                .paletteProbe("tag")
            } else if let command = store.typedCommand {
                CommandArgsHint(command: command).frame(maxWidth: .infinity, alignment: .leading)
            }
            TurnStatusArea(
                botName: store.config?.name ?? String(localized: "The bot"), phase: store.turnPhase, tool: store.currentTool,
                toolDetail: store.currentToolDetail, steps: store.stepCount, startedAt: store.turnStartedAt, finished: turnFinishedAt != nil,
                hidden: paletteVisible || tagQuery != nil)
            MacComposer(store: store, focused: composerFocused, tags: tags)
        }
        // Floats above the bar instead of sitting in it: the bar's height moves the transcript, which flips
        // `nearBottom`, so a button inside it made a growing composer loop on layout and freeze the app.
        .overlay(alignment: .top) {
            if !nearBottom && !paletteVisible && tagQuery == nil {
                Button {
                    onScrollToBottom()
                } label: {
                    Image(systemName: "arrow.down").font(.subheadline.weight(.bold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("Scroll to bottom")
                .offset(y: -38)
            }
        }
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
        .animation(.snappy(duration: 0.25), value: paletteVisible)
        .animation(.snappy(duration: 0.25), value: tagQuery != nil)
        .animation(.snappy, value: store.errorMessage)
        .animation(.snappy(duration: 0.25), value: store.turnPhase != nil)
        .turnDoneBeat($turnFinishedAt, running: store.turnPhase != nil, failed: store.errorMessage != nil)
        .onChange(of: tagQuery) { _, _ in tags.highlight = 0 }
    }

    private var paletteVisible: Bool { store.paletteQuery != nil }
    private var tagQuery: String? { paletteVisible ? nil : ToolTag.query(in: store.draft) }
}

private extension View {
    /// Debug builds report the height a palette takes on screen: its glass does not draw in window snapshots.
    @ViewBuilder func paletteProbe(_ name: String) -> some View {
        #if DEBUG
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { DemoChatTest.palettes[name] = $0 }
            .onDisappear { DemoChatTest.palettes[name] = 0 }
        #else
        self
        #endif
    }

    /// Debug builds report where the transcript's end marker is laid out, for the scripted chat test.
    @ViewBuilder func transcriptEndProbe() -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
            DemoChatTest.transcriptEnd = frame
        }
        .onDisappear { DemoChatTest.transcriptEnd = nil }
        #else
        self
        #endif
    }

    /// Debug builds report where the transcript is scrolled, for the scripted chat test (`-demoBench chat`).
    @ViewBuilder func transcriptProbe() -> some View {
        #if DEBUG
        onScrollGeometryChange(for: TranscriptEdge.self) { TranscriptEdge($0) } action: { _, edge in
            DemoChatTest.transcript = edge
        }
        #else
        self
        #endif
    }
}
