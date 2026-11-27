import SwiftUI

/// Where a chat transcript is scrolled, in its content's coordinates, with the bottom bar (composer, status line,
/// keyboard) laid over the end through the scroll view's bottom inset.
struct TranscriptEdge: Equatable {
    /// Bottom of the visible rect, the area under the bottom bar included.
    var visibleMaxY: CGFloat
    var contentHeight: CGFloat
    var offsetY: CGFloat
    var topInset: CGFloat
    /// The viewport between the top and bottom insets.
    var containerHeight: CGFloat

    /// The scroll view keeps its offset when the content gets shorter or the bottom bar lower: a transcript scrolled
    /// to its end then shows past it, and only a drag brings it back. Beyond this, the band is visible.
    static let pastEndTolerance: CGFloat = 1

    var isNearBottom: Bool { visibleMaxY >= contentHeight - 80 }

    /// How far the area above the bottom bar reaches past the end of the content: an empty band when positive.
    /// Content shorter than the viewport is held at the bottom by a larger top inset, so it is measured against the
    /// viewport rather than its own height.
    var pastEnd: CGFloat { offsetY + topInset + containerHeight - max(contentHeight, containerHeight) }

    /// Put back on its end only once nothing else moves it: the reader dragging or flinging past the end bounces
    /// back on their own, and an animated scroll still on its way must not be cut short.
    func needsSnapBack(scrollIdle: Bool) -> Bool {
        scrollIdle && pastEnd > Self.pastEndTolerance
    }
}

extension TranscriptEdge {
    init(_ geometry: ScrollGeometry) {
        self.init(
            visibleMaxY: geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height,
            offsetY: geometry.contentOffset.y, topInset: geometry.contentInsets.top,
            containerHeight: geometry.containerSize.height)
    }
}

extension TranscriptEdge {
    /// How much of the content lies under the bottom bar or below it: zero on the end or past it.
    var hiddenBelowEnd: CGFloat { max(0, -pastEnd) }
}

/// Whether the reader follows the end of a transcript. Decided by where the reader leaves it, not by where it happens
/// to be: an answer growing fast, a card laid out after the last delta or the keyboard rising push the end out of
/// view without the reader having moved.
struct TranscriptFollow: Equatable {
    private(set) var following = true
    /// The reader let go close to the end and the scroll view is carrying the transcript onto it.
    private(set) var landingOnEnd = false
    /// Top of the visible rect, in the content's coordinates, kept while a block the reader expanded grows under it.
    private(set) var expandedFromY: CGFloat?
    /// The reader tapped the status bar and the scroll view is carrying the transcript to its top.
    private(set) var scrollingToTop = false

    /// A reader who stops scrolling this close to the end is still on it.
    static let endZone: CGFloat = 80

    /// The reader dragged or flung the transcript, or dragged the keyboard down with it. While the transcript lands
    /// on its end, the geometry changing is the keyboard rising or an answer growing, not the reader.
    mutating func readerScrolled(to edge: TranscriptEdge) {
        guard !landingOnEnd else { return }
        following = edge.hiddenBelowEnd <= Self.endZone
    }

    /// A jump to the end, a message sent, a conversation opened.
    mutating func returnToEnd() {
        following = true
        expandedFromY = nil
        scrollingToTop = false
    }

    /// Something other than the reader moved the transcript or its end (an answer growing, the bottom bar changing
    /// height, a layout pass): whether to put it back on its end. Past the end there is an empty band, and a reader
    /// following the end must see whatever grew under the bottom bar. An end that comes into view this way, the
    /// keyboard going down say, is the reader's again.
    mutating func settled(on edge: TranscriptEdge) -> Bool {
        let tolerance = TranscriptEdge.pastEndTolerance
        if scrollingToTop {
            guard edge.offsetY + edge.topInset <= tolerance else { return false }
            scrollingToTop = false
        }
        if edge.hiddenBelowEnd <= tolerance { following = true }
        return edge.pastEnd > tolerance || following && edge.hiddenBelowEnd > tolerance
    }
}

