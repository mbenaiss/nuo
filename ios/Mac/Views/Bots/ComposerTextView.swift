import AppKit
import SwiftUI

/// Keys the composer may take before the text view: the palettes use them while open.
enum ComposerKey {
    case send, up, down, tab, escape
}

/// The composer's text view. A SwiftUI `TextField` measured and laid out its whole text on every keystroke, so a pasted
/// log of 100 000 characters froze the window for most of a second per key; TextKit 2 lays out only the lines on screen.
struct ComposerTextView: NSViewRepresentable {
    let text: TextAccess
    /// Changes when the field starts showing another conversation's draft, whose undo history it must not reach.
    var history: AnyHashable = 0
    let placeholder: String
    @Binding var isFocused: Bool
    var maxLines = 10
    /// Returns true when the key was used and the text view must ignore it.
    let onKey: (ComposerKey) -> Bool
    /// Returns true when the pasteboard held attachments (images, files) that were taken instead of text.
    let onPaste: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let view = ComposerScrollView(maxLines: maxLines)
        let textView = view.textView
        textView.delegate = context.coordinator
        view.placeholder = placeholder
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.focusChanged(focused) }
        textView.onPaste = { [weak coordinator = context.coordinator] in coordinator?.parent.onPaste() ?? false }
        let text = text.value
        textView.string = text
        context.coordinator.synced = text
        context.coordinator.history = history
        context.coordinator.observe(textView)
        view.updatePlaceholder()
        return view
    }

    /// A scroll view takes all the height it is offered: without this, the composer filled the chat and hid the messages.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ComposerScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    func updateNSView(_ view: ComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let textView = view.textView
        if view.placeholder != placeholder { view.placeholder = placeholder }
        if coordinator.history != history {
            coordinator.history = history
            if textView.hasMarkedText() { textView.inputContext?.discardMarkedText() }
            coordinator.undo.removeAllActions()
        }
        // Compared with what was last exchanged rather than with the text view's string, which would copy the whole
        // text: both usually share their storage, which makes the comparison immediate.
        let text = text.value
        if text != coordinator.synced {
            coordinator.synced = text
            coordinator.applying = true
            // A send, a palette or the dictation replaces the text: a composition in progress would otherwise put the
            // replaced text back when it ends.
            if textView.hasMarkedText() { textView.inputContext?.discardMarkedText() }
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.applying = false
            // Undo entries point at ranges of the text just replaced.
            coordinator.undo.removeAllActions()
            view.textDidChange()
        }
        if isFocused != coordinator.focused {
            coordinator.focused = isFocused
            textView.wantsFocus = isFocused
            // Changing the first responder during a SwiftUI update is not allowed.
            DispatchQueue.main.async { [weak textView] in textView?.applyFocus() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        /// The text both sides last agreed on.
        var synced = ""
        var history: AnyHashable?
        var focused = false
        /// Set while the draft is written into the text view, whose change must not go back to the draft.
        var applying = false
        /// The field's own history: the window's one is shared with every other field and conversation.
        let undo = UndoManager()

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        nonisolated(unsafe) private var storageObserver: NSObjectProtocol?
        /// Edits of the text, and how many of them the draft has seen: counted rather than compared, since comparing a
        /// long accented text costs a Unicode normalisation on every keystroke.
        private var edits = 0
        private var pushedEdits = 0

        deinit {
            if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// An undo does not always end with a text-did-change notification, and the draft then kept the text the field
        /// no longer showed: every edit of the storage is counted, and one left unseen is pushed right after.
        func observe(_ textView: ComposerNSTextView) {
            guard let storage = textView.textStorage else { return }
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
            ) { [weak self, weak textView] _ in
                guard storage.editedMask.contains(.editedCharacters) else { return }
                MainActor.assumeIsolated {
                    guard let self, !self.applying else { return }
                    self.edits += 1
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let textView, self.pushedEdits != self.edits else { return }
                        self.pushText(of: textView)
                    }
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            pushText(of: textView)
        }

        private func pushText(of textView: ComposerNSTextView) {
            guard !applying else { return }
            pushedEdits = edits
            let text = textView.string
            synced = text
            parent.text.value = text
            (textView.enclosingScrollView as? ComposerScrollView)?.textDidChange()
        }

        /// Written back on the next turn of the run loop: AppKit also resigns the field while SwiftUI tears the pane down,
        /// and state must not change during a view update.
        func focusChanged(_ isFocused: Bool) {
            guard focused != isFocused else { return }
            focused = isFocused
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focused == isFocused else { return }
                self.parent.isFocused = isFocused
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if flags.contains(.option) || flags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                return parent.onKey(.send)
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)):
                if !parent.onKey(.tab) { textView.window?.selectNextKeyView(nil) }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Left to the text view, Escape opens the word completion list.
                _ = parent.onKey(.escape)
                return true
            case NSSelectorFromString("noop:"):
                // ⌘Return reaches the field as a no-op: it sends, like Return.
                guard let event = NSApp.currentEvent, [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) else { return false }
                return parent.onKey(.send)
            default: return false
            }
        }
    }
}

