#if DEBUG
import AppKit
import QuartzCore

/// `-demo -demoBench paste` pastes ever longer texts into the chat composer with a real ⌘V, types a key, sends them and
/// logs how long the main thread froze; `-demoBench screens` opens every screen of the sidebar in turn, five rounds,
/// and logs how long each took to show, the longest frame and the memory footprint.
@MainActor
enum DemoPasteBench {
    static func run(navigator: MacNavigator) async {
        let monitor = StallMonitor()
        openMainWindow()
        navigator.openChat(ChatSelection(botId: "voyages", conversationId: "c-voyages-1"))
        try? await Task.sleep(for: .seconds(4))
        guard let window, let field = composer(in: window) else {
            let windows = NSApp.windows.map { String(format: "%@ %.0fx%.0f visible=%d", $0.title, $0.frame.width, $0.frame.height, $0.isVisible) }
            DemoBench.log("paste: no composer, windows: \(windows.joined(separator: " | "))")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        try? await Task.sleep(for: .milliseconds(500))
        monitor.start()
        try? await Task.sleep(for: .seconds(5))
        DemoBench.log("empty \(composerHeight)")
        DemoBench.log("idle \(monitor.summary()) responder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
        let sizes = (DemoDirector.argument("-demoPasteSizes") ?? "2000,20000,100000,400000").split(separator: ",").compactMap { Int($0) }
        for size in sizes {
            let text = sample(characters: size)
            let length = (text as NSString).length
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let pasted = await measure(monitor, until: { editorLength >= length }) { (window.firstResponder as? NSTextView)?.paste(nil) }
            let typed = await measure(monitor, until: { editorEndsWithTypedKey }) { post("é", keyCode: 0, flags: []) }
            // `-demoPasteTyping 10` keeps typing for that many seconds, to sample the process meanwhile.
            if let seconds = Double(DemoDirector.argument("-demoPasteTyping") ?? "") {
                let end = CACurrentMediaTime() + seconds
                while CACurrentMediaTime() < end {
                    _ = await measure(monitor, until: { editorEndsWithTypedKey }) { post("é", keyCode: 0, flags: []) }
                }
            }
            DemoBench.log(String(format: "paste %d chars=%d pasted=%@ typed=%@ footprint=%@ %@", size, editorLength, pasted, typed, DemoBench.footprint(), composerHeight))
            let sent = await measure(monitor, until: { editorLength == 0 }) { post("\r", keyCode: 36, flags: []) }
            // The demo bot streams a pasted text back, 240 characters every 22 ms, up to 60 000 characters.
            let streaming = Double(min(size, 60_000)) / 240 * 0.03 + 3
            let before = monitor.intervals.count
            try? await Task.sleep(for: .seconds(streaming))
            DemoBench.log(String(format: "send %d sent=%@ streamed=%@ footprint=%@ %@", size, sent, stalls(monitor, since: before), DemoBench.footprint(), composerHeight))
            await waitIdle()
        }
        monitor.stop()
        DemoBench.log("paste stalls \(monitor.summary())")
    }

    static func screens(navigator: MacNavigator) async {
        let monitor = StallMonitor()
        openMainWindow()
        let screens: [(String, @MainActor () -> Void)] = [
            ("chat", { navigator.openChat(ChatSelection(botId: "voyages", conversationId: "c-voyages-1")) }),
            ("chat-cobot", { navigator.openChat(ChatSelection(botId: "cobot", conversationId: "c-cobot-1")) }),
            ("chat-new", { navigator.newConversation(botId: "coach") }),
            ("calendar", { navigator.sidebar = .calendar }),
            ("booking", { navigator.sidebar = .booking }),
            ("dashboards", { navigator.sidebar = .dashboards }),
            ("collections", { navigator.sidebar = .collections }),
            ("docs", { navigator.sidebar = .docs }),
            ("today", { navigator.sidebar = .reminders(.today) }),
            ("upcoming", { navigator.sidebar = .reminders(.upcoming) }),
            ("logbook", { navigator.sidebar = .reminders(.logbook) }),
            ("schedules", { navigator.sidebar = .schedules }),
            ("memory", { navigator.sidebar = .memory }),
            ("meetings", { navigator.sidebar = .meetings }),
        ]
        try? await Task.sleep(for: .seconds(4))
        monitor.start()
        DemoBench.log("screens start footprint=\(DemoBench.footprint())")
        for round in 1...5 {
            for (name, show) in screens {
                let start = monitor.intervals.count
                let begun = CACurrentMediaTime()
                show()
                await waitIdle()
                let shown = (CACurrentMediaTime() - begun) * 1_000
                try? await Task.sleep(for: .milliseconds(700))
                if round == 1 || round == 5 {
                    DemoBench.log(String(format: "screen %d %@ shown=%.0fms longest=%@ footprint=%@", round, name, shown, longestFrame(monitor, since: start), DemoBench.footprint()))
                }
            }
        }
        monitor.stop()
        DemoBench.log("screens stalls \(monitor.summary()) footprint=\(DemoBench.footprint())")
    }

    /// The main window is not reopened at launch when it was closed when the app last quit: Window › Nuo opens it.
    static func openMainWindow() {
        guard window == nil, let menu = NSApp.mainMenu else { return }
        for item in menu.items {
            guard let entry = item.submenu?.items.first(where: { $0.title == "Nuo" }), let action = entry.action else { continue }
            NSApp.sendAction(action, to: entry.target, from: entry)
            return
        }
    }

    /// The composer must stay a few lines tall, under the messages, whatever its text.
    static var composerHeight: String {
        guard let window, let view = composer(in: window)?.enclosingScrollView as? ComposerScrollView else { return "composer=-" }
        return String(format: "composer=%.0fpt window=%.0fpt placeholder=%@", view.frame.height, window.contentLayoutRect.height,
                      view.showsPlaceholder ? "shown" : "hidden")
    }

    static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width > 600 } }

