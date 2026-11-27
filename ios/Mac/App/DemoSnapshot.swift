#if DEBUG
import AppKit
import SwiftUI

/// `-demo -demoSnapshot <name>` writes the main window to `<sandbox tmp>/<name>.png` after a few seconds.
/// The window draws itself, so it needs no Screen Recording permission, but glass and vibrant text (sidebar) do not render.
/// `-demoWindowSize 1280x800` resizes the main window first; an attached sheet is written as `<name>-sheet.png`;
/// `-demoWindow settings|menubar|sidebar|meeting|meetingcard` snapshots the Settings window, the menu bar panel, the sidebar,
/// the meeting window (state from `-demoScreen`) or the meeting card of the « Réunions » list instead.
enum DemoSnapshot {
    @MainActor private static var extraWindow: NSWindow?

    @MainActor private static var scheduled = false

    @MainActor static func scheduleIfRequested() {
        guard !scheduled, let name = DemoDirector.argument("-demoSnapshot") else { return }
        scheduled = true
        let delay = Double(DemoDirector.argument("-demoSnapshotDelay") ?? "") ?? 4
        let target = DemoDirector.argument("-demoWindow")
        Task { @MainActor in
            if let size = DemoDirector.argument("-demoWindowSize").flatMap(parseSize), let window = mainWindow {
                window.setContentSize(size)
                window.center()
            }
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            switch target {
            case "settings":
                NSApp.activate()
                let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," }
                if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            case "menubar": showMenuBarPanel()
            case "sidebar": showSidebar()
            case "chat": await showChat()
            case "meeting": showMeeting()
            case "meetingcard": showMeetingCard()
            default: break
            }
            try? await Task.sleep(for: .seconds(delay))
            let window = target == nil
                ? mainWindow
                : extraWindow ?? NSApp.windows.first { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
            guard let window else { return }
            write(window, to: name)
            if let sheet = window.attachedSheet { write(sheet, to: "\(name)-sheet") }
            if DemoDirector.argument("-demoSnapshotQuit") != nil { NSApp.terminate(nil) }
        }
    }

    @MainActor private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.width > 600 }
    }

    /// The real extra lives in the status bar, whose window cannot be opened programmatically: host the same panel in a plain window.
    @MainActor private static func showMenuBarPanel() {
        let session = SessionStore(demo: true)
        let bots = BotsStore(session: session)
        Task { await bots.load() }
        let host = NSHostingController(rootView: MenuBarPanel().environments(session: session, bots: bots))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        panel.makeKeyAndOrderFront(nil)
        extraWindow = panel
    }

    /// A chat pane in a plain window (`-demoWindow chat`, with `-demoBot`/`-demoConversation`), without the main window.
    @MainActor private static func showChat() async {
        let session = SessionStore(demo: true)
        let bots = BotsStore(session: session)
        await bots.load()
        let botId = DemoDirector.argument("-demoBot") ?? "cobot"
        guard let bot = bots.bot(id: botId) else { return }
        let selection = ChatSelection(botId: botId, conversationId: DemoDirector.argument("-demoConversation") ?? "c-\(botId)-1")
        let host = NSHostingController(rootView: ChatPane(selection: selection, bot: bot, session: session, bots: bots)
            .environments(session: session, bots: bots)
            .frame(width: 900, height: 720))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        panel.makeKeyAndOrderFront(nil)
        extraWindow = panel
    }

    /// The meeting window in a plain window: the real one opens only once the main window ran its demo setup, and
    /// macOS may not restore the main window.
    @MainActor private static func showMeeting() {
        let session = SessionStore(demo: true)
        let bots = BotsStore(session: session)
        Task {
            await bots.load()
            MeetingRecorder.shared.attach(session: session, bots: bots)
            MeetingRecorder.shared.applyDemo()
        }
        let size = DemoDirector.argument("-demoWindowSize").flatMap(parseSize) ?? NSSize(width: 1100, height: 720)
        let host = NSHostingController(rootView: MeetingWindow()
            .environments(session: session, bots: bots)
            .frame(width: size.width, height: size.height))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        panel.title = String(localized: "Meeting")
        panel.makeKeyAndOrderFront(nil)
        extraWindow = panel
    }

    /// The meeting card at the top of the « Réunions » list.
    @MainActor private static func showMeetingCard() {
        let session = SessionStore(demo: true)
        let bots = BotsStore(session: session)
        Task {
            await bots.load()
            MeetingRecorder.shared.attach(session: session, bots: bots)
            MeetingRecorder.shared.applyDemo()
        }
        let host = NSHostingController(rootView: MeetingStartCard()
            .padding(Spacing.md)
            .frame(width: 320, alignment: .topLeading)
            .background(Color.canvas)
            .environments(session: session, bots: bots))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        panel.makeKeyAndOrderFront(nil)
        extraWindow = panel
    }

    /// The sidebar's glass and vibrant rows do not draw in a cached snapshot: the same list in a plain window does.
    @MainActor private static func showSidebar() {
        guard let navigator = currentNavigator, let session = currentSession, let bots = currentBots else { return }
        let host = NSHostingController(rootView: MacSidebar()
            .environment(navigator)
            .environments(session: session, bots: bots)
            .frame(width: 236, height: mainWindow?.contentLayoutRect.height ?? 760))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.makeKeyAndOrderFront(nil)
        extraWindow = panel
    }

    @MainActor static var currentNavigator: MacNavigator?
    @MainActor static var currentSession: SessionStore?
    @MainActor static var currentBots: BotsStore?

    private static func parseSize(_ text: String) -> NSSize? {
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    @MainActor private static func write(_ window: NSWindow, to name: String) {
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("demoSnapshot \(url.path)")
    }
}
#endif
