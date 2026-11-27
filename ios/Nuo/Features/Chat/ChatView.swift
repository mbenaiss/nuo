import SwiftUI

struct ChatView: View {
    @State private var store: ConversationStore
    @Environment(SessionStore.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var tags = ToolTagPalette()
    @State private var composerFocused = false
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var scroll = TranscriptScroll()
    @State private var openingVoice = false
    @State private var safariURL: URL?
    @State private var showsScanner = false
    @State private var scannedCode: String?
    @State private var scannedSymbology: String?
    @State private var scanChoice: ScanChoice?
    @State private var scanSheet: ScanSheetTarget?
    @State private var productSheet: ProductSheetTarget?
    @State private var showsContext = false
    @State private var showsSubagents = false
    /// Code blocks and pasted texts the reader asked to see in full, by `TranscriptRows` key.
    @State private var expansions: Set<String> = []
    @State private var codeOffsets = CodeScrollOffsets()
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17

    @State private var initialPrompt: String?

    init(store: ConversationStore, initialPrompt: String? = nil) {
        _store = State(initialValue: store)
        _initialPrompt = State(initialValue: initialPrompt)
    }

    var body: some View {
        messageList
            .background(Color.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatBottomBar(
                    store: store, tags: tags, composerFocused: $composerFocused, scroll: scroll,
                    onScrollToBottom: jumpToBottom, onVoice: openVoice)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(Color.canvas, for: .navigationBar)
            .environment(\.sendCardPrompt, CardPromptSender { prompt in store.send(prompt: prompt) })
            .environment(\.cardBotName, store.config?.name)
            .sheet(item: $store.pendingPermission) { prompt in
                PermissionSheet(prompt: prompt, botName: store.config?.name ?? String(localized: "The bot")) { option, rule in
                    store.answerPermission(option, rule: rule)
                }
                .presentationDetents(prompt.offer == nil ? [.height(320), .medium] : [.height(490), .large])
                .interactiveDismissDisabled()
            }
            .sheet(item: Binding(get: { safariURL.map(IdentifiedURL.init) }, set: { safariURL = $0?.url })) { item in
                SafariView(url: item.url).ignoresSafeArea()
            }
            .sheet(isPresented: $showsScanner, onDismiss: {
                // The product sheet can only be presented once the scanner sheet is fully gone.
                if let code = scannedCode {
                    scannedCode = nil
                    resolveScan(code, symbology: scannedSymbology)
                }
            }) {
                BarcodeScannerSheet { code, symbology in
                    scannedCode = code
                    scannedSymbology = symbology
                    if code.allSatisfy(\.isNumber) { Task { _ = await ProductMemo.load(code) } }
                }
            }
            .confirmationDialog("What did you scan?", isPresented: Binding(get: { scanChoice != nil }, set: { if !$0 { scanChoice = nil } }), titleVisibility: .visible, presenting: scanChoice) { choice in
                ForEach(choice.candidates) { kind in
                    Button(kind.label) { choose(kind, code: choice.code) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { choice in
                Text(choice.error.map { String(localized: "Code \(choice.code): \($0)") } ?? String(localized: "Code \(choice.code) was not recognized automatically."))
            }
            .sheet(item: $scanSheet) { target in
                switch target {
                case let .cosmetic(code):
                    CosmeticSheetView(barcode: code, onAsk: { store.send(prompt: "Cosmétique scanné : \(code)") })
                case let .parcel(detection):
                    ParcelSheetView(detection: detection)
                }
            }
            .hostsFullPages()
            .environment(\.openSubagents, SubagentsOpener { showsSubagents = true })
            .sheet(isPresented: $showsSubagents) {
                SubagentsView(store: store)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showsContext) {
                ContextSheet(context: store.context, modelLabel: store.modelLabel, isRunning: store.isRunning) {
                    showsContext = false
                    store.compact()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $productSheet) { target in
                ProductSheetView(
                    barcode: target.barcode, botName: store.config?.name,
                    onAsk: target.fromScan ? { store.send(prompt: "Code-barres scanné : \(target.barcode)") } : nil
                ) { prompt in
                    store.send(prompt: prompt)
                }
            }
            .onChange(of: store.localCommand) { _, command in
                guard let command else { return }
                store.localCommand = nil
                handle(command)
            }
            .onAppear {
                store.start()
                DemoDirector.autoPrompt(store)
                if let prompt = initialPrompt {
                    initialPrompt = nil
                    // Load the history first, or the first reload would replace the message being sent.
                    Task {
                        await store.reload()
                        store.send(prompt: prompt)
                    }
                }
                if let code = DemoDirector.takeProductSheet() {
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        productSheet = ProductSheetTarget(barcode: code, fromScan: true)
                    }
                }
                if DemoDirector.takeContextSheet() {
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        showsContext = true
                    }
                }
                if let draft = DemoDirector.takeDraft() {
                    store.draft = draft
                    composerFocused = true
                }
            }
            .onDisappear { store.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.reload() } }
            }
            .task { await MachineToolsStore.shared.refresh(api: session.api) }
            .onChange(of: router.voice == nil) { _, closed in
                if closed { Task { await store.reload() } }
            }
            .onChange(of: store.messages.count) { old, new in
                // A conversation that loads (or reloads many messages) opens on its end, and sending brings the reader back to it.
                if old == 0 || new - old > 1 || store.messages.last?.role == .user { jumpToBottom() }
            }
            // Messages already in memory (a chat reopened) never go through the count change above.
            .onAppear { if !store.messages.isEmpty { jumpToBottom() } }
    }

    private let transcriptEnd = "transcript-end"

    /// No animated scroll over a long conversation: it builds every lazy row on the way down. Rows measured on
    /// arrival change the content height, and following the end then finishes the jump.
    private func jumpToBottom() {
        scroll.follow.returnToEnd()
        scrollToEnd()
    }

    private func scrollToEnd() {
        let scrollView = scroll.scrollView
        let targetingMarker = position.viewID(type: String.self) == transcriptEnd
        let move = scroll.endScroller.next(targetingMarker: targetingMarker, edge: scrollView.map(TranscriptEdge.init))
        switch move {
        case let .toMarker(anchor):
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { position.scrollTo(id: transcriptEnd, anchor: anchor) }
        case let .toOffset(offsetY):
            guard let scrollView else { return }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offsetY), animated: false)
            continueToEnd()
        case .none:
            break
        }
    }

