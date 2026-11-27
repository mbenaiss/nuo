#if DEBUG
import AppKit
import QuartzCore

/// `-demo -demoBench chat` drives the chat like a person would, with real key events sent to the window: typing,
/// ⌥Return, sending, the / and # palettes, a long paste, a pasted image, switching conversations, cancelling, undo,
/// queueing, resizing. Each step is checked against the composer and the conversation, and snapshots of the window go to
/// stdout as `SNAP <name> <base64 png>` so they can be looked at.
@MainActor
enum DemoChatTest {
    static weak var store: ConversationStore?
    static var transcript = TranscriptEdge(visibleMaxY: 0, contentHeight: 0, offsetY: 0, topInset: 0, containerHeight: 0)
    static var palettes: [String: CGFloat] = [:]
    /// Where the transcript's end marker is laid out, in the scroll view's visible area (0 under the toolbar); nil while
    /// the lazy stack has not laid it out. The scroll geometry's content height is an estimate that can hide its distance.
    static var transcriptEnd: CGRect?
    private static var passed = 0
    private static var failed: [String] = []

    static func run(navigator: MacNavigator) async {
        let monitor = DemoPasteBench.StallMonitor()
        DemoPasteBench.openMainWindow()
        navigator.openChat(ChatSelection(botId: "voyages", conversationId: "c-voyages-1"))
        try? await Task.sleep(for: .seconds(4))
        guard let window = DemoPasteBench.window, let store, DemoPasteBench.composer(in: window) != nil else {
            DemoBench.log("chat: no chat on screen")
            return
        }
        window.setContentSize(NSSize(width: 1280, height: 820))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        monitor.start()
        await settle()

        // Opening a chat
        check("composer focused on open", editor != nil, "\(String(describing: window.firstResponder))")
        check("placeholder shown when empty", scroll?.showsPlaceholder == true)
        check("composer one line high", (scroll?.frame.height ?? 0) < 40, "\(scroll?.frame.height ?? 0)")
        snap("01-open")

        // Typing
        let question = "Le vol AF1234 de lundi est à l'heure ? 😊"
        await type("Le vol AF1234 de lundi est à l'heure ? ")
        // Emoji come from the character palette, which inserts text: a synthesized key event cannot carry one.
        editor?.insertText("😊", replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0))
        await settle()
        check("typed text in the field", editorText == question, editorText)
        check("typed text in the draft", store.draft == question, store.draft)
        check("placeholder hidden while typing", scroll?.showsPlaceholder == false)
        snap("02-typed")

        // ⌥Return adds a line, the field grows
        await key("\r", code: 36, flags: .option)
        await type("Merci")
        check("option-return adds a line", store.draft == question + "\nMerci", store.draft.debugDescription)
        check("composer grows with a second line", (scroll?.frame.height ?? 0) > 40, "\(scroll?.frame.height ?? 0)")
        snap("03-two-lines")

        // Return sends, the answer streams
        let before = store.messages.count
        await key("\r", code: 36)
        check("return empties the field", editorText.isEmpty && store.draft.isEmpty, editorText)
        check("placeholder back after sending", scroll?.showsPlaceholder == true)
        check("composer back to one line", (scroll?.frame.height ?? 0) < 40, "\(scroll?.frame.height ?? 0)")
        await wait(5) { store.messages.count > before }
        check("question in the transcript", store.messages.dropFirst(before).first?.text == question + "\nMerci",
              store.messages.last?.text.prefix(60).description ?? "-")
        try? await Task.sleep(for: .milliseconds(900))
        snap("04-streaming")
        await wait(25) { !store.isRunning }
        check("answer arrives", !store.isRunning && store.messages.last?.role == .assistant, "\(store.messages.last?.role.rawValue ?? "-")")
        try? await Task.sleep(for: .seconds(1))
        check("transcript shows the end of the answer", atBottom, transcriptReport)
        snap("05-answered")
        try? await Task.sleep(for: .seconds(2))
        check("transcript rests on its end once the done line is gone", onEnd, transcriptReport)

