import CoreGraphics
import Testing

/// Geometries measured in the Mac chat (`-demo -demoBench chat`, « Voyages » conversation, window content 1280×820):
/// 52 pt of toolbar above the transcript, 60 pt of composer under it, 104 pt while the turn status line shows.
struct MacTranscriptFollowTests {
    private func edge(offset: CGFloat, content: CGFloat, container: CGFloat, bottom: CGFloat) -> TranscriptEdge {
        TranscriptEdge(
            visibleMaxY: offset + 52 + container + bottom, contentHeight: content, offsetY: offset, topInset: 52,
            containerHeight: container)
    }

    private func putsBackOnTheEnd(_ edge: TranscriptEdge, follow: TranscriptFollow = TranscriptFollow()) -> Bool {
        var follow = follow
        return follow.settled(on: edge)
    }

    @Test func answerRestingOnTheComposerNeedsNothing() {
        let weatherAnswered = edge(offset: -9, content: 751, container: 708, bottom: 60)
        #expect(weatherAnswered.pastEnd == 0)
        #expect(!putsBackOnTheEnd(weatherAnswered))
    }

    @Test func shortConversationRestsOnItsEdge() {
        let cobotOpened = edge(offset: -52, content: 708, container: 708, bottom: 60)
        #expect(cobotOpened.pastEnd == 0)
        #expect(!putsBackOnTheEnd(cobotOpened))
    }

    @Test func halfAPointShortOfTheEndIsLeftAlone() {
        let jumpedToTheEndMarker = edge(offset: 1546.5, content: 2263, container: 664, bottom: 104)
        #expect(jumpedToTheEndMarker.pastEnd == -0.5)
        #expect(!putsBackOnTheEnd(jumpedToTheEndMarker))
    }

    @Test func slashPaletteOpenKeepsTheEndAboveIt() {
        let paletteOpen = edge(offset: 672, content: 1124, container: 400, bottom: 368)
        #expect(paletteOpen.pastEnd == 0)
        #expect(!putsBackOnTheEnd(paletteOpen))
    }

    @Test func windowShortenedRightAfterAnAnswerBringsItsEndBack() {
        let before = edge(offset: 1546.5, content: 2263, container: 664, bottom: 104)
        let shortened = edge(offset: 1546.5, content: 2379, container: 484, bottom: 104)
        // The bottom of the visible rect drops with the window while the offset stays: the reader did not move.
        #expect(shortened.visibleMaxY < before.visibleMaxY)
        #expect(shortened.offsetY == before.offsetY)
        #expect(shortened.hiddenBelowEnd == 296.5)
        #expect(putsBackOnTheEnd(shortened))
    }

    @Test func readerWhoScrolledUpDuringAnAnswerStaysThere() {
        var follow = TranscriptFollow()
        follow.readerScrolled(to: edge(offset: 191.5, content: 1799, container: 664, bottom: 104))
        #expect(!follow.following)
        let answerFinished = edge(offset: 191.5, content: 1957, container: 708, bottom: 60)
        #expect(!putsBackOnTheEnd(answerFinished, follow: follow))
    }

    // Ends as laid out, measured on the transcript's end marker in the Mac chat (`-demoBench chat`, long conversations):
    // 52 pt of toolbar, 520 pt of viewport, 60 pt of composer.

    @Test func endShownAboveAnEmptyAreaIsPutBackWhatTheGeometrySays() {
        let manifestOpened = edge(offset: 982, content: 1554, container: 520, bottom: 60)
        #expect(manifestOpened.pastEnd == 0)
        #expect(!putsBackOnTheEnd(manifestOpened))
        let end = TranscriptEndMark(maxY: 1554 - 915)
        #expect(end.measure(manifestOpened).pastEnd == 915)
        var reader = TranscriptFollow()
        reader.readerScrolled(to: edge(offset: 0, content: 4000, container: 520, bottom: 60))
        let putBack = reader.settled(on: manifestOpened, end: end)
        #expect(putBack)
    }

    @Test func journalOpenedMidAnswerJumpsToItsEnd() {
        let journalOpened = edge(offset: 32554, content: 33126, container: 520, bottom: 60)
        #expect(journalOpened.pastEnd == 0)
        var follow = TranscriptFollow()
        let putBack = follow.settled(on: journalOpened, end: TranscriptEndMark(maxY: nil))
        #expect(putBack)
        #expect(follow.following)
    }