    /// The rows an offset step lands on are measured a pass or two later, and the scroll geometry does not always report
    /// it: the next step is decided once they are.
    private func continueToEnd() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard scroll.follow.following, scroll.phase == .idle else { return }
            scrollToEnd()
        }
    }

    /// Keyboard notifications arrive inside the keyboard's animation, before SwiftUI lays the transcript out again: a
    /// change to the scroll view's offset made here is animated with the keyboard.
    private func moveWithKeyboard() {
        guard let scrollView = scroll.scrollView, scroll.phase != .tracking, scroll.phase != .interacting,
              let offsetY = scroll.follow.endOffset(beforeKeyboardMoves: TranscriptEdge(scrollView)) else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offsetY), animated: false)
    }

    /// Acts on the last geometry once the current layout is done: a layout pass reports transient content heights
    /// in between, several times a frame.
    private func settleScroll() {
        guard !scroll.settlePending else { return }
        scroll.settlePending = true
        Task { @MainActor in
            scroll.settlePending = false
            guard let edge = scroll.edge else { return }
            switch scroll.phase {
            case .tracking, .interacting, .decelerating:
                scroll.follow.readerScrolled(to: edge)
            default:
                if scroll.follow.settled(on: edge) { scrollToEnd() }
            }
        }
    }

    private var transcriptItems: [TranscriptItem] {
        let compacting = store.isCompacting
        let live = store.liveMessageId
        return scroll.rows.items(
            for: store.messages.withoutTaskPrompts, liveMessageId: live, expanded: expansions,
            metrics: TranscriptMetrics().scaled(by: bodySize / 17)
        ) { message in
            message.notice != nil || message.wake?.isShown == true || (compacting && message.id == live && message.text.isEmpty)
        }
    }

    private var messageList: some View {
        let answerLabels = store.answerLabels
        let replies = store.replies
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.messages.isEmpty && !store.isLoading {
                    EmptyChat(store: store).padding(.top, 80)
                }
                ForEach(transcriptItems) { item in
                    TranscriptRowView(
                        item: item, store: store, answeredBy: answerLabels[item.message.id], reply: replies[item.message.id])
                        .padding(.top, item.row.joint.spacing)
                }
                if store.isCompacting && store.liveMessageId == nil {
                    CompactingChip().padding(.top, TranscriptJoint.message.spacing)
                } else if store.isRunning && store.liveMessageId == nil {
                    WorkRow(steps: [], thoughts: nil, durationMs: nil, isLive: true, startedAt: store.turnStartedAt ?? Date())
                        .padding(.top, TranscriptJoint.message.spacing)
                        .transition(.opacity)
                }
                if store.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                // The end of the transcript as a real view: scrolling to the content's edge uses the lazy rows' estimated
                // heights and could stop past the last message, on an empty area. It ends the content, margin included,
                // so that a transcript scrolled to it rests on the scroll view's edge, where the bottom bar changing
                // height keeps it.
                Color.clear.frame(height: 13).padding(.top, TranscriptJoint.message.spacing).id(transcriptEnd)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background { EnclosingScrollView { scroll.attach($0) } }
            .transaction(value: store.messages.count) { [scroll, count = store.messages.count] transaction in
                transaction.animation = scroll.growth.isSingleArrival(count: count)
                    ? .spring(response: 0.4, dampingFraction: 0.86) : nil
            }
        }
        .modifier(TranscriptParts(expansions: $expansions, codeOffsets: codeOffsets, scroll: scroll))
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .scrollTargetBehavior(TranscriptRestBehavior(scroll: scroll))
        .onScrollGeometryChange(for: TranscriptEdge.self) { TranscriptEdge($0) } action: { _, edge in
            scroll.edge = edge
            settleScroll()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            moveWithKeyboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            moveWithKeyboard()
        }
        .onScrollPhaseChange { old, new in
            scroll.phase = new
            defer { if new != .decelerating { scroll.follow.landed() } }
            guard new == .idle, let edge = scroll.edge else { return }
            switch old {
            case .tracking, .interacting, .decelerating:
                // Where the reader let go decides whether they follow the end; only a band past it is put back.
                scroll.follow.readerScrolled(to: edge)
                if edge.needsSnapBack(scrollIdle: true) { scrollToEnd() }
            default:
                settleScroll()
            }
        }
    }

    /// The Coach's tool server: its bot gets the Muscu screen's button.
    private static let fitnessServer = "fitness"

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                Button {
                    Haptics.tap()
                    showsContext = true
                } label: {
                    ContextAvatar(config: store.config, context: store.context)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows context usage")
                ModelMenu(store: store) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(store.config?.name ?? "Bot").font(.headline).foregroundStyle(Color.ink)
                            if store.useDraft { Badge(text: String(localized: "Draft"), tint: Color.accentInk, fill: Color.accentSoft) }
                        }
                        HStack(spacing: 3) {
                            Text(headerSubtitle).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(.caption)
                        .foregroundStyle(Color.text2)
                    }
                }
            }
            .padding(.trailing, 6)
            // Past this size the bar drops the whole item, hiding the bot name and the context gauge.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
        .sharedBackgroundVisibility(.hidden)
        if store.config?.toolServers.contains(Self.fitnessServer) == true {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    WorkspaceRouter.shared.showsMuscu = true
                } label: {
                    Image(systemName: "dumbbell.fill").foregroundStyle(Color.ink)
                }
                .accessibilityLabel("Gym session")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    router.openChat(botId: store.bot.id, useDraft: store.useDraft)
                } label: { Label("New conversation", systemImage: "square.and.pencil") }
                Button {
                    router.path.append(.conversations(botId: store.bot.id))
                } label: { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
                Button {
                    router.editor = EditorTarget(botId: store.bot.id)
                } label: { Label("Edit bot", systemImage: "slider.horizontal.3") }
                Button(action: openVoice) { Label("Voice mode", systemImage: "waveform") }
                Button { showsSubagents = true } label: {
                    Label(store.activeSubagentCount > 0 ? String(localized: "Subagents (\(store.activeSubagentCount) running)") : String(localized: "Subagents"), systemImage: "person.2.wave.2")
                }
                Button { WorkspaceRouter.shared.showsBrowser = true } label: { Label("Browser", systemImage: "safari") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Color.ink)
            }
            .accessibilityLabel("Options")
        }
    }

    private func handle(_ command: LocalCommand) {
        composerFocused = false
        switch command {
        case let .open(url):
            Haptics.tap()
            safariURL = url
        case .newConversation:
            Haptics.send()
            let target = Route.chat(ChatTarget(botId: store.bot.id, useDraft: store.useDraft))
            if router.path.isEmpty { router.path = [target] } else { router.path[router.path.count - 1] = target }
        case .voice:
            openVoice()
        case .barcode:
            Haptics.tap()
            showsScanner = true
        }
    }

    /// Asks the gateway what the code is; without it (demo, older gateway) every scan is a food, as before.
    private func resolveScan(_ code: String, symbology: String?, kind: ScanKind? = nil) {
        guard let api = session.api as? any NuoScanAPI else {
            productSheet = ProductSheetTarget(barcode: code, fromScan: true)
            return
        }
        Task {
            do {
                present(try await api.scan(code: code, symbology: symbology, kind: kind))
            } catch {
                scanChoice = ScanChoice(code: code, candidates: ScanKind.allCases, error: error.localizedDescription)
            }
        }
    }

    private func present(_ result: ScanResult) {
        switch result.scanKind {
        case .food: productSheet = ProductSheetTarget(barcode: result.code, fromScan: true)
        case .cosmetic: scanSheet = .cosmetic(result.code)
        case .parcel:
            if let detection = result.parcel { scanSheet = .parcel(detection) } else { scanChoice = ScanChoice(code: result.code, candidates: [.food, .cosmetic], error: result.error) }
        case nil: scanChoice = ScanChoice(code: result.code, candidates: result.candidates, error: result.error)
        }
    }

    private func choose(_ kind: ScanKind, code: String) {
        switch kind {
        case .food: productSheet = ProductSheetTarget(barcode: code, fromScan: true)
        case .cosmetic: scanSheet = .cosmetic(code)
        case .parcel: resolveScan(code, symbology: nil, kind: .parcel)
        }
    }

    private var headerSubtitle: String {
        let model = store.brainLabel
        guard store.modelInfo?.efforts?.isEmpty == false else { return model }
        return "\(model) · \(Effort.label(store.effort))"
    }

    private func openVoice() {
        guard !openingVoice else { return }
        Haptics.send()
        openingVoice = true
        composerFocused = false
        Task {
            defer { openingVoice = false }
            do {
                let id = try await store.ensureConversation()
                router.voice = VoiceTarget(bot: store.bot, conversationId: id)
            } catch {
                Haptics.error()
            }
        }
    }
}

