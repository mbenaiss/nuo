import CoreGraphics

/// Where the Mac transcript's end marker is laid out. The scroll geometry's content height adds up estimated heights for
/// the lazy rows not laid out yet: a transcript resting on that edge showed its end far above the composer, or none of it,
/// while the geometry said it was on it, and a window resized moved the end without the geometry noticing.
struct TranscriptEndMark: Equatable {
    /// Bottom of the end marker in the content's coordinates, which is where the content really ends; nil while the lazy
    /// stack has not laid it out, the end being out of view.
    var maxY: CGFloat?

    /// The edge with the content ending on the marker; an end not laid out is taken as far below.
    func measure(_ edge: TranscriptEdge) -> TranscriptEdge {
        var measured = edge
        measured.contentHeight = maxY ?? .infinity
        return measured
    }

    /// The offset that rests the transcript on its end. On the content's edge rather than on the marker when they are
    /// less than a point apart, the content's height being rounded: only a transcript resting exactly on that edge is
    /// kept on it by the scroll view as the content grows. On the estimated edge while the marker is not laid out.
    func endOffset(for edge: TranscriptEdge) -> CGFloat {
        var end = maxY ?? edge.contentHeight
        if (0..<1).contains(edge.contentHeight - end) { end = edge.contentHeight }
        return max(end, edge.containerHeight) - edge.topInset - edge.containerHeight
    }

    /// At most this much of the content is hidden under the bottom bar or below it; the bar's own height does not count.
    func isNearEnd(_ edge: TranscriptEdge) -> Bool {
        measure(edge).hiddenBelowEnd <= TranscriptFollow.endZone
    }
}

extension TranscriptFollow {
    /// `settled(on:)` against the end as laid out: a reader following it gets it back when it is not laid out at all.
    mutating func settled(on edge: TranscriptEdge, end: TranscriptEndMark) -> Bool {
        settled(on: end.measure(edge))
    }

    mutating func readerScrolled(to edge: TranscriptEdge, end: TranscriptEndMark) {
        readerScrolled(to: end.measure(edge))
    }
}