/// The visible rect a scroll view proposes to come to rest on, in its content's coordinates: at the end of a drag or a
/// fling, and when its content or its bottom bar changes size.
struct TranscriptTarget: Equatable {
    var maxY: CGFloat
    var contentHeight: CGFloat
    /// The viewport between the top and bottom insets.
    var containerHeight: CGFloat

    /// Content shorter than the viewport rests at its bottom, held there by a larger top inset.
    var endMaxY: CGFloat { max(contentHeight, containerHeight) }
    var hiddenBelowEnd: CGFloat { endMaxY - maxY }

    /// The scroll view stops scrolling to the end marker a pixel or two short of it, and short by 0.7 pt it no longer
    /// keeps the end as the content grows: only rounding noise counts as resting on the end.
    static let onEndTolerance: CGFloat = 0.1
}

/// Why the scroll view proposes where to come to rest.
enum TranscriptRestCause {
    /// The reader lifts their finger, with or without a fling.
    case readerLettingGo
    /// The fling or the landing that followed is under way.
    case readerFlinging
    /// The content or the bottom bar changed size, or the transcript was scrolled to its end.
    case layout
}

extension TranscriptFollow {
    /// Where to come to rest instead of the proposed target: on the end, or nil to keep it.
    ///
    /// Only a transcript resting exactly on its end is kept there by the scroll view itself as the keyboard rises or
    /// an answer grows, in the same frame and the keyboard's animation. Put back afterwards, it shows an empty band
    /// while the keyboard rises, or the end under the bottom bar for a frame. So a reader letting go close to the end
    /// lands on it, and a layout change moving a reader who follows it off the end is undone in the same pass.
    mutating func rest(on target: TranscriptTarget, cause: TranscriptRestCause) -> CGFloat? {
        let hidden = target.hiddenBelowEnd
        switch cause {
        case .readerLettingGo:
            landingOnEnd = hidden <= Self.endZone
            if landingOnEnd { following = true }
            return hidden > TranscriptTarget.onEndTolerance && landingOnEnd ? target.endMaxY : nil
        case .readerFlinging:
            return landingOnEnd && abs(hidden) > TranscriptTarget.onEndTolerance ? target.endMaxY : nil
        case .layout:
            if scrollingToTop { return nil }
            if let held = heldMaxY(on: target) { return held }
            guard abs(hidden) > TranscriptTarget.onEndTolerance else { return nil }
            return following || hidden < 0 ? target.endMaxY : nil
        }
    }

    /// The scroll came to rest, or the reader took hold of it again.
    mutating func landed() {
        landingOnEnd = false
        expandedFromY = nil
        scrollingToTop = false
    }

    /// The keyboard is about to rise or go down: the offset that puts a transcript following its end on it, or nil.
    /// Moved from inside the keyboard's animation, it moves with the keyboard; the scroll view would only keep a
    /// transcript already resting exactly on its end, and one still landing on it would show an empty band.
    func endOffset(beforeKeyboardMoves edge: TranscriptEdge) -> CGFloat? {
        guard following, abs(edge.pastEnd) > TranscriptTarget.onEndTolerance else { return nil }
        return edge.offsetY - edge.pastEnd
    }
}

extension TranscriptFollow {
    /// The reader tapped the status bar: the scroll view scrolls to the top on its own, through no scroll phase, and
    /// the end goes out of view unless the whole transcript fits above the bottom bar. Until it gets there, the end
    /// still in view or rows laid out on the way are not the reader coming back to the end.
    mutating func readerScrolledToTop(from edge: TranscriptEdge) {
        landed()
        guard edge.contentHeight - edge.containerHeight > Self.endZone else { return }
        following = false
        scrollingToTop = true
    }

    /// The scroll view reached the top the status bar asked for.
    mutating func scrolledToTop() { scrollingToTop = false }

    /// A scroll view resting on its end keeps the end in view as the content grows; this far short of it, it leaves the
    /// offset alone.
    static let expansionNudge: CGFloat = 2

