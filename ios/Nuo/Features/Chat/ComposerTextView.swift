import SwiftUI
import UIKit

enum ComposerKey { case up, down, tab, enter, escape }

/// UIKit field behind the composer: SwiftUI's TextField refuses to paste an image, this one hands it to `onPasteImage`.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// A value, not a binding: the parent re-renders on focus changes only when its body reads it.
    var focused: Bool
    var onFocusChange: (Bool) -> Void = { _ in }
    var autocorrects = true
    var capitalizes = true
    var maxLines = 6
    var onKey: (ComposerKey) -> Bool = { _ in false }
    var onPasteImage: () -> Void = {}

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Color.ink)
        view.tintColor = UIColor(Color.accent)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        view.onKey = onKey
        view.onPasteImage = onPasteImage
        // Rewriting the text mid-composition would drop the marked (IME) text.
        if view.text != text, view.markedTextRange == nil { view.text = text }
        let correction: UITextAutocorrectionType = autocorrects ? .default : .no
        let capitalization: UITextAutocapitalizationType = capitalizes ? .sentences : .none
        if view.autocorrectionType != correction || view.autocapitalizationType != capitalization {
            view.autocorrectionType = correction
            view.autocapitalizationType = capitalization
            if view.isFirstResponder { view.reloadInputViews() }
        }
        if focused, !view.isFirstResponder, view.window != nil {
            // Leaving the chat can run this just before the view goes: it must not take the keyboard to the next screen.
            DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
        } else if !focused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maxHeight = context.coordinator.height(ofLines: maxLines, like: view, width: width)
        let scrolls = fitting > maxHeight
        if view.isScrollEnabled != scrolls { DispatchQueue.main.async { view.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: min(fitting, maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        private var measured: (key: String, height: CGFloat)?
        init(_ parent: ComposerTextView) { self.parent = parent }

        /// Measured on a probe: TextKit's line pitch is taller than `font.lineHeight`, so a computed cap cuts the last line.
        func height(ofLines lines: Int, like view: UITextView, width: CGFloat) -> CGFloat {
            let font = view.font ?? .preferredFont(forTextStyle: .body)
            let key = "\(font.pointSize)-\(lines)"
            if let measured, measured.key == key { return measured.height }
            let probe = UITextView()
            probe.font = font
            probe.textContainerInset = view.textContainerInset
            probe.textContainer.lineFragmentPadding = view.textContainer.lineFragmentPadding
            probe.isScrollEnabled = false
            probe.text = Array(repeating: "M", count: lines).joined(separator: "\n")
            let height = probe.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            measured = (key, height)
            return height
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { parent.onFocusChange(true) }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.onFocusChange(false) }
        }
    }
}

final class PastingTextView: UITextView {
    var onKey: (ComposerKey) -> Bool = { _ in false }
    var onPasteImage: () -> Void = {}

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Copied text wins over an image so a link copied with its preview still pastes as text, as on the Mac.
    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        guard board.hasImages, !board.hasStrings else { return super.paste(sender) }
        onPasteImage()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let modifiers = presses.first?.key?.modifierFlags.intersection([.command, .control, .alternate, .shift]) ?? []
        if presses.count == 1, modifiers.isEmpty, let key = presses.first?.key.flatMap(Self.composerKey), onKey(key) { return }
        super.pressesBegan(presses, with: event)
    }

    private static func composerKey(_ key: UIKey) -> ComposerKey? {
        switch key.keyCode {
        case .keyboardUpArrow: .up
        case .keyboardDownArrow: .down
        case .keyboardTab: .tab
        case .keyboardReturnOrEnter: .enter
        case .keyboardEscape: .escape
        default: nil
        }
    }
}