/// The transcript's last geometry and scroll phase change every frame while scrolling: they are not observed, so that
/// the conversation does not re-render for them. Only the jump to the end, shown when the reader leaves it, is.
@Observable private final class TranscriptScroll {
    @ObservationIgnored private(set) weak var scrollView: UIScrollView?
    @ObservationIgnored private let scrollToTop = ScrollToTopRelay()
    @ObservationIgnored var edge: TranscriptEdge?
    @ObservationIgnored var phase = ScrollPhase.idle
    @ObservationIgnored var settlePending = false
    @ObservationIgnored var growth = TranscriptGrowth()
    @ObservationIgnored var endScroller = TranscriptEndScroller()
    @ObservationIgnored let rows = TranscriptRowCache()
    @ObservationIgnored var follow = TranscriptFollow() {
        didSet { if showsJump == follow.following { showsJump = !follow.following } }
    }
    private(set) var showsJump = false

    @MainActor func readerExpandsBlock() {
        guard let offsetY = follow.readerExpandedBlock(at: scrollView.map(TranscriptEdge.init)), let scrollView else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offsetY), animated: false)
    }

    @MainActor func attach(_ scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }
        self.scrollView = scrollView
        scrollToTop.onScrollToTop = { [weak self] in self?.follow.readerScrolledToTop(from: TranscriptEdge($0)) }
        scrollToTop.onScrolledToTop = { [weak self] in self?.follow.scrolledToTop() }
        scrollToTop.install(on: scrollView)
    }
}