    /// The reader asked to see all of a code block or a pasted text: they read it from its start, and the end it
    /// pushes down is theirs again once they come back to it. A transcript resting on its end would follow the block's
    /// growth down to its last line, carried there by the scroll view before any layout pass can put it back, so it is
    /// first moved a hair short of the end: the offset to move to, or nil. Layout passes then rest where the reader was
    /// until they scroll.
    mutating func readerExpandedBlock(at edge: TranscriptEdge?) -> CGFloat? {
        following = false
        guard let edge else {
            expandedFromY = nil
            return nil
        }
        let restsOnEnd = edge.hiddenBelowEnd < Self.expansionNudge && edge.contentHeight > edge.containerHeight
        let offsetY = restsOnEnd ? edge.offsetY - edge.pastEnd - Self.expansionNudge : edge.offsetY
        expandedFromY = offsetY + edge.topInset
        return restsOnEnd ? offsetY : nil
    }

    /// Where a layout pass rests while a block the reader expanded grows: where they were reading, or the end if the
    /// content no longer reaches that far.
    private func heldMaxY(on target: TranscriptTarget) -> CGFloat? {
        guard let expandedFromY else { return nil }
        let maxY = min(expandedFromY + target.containerHeight, target.endMaxY)
        return abs(maxY - target.maxY) > TranscriptTarget.onEndTolerance ? maxY : nil
    }
}

/// How to bring a transcript onto its end.
enum TranscriptEndScroll: Equatable {
    /// Scroll to the end marker with this anchor: the scroll view lays the marker out whatever the rows' estimates.
    case toMarker(UnitPoint)
    /// Move the offset itself, which changes no state.
    case toOffset(CGFloat)
    /// Already on the end.
    case none
}

/// Brings a transcript onto its end. The scroll position keeps targeting the end marker until the reader drags: the
/// status bar scrolling to the top, the keyboard or the content moving the transcript off its end leave it set, and
/// asking it again for the same marker and anchor changes nothing. The transcript then stayed off its end and, its
/// geometry changing, asked again on every pass, re-rendering the conversation each time.
struct TranscriptEndScroller: Equatable {
    /// Both anchors put a marker as wide as the transcript at the same place: the transcript does not scroll sideways.
    static let anchors = [UnitPoint.bottom, .bottomLeading]
    /// Offset steps on one way back to the end, past which something holds the transcript off it: it is left there.
    static let maxSteps = 60

    private var anchorIndex = 0
    private var askedAgain = false
    private var steps = 0

    /// Only a scroll to the marker re-renders the conversation: it is asked again once per way back to the end, and
    /// otherwise the offset moves. An offset moved further than a screen lands on rows laid out from estimated heights,
    /// which the stack never lays out: a blank screen. So it moves at most a screen at a time, onto rows next to the
    /// ones in view, and each pass measures them before the next step.
    mutating func next(targetingMarker: Bool, edge: TranscriptEdge?) -> TranscriptEndScroll {
        guard targetingMarker, let edge else {
            restart()
            return .toMarker(Self.anchors[anchorIndex])
        }
        let pastEnd = edge.pastEnd
        guard abs(pastEnd) > TranscriptTarget.onEndTolerance else {
            restart()
            return .none
        }
        let screen = edge.containerHeight
        if abs(pastEnd) > screen, !askedAgain {
            askedAgain = true
            anchorIndex = (anchorIndex + 1) % Self.anchors.count
            return .toMarker(Self.anchors[anchorIndex])
        }
        guard steps < Self.maxSteps else { return .none }
        steps += 1
        return .toOffset(edge.offsetY - min(max(pastEnd, -screen), screen))
    }

    private mutating func restart() {
        askedAgain = false
        steps = 0
    }
}

/// The message count as last laid out, to tell a message arriving, whose row slides in, from a conversation loading
/// or reloading, whose rows must appear at once: animated, they slide in over each other above the end.
struct TranscriptGrowth: Equatable {
    private(set) var previous = 0
    private(set) var current = 0

    /// Asking again about the same count gives the same answer: a transaction can be asked several times.
    mutating func isSingleArrival(count: Int) -> Bool {
        if count != current {
            previous = current
            current = count
        }
        return current == previous + 1
    }
}
