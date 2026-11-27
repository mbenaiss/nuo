import AppKit
import SwiftUI

/// Mouse, trackpad and keyboard of the Mac, forwarded to the shared browser over the frame.
struct MacBrowserInput: NSViewRepresentable {
    let model: BrowserModel
    let onPageTap: () -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.model = model
        view.onPageTap = onPageTap
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.model = model
        view.onPageTap = onPageTap
    }

    final class InputView: NSView {
        var model: BrowserModel?
        var onPageTap: (() -> Void)?
        private var lastMove = Date.distantPast
        private var wheel = (x: 0.0, y: 0.0, dx: 0.0, dy: 0.0)
        private var wheelPending = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        private func point(_ event: NSEvent) -> (Double, Double) {
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
            return (p.x / bounds.width, p.y / bounds.height)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onPageTap?()
            let (x, y) = point(event)
            model?.send(.mouse(action: "down", x: x, y: y))
        }

        override func mouseUp(with event: NSEvent) {
            let (x, y) = point(event)
            model?.send(.mouse(action: "up", x: x, y: y))
        }

        override func mouseDragged(with event: NSEvent) { move(event, force: false) }
        override func mouseMoved(with event: NSEvent) { move(event, force: false) }

        override func rightMouseDown(with event: NSEvent) {
            let (x, y) = point(event)
            model?.send(.mouse(action: "down", x: x, y: y, button: "right"))
        }

        override func rightMouseUp(with event: NSEvent) {
            let (x, y) = point(event)
            model?.send(.mouse(action: "up", x: x, y: y, button: "right"))
        }

        private func move(_ event: NSEvent, force: Bool) {
            // Hover effects need moves, but not one message per pixel.
            guard force || Date().timeIntervalSince(lastMove) > 0.05 else { return }
            lastMove = Date()
            let (x, y) = point(event)
            model?.send(.mouse(action: "move", x: x, y: y))
        }

        /**
         The trackpad fires around sixty events a second, its momentum included. Each one as its own message would
         crowd the socket the frames come back on, so a frame's worth is added up and sent as one: the same distance
         scrolled, a fraction of the traffic.
         */
        override func scrollWheel(with event: NSEvent) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
            let (x, y) = point(event)
            wheel.x = x
            wheel.y = y
            wheel.dx += -event.scrollingDeltaX * lines / bounds.width
            wheel.dy += -event.scrollingDeltaY * lines / bounds.height
            guard !wheelPending else { return }
            wheelPending = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                self?.flushWheel()
            }
        }

        private func flushWheel() {
            wheelPending = false
            let pending = wheel
            wheel.dx = 0
            wheel.dy = 0
            guard pending.dx != 0 || pending.dy != 0 else { return }
            model?.send(.wheel(x: pending.x, y: pending.y, dx: pending.dx, dy: pending.dy))
        }

        private static let specialKeys: [UInt16: String] = [
            36: "Enter", 76: "Enter", 48: "Tab", 51: "Backspace", 53: "Escape", 117: "Delete",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
            115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        ]

        override func keyDown(with event: NSEvent) {
            guard let model else { return }
            let flags = event.modifierFlags
            var modifiers = 0
            if flags.contains(.option) { modifiers |= 1 }
            if flags.contains(.control) || flags.contains(.command) { modifiers |= 2 }
            if flags.contains(.shift) { modifiers |= 8 }
            if let key = Self.specialKeys[event.keyCode] {
                model.send(.key(key, modifiers: modifiers))
                return
            }
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags.contains(.command) {
                // The Mac clipboard is not the remote browser's: ⌘V types it instead.
                if characters == "v", let text = NSPasteboard.general.string(forType: .string) {
                    model.send(.text(text))
                } else if characters.count == 1 {
                    // ⌘A, ⌘C, ⌘Z… are Ctrl shortcuts on the Linux browser.
                    model.send(.key(characters, modifiers: modifiers))
                }
                return
            }
            if let text = event.characters, !text.isEmpty, !flags.contains(.control) {
                model.send(.text(text))
            } else if characters.count == 1 {
                model.send(.key(characters, modifiers: modifiers))
            }
        }
    }
}
