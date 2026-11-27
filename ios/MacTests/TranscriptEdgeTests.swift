import CoreGraphics
import SwiftUI
import Testing

/// Geometries measured on an iPhone 17 Pro simulator in the demo « Voyages » conversation: 116 pt of navigation bar
/// above the transcript, 146 pt of composer under it, 447 pt with the keyboard open.
struct TranscriptEdgeTests {
    private func edge(offset: CGFloat, content: CGFloat, container: CGFloat, top: CGFloat = 116, bottom: CGFloat) -> TranscriptEdge {
        TranscriptEdge(
            visibleMaxY: offset + top + container + bottom, contentHeight: content, offsetY: offset, topInset: top,
            containerHeight: container)
    }

    @Test func transcriptRestingOnItsEndStaysPut() {
        let atEnd = edge(offset: 2839, content: 3567, container: 612, bottom: 146)
        #expect(atEnd.pastEnd == 0)
        #expect(!atEnd.needsSnapBack(scrollIdle: true))
    }

    @Test func lastMessageAboveTheComposerPaddingIsNotPastTheEnd() {
        let afterScrollingToTheEnd = edge(offset: 3247.3, content: 3686, container: 311, bottom: 447)
        #expect(afterScrollingToTheEnd.pastEnd < 0)
        #expect(!afterScrollingToTheEnd.needsSnapBack(scrollIdle: true))
    }

    @Test func answerLaidOutShorterWithTheKeyboardOpenLeavesAnEmptyBand() {
        let flightAnswerFinished = edge(offset: 3328, content: 3737, container: 311, bottom: 447)
        #expect(flightAnswerFinished.pastEnd == 18)
        #expect(flightAnswerFinished.needsSnapBack(scrollIdle: true))
    }

    @Test func doneLineLeavingTheComposerUncoversAnEmptyBand() {
        let statusLineGone = edge(offset: 685, content: 1371, container: 612, bottom: 146)
        #expect(statusLineGone.pastEnd == 42)
        #expect(statusLineGone.needsSnapBack(scrollIdle: true))
    }

    @Test func readerDraggingPastTheEndIsLeftToBounceBack() {
        let rubberBanding = edge(offset: 3020, content: 3567, container: 612, bottom: 146)
        #expect(rubberBanding.pastEnd > 100)
        #expect(!rubberBanding.needsSnapBack(scrollIdle: false))
    }

    @Test func shortConversationHeldAtTheBottomIsNeverPastItsEnd() {
        let twoMessages = edge(offset: -302, content: 426, container: 612, top: 302, bottom: 146)
        #expect(twoMessages.pastEnd == 0)
        #expect(!twoMessages.needsSnapBack(scrollIdle: true))
    }

    @Test func subPointRoundingIsNotABand() {
        let insetSettling = edge(offset: 1385.7, content: 2113, container: 611.8, bottom: 146.2)
        #expect(insetSettling.pastEnd > 0)
        #expect(!insetSettling.needsSnapBack(scrollIdle: true))
    }

    @Test func scrollPositionNotOnTheMarkerScrollsToIt() {
        var scroller = TranscriptEndScroller()
        let readerDraggedUp = scroller.next(targetingMarker: false, edge: edge(offset: 900, content: 3567, container: 612, bottom: 146))
        let noScrollViewYet = scroller.next(targetingMarker: true, edge: nil)
        #expect(readerDraggedUp == .toMarker(.bottom))
        #expect(noScrollViewYet == .toMarker(.bottom))
    }

    @Test func endWithinAScreenIsReachedByTheOffset() {
        var scroller = TranscriptEndScroller()
        let bandUnderTheKeyboard = scroller.next(targetingMarker: true, edge: edge(offset: 3328, content: 3737, container: 311, bottom: 447))
        let answerGrewUnderTheComposer = scroller.next(
            targetingMarker: true, edge: edge(offset: 72765, content: 73300, container: 612, bottom: 146))
        #expect(bandUnderTheKeyboard == .toOffset(3310))
        #expect(answerGrewUnderTheComposer == .toOffset(72572))
    }

    @Test func endFarOffWhileTheMarkerIsTargetedIsAskedForOnceWithTheOtherAnchor() {
        var scroller = TranscriptEndScroller()
        let afterTheStatusBarTap = scroller.next(targetingMarker: true, edge: edge(offset: -116, content: 4308, container: 566, bottom: 192))
        #expect(afterTheStatusBarTap == .toMarker(.bottomLeading))
        let landedShortOnEstimatedRows = scroller.next(
            targetingMarker: true, edge: edge(offset: 58652, content: 62344, container: 481, top: 74, bottom: 112))
        #expect(landedShortOnEstimatedRows == .toOffset(59133))
    }

    @Test func endFarOffIsReachedAScreenAtATimeWithoutRendering() {
        var scroller = TranscriptEndScroller()
        _ = scroller.next(targetingMarker: true, edge: edge(offset: -74, content: 58043, container: 481, top: 74, bottom: 112))
        var offset: CGFloat = 58652
        var steps = 0
        while case let .toOffset(next) = scroller.next(
            targetingMarker: true, edge: edge(offset: offset, content: 62344, container: 481, top: 74, bottom: 112)) {
            #expect(next - offset <= 481)
            offset = next
            steps += 1
        }
        #expect(offset == 61789)
        #expect(steps == 7)
        let readerDraggedUp = scroller.next(targetingMarker: false, edge: edge(offset: 40000, content: 62344, container: 481, bottom: 112))
        #expect(readerDraggedUp == .toMarker(.bottomLeading))
    }

    @Test func transcriptHeldOffItsEndIsLeftThereAfterEnoughSteps() {
        var scroller = TranscriptEndScroller()
        let heldShortOfTheEnd = edge(offset: 61025, content: 63233, container: 481, top: 74, bottom: 112)
        _ = scroller.next(targetingMarker: true, edge: heldShortOfTheEnd)
        var moves: [TranscriptEndScroll] = []
        for _ in 0..<TranscriptEndScroller.maxSteps + 2 { moves.append(scroller.next(targetingMarker: true, edge: heldShortOfTheEnd)) }
        #expect(moves.filter { $0 == .toOffset(61506) }.count == TranscriptEndScroller.maxSteps)
        #expect(moves.last == TranscriptEndScroll.none)
    }

    @Test func bandPastTheEndIsClosedByTheOffset() {
        var scroller = TranscriptEndScroller()
        let contentShrankUnderTheReader = scroller.next(targetingMarker: true, edge: edge(offset: 2194, content: 1685, container: 311, bottom: 447))
        #expect(contentShrankUnderTheReader == .toMarker(.bottomLeading))
        let stillPastTheEnd = scroller.next(targetingMarker: true, edge: edge(offset: 2194, content: 1685, container: 311, bottom: 447))
        #expect(stillPastTheEnd == .toOffset(1883))
    }

    @Test func scrollPositionOnTheMarkerAndTheEndDoesNothing() {
        var scroller = TranscriptEndScroller()
        let onTheEnd = scroller.next(targetingMarker: true, edge: edge(offset: 2839, content: 3567, container: 612, bottom: 146))
        #expect(onTheEnd == TranscriptEndScroll.none)
    }

    @Test func nearBottomWithinEightyPointsOfTheEnd() {
        #expect(edge(offset: 2839, content: 3567, container: 612, bottom: 146).isNearBottom)
        #expect(!edge(offset: -116, content: 3284, container: 566, bottom: 192).isNearBottom)
    }
}
