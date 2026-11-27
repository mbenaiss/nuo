import CoreGraphics
import Testing

struct BrowserTouchTests {
    private let past = CGSize(width: BrowserTouch.slop + 4, height: 0)
    private let short = CGSize(width: BrowserTouch.slop - 4, height: 0)

    @Test func scrollsWhenTheFingerLeavesStraightAway() {
        var touch = BrowserTouch()
        touch.began()
        #expect(touch.moved(translation: past) == .scroll)
        #expect(touch.moved(translation: CGSize(width: 40, height: 0)) == .scroll)
        #expect(touch.ended() == .coast)
    }

    @Test func waitsWhileTheFingerIsStillWithinTheSlop() {
        var touch = BrowserTouch()
        touch.began()
        #expect(touch.moved(translation: short) == .nothing)
        #expect(touch.mode == .undecided)
    }

    @Test func takesHoldOfThePageWhenTheFingerWaitedBeforeMoving() {
        var touch = BrowserTouch()
        touch.began()
        touch.held()
        #expect(touch.moved(translation: short) == .press)
        #expect(touch.moved(translation: past) == .drag)
        #expect(touch.ended() == .release)
    }

    /// The slider that started all this: once the page is held, every pixel has to follow, slop or not.
    @Test func dragsTheSmallestMoveOnceThePageIsHeld() {
        var touch = BrowserTouch()
        touch.began()
        touch.held()
        #expect(touch.moved(translation: CGSize(width: 1, height: 0)) == .press)
        #expect(touch.mode == .grabbing)
    }

    @Test func ignoresTheHoldOnceTheFingerIsAlreadyScrolling() {
        var touch = BrowserTouch()
        touch.began()
        #expect(touch.moved(translation: past) == .scroll)
        touch.held()
        #expect(touch.mode == .scrolling)
        #expect(touch.moved(translation: CGSize(width: 60, height: 0)) == .scroll)
    }

    @Test func leavesALongPressThatNeverMovedAsATap() {
        var touch = BrowserTouch()
        touch.began()
        touch.held()
        #expect(touch.ended() == .nothing)
        #expect(!touch.grabbed, "the tap gesture still has to click it")
    }

    @Test func suppressesTheTapAfterADragButNotOnTheNextTouch() {
        var touch = BrowserTouch()
        touch.began()
        touch.held()
        _ = touch.moved(translation: short)
        _ = touch.ended()
        #expect(touch.grabbed, "the click would land on top of the drag that just ended")

        touch.began()
        #expect(!touch.grabbed)
    }

    @Test func startsEachTouchOverFromTheLastOne() {
        var touch = BrowserTouch()
        touch.began()
        _ = touch.moved(translation: past)
        #expect(touch.ended() == .coast)
        #expect(touch.mode == .undecided)

        touch.began()
        touch.held()
        #expect(touch.moved(translation: short) == .press)
    }
}