/// Grows with its text up to `maxLines`, then scrolls.
final class ComposerScrollView: NSScrollView {
    let textView: ComposerNSTextView
    private let maxLines: Int
    /// A label over the text view rather than drawn by it: TextKit 2 does not redraw the text view itself as the user
    /// types, so a drawn placeholder stayed under the first characters.
    private let placeholderLabel = PassThroughLabel(labelWithString: "")

    var placeholder: String {
        get { placeholderLabel.stringValue }
        set { placeholderLabel.stringValue = newValue }
    }

    init(maxLines: Int) {
        self.maxLines = maxLines
        textView = ComposerNSTextView(usingTextLayoutManager: true)
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // Commands, paths and code are sent to bots as typed: no curly quotes or long dashes.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        documentView = textView
        setContentHuggingPriority(.required, for: .vertical)
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: textView.textContainerInset.height),
        ])
        textView.onTextChange = { [weak self] in self?.updatePlaceholder() }
    }

    var showsPlaceholder: Bool { !placeholderLabel.isHidden }

    func updatePlaceholder() {
        placeholderLabel.isHidden = (textView.textStorage?.length ?? 0) > 0
    }

    required init?(coder: NSCoder) { nil }

    private var lineHeight: CGFloat {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        return ceil(font.ascender - font.descender + font.leading)
    }

    private var maxHeight: CGFloat { lineHeight * CGFloat(maxLines) + textView.textContainerInset.height * 2 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    /// Lays out the text only until it is taller than the composer can grow.
    func height(forWidth width: CGFloat) -> CGFloat {
        let inset = textView.textContainerInset.height * 2
        let single = lineHeight + inset
        let length = textView.textStorage?.length ?? 0
        guard width > 0, length > 0 else { return single }
        // Ten lines hold far fewer characters: no layout, which a single long line (minified JSON, base64) would make
        // as long as the whole line on every keystroke.
        if length > Self.alwaysFullLength { return maxHeight }
        if textView.frame.width != width { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        let limit = maxHeight - inset
        var height: CGFloat = 0
        if let layout = textView.textLayoutManager {
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                height = fragment.layoutFragmentFrame.maxY
                return height < limit
            }
        } else if let layout = textView.layoutManager, let container = textView.textContainer {
            // An extension that asks for the TextKit 1 layout manager switches the view over to it.
            layout.ensureLayout(for: container)
            height = layout.usedRect(for: container).height
        }
        return min(maxHeight, max(single, ceil(height) + inset))
    }

    static let alwaysFullLength = 4_000

    func textDidChange() {
        updatePlaceholder()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

final class ComposerNSTextView: NSTextView {
    /// Focus asked by SwiftUI, applied once the view is in a window: a chat that opens asks before its view is placed.
    var wantsFocus = false
    var onTextChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onPaste: (() -> Bool)?

    func applyFocus() {
        guard let window else { return }
        if wantsFocus, window.firstResponder !== self {
            window.makeFirstResponder(self)
        } else if !wantsFocus, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { DispatchQueue.main.async { [weak self] in self?.applyFocus() } }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            wantsFocus = true
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            wantsFocus = false
            onFocusChange?(false)
        }
        return resigned
    }

    override func paste(_ sender: Any?) {
        if onPaste?() == true { return }
        pasteAsPlainText(sender)
    }

    /// Files and images dropped on the composer go to the chat's drop zone, which attaches them.
    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }
}

/// Clicks go through to the text view under it.
private final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