        // / palette: ↓ ↑ move, Escape clears, Tab picks
        await type("/")
        check("slash opens the command palette", store.paletteQuery == "", store.paletteQuery ?? "nil")
        snap("06-slash-palette")
        check("command palette on screen", (palettes["slash"] ?? 0) > 40, "\(palettes["slash"] ?? 0)pt")
        await key(arrow(NSDownArrowFunctionKey), code: 125, flags: [.numericPad, .function])
        check("down moves the highlight", store.paletteHighlight == 1, "\(store.paletteHighlight)")
        await key(arrow(NSUpArrowFunctionKey), code: 126, flags: [.numericPad, .function])
        check("up moves it back", store.paletteHighlight == 0, "\(store.paletteHighlight)")
        await key("\u{1b}", code: 53)
        check("escape closes the palette", store.draft.isEmpty && store.paletteQuery == nil, store.draft.debugDescription)
        await type("/")
        let withArgs = store.paletteMatches.firstIndex { $0.takesArgs }
        for _ in 0..<(withArgs ?? 0) { await key(arrow(NSDownArrowFunctionKey), code: 125, flags: [.numericPad, .function]) }
        let picked = withArgs.map { store.paletteMatches[$0].name }
        await key("\t", code: 48)
        check("tab picks the highlighted command", picked != nil && store.draft == "/\(picked ?? "") ", "\(picked ?? "-") \(store.draft.debugDescription)")
        check("field shows the picked command", editorText == store.draft, editorText.debugDescription)
        snap("07-command-picked")
        store.draft = ""
        await settle()
        check("clearing the draft clears the field", editorText.isEmpty, editorText.debugDescription)

        // # palette
        await type("Vérifie #")
        check("hash opens the tool palette", ToolTag.query(in: store.draft) == "", store.draft.debugDescription)
        snap("08-hash-palette")
        check("tool palette on screen", (palettes["tag"] ?? 0) > 40, "\(palettes["tag"] ?? 0)pt")
        await key("\u{1b}", code: 53)
        check("escape removes the tag being typed", store.draft == "Vérifie ", store.draft.debugDescription)
        store.draft = ""
        await settle()

        // Return is not swallowed by a palette with nothing to pick
        for text in ["Corrige l'issue #42", "/Users/alex/Documents/devis-cuisine.pdf"] {
            let count = store.messages.count
            await type(text)
            await key("\r", code: 36)
            await wait(5) { store.messages.count > count }
            check("return sends « \(text) »", store.draft.isEmpty && store.messages.contains { $0.text == text }, store.draft.debugDescription)
            await wait(25) { !store.isRunning }
        }

        // Tab without a palette moves on instead of typing a tab; ⌘Return sends
        await type("Réserve une table")
        await key("\t", code: 48)
        check("tab without a palette types nothing", store.draft == "Réserve une table", store.draft.debugDescription)
        editor?.window?.makeFirstResponder(editor ?? scroll?.textView)
        if let field = scroll?.textView { field.window?.makeFirstResponder(field) }
        await settle()
        let beforeCommand = store.messages.count
        await key("\r", code: 36, flags: .command)
        await wait(5) { store.messages.count > beforeCommand }
        check("command-return sends", store.draft.isEmpty && store.messages.count > beforeCommand, store.draft.debugDescription)
        await wait(25) { !store.isRunning }

        // Undo after a send has nothing left to undo in the field
        await type("Bonjour")
        await key("\r", code: 36)
        await wait(25) { !store.isRunning }
        editor?.undoManager?.undo()
        await settle()
        check("undo after sending leaves the field empty", store.draft.isEmpty && editorText.isEmpty, "\(store.draft.debugDescription) \(editorText.debugDescription)")