/// One row of the transcript: a slice of a user's bubble, part of an answer, or a notice.
private struct TranscriptRowView: View {
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
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        case let .assistant(part):
            AssistantMessageView(
                message: message, isLive: message.id == store.liveMessageId, startedAt: store.turnStartedAt,
                answeredBy: answeredBy, reply: reply, canAnswer: reply == nil && !store.isRunning, part: part)
        case .whole:
            if let notice = message.notice {
                NoticeChip(payload: notice).padding(.vertical, 6)
            } else if let wake = message.wake, wake.isShown {
                WakeCard(wake: wake)
            } else {
                CompactingChip()
            }
        }
    }
}

/// Lets the transcript's rows expand a code block or a pasted text, and scroll a code block's slices together.
private struct TranscriptParts: ViewModifier {
    @Binding var expansions: Set<String>
    let codeOffsets: CodeScrollOffsets
    let scroll: TranscriptScroll

    func body(content: Content) -> some View {
        content
            .environment(\.expandTranscriptPart, TranscriptExpander { key in
                scroll.readerExpandsBlock()
                expansions.insert(key)
            })
            .environment(\.codeScrollOffsets, codeOffsets)
    }
}

private extension TranscriptJoint {
    var spacing: CGFloat {
        switch self {
        case .start, .flush: 0
        case .message: 16
        case .block: 10
        case .line: TextMetrics.lineSpacing
        case .listItem: TextMetrics.listItemGap
        }
    }
}