    @Test func endNotLaidOutIsLeftToAReaderWhoScrolledUp() {
        var follow = TranscriptFollow()
        follow.readerScrolled(to: edge(offset: 4805, content: 12274, container: 520, bottom: 60), end: TranscriptEndMark(maxY: nil))
        #expect(!follow.following)
        let putBack = follow.settled(on: edge(offset: 4805, content: 15354, container: 520, bottom: 60), end: TranscriptEndMark(maxY: nil))
        #expect(!putBack)
    }

    @Test func narrowerWindowPushingTheEndUnderTheComposerBringsItBack() {
        let narrowed = edge(offset: 965, content: 1537, container: 520, bottom: 60)
        #expect(narrowed.pastEnd == 0)
        let end = TranscriptEndMark(maxY: 1837)
        #expect(end.measure(narrowed).hiddenBelowEnd == 300)
        var follow = TranscriptFollow()
        let putBack = follow.settled(on: narrowed, end: end)
        #expect(putBack)
    }

    @Test func endRightOnTheComposerNeedsNothing() {
        let rested = edge(offset: 894, content: 1466, container: 520, bottom: 60)
        var follow = TranscriptFollow()
        let onMarker = follow.settled(on: rested, end: TranscriptEndMark(maxY: 1466))
        #expect(!onMarker)
        let underAPoint = follow.settled(on: rested, end: TranscriptEndMark(maxY: 1466.4))
        #expect(!underAPoint)
    }

    @Test func jumpButtonCountsOnlyContentHiddenUnderTheComposer() {
        let hundredHidden = edge(offset: 900, content: 1572, container: 520, bottom: 60)
        // The visible rect reaches under the composer: measured on it, up to 140 pt hidden counted as near the end.
        #expect(hundredHidden.isNearBottom)
        #expect(!TranscriptEndMark(maxY: 1572).isNearEnd(hundredHidden))
        #expect(TranscriptEndMark(maxY: 1552).isNearEnd(hundredHidden))
        #expect(!TranscriptEndMark(maxY: nil).isNearEnd(hundredHidden))
    }

    @Test func readerWheelingCloseToTheEndStillFollowsIt() {
        var follow = TranscriptFollow()
        follow.readerScrolled(to: edge(offset: 854, content: 1466, container: 520, bottom: 60), end: TranscriptEndMark(maxY: 1466))
        #expect(follow.following)
        follow.readerScrolled(to: edge(offset: 700, content: 1466, container: 520, bottom: 60), end: TranscriptEndMark(maxY: 1466))
        #expect(!follow.following)
    }

    @Test func jumpRestsOnTheContentEdgeAPointBelowTheMarker() {
        // The content's height is rounded up: resting on the marker leaves the scroll view short of its edge, where it
        // no longer keeps the end on screen as the answer grows.
        let answered = edge(offset: 3015, content: 3544, container: 476, bottom: 104)
        #expect(TranscriptEndMark(maxY: 3543.02).endOffset(for: answered) == 3016)
    }

    @Test func jumpRestsOnTheMarkerWhenTheEstimateOvershoots() {
        let answerArrived = edge(offset: 3015, content: 3862, container: 520, bottom: 60)
        #expect(TranscriptEndMark(maxY: 3769).endOffset(for: answerArrived) == 3197)
    }

    @Test func jumpAimsAtTheEstimatedEdgeWhileTheMarkerIsNotLaidOut() {
        let journalNarrowed = edge(offset: 33102, content: 33958, container: 520, bottom: 60)
        #expect(TranscriptEndMark(maxY: nil).endOffset(for: journalNarrowed) == 33386)
    }

    @Test func jumpInAShortConversationStaysOnTop() {
        let cobotOpened = edge(offset: -52, content: 520, container: 520, bottom: 60)
        #expect(TranscriptEndMark(maxY: 520).endOffset(for: cobotOpened) == -52)
    }

    @Test func readerWheelingBackToTheEndFollowsAgain() {
        var follow = TranscriptFollow()
        follow.readerScrolled(to: edge(offset: 191.5, content: 1957, container: 708, bottom: 60))
        follow.readerScrolled(to: edge(offset: 843, content: 1603, container: 708, bottom: 60))
        #expect(follow.following)
    }
}