        // Undo keeps the field and the draft together
        var undoMismatches: [String] = []
        for phrase in ["Réserve un taxi", "Annule la réunion de 15 h", "Rappelle-moi d'appeler Julie Martin"] {
            for _ in 0..<2 {
                await type(phrase)
                editor?.undoManager?.undo()
                await settle()
                if store.draft != editorText { undoMismatches.append("\(store.draft.debugDescription) vs \(editorText.debugDescription)") }
                store.draft = ""
                await settle()
            }
        }
        check("undo keeps the draft and the field together (6 tries)", undoMismatches.isEmpty, undoMismatches.joined(separator: "; "))

        // A long paste, sent, answered
        let long = DemoPasteBench.sample(characters: 100_000)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(long, forType: .string)
        let pasteStart = monitor.intervals.count
        editor?.paste(nil)
        await settle()
        check("long paste lands whole", (editor?.textStorage?.length ?? 0) == (long as NSString).length, "\(editor?.textStorage?.length ?? 0)")
        check("long paste stays ten lines high", (scroll?.frame.height ?? 0) < 200, "\(scroll?.frame.height ?? 0)")
        check("long paste does not freeze", worst(monitor, since: pasteStart) < 0.25, String(format: "%.0fms", worst(monitor, since: pasteStart) * 1_000))
        snap("09-long-draft")
        let typedStart = monitor.intervals.count
        await type("Résume")
        check("typing after a long paste stays fluid", worst(monitor, since: typedStart) < 0.15, String(format: "%.0fms", worst(monitor, since: typedStart) * 1_000))
        let sendStart = monitor.intervals.count
        await key("\r", code: 36)
        await wait(5) { store.messages.last?.role == .user || store.isRunning }
        check("long message sent", store.draft.isEmpty, "\(store.draft.count)")
        check("sending a long message does not freeze", worst(monitor, since: sendStart) < 0.5, String(format: "%.0fms", worst(monitor, since: sendStart) * 1_000))
        snap("10-long-sent")
        let streamStart = monitor.intervals.count
        await wait(40) { !store.isRunning }
        check("long answer completes", !store.isRunning)
        try? await Task.sleep(for: .seconds(1))
        check("transcript follows the long answer to its end", atBottom, transcriptReport)
        check("long answer streams without long freezes", worst(monitor, since: streamStart) < 0.25,
              String(format: "worst %.0fms, %d over 100ms", worst(monitor, since: streamStart) * 1_000, over(monitor, since: streamStart, 0.1)))
        snap("11-long-answer")

        // Scrolling a transcript with long messages
        do {
            let scrollStart = monitor.intervals.count
            for _ in 0..<40 { await wheel(lines: 12) }
            snap("12-scrolled-up")
            check("wheel scrolls the transcript up", !atBottom, transcriptReport)
            for _ in 0..<60 { await wheel(lines: -12) }
            check("scrolling stays fluid", worst(monitor, since: scrollStart) < 0.2, String(format: "%.0fms", worst(monitor, since: scrollStart) * 1_000))
            check("wheel brings the transcript back down", atBottom, transcriptReport)
        }

        // A pasted image becomes an attachment, not text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(sampleImage(), forType: .png)
        editor?.paste(nil)
        await wait(5) { !store.attachments.isEmpty }
        check("pasted image attached", store.attachments.count == 1 && editorText.isEmpty, "\(store.attachments.count) \(editorText.debugDescription)")
        snap("13-image")
        store.attachments.removeAll()
        await settle()

        // Draft kept across conversations, focus back in the composer
        await type("Brouillon à garder")
        navigator.openChat(ChatSelection(botId: "cobot", conversationId: "c-cobot-1"))
        try? await Task.sleep(for: .seconds(2))
        check("other conversation opens empty", self.store?.draft.isEmpty == true, self.store?.draft ?? "nil")
        navigator.openChat(ChatSelection(botId: "voyages", conversationId: "c-voyages-1"))
        try? await Task.sleep(for: .seconds(2))
        check("draft restored when coming back", self.store?.draft == "Brouillon à garder" && editorText == "Brouillon à garder",
              "\(self.store?.draft ?? "nil") / \(editorText)")
        check("composer focused after switching", editor != nil)
        check("conversation reopened on its end", onEnd, transcriptReport)
        snap("14-draft-restored")
        guard let store = self.store else { return finish(monitor) }
        store.draft = ""
        await settle()