/// Lands the transcript on its end where it would otherwise come to rest just short of it or move off it.
private struct TranscriptRestBehavior: ScrollTargetBehavior {
    let scroll: TranscriptScroll

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let proposed = TranscriptTarget(
            maxY: target.rect.maxY, contentHeight: context.contentSize.height, containerHeight: context.containerSize.height)
        guard let maxY = scroll.follow.rest(on: proposed, cause: scroll.phase.restCause) else { return }
        target.rect = CGRect(
            x: target.rect.minX, y: maxY - context.containerSize.height, width: context.containerSize.width,
            height: context.containerSize.height)
    }
}

private extension TranscriptEdge {
    init(_ scrollView: UIScrollView) {
        let insets = scrollView.adjustedContentInset
        self.init(
            visibleMaxY: scrollView.contentOffset.y + scrollView.bounds.height, contentHeight: scrollView.contentSize.height,
            offsetY: scrollView.contentOffset.y, topInset: insets.top,
            containerHeight: scrollView.bounds.height - insets.top - insets.bottom)
    }
}

/// Hears the reader tapping the status bar, the one scroll the scroll view makes on its own, and passes everything else
/// on to the delegate SwiftUI set.
private final class ScrollToTopRelay: NSObject, UIScrollViewDelegate {
    var onScrollToTop: ((UIScrollView) -> Void)?
    var onScrolledToTop: (() -> Void)?
    private weak var forwarded: (any UIScrollViewDelegate)?

