import SwiftUI
import WidgetKit

@main
struct NuoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session: SessionStore
    @State private var bots: BotsStore

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        CompiledModelCache.purgeIfBuildChanged()
        let session = SessionStore(demo: arguments.contains("-demo"))
        _session = State(initialValue: session)
        _bots = State(initialValue: BotsStore(session: session))
        WatchSync.shared.start()
        LiveActivityCenter.shared.endStaleActivities()
        // A background refresh launch builds no scene: the bridge needs its gateway client from here.
        CalendarBridge.shared.attach(session.api, demo: session.isDemo)
        #if DEBUG
        if arguments.contains("-renderWidgets") { WidgetSnapshotRenderer.renderAll() }
        #endif
        #if DEBUG || DICTATION_BENCHMARK
        DictationBenchmark.runOnce()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(bots)
                .environment(AppRouter.shared)
                .environment(WorkspaceRouter.shared)
                .environment(PushManager.shared)
                .environment(\.mediaLoader, session.mediaLoader)
                .environment(\.scanAPI, session.api as? any NuoScanAPI)
                .preferredColorScheme(session.appearance.colorScheme)
                .tint(Color.accent)
                .appLock()
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router
    /// The relay access is offered once, on its own screen, before any Face ID.
    @State private var offersRelay = false
    @State private var relayError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            switch session.phase {
            case .locked:
                LockedSessionView()
            case .pairing:
                PairingView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .ready:
                MainView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: session.phase)
        .onChange(of: scenePhase, initial: true) { _, phase in session.setForeground(phase == .active) }
        .onChange(of: scenePhase) { _, phase in
            session.handleScenePhase(active: phase == .active)
            LiveActivityCenter.shared.sceneDidChange(active: phase == .active)
            if phase == .active, session.phase == .ready {
                bots.refreshActivity()
                Task { await AlertsStore.shared.load() }
                if !session.isDemo {
                    RecordingsStore.shared.resumeAll()
                    Task { await WatchAskRelay.retry() }
                }
            }
        }
        .onOpenURL { url in
            if WorkspaceRouter.shared.open(url: url) { return }
            router.open(url: url)
        }
        .task(id: session.phase) {
            if !session.isDemo {
                if session.phase == .ready, SharedCredentials.gatewayURL != session.gatewayURL {
                    SharedCredentials.gatewayURL = session.gatewayURL
                }
                WidgetCenter.shared.reloadAllTimelines()
            }
            guard session.phase == .ready else { return }
            LiveActivityCenter.shared.attach(transport: session.transport, api: session.api)
            AnswerNotifier.shared.attach(transport: session.transport, api: session.api, bots: bots)
            bots.follow(session.transport)
            AlertsStore.shared.attach(api: session.api, transport: session.transport)
            Task { await AlertsStore.shared.load() }
            PushManager.shared.api = session.api
            PushManager.shared.refreshRegistration()
            DeviceToolsCenter.shared.attach(api: session.api, transport: session.transport, demo: session.isDemo)
            async let health: Void = session.refreshHealth()
            async let profile: Void = session.refreshProfile()
            await bots.load()
            RecordingsStore.shared.attach(session: session, bots: bots)
            NuoShortcuts.updateAppShortcutParameters()
            await health
            await profile
            if !session.isDemo, let client = session.api as? NuoClient,
               await RelayEnrollment.shouldOffer(client: client, deviceId: UserDefaults.standard.string(forKey: "nuo.deviceId"), profileId: session.profile?.id) {
                offersRelay = true
            }
            router.resolvePendingLink(bots: bots.bots)
            await router.resolveDeepLink(bots: bots.bots, api: session.api)
            DemoDirector.apply(router: router, bots: bots)
            WorkspaceRouter.shared.applyDemo()
            DemoDirector.playIncoming(transport: session.transport)
        }
        .onChange(of: router.pendingDeepLink) { _, _ in
            Task { await router.resolveDeepLink(bots: bots.bots, api: session.api) }
        }
        // A notification tapped while the bots were not loaded yet (cold start offline, bot created elsewhere).
        .onChange(of: bots.bots.map(\.id)) { _, _ in
            router.resolvePendingLink(bots: bots.bots)
            Task { await router.resolveDeepLink(bots: bots.bots, api: session.api) }
        }
        .onChange(of: router.pendingLink?.conversationId) { _, _ in
            router.resolvePendingLink(bots: bots.bots)
        }
        .onChange(of: router.pendingLink?.botId) { _, _ in
            router.resolvePendingLink(bots: bots.bots)
        }
        .alert("Relay Apple Watch requests while the iPhone is locked?", isPresented: $offersRelay) {
            Button("Turn On") { Task { await enableRelay() } }
            Button("Later", role: .cancel) { RelayEnrollment.decline() }
        } message: {
            Text(RelayAccessCopy.consent)
        }
        .alert("Relay Access", isPresented: Binding(get: { relayError != nil }, set: { if !$0 { relayError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(relayError ?? "")
        }
    }

    /// One Face ID, given for this action; cancelled, it is not asked again by itself.
    private func enableRelay() async {
        guard let client = session.api as? NuoClient, let deviceId = UserDefaults.standard.string(forKey: "nuo.deviceId") else { return }
        do {
            try await RelayEnrollment.register(client: client, deviceId: deviceId, profileId: session.profile?.id)
        } catch NuoError.stepUpCancelled {
            RelayEnrollment.decline()
        } catch {
            relayError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct MainView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router

    @Environment(WorkspaceRouter.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var reminders = RemindersStore.shared

    var body: some View {
        @Bindable var router = router
        @Bindable var workspace = workspace
        TabView(selection: $workspace.tab) {
            Tab("Bots", systemImage: "bubble.left.and.text.bubble.right", value: AppTab.bots) {
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case let .chat(target):
                                if let bot = bots.bot(id: target.botId) {
                                    ChatView(
                                        store: ConversationStore(bot: bot, conversationId: target.conversationId, useDraft: target.useDraft, session: session, bots: bots),
                                        initialPrompt: target.initialPrompt)
                                        .id(target)
                                        .toolbarVisibility(.hidden, for: .tabBar)
                                }
                            case let .conversations(botId):
                                BotConversationsView(botId: botId)
                            case let .schedule(taskId):
                                SchedulesView(focusTaskId: taskId)
                            case .settings:
                                SettingsView()
                            }
                        }
                }
            }
            Tab(String(localized: "nav.calendar", defaultValue: "Calendar"), systemImage: "calendar", value: AppTab.calendar) {
                CalendarView()
            }
            Tab("Reminders", systemImage: "checklist", value: AppTab.reminders) {
                RemindersView()
            }
            .badge(reminders.badgeCount)
            Tab("Files", systemImage: "square.grid.2x2", value: AppTab.files) {
                FilesView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // A chat opened from a notification, a widget or the dock lives in the Bots tab.
        .onChange(of: router.path) { _, path in
            if !path.isEmpty { workspace.tab = .bots }
        }
        .onChange(of: router.voice?.id) { _, id in
            if id != nil { workspace.tab = .bots }
        }
        .task {
            WorkspaceCache.shared.namespace = session.isDemo ? "demo" : session.gatewayDisplay
            reminders.attach(session.api)
            PlacesStore.shared.attach(session.api)
            FilesHomeStore.shared.attach(session.api)
            CalendarStore.shared.attach(session.api)
            BookingStore.shared.attach(session.api)
            CalendarBridge.shared.attach(session.api, demo: session.isDemo)
            CalendarBridge.shared.start()
            async let places: Void = PlacesStore.shared.load()
            async let agenda: Void = CalendarStore.shared.load()
            await reminders.load()
            await (places, agenda)
        }
        // Location triggers are ranked by distance, so the set is rebuilt when the app comes back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                reminders.refreshTriggers()
                CalendarBridge.shared.appBecameActive()
                DeviceToolsCenter.shared.permissionsChanged()
                EventNotifications.scheduleRefresh()
            } else if phase == .background {
                CalendarBridge.shared.scheduleBackgroundRefresh()
            }
        }
        .sheet(item: $router.editor) { target in
            BotEditorView(botId: target.botId)
        }
        .sheet(isPresented: $router.showsNewBot) {
            NewBotSheet()
                .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .top) {
            AnswerBannerHost()
        }
        .fullScreenCover(isPresented: $workspace.showsBrowser) {
            BrowserScreen { workspace.showsBrowser = false }
        }
        .fullScreenCover(item: $router.voice) { target in
            VoiceModeView(bot: target.bot, conversationId: target.conversationId, transport: session.transport) {
                router.voice = nil
            }
        }
    }
}

extension DemoDirector {
    @MainActor private static var prompted = false
    @MainActor private static var draftTaken = false
    @MainActor private static var productTaken = false
    @MainActor private static var contextSheetTaken = false

    /// `-demoContextSheet` opens the context sheet once in the first chat.
    @MainActor static func takeContextSheet() -> Bool {
        guard !contextSheetTaken, ProcessInfo.processInfo.arguments.contains("-demoContextSheet") else { return false }
        contextSheetTaken = true
        return true
    }

    /// `-demoIncoming` runs a turn in another conversation (coach) to show the "answer ready" banner.
    @MainActor static func playIncoming(transport: any LiveTransport) {
        guard ProcessInfo.processInfo.arguments.contains("-demo"), ProcessInfo.processInfo.arguments.contains("-demoIncoming") else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            try? await transport.send(.prompt(conversationId: "c-coach-1", text: "/\(DemoSeed.Command.workout)"))
        }
    }

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo"), let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `-demoDraft "/s"` pre-fills the first chat composer to capture the command palette.
    @MainActor static func takeDraft() -> String? {
        guard !draftTaken, let draft = argument("-demoDraft") else { return nil }
        draftTaken = true
        return draft
    }

    /// `-demoProduct <barcode>` opens the product sheet once in the first chat, `-demoProductSection details` scrolls it.
    @MainActor static func takeProductSheet() -> String? {
        guard !productTaken, let code = argument("-demoProduct") else { return nil }
        productTaken = true
        return code
    }

    static var productSection: String? { argument("-demoProductSection") }

    /// `-demoDockBot coach` tags a bot in the home dock, `-demoDockDraft "@"` pre-fills it.
    static var dockBot: String? { argument("-demoDockBot") }
    static var dockDraft: String? { argument("-demoDockDraft") }

    /// `-demoEditor commands` scrolls the editor to its commands, `-demoEditor command:vol` opens that command.
    static var editorFocus: String? { argument("-demoEditor") }

    /// `-demoPrompt "…"` sends a prompt once the demo chat opens, to capture streaming states.
    @MainActor static func autoPrompt(_ store: ConversationStore) {
        let arguments = ProcessInfo.processInfo.arguments
        guard !prompted, arguments.contains("-demo"), let index = arguments.firstIndex(of: "-demoPrompt"), index + 1 < arguments.count else { return }
        prompted = true
        let prompt = arguments[index + 1]
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            store.send(prompt: prompt)
        }
    }
}