        // Escape cancels a running answer; a message sent meanwhile is queued
        await type("Explique en détail le programme de lundi")
        await key("\r", code: 36)
        await wait(3) { store.isRunning }
        await type("Et mardi ?")
        await key("\r", code: 36)
        check("message sent during an answer is queued", store.queued.count == 1, "\(store.queued.count)")
        snap("15-queued")
        await key("\u{1b}", code: 53)
        await wait(5) { !store.isRunning || store.messages.last?.stopReason == .cancelled }
        check("escape stops the answer", store.messages.contains { $0.stopReason == .cancelled }, "\(store.messages.last?.stopReason?.rawValue ?? "-")")
        await wait(30) { !store.isRunning && store.queued.isEmpty }
        check("queued message sent afterwards", store.queued.isEmpty && store.messages.contains { $0.text == "Et mardi ?" })
        snap("16-after-queue")

        // The window resized while the end is on screen: the end stays above the composer
        await type("Quel temps à Nice demain ?")
        await key("\r", code: 36)
        await wait(3) { store.isRunning }
        await wait(25) { !store.isRunning }
        try? await Task.sleep(for: .seconds(1))
        window.setContentSize(NSSize(width: 1280, height: 640))
        try? await Task.sleep(for: .seconds(2.5))
        check("window shortened right after an answer keeps its end on screen", onEnd, transcriptReport)
        snap("17-resized-after-answer")
        window.setContentSize(NSSize(width: 1280, height: 820))
        await settle()
        await type("Résume la journée de demain")
        await key("\r", code: 36)
        await wait(3) { store.isRunning }
        try? await Task.sleep(for: .milliseconds(900))
        window.setContentSize(NSSize(width: 1280, height: 640))
        await wait(25) { !store.isRunning }
        try? await Task.sleep(for: .seconds(2.5))
        check("window shortened while an answer streams keeps following it", onEnd, transcriptReport)
        window.setContentSize(NSSize(width: 1280, height: 820))
        await settle()

        // A reader who scrolled up is left there when the answer ends
        await type("Résume la journée de demain")
        await key("\r", code: 36)
        await wait(3) { store.isRunning }
        try? await Task.sleep(for: .milliseconds(400))
        for _ in 0..<6 { await wheel(lines: 6) }
        try? await Task.sleep(for: .milliseconds(600))
        let readerOffset = transcript.offsetY
        await wait(25) { !store.isRunning }
        try? await Task.sleep(for: .seconds(2.5))
        check("reader scrolled up stays there when the answer ends", !atBottom && abs(transcript.offsetY - readerOffset) <= 1,
              String(format: "offset %.0f then %.0f, ", readerOffset, transcript.offsetY) + transcriptReport)
        for _ in 0..<40 { await wheel(lines: -12) }
        await settle()

        // A narrow window keeps the composer usable
        window.setContentSize(NSSize(width: 760, height: 620))
        await type("Une question assez longue pour passer sur plusieurs lignes dans une fenêtre étroite, avec des accents à gogo")
        await settle()
        check("narrow window wraps the draft", (scroll?.frame.height ?? 0) > 40 && (scroll?.frame.height ?? 0) < 200, "\(scroll?.frame.height ?? 0)")
        snap("18-narrow")
        store.draft = ""
        window.setContentSize(NSSize(width: 1280, height: 820))
        await settle()

        // A single very long line (minified JSON) stays fluid to type in
        let json = "{\"commande\":\"ORD-2026-104857\",\"client\":\"Julie Martin\",\"lignes\":[" + String(repeating: "{\"sku\":\"VP-889120\",\"qte\":2,\"prix\":34.9},", count: 6_000) + "{}]}"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        editor?.paste(nil)
        await settle()
        let lineStart = monitor.intervals.count
        await type("ok")
        // TextKit lays out a whole paragraph again on each edit: one of 250 000 characters costs a few hundred ms.
        check("typing after a 250 000 character line stays usable", worst(monitor, since: lineStart) < 0.4,
              String(format: "%.0fms", worst(monitor, since: lineStart) * 1_000))
        store.draft = ""
        await settle()