    nonisolated override init() { super.init() }

    func install(on scrollView: UIScrollView) {
        guard scrollView.delegate !== self else { return }
        forwarded = scrollView.delegate
        scrollView.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwarded?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        forwarded?.responds(to: selector) == true ? forwarded : super.forwardingTarget(for: selector)
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        let scrolls = forwarded?.scrollViewShouldScrollToTop?(scrollView) ?? true
        if scrolls { onScrollToTop?(scrollView) }
        return scrolls
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        forwarded?.scrollViewDidScrollToTop?(scrollView)
        onScrolledToTop?()
    }
}

/// The scroll view under the transcript, which SwiftUI does not expose.
private struct EnclosingScrollView: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> Finder { Finder(found: found) }
    func updateUIView(_ uiView: Finder, context: Context) {}

    final class Finder: UIView {
        private let found: (UIScrollView) -> Void

        init(found: @escaping (UIScrollView) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let candidate = view, !(candidate is UIScrollView) { view = candidate.superview }
            if let scrollView = view as? UIScrollView { found(scrollView) }
        }
    }
}

private extension ScrollPhase {
    var restCause: TranscriptRestCause {
        switch self {
        case .tracking, .interacting: .readerLettingGo
        case .decelerating: .readerFlinging
        default: .layout
        }
    }
}

/// Palettes, status and composer under the transcript. Its own view so that typing, which only changes the draft,
/// re-renders this bar and not the whole conversation.
private struct ChatBottomBar: View {
    let store: ConversationStore
    let tags: ToolTagPalette
    @Binding var composerFocused: Bool
    let scroll: TranscriptScroll
    let onScrollToBottom: () -> Void
    let onVoice: () -> Void
    @Environment(BotsStore.self) private var bots
    @State private var turnFinishedAt: Date?

    var body: some View {
        VStack(spacing: 8) {
            if scroll.showsJump && !paletteVisible && tagQuery == nil {
                Button {
                    Haptics.tap()
                    onScrollToBottom()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 38, height: 38)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("Scroll to bottom")
            }
            if let error = store.errorMessage {
                ErrorBanner(message: error, onRetry: store.canRetry ? { store.retry() } : nil, onDismiss: { store.dismissError() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if paletteVisible {
                CommandPalette(
                    commands: store.paletteMatches, query: store.paletteQuery ?? "", hasCommands: true,
                    highlighted: store.paletteHighlight
                ) { command in
                    store.pick(command)
                    if command.takesArgs { composerFocused = true }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))))
            } else if let query = tagQuery {
                let toolsStore = MachineToolsStore.shared
                ToolTagPaletteView(
                    tools: toolsStore.matches(query), query: query, highlighted: tags.highlight, config: store.config,
                    shellBots: bots.bots.filter { $0.config?.permissionPolicy == .auto }, loaded: toolsStore.loaded
                ) { tool in
                    Haptics.selection()
                    store.draft = ToolTag.insert(tool, into: store.draft)
                    composerFocused = true
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))))
            } else if let command = store.typedCommand {
                CommandArgsHint(command: command)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            TurnStatusArea(
                botName: store.config?.name ?? String(localized: "The bot"), phase: store.turnPhase, tool: store.currentTool,
                toolDetail: store.currentToolDetail, steps: store.stepCount, startedAt: store.turnStartedAt, finished: turnFinishedAt != nil,
                hidden: paletteVisible || tagQuery != nil)
            Composer(store: store, focused: $composerFocused, onVoice: onVoice, tags: tags)
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: paletteVisible)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: tagQuery != nil)
        .sensoryFeedback(.impact(weight: .light), trigger: tagQuery != nil) { _, visible in visible }
        .onChange(of: tagQuery) { _, _ in tags.highlight = 0 }
        .animation(.snappy(duration: 0.22), value: store.typedCommand?.name)
        .sensoryFeedback(.impact(weight: .light), trigger: paletteVisible) { _, visible in visible }
        .animation(.snappy, value: scroll.showsJump)
        .animation(.snappy, value: store.errorMessage)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: store.turnPhase != nil)
        .turnDoneBeat($turnFinishedAt, running: store.turnPhase != nil, failed: store.errorMessage != nil)
    }

    private var paletteVisible: Bool { store.paletteQuery != nil }
    private var tagQuery: String? { paletteVisible ? nil : ToolTag.query(in: store.draft) }
}