/// Opens a given screen at launch in demo mode (`-demo -demoScreen chat`) so screenshots need no taps.
enum DemoDirector {
    @MainActor static func apply(router: AppRouter, bots: BotsStore) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo"), let index = arguments.firstIndex(of: "-demoScreen"), index + 1 < arguments.count else { return }
        switch arguments[index + 1] {
        case "chat": router.path = [.chat(ChatTarget(botId: "voyages", conversationId: "c-voyages-1"))]
        case "coach": router.path = [.chat(ChatTarget(botId: "coach", conversationId: "c-coach-1"))]
        case "cobot": router.path = [.chat(ChatTarget(botId: "cobot", conversationId: "c-cobot-1"))]
        case "newchat": router.path = [.chat(ChatTarget(botId: "voyages"))]
        case "conversations": router.path = [.conversations(botId: "voyages")]
        case "product": router.path = [.chat(ChatTarget(botId: "coach", conversationId: "c-coach-2"))]
        case "coachnew": router.path = [.chat(ChatTarget(botId: "coach"))]
        case "editor": router.editor = EditorTarget(botId: "voyages")
        case "coacheditor": router.editor = EditorTarget(botId: "coach")
        case "settings": router.path = [.settings]
        case "newbot": router.showsNewBot = true
        default: break
        }
    }
}
