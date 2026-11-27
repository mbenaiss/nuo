import CoreGraphics

/**
 One finger on the page has two jobs to do. Moving it scrolls, which is what a touch screen owes the user. But a
 slider, a map or a drag and drop needs the button held down while the finger travels, and a scroll wheel can never
 say that, so from the phone those were simply out of reach. A finger that stays still for a moment before it moves
 now grabs what is under it instead.

 The press is only sent once the finger has actually travelled: a long press that never moves stays a tap, and the
 view's own tap gesture clicks it without this ever firing a second click on top of it.
 */
struct BrowserTouch: Equatable {
    /// How far the finger may travel before it is scrolling for good, in points.
    static let slop: CGFloat = 8
    /// How long it has to stay within that distance to take hold of the page instead.
    static let hold = Duration.milliseconds(450)

    enum Mode: Equatable { case undecided, scrolling, armed, grabbing }

    /// What the view has to send for this event.
    enum Action: Equatable {
        case nothing
        /// Keep scrolling by the distance travelled since the last event.
        case scroll
        /// Put the button down where the finger landed, then move it to where the finger is now.
        case press
        /// Keep the button down and follow the finger.
        case drag
        /// Let the button go.
        case release
        /// The flick carries on for a moment after the finger leaves.
        case coast
    }

    private(set) var mode: Mode = .undecided
    /// Set while this touch owns the page, so the tap gesture does not click on top of the grab.
    private(set) var grabbed = false

    /// A finger landed on the page.
    mutating func began() {
        mode = .undecided
        grabbed = false
    }

    /// The finger stayed put long enough to take hold.
    mutating func held() {
        guard mode == .undecided else { return }
        mode = .armed
    }

    mutating func moved(translation: CGSize) -> Action {
        switch mode {
        case .undecided:
            guard abs(translation.width) > Self.slop || abs(translation.height) > Self.slop else { return .nothing }
            mode = .scrolling
            return .scroll
        case .scrolling:
            return .scroll
        case .armed:
            mode = .grabbing
            grabbed = true
            return .press
        case .grabbing:
            return .drag
        }
    }

    mutating func ended() -> Action {
        defer { mode = .undecided }
        switch mode {
        case .grabbing: return .release
        case .scrolling: return .coast
        case .undecided, .armed: return .nothing
        }
    }
}
