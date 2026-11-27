import CoreGraphics
import Testing

/// Targets the iPhone 17 Pro simulator's scroll view proposed in the demo « Voyages » conversation, in the content's
/// coordinates: 116 pt of navigation bar above the transcript, a 612 pt viewport over the composer (568 pt with the
/// status line, 311 pt with the keyboard open, 265 pt with the jump button too).
struct TranscriptRestTests {
    private func target(y: CGFloat, height: CGFloat, content: CGFloat, container: CGFloat) -> TranscriptTarget {
        TranscriptTarget(maxY: y + height, contentHeight: content, containerHeight: container)
    }

    private func edge(offset: CGFloat, content: CGFloat, container: CGFloat, bottom: CGFloat) -> TranscriptEdge {
        TranscriptEdge(
            visibleMaxY: offset + 116 + container + bottom, contentHeight: content, offsetY: offset, topInset: 116,
            containerHeight: container)
    }

    @Test func readerLettingGoJustAboveTheEndLandsOnIt() {
        var follow = TranscriptFollow()
        let releasedFortyPointsUp = target(y: 1324, height: 612, content: 1976, container: 612)
        let restsOn = follow.rest(on: releasedFortyPointsUp, cause: .readerLettingGo)
        #expect(restsOn == 1976)
        #expect(follow.following)
        #expect(follow.landingOnEnd)
    }

    @Test func readerLettingGoFurtherUpStaysWhereTheyRead() {
        var follow = TranscriptFollow()
        let releasedOnThePreviousAnswer = target(y: 882.7, height: 566, content: 2256, container: 566)
        let restsOn = follow.rest(on: releasedOnThePreviousAnswer, cause: .readerLettingGo)
        #expect(restsOn == nil)
        #expect(!follow.landingOnEnd)
    }

    @Test func readerFlingingUpWhileAnAnswerStreamsIsNotStopped() {
        var follow = TranscriptFollow()
        _ = follow.rest(on: target(y: 1122, height: 522, content: 2896, container: 522), cause: .readerLettingGo)
        let answerGrewMidFling = target(y: 1122, height: 522, content: 3293, container: 522)
        #expect(follow.rest(on: answerGrewMidFling, cause: .readerFlinging) == nil)
    }

    @Test func keyboardRisingWhileLandingStillLandsOnTheEnd() {
        var follow = TranscriptFollow()
        _ = follow.rest(on: target(y: 1324, height: 612, content: 1976, container: 612), cause: .readerLettingGo)
        let composerTappedMidLanding = target(y: 1364, height: 311, content: 1976, container: 311)
        #expect(follow.rest(on: composerTappedMidLanding, cause: .readerFlinging) == 1976)
    }

    @Test func keyboardRisingWhileLandingIsNotTheReaderLeavingTheEnd() {
        var follow = TranscriptFollow()
        _ = follow.rest(on: target(y: 1324, height: 612, content: 1976, container: 612), cause: .readerLettingGo)
        let keyboardOverTheLanding = edge(offset: 1233.3, content: 1976, container: 265, bottom: 493)
        follow.readerScrolled(to: keyboardOverTheLanding)
        #expect(follow.following)
        follow.landed()
        follow.readerScrolled(to: keyboardOverTheLanding)
        #expect(!follow.following)
    }

    @Test func scrollToTheEndMarkerStoppingShortLandsOnTheEnd() {
        var follow = TranscriptFollow()
        let questionSentMarkerShortBySubPoint = target(y: 2082.3, height: 13, content: 2096, container: 612)
        #expect(follow.rest(on: questionSentMarkerShortBySubPoint, cause: .layout) == 2096)
    }

    @Test func answerGrowingUnderAFollowingReaderIsShownInTheSamePass() {
        var follow = TranscriptFollow()
        let flightAnswerFirstLine = target(y: 1528, height: 568, content: 2126, container: 568)
        #expect(follow.rest(on: flightAnswerFirstLine, cause: .layout) == 2126)
    }

    @Test func answerGrowingUnderAReaderWhoScrolledUpLeavesThemThere() {
        var follow = TranscriptFollow()
        follow.readerScrolled(to: edge(offset: 1006.7, content: 3964, container: 522, bottom: 236))
        let answerStillStreaming = target(y: 1122.7, height: 522, content: 4289, container: 522)
        #expect(follow.rest(on: answerStillStreaming, cause: .layout) == nil)
    }

    @Test func doneLineLeavingAnEmptyBandIsClosedEvenForAReaderWhoLeftTheEnd() {
        var follow = TranscriptFollow()
        follow.readerScrolled(to: edge(offset: 400, content: 1371, container: 568, bottom: 190))
        let statusLineGone = target(y: 801, height: 612, content: 1371, container: 612)
        #expect(follow.rest(on: statusLineGone, cause: .layout) == 1371)
    }

