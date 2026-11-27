import CoreGraphics
import Testing

/// Geometries measured on an iPhone 17 Pro simulator in the demo « Voyages » conversation after three summaries:
/// 116 pt of navigation bar above the transcript, 146 pt of composer under it (192 with the jump button, 447 with
/// the keyboard open).
struct TranscriptFollowTests {
    private func edge(offset: CGFloat, content: CGFloat, container: CGFloat, bottom: CGFloat) -> TranscriptEdge {
        TranscriptEdge(
            visibleMaxY: offset + 116 + container + bottom, contentHeight: content, offsetY: offset, topInset: 116,
            containerHeight: container)
    }

    private func follow(after edges: TranscriptEdge...) -> TranscriptFollow {
        var follow = TranscriptFollow()
        for edge in edges { follow.readerScrolled(to: edge) }
        return follow
    }

    @Test func hiddenBelowEndCountsWhatTheBottomBarCovers() {
        #expect(edge(offset: 1198, content: 1976, container: 311, bottom: 447).hiddenBelowEnd == 351)
        #expect(edge(offset: 1248, content: 1976, container: 612, bottom: 146).hiddenBelowEnd == 0)
        #expect(edge(offset: 1549, content: 1976, container: 612, bottom: 146).hiddenBelowEnd == 0)
    }

    @Test func readerLettingGoJustAboveTheEndStillFollowsIt() {
        let nudgedUp = follow(after: edge(offset: 1198, content: 1976, container: 612, bottom: 146))
        #expect(nudgedUp.following)
    }

    @Test func readerScrollingUpToReadLeavesTheEnd() {
        let keyboardDraggedDown = follow(after: edge(offset: 1036, content: 1976, container: 566, bottom: 192))
        #expect(!keyboardDraggedDown.following)
    }

    @Test func keyboardRisingUnderAReaderOnTheEndBringsTheEndAboveIt() {
        var follow = follow(after: edge(offset: 1198, content: 1976, container: 612, bottom: 146))
        let keyboardOpen = edge(offset: 1198, content: 1976, container: 311, bottom: 447)
        let scrollsToEnd = follow.settled(on: keyboardOpen)
        #expect(scrollsToEnd)
    }

    @Test func cardLaidOutAfterTheLastDeltaIsBroughtAboveTheComposer() {
        var follow = TranscriptFollow()
        let flightCardUnderTheKeyboard = edge(offset: 1189.7, content: 1817, container: 311, bottom: 447)
        let scrollsToEnd = follow.settled(on: flightCardUnderTheKeyboard)
        #expect(scrollsToEnd)
    }

    @Test func answerStreamingUnderAReaderWhoScrolledUpLeavesThemWhereTheyRead() {
        var follow = follow(after: edge(offset: 5393, content: 6177, container: 522, bottom: 190))
        let pastedTextStillStreaming = edge(offset: 4821.7, content: 10283, container: 612, bottom: 146)
        let scrollsToEnd = follow.settled(on: pastedTextStillStreaming)
        #expect(!scrollsToEnd)
        #expect(!follow.following)
    }

    @Test func keyboardRisingUnderAReaderWhoScrolledUpLeavesThemWhereTheyRead() {
        var follow = follow(after: edge(offset: 1036, content: 1976, container: 566, bottom: 192))
        let scrollsToEnd = follow.settled(on: edge(offset: 1036, content: 1976, container: 265, bottom: 493))
        #expect(!scrollsToEnd)
    }

    @Test func endComingIntoViewOnItsOwnMakesTheReaderFollowAgain() {
        var follow = follow(after: edge(offset: 1036, content: 1976, container: 566, bottom: 192))
        let keyboardGoneOverTheEnd = edge(offset: 1549, content: 1976, container: 612, bottom: 146)
        let scrollsToEnd = follow.settled(on: keyboardGoneOverTheEnd)
        #expect(scrollsToEnd)
        #expect(follow.following)
    }