    /// UTF-16 length and last character of the field, read without bridging the whole text to a Swift string.
    private static var editorLength: Int { (window?.firstResponder as? NSTextView)?.textStorage?.length ?? 0 }

    private static var editorEndsWithTypedKey: Bool {
        guard let storage = (window?.firstResponder as? NSTextView)?.textStorage, storage.length > 0 else { return false }
        return (storage.string as NSString).character(at: storage.length - 1) == 0xE9
    }

    static func composer(in window: NSWindow) -> ComposerNSTextView? {
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let field = view as? ComposerNSTextView { return field }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    static func post(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Time until `done` holds, and the longest frame meanwhile: the freeze the user sees.
    static func measure(_ monitor: StallMonitor, until done: () -> Bool, _ action: () -> Void) async -> String {
        monitor.rebase()
        let start = monitor.intervals.count
        let begun = CACurrentMediaTime()
        action()
        while !done() {
            if CACurrentMediaTime() - begun > 30 { return "TIMEOUT" }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let elapsed = (CACurrentMediaTime() - begun) * 1_000
        await waitIdle()
        return String(format: "%.0fms(longest %@)", elapsed, longestFrame(monitor, since: start))
    }

    static func stalls(_ monitor: StallMonitor, since start: Int) -> String {
        let frames = monitor.intervals.dropFirst(max(0, start))
        let long = frames.filter { $0 > 0.1 }
        return String(format: "worst %.0fms, %d over 100ms (%.0fms)", (frames.max() ?? 0) * 1_000, long.count, long.reduce(0, +) * 1_000)
    }

    private static func longestFrame(_ monitor: StallMonitor, since start: Int) -> String {
        let frames = monitor.intervals.dropFirst(max(0, start))
        return String(format: "%.0fms", (frames.max() ?? 0) * 1_000)
    }

    static func waitIdle() async {
        for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// A main-thread timer: a gap between two fires is a freeze, whether or not the window is on screen.
    final class StallMonitor: NSObject {
        private(set) var intervals: [Double] = []
        private var timer: Timer?
        private var last: CFTimeInterval?

        /// App Nap would coalesce the timer of an app in the background and show freezes that are not there.
        private var activity: NSObjectProtocol?

        func start() {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Composer benchmark")
            let timer = Timer(timeInterval: 0.004, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        /// Work of the benchmark itself before a measure is not a freeze of the app.
        func rebase() { last = CACurrentMediaTime() }

        func stop() {
            timer?.invalidate()
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
        }

        @objc private func tick() {
            let now = CACurrentMediaTime()
            if let last { intervals.append(now - last) }
            last = now
        }

        func summary() -> String {
            let stalls = intervals.filter { $0 > 0.1 }
            return String(format: "ticks=%d over100ms=%d stalled=%.0fms worst=%.0fms", intervals.count, stalls.count,
                          stalls.reduce(0, +) * 1_000, (intervals.max() ?? 0) * 1_000)
        }
    }

    /// A pasted server log: long lines, numbers, `#` and code, like what gets copied into a chat.
    /// One line without breaks, like minified JSON, when `-demoPasteOneLine` is passed.
    static func sample(characters: Int) -> String {
        if ProcessInfo.processInfo.arguments.contains("-demoPasteOneLine") {
            return String(String(repeating: "{\"sku\":\"VP-889120\",\"qte\":2,\"prix\":34.9},", count: characters / 40 + 1).prefix(characters))
        }
        let lines = [
            "2026-10-31T09:14:02.381Z [gateway] prompt conv=c-voyages-1 bot=voyages tokens=48213 #deploy",
            "2026-10-31T09:14:02.512Z [runner] tool_call Bash \"curl -s https://api.ship24.com/public/v1/trackers\" status=pending",
            "    at Runner.prompt (/home/alex/nuo/gateway/src/runner/runner.ts:812:17)",
            "2026-10-31T09:14:05.004Z [hub] turn.done conv=c-voyages-1 firstText=2.8s total=5.7s steps=3",
            "Le vol AF1234 Paris-Lisbonne de lundi 3 novembre décolle à 07:35 du terminal 2F, porte F42, embarquement 07:05.",
        ]
        var text = ""
        var index = 0
        while text.utf8.count < characters {
            text += lines[index % lines.count] + "\n"
            index += 1
        }
        return String(text.utf8.prefix(characters)) ?? text
    }
}
#endif