private struct EmptyChat: View {
    let store: ConversationStore

    var body: some View {
        VStack(spacing: 14) {
            BotAvatar(config: store.config, size: 72)
            Text(store.config?.name ?? "Bot").font(.title2.bold()).foregroundStyle(Color.ink)
            if let description = store.config?.description, !description.isEmpty {
                Text(description).font(.subheadline).foregroundStyle(Color.text2).multilineTextAlignment(.center)
            }
            if store.useDraft {
                Text("You are testing the draft: unpublished changes are active in this conversation.")
                    .font(.footnote)
                    .foregroundStyle(Color.accentInk)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

private struct ErrorBanner: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.bad)
            Text(message).font(.subheadline).foregroundStyle(Color.ink).lineLimit(3)
            Spacer(minLength: 4)
            if let onRetry {
                Button("Try again", action: onRetry)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accent)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.bad.opacity(0.3)))
    }
}

struct PermissionSheet: View {
    let prompt: PermissionPrompt
    let botName: String
    let onAnswer: (PermissionOption, ToolRule?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accent)
                    .frame(width: 44, height: 44)
                    .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(botName) asks for permission").font(.subheadline).foregroundStyle(Color.text2)
                    Text(prompt.title).font(.headline).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 10) {
                ForEach(sortedOptions) { option in
                    Button(option.name) { onAnswer(option, nil) }
                        .buttonStyle(InkButtonStyle(prominent: option.kind == "allow_once", destructive: option.kind.hasPrefix("reject")))
                }
            }
            if let offer = prompt.offer {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Remember for “\(ToolRuleLabel.name(offer.tool))” in \(botName)")
                        .font(.footnote).foregroundStyle(Color.text2)
                    if let option = prompt.option(for: .allow) {
                        Button("Always for this tool") { onAnswer(option, .allow) }
                            .buttonStyle(InkButtonStyle(prominent: false, destructive: false))
                    }
                    if let option = prompt.option(for: .block) {
                        Button("Block this tool") { onAnswer(option, .block) }
                            .buttonStyle(InkButtonStyle(prominent: false, destructive: true))
                    }
                }
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.canvas)
    }

    private var sortedOptions: [PermissionOption] {
        let order = ["allow_once": 0, "allow_always": 1, "reject_once": 2, "reject_always": 3]
        return prompt.shownOptions.sorted { (order[$0.kind] ?? 9) < (order[$1.kind] ?? 9) }
    }
}

struct ScanChoice: Identifiable {
    let code: String
    let candidates: [ScanKind]
    let error: String?
    var id: String { code }
}

enum ScanSheetTarget: Identifiable {
    case cosmetic(String)
    case parcel(ParcelDetection)

    var id: String {
        switch self {
        case let .cosmetic(code): "cosmetic-\(code)"
        case let .parcel(detection): "parcel-\(detection.number)"
        }
    }
}

struct ProductSheetTarget: Identifiable {
    let barcode: String
    let fromScan: Bool
    var id: String { barcode }
}