    @Test func transcriptOnItsEndOrShorterThanTheViewportIsLeftAlone() {
        var follow = TranscriptFollow()
        let keyboardOpenOnTheEnd = target(y: 1665, height: 311, content: 1976, container: 311)
        let singleExchange = target(y: 0, height: 612, content: 426, container: 612)
        #expect(follow.rest(on: keyboardOpenOnTheEnd, cause: .layout) == nil)
        #expect(follow.rest(on: singleExchange, cause: .layout) == nil)
        #expect(follow.rest(on: singleExchange, cause: .readerLettingGo) == nil)
    }

    @Test func codeBlockExpandedOnTheEndGrowsUnderTheReader() {
        var follow = TranscriptFollow()
        let flightLogCollapsedOnTheEnd = edge(offset: 1909, content: 2637, container: 612, bottom: 146)
        let movedTo = follow.readerExpandedBlock(at: flightLogCollapsedOnTheEnd)
        #expect(movedTo == 1907)
        #expect(!follow.following)
        let jumpButtonShownOverTheEnd = target(y: 2071, height: 566, content: 2637, container: 566)
        #expect(follow.rest(on: jumpButtonShownOverTheEnd, cause: .layout) == 2589)
        let allLinesLaidOut = target(y: 2023, height: 566, content: 7774, container: 566)
        #expect(follow.rest(on: allLinesLaidOut, cause: .layout) == nil)
    }

    @Test func pastedTextExpandedAboveTheEndStaysWhereTheReaderIs() {
        var follow = TranscriptFollow()
        let itineraryBubbleMidTranscript = edge(offset: 900, content: 2637, container: 612, bottom: 146)
        let movedTo = follow.readerExpandedBlock(at: itineraryBubbleMidTranscript)
        #expect(movedTo == nil)
        let bubbleGrown = target(y: 1016, height: 612, content: 29660, container: 612)
        #expect(follow.rest(on: bubbleGrown, cause: .layout) == nil)
    }

    @Test func readerScrollingOrJumpingAfterExpandingIsNoLongerHeld() {
        var follow = TranscriptFollow()
        _ = follow.readerExpandedBlock(at: edge(offset: 1909, content: 2637, container: 612, bottom: 146))
        follow.landed()
        let readerScrolledFurtherDown = target(y: 3400, height: 566, content: 7774, container: 566)
        #expect(follow.rest(on: readerScrolledFurtherDown, cause: .layout) == nil)
        _ = follow.readerExpandedBlock(at: edge(offset: 1909, content: 2637, container: 612, bottom: 146))
        follow.returnToEnd()
        #expect(follow.rest(on: target(y: 2023, height: 566, content: 7774, container: 566), cause: .layout) == 7774)
    }

    @Test func statusBarScrollIsLeftToTheScrollViewAsRowsAreLaidOut() {
        var follow = TranscriptFollow()
        follow.readerScrolledToTop(from: edge(offset: 28296, content: 29024, container: 612, bottom: 146))
        let rowsLaidOutPastTheEnd = target(y: 23900, height: 612, content: 23500, container: 612)
        #expect(follow.rest(on: rowsLaidOutPastTheEnd, cause: .layout) == nil)
    }

    @Test func expandingWithoutAScrollViewOnlyStopsFollowing() {
        var follow = TranscriptFollow()
        let movedTo = follow.readerExpandedBlock(at: nil)
        #expect(movedTo == nil)
        #expect(!follow.following)
        #expect(follow.rest(on: target(y: 2023, height: 566, content: 7774, container: 566), cause: .layout) == nil)
    }

    @Test func keyboardRisingOverAFollowingReaderShortOfTheEndMovesThemOntoIt() {
        let follow = TranscriptFollow()
        let landingFourPointsShort = edge(offset: 1244, content: 1976, container: 311, bottom: 447)
        #expect(follow.endOffset(beforeKeyboardMoves: landingFourPointsShort) == 1549)
    }

    @Test func keyboardOverATranscriptOnItsEndOrScrolledUpIsLeftToTheScrollView() {
        var follow = TranscriptFollow()
        #expect(follow.endOffset(beforeKeyboardMoves: edge(offset: 1248, content: 1976, container: 612, bottom: 146)) == nil)
        follow.readerScrolled(to: edge(offset: 1006.7, content: 4294, container: 522, bottom: 236))
        #expect(follow.endOffset(beforeKeyboardMoves: edge(offset: 1006.7, content: 4294, container: 265, bottom: 493)) == nil)
    }
}
