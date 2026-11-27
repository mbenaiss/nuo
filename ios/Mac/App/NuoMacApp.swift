import AppKit
import SwiftUI
import UserNotifications

@main
struct NuoMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var session: SessionStore
    @State private var bots: BotsStore
    @State private var controller: MacAppController

    init() {
        CompiledModelCache.purgeIfBuildChanged()
        let session = SessionStore(demo: ProcessInfo.processInfo.arguments.contains("-demo"))
        let bots = BotsStore(session: session)
        _session = State(initialValue: session)
        _bots = State(initialValue: bots)
        _controller = State(initialValue: MacAppController(session: session, bots: bots))
    }

    var body: some Scene {
        Window("Nuo", id: MacWindow.main) {
            MacRootView()
                .environment(controller.navigator)
                .environments(session: session, bots: bots)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands { NuoCommands(bots: bots) }

        WindowGroup("Conversation", id: MacWindow.chat, for: ChatSelection.self) { $selection in
            if let selection {
                ChatWindow(selection: selection)
                    .appLock()
                    .environments(session: session, bots: bots)
            }
        }
        .defaultSize(width: 720, height: 780)

        WindowGroup("Document", id: MacWindow.doc, for: String.self) { $path in
            if let path {
                DocWindow(path: path)
                    .appLock()
                    .environments(session: session, bots: bots)
            }
        }
        .defaultSize(width: 1000, height: 760)

        Window("Meeting", id: MacWindow.meeting) {
            MeetingWindow()
                .appLock()
                .environments(session: session, bots: bots)
        }
        .defaultSize(width: 1100, height: 720)

        Window("Browser", id: MacWindow.browser) {
            MacBrowserWindow()
                .appLock()
                .environments(session: session, bots: bots)
        }
        .defaultSize(width: 1100, height: 820)

        Settings {
            MacSettingsView()
                .appLock()
                .environments(session: session, bots: bots)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environments(session: session, bots: bots)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Windows asked for from outside a view (notification taps). The menu bar label, alive as long as the app, opens them.
@MainActor
@Observable
final class MacWindowRequests {
    static let shared = MacWindowRequests()
    private(set) var main = 0
    private(set) var settings = 0
    private(set) var browser = 0

    private init() {}

    func showMain() { main += 1 }
    func showSettings() { settings += 1 }
    func showBrowser() { browser += 1 }
}

enum MacWindow {
    static let main = "main"
    static let chat = "chat"
    static let doc = "doc"
    static let browser = "browser"
    static let meeting = "meeting"
}

/// The shared browser in its own window; « Terminé » closes it.
struct MacBrowserWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        BrowserScreen { dismissWindow(id: MacWindow.browser) }
            .frame(minWidth: 720, minHeight: 520)
    }
}

extension View {
    func environments(session: SessionStore, bots: BotsStore) -> some View {
        environment(session)
            .environment(bots)
            .environment(AppRouter.shared)
            .environment(WorkspaceRouter.shared)
            .environment(PushManager.shared)
            .environment(\.mediaLoader, session.mediaLoader)
            .environment(\.scanAPI, session.api as? any NuoScanAPI)
            .environment(\.emailDraftAPI, session.api as? any NuoEmailDraftAPI)
            .preferredColorScheme(session.appearance.colorScheme)
            .tint(Color.accent)
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MacAppController.current?.launch()
        AnswerNotifier.registerCategories(extra: [MeetingPrompts.notificationCategory])
        // Dictation then never rests on Apple's recognizer alone, which some Macs fail to start.
        DictationModelStore.shared.downloadIfMissing()
        #if DEBUG
        // These snapshots host their view in their own window (settings too), so they need no main window, which macOS may not restore.
        if ["menubar", "chat", "meeting", "meetingcard", "settings"].contains(DemoDirector.argument("-demoWindow")) { DemoSnapshot.scheduleIfRequested() }
        MeetingBenchmark.runIfRequested()
        DictationBenchmark.runOnce()
        #endif
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(token: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushManager.shared.didFail(error)
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        nonisolated(unsafe) let info = userInfo
        Task { _ = await DeviceToolsCenter.shared.handlePush(info) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { MacAppController.current?.open(url: url) }
    }

    // The menu bar extra keeps the app useful with every window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q and the menu bar's « Quitter »: asks before losing a meeting or a document, then lets each one save.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The quit already under way replies for both.
        guard !quitting else { return .terminateCancel }
        if let message = QuitPrompt.message(for: QuitCoordinator.shared.pendingReasons) {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = QuitPrompt.title
            alert.informativeText = message
            alert.addButton(withTitle: QuitPrompt.confirm)
            alert.addButton(withTitle: QuitPrompt.cancel)
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        quitting = true
        Task {
            await QuitCoordinator.shared.flushAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if MeetingPrompts.handle(response) {
            completionHandler()
            return
        }
        Task {
            if await NotificationResponder.handle(response) {
                MacWindowRequests.shared.showMain()
            }
            completionHandler()
        }
    }
}
