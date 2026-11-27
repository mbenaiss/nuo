import AppKit
import Observation
import SwiftUI

/// Startup and routing of the whole app. The menu bar extra, notifications, device tools and meetings work without
/// a main window (launched at login, window closed), so none of this lives in a view; the main window's selection
/// lives here too, which keeps it when the window is closed and reopened.
@MainActor
final class MacAppController {
    private(set) static var current: MacAppController?

    let session: SessionStore
    let bots: BotsStore
    let navigator = MacNavigator()
    private let router = AppRouter.shared
    private let workspace = WorkspaceRouter.shared
    private var launched = false
    private var phase: SessionStore.Phase?
    private var startTask: Task<Void, Never>?
    private var wasConnected = false
    private var lastLink: (url: URL, at: Date)?

    init(session: SessionStore, bots: BotsStore) {
        self.session = session
        self.bots = bots
        Self.current = self
    }

    /// Called once AppKit has finished launching: `NSApp` is up, and launching does not depend on a window.
    func launch() {
        guard !launched else { return }
        launched = true
        if NSApp.isActive { AppLock.shared.activityChanged(active: true) }
        observeActivity()
        observePhase()
        observeConnection()
        observeRouters()
    }

    // MARK: Session

    private func observePhase() {
        let current = observe({ [session] in session.phase }, changed: { [weak self] in self?.observePhase() })
        guard current != phase else { return }
        phase = current
        startTask?.cancel()
        wasConnected = false
        startTask = current == .ready ? Task { await start() } : nil
    }

    private func start() async {
        WorkspaceCache.shared.namespace = session.isDemo ? "demo" : session.gatewayDisplay
        AnswerNotifier.shared.attach(transport: session.transport, api: session.api, bots: bots)
        bots.follow(session.transport)
        AlertsStore.shared.attach(api: session.api, transport: session.transport)
        Task { await AlertsStore.shared.load() }
        PushManager.shared.api = session.api
        PushManager.shared.refreshRegistration()
        DeviceToolsCenter.shared.attach(api: session.api, transport: session.transport, demo: session.isDemo)
        RemindersStore.shared.attach(session.api)
        PlacesStore.shared.attach(session.api)
        FilesHomeStore.shared.attach(session.api)
        CalendarStore.shared.attach(session.api)
        BookingStore.shared.attach(session.api)
        CalendarBridge.shared.attach(session.api, demo: session.isDemo)
        CalendarBridge.shared.start()
        MeetingRecorder.shared.attach(session: session, bots: bots)
        MeetingPrompts.start()
        async let agenda: Void = CalendarStore.shared.load()
        async let bookings: Void = BookingStore.shared.load()
        async let health: Void = session.refreshHealth()
        async let profile: Void = session.refreshProfile()
        async let reminders: Void = RemindersStore.shared.load()
        async let places: Void = PlacesStore.shared.load()
        async let files: Void = FilesHomeStore.shared.load()
        await bots.load()
        guard !Task.isCancelled else { return }
        if navigator.sidebar == nil, let first = bots.bots.first { navigator.sidebar = .bot(first.id) }
        router.resolvePendingLink(bots: bots.bots)
        await router.resolveDeepLink(bots: bots.bots, api: session.api)
        navigator.consumeRouters(bots: bots.bots)
        await files
        navigator.consumeWorkspace()
        _ = await (health, profile, reminders, places, agenda, bookings)
        guard !Task.isCancelled else { return }
        navigator.applyDemo(bots: bots.bots)
        MeetingRecorder.shared.applyDemo()
        WorkspaceRouter.shared.applyDemo()
        navigator.consumeWorkspace()
        openBrowserIfAsked()
        #if DEBUG
        (DemoSnapshot.currentNavigator, DemoSnapshot.currentSession, DemoSnapshot.currentBots) = (navigator, session, bots)
        DemoSnapshot.scheduleIfRequested()
        DemoBench.scheduleIfRequested(navigator: navigator)
        #endif
    }