    @Test func transcriptRestingOnItsEndIsLeftAlone() {
        var follow = TranscriptFollow()
        let onTheEnd = follow.settled(on: edge(offset: 1248, content: 1976, container: 612, bottom: 146))
        let subPointShort = follow.settled(on: edge(offset: 14335.3, content: 15064, container: 612, bottom: 146))
        #expect(!onTheEnd)
        #expect(!subPointShort)
    }

    @Test func jumpingToTheEndFollowsItAgain() {
        var follow = follow(after: edge(offset: 4821.7, content: 10749, container: 566, bottom: 192))
        follow.returnToEnd()
        #expect(follow.following)
    }

    @Test func statusBarTapOverALongTranscriptLeavesTheEnd() {
        var follow = TranscriptFollow()
        follow.readerScrolledToTop(from: edge(offset: 1909, content: 2637, container: 612, bottom: 146))
        #expect(!follow.following)
        let scrollingToTheTop = edge(offset: 1302.3, content: 3445, container: 612, bottom: 146)
        let scrollsToEnd = follow.settled(on: scrollingToTheTop)
        #expect(!scrollsToEnd)
        #expect(!follow.following)
    }

    @Test func endStillInViewAsTheStatusBarScrollStartsIsNotTheReaderComingBack() {
        var follow = TranscriptFollow()
        follow.readerScrolledToTop(from: edge(offset: 28296, content: 29024, container: 612, bottom: 146))
        let jumpButtonShownOverTheEnd = edge(offset: 28342, content: 29024, container: 566, bottom: 192)
        let rowsReestimatedPastTheOffset = edge(offset: 23784, content: 23500, container: 566, bottom: 192)
        let backToEndAsTheButtonShows = follow.settled(on: jumpButtonShownOverTheEnd)
        let backToEndOverTheReestimate = follow.settled(on: rowsReestimatedPastTheOffset)
        #expect(!backToEndAsTheButtonShows)
        #expect(!backToEndOverTheReestimate)
        #expect(!follow.following)
        #expect(follow.scrollingToTop)
        let backToEndFromTheTop = follow.settled(on: edge(offset: -116, content: 66401, container: 566, bottom: 192))
        #expect(!backToEndFromTheTop)
        #expect(!follow.scrollingToTop)
        #expect(!follow.following)
    }

    @Test func readerTakingHoldDuringTheStatusBarScrollEndsIt() {
        var follow = TranscriptFollow()
        follow.readerScrolledToTop(from: edge(offset: 28296, content: 29024, container: 612, bottom: 146))
        follow.landed()
        #expect(!follow.scrollingToTop)
        follow.readerScrolledToTop(from: edge(offset: 28296, content: 29024, container: 612, bottom: 146))
        follow.scrolledToTop()
        #expect(!follow.scrollingToTop)
        follow.readerScrolledToTop(from: edge(offset: 28296, content: 29024, container: 612, bottom: 146))
        follow.returnToEnd()
        #expect(!follow.scrollingToTop)
        #expect(follow.following)
    }

    @Test func statusBarTapOverAnExchangeThatFitsKeepsFollowingTheEnd() {
        var follow = TranscriptFollow()
        follow.readerScrolledToTop(from: edge(offset: -302, content: 426, container: 612, bottom: 146))
        #expect(follow.following)
    }

    @Test func onlyASingleMessageArrivingSlidesIn() {
        var growth = TranscriptGrowth()
        let conversationOpened = growth.isSingleArrival(count: 9)
        let questionSent = growth.isSingleArrival(count: 10)
        let askedAgain = growth.isSingleArrival(count: 10)
        let answerStarted = growth.isSingleArrival(count: 11)
        let reloadFromAnotherDevice = growth.isSingleArrival(count: 15)
        let reloadDroppingAMessage = growth.isSingleArrival(count: 14)
        #expect(!conversationOpened)
        #expect(questionSent)
        #expect(askedAgain)
        #expect(answerStarted)
        #expect(!reloadFromAnotherDevice)
        #expect(!reloadDroppingAMessage)
    }

    @Test func firstMessageOfANewConversationSlidesIn() {
        var growth = TranscriptGrowth()
        let firstQuestion = growth.isSingleArrival(count: 1)
        #expect(firstQuestion)
    }
}