        // Fast typing
        let burst = String(repeating: "abcdefghij ", count: 30)
        await type(burst, pause: false)
        check("fast typing loses nothing", store.draft == burst && editorText == burst, "\(store.draft.count) / \(editorText.count)")
        store.draft = ""
        await settle()

        // Switching conversations many times
        let footprintBefore = DemoBench.footprint()
        let switchStart = monitor.intervals.count
        for index in 0..<30 {
            let pick = [("voyages", "c-voyages-1"), ("cobot", "c-cobot-1"), ("coach", "c-coach-1")][index % 3]
            navigator.openChat(ChatSelection(botId: pick.0, conversationId: pick.1))
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2))
        check("30 conversation switches", DemoPasteBench.composer(in: window) != nil,
              String(format: "worst %.0fms, footprint %@ -> %@", worst(monitor, since: switchStart) * 1_000, footprintBefore, DemoBench.footprint()))
        snap("19-after-switches")

        await longTranscripts(window: window, navigator: navigator)
        finish(monitor)
    }

    /// Conversations with messages several screens tall open on their end, keep it when the window changes size, and
    /// follow an answer to its end.
    private static func longTranscripts(window: NSWindow, navigator: MacNavigator) async {
        guard let backend = DemoSnapshot.currentSession?.api as? DemoBackend else { return check("long conversations seeded", false) }
        for (index, layout) in DemoLongChats.layouts.enumerated() {
            window.setContentSize(NSSize(width: 1280, height: 820))
            guard let conversation = try? await backend.createConversation(botId: "voyages", useDraft: false) else { continue }
            await backend.record(conversationId: conversation.id, messages: DemoLongChats.messages(layout, conversationId: conversation.id))
            navigator.openChat(ChatSelection(botId: "voyages", conversationId: conversation.id))
            try? await Task.sleep(for: .seconds(3))
            check("\(layout.name): opens on its end", endOnScreen, endReport)
            snap("20-long-\(index)-open")
            window.setContentSize(NSSize(width: 1040, height: 480))
            try? await Task.sleep(for: .seconds(2.5))
            check("\(layout.name): keeps its end in a smaller window", endOnScreen, endReport)
            window.setContentSize(NSSize(width: 1280, height: 820))
            try? await Task.sleep(for: .seconds(2.5))
            check("\(layout.name): keeps its end in a larger window", endOnScreen, endReport)
            snap("21-long-\(index)-resized")
        }
        guard let store else { return }
        await type("Résume la journée de demain")
        await key("\r", code: 36)
        await wait(3) { store.isRunning }
        await wait(25) { !store.isRunning }
        try? await Task.sleep(for: .seconds(2))
        check("long conversation follows a new answer to its end", endOnScreen, endReport)
    }

    private static func finish(_ monitor: DemoPasteBench.StallMonitor) {
        monitor.stop()
        DemoBench.log("chat stalls \(monitor.summary()) footprint=\(DemoBench.footprint())")
        DemoBench.log("chat done passed=\(passed) failed=\(failed.count) \(failed.joined(separator: " | "))")
    }

    // MARK: Helpers

    private static var editor: ComposerNSTextView? { DemoPasteBench.window?.firstResponder as? ComposerNSTextView }
    private static var editorText: String { editor?.string ?? "<no focus>" }
    private static var scroll: ComposerScrollView? {
        guard let window = DemoPasteBench.window else { return nil }
        return DemoPasteBench.composer(in: window)?.enclosingScrollView as? ComposerScrollView
    }

    /// The point a third of the way up the transcript, above the composer.
    private static var transcriptPoint: NSPoint? {
        guard let composer = scroll, let window = composer.window else { return nil }
        let frame = composer.convert(composer.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.maxY + (window.contentLayoutRect.height - frame.maxY) / 3)
    }

    /// A mouse wheel notch over the transcript, given to the view under the pointer as the hardware event would be.
    private static func wheel(lines: Int32) async {
        guard let point = transcriptPoint, let window = scroll?.window, let content = window.contentView,
              let target = content.hitTest(content.convert(point, from: nil)),
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        let screen = window.convertPoint(toScreen: point)
        cgEvent.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        target.scrollWheel(with: event)
        try? await Task.sleep(for: .milliseconds(30))
    }

    private static var atBottom: Bool { transcript.visibleMaxY >= transcript.contentHeight - 90 }

    /// The last message right above the composer: neither under it nor with an empty band below it.
    private static var onEnd: Bool { abs(transcript.pastEnd) <= TranscriptEdge.pastEndTolerance }

    /// The end marker right on the top of the bottom bar, as laid out: neither under it nor above an empty band.
    private static var endOnScreen: Bool {
        guard let end = transcriptEnd else { return false }
        return abs(transcript.containerHeight - end.maxY) <= TranscriptEdge.pastEndTolerance
    }

    private static var endReport: String {
        guard let end = transcriptEnd else { return "end not laid out, " + transcriptReport }
        return String(format: "end %.1f pt above the bar, ", transcript.containerHeight - end.maxY) + transcriptReport
    }

    private static var transcriptReport: String {
        String(format: "visible to %.0f of %.0f, %.1f pt past the end", transcript.visibleMaxY, transcript.contentHeight, transcript.pastEnd)
    }

    /// Whether a text containing this is drawn in the window, read through the accessibility tree SwiftUI builds.
    private static func hasText(containing needle: String) -> Bool {
        guard let root = DemoPasteBench.window?.contentView else { return false }
        var stack: [Any] = [root]
        var visited = 0
        while let element = stack.popLast(), visited < 20_000 {
            visited += 1
            guard let object = element as? NSObject else { continue }
            for key in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
                if object.responds(to: NSSelectorFromString(key)), let text = object.value(forKey: key) as? String, text.contains(needle) { return true }
            }
            if let children = (object as? NSAccessibilityElementProtocol).flatMap({ _ in (object as? NSView)?.accessibilityChildren() ?? (object as? NSAccessibilityElement)?.accessibilityChildren() }) {
                stack.append(contentsOf: children)
            }
            if let view = object as? NSView { stack.append(contentsOf: view.subviews) }
        }
        return false
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed.append(name) }
        DemoBench.log("CHECK \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail.prefix(160))")")
    }

    private static func type(_ text: String, pause: Bool = true) async {
        for character in text {
            DemoPasteBench.post(String(character), keyCode: 0, flags: [])
            if pause { try? await Task.sleep(for: .milliseconds(12)) }
        }
        await settle()
    }

    private static func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) async {
        DemoPasteBench.post(characters, keyCode: code, flags: flags)
        await settle()
    }

    private static func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt16(key))!)) }

    private static func settle() async {
        for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(40)) }
    }

    private static func wait(_ seconds: Double, until done: () -> Bool) async {
        let end = CACurrentMediaTime() + seconds
        while !done(), CACurrentMediaTime() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private static func worst(_ monitor: DemoPasteBench.StallMonitor, since start: Int) -> Double {
        monitor.intervals.dropFirst(max(0, start)).max() ?? 0
    }

    private static func over(_ monitor: DemoPasteBench.StallMonitor, since start: Int, _ limit: Double) -> Int {
        monitor.intervals.dropFirst(max(0, start)).filter { $0 > limit }.count
    }

    private static func sampleImage() -> Data {
        let image = NSImage(size: NSSize(width: 240, height: 140), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            ("Billet AF1234" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// The window as it draws itself (no Screen Recording permission needed), at 1x, base64 on stdout.
    private static func snap(_ name: String) {
        // Lets transitions end: a snapshot mid-animation shows views half in place.
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        guard let view = DemoPasteBench.window?.contentView?.superview else { return }
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        print("SNAP \(name) \(png.base64EncodedString())")
        fflush(stdout)
    }
}
#endif