    /// A Mac app's scenes stay "active" behind other apps: the app's own activation says whether it is in front.
    private func observeActivity() {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session.handleScenePhase(active: true)
                if self?.phase == .ready {
                    self?.bots.refreshActivity()
                    Task { await AlertsStore.shared.load() }
                }
                CalendarBridge.shared.appBecameActive()
                DeviceToolsCenter.shared.permissionsChanged()
            }
        }
        _ = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.handleScenePhase(active: false) }
        }
        // The menu bar and notifications keep working in the background: the socket a sleep killed is revived on wake.
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.revive() }
        }
    }

    /// Bots changed on the gateway while the socket was down (sleep, network change): reload them on reconnection.
    private func observeConnection() {
        let state = observe({ [session] in session.connectionState }, changed: { [weak self] in self?.observeConnection() })
        guard state == .connected, phase == .ready else { return }
        if wasConnected {
            Task { await bots.load() }
        }
        wasConnected = true
    }

    // MARK: Links and routers

    /// `nuo://` links, from the app delegate and from the main window, which may both receive the same one.
    func open(url: URL) {
        if let last = lastLink, last.url == url, Date().timeIntervalSince(last.at) < 2 { return }
        lastLink = (url, Date())
        if let override = MacLinkOverride(url: url) {
            switch override {
            case .collections: navigator.sidebar = .collections
            }
            MacWindowRequests.shared.showMain()
            return
        }
        if !workspace.open(url: url) { router.open(url: url) }
    }

    /// Notification taps, links and Siri land in the shared routers: mirror them into the main window, and bring it
    /// up when it is closed.
    private func observeRouters() {
        observe({ [router] in _ = router.pendingDeepLink }, every: { [weak self] in
            guard let self, router.pendingDeepLink != nil else { return }
            MacWindowRequests.shared.showMain()
            Task {
                await self.router.resolveDeepLink(bots: self.bots.bots, api: self.session.api)
                self.navigator.consumeRouters(bots: self.bots.bots)
            }
        })
        // A notification tapped before the bots were loaded, or for a bot created elsewhere since.
        observe({ [bots] in _ = bots.bots.map(\.id) }, every: { [weak self] in
            guard let self, router.pendingDeepLink != nil else { return }
            Task {
                await self.router.resolveDeepLink(bots: self.bots.bots, api: self.session.api)
                self.navigator.consumeRouters(bots: self.bots.bots)
            }
        })
        observe({ [router] in _ = (router.pendingLink?.conversationId, router.pendingLink?.botId) }, every: { [weak self] in
            guard let self, router.pendingLink != nil else { return }
            MacWindowRequests.shared.showMain()
            router.resolvePendingLink(bots: bots.bots)
            navigator.consumeRouters(bots: bots.bots)
        })
        observe({ [router] in _ = (router.path, router.editor) }, every: { [weak self] in
            guard let self, !router.path.isEmpty || router.editor != nil else { return }
            MacWindowRequests.shared.showMain()
            navigator.consumeRouters(bots: bots.bots)
        })
        observe({ [workspace] in
            _ = (workspace.tab, workspace.focusedReminder, workspace.focusedAgendaItem, workspace.showsBookings, workspace.showsMeetings)
        }, every: { [weak self] in
            guard let self, workspace.tab != .bots || workspace.showsMeetings else { return }
            MacWindowRequests.shared.showMain()
            navigator.consumeWorkspace()
        })
        observe({ [workspace] in _ = workspace.showsBrowser }, every: { [weak self] in self?.openBrowserIfAsked() })
    }

    private func openBrowserIfAsked() {
        guard workspace.showsBrowser, session.phase == .ready else { return }
        workspace.showsBrowser = false
        MacWindowRequests.shared.showBrowser()
    }

    /// Reads `value` with observation, and calls `changed` on the main actor after the next change, once.
    @discardableResult
    private func observe<T>(_ value: @escaping @MainActor () -> T, changed: @escaping @MainActor () -> Void) -> T {
        withObservationTracking(value) {
            Task { @MainActor in changed() }
        }
    }

    /// Like `observe(_:changed:)`, re-armed after every change.
    private func observe(_ value: @escaping @MainActor () -> Void, every changed: @escaping @MainActor () -> Void) {
        observe(value, changed: { [weak self] in
            changed()
            self?.observe(value, every: changed)
        })
    }
}
