import Foundation
import Testing

struct StopGuardTests {
    private let sent = Date(timeIntervalSince1970: 1_794_560_100)

    @Test func ignoresATapRightAfterTheMessageLeft() {
        #expect(StopGuard.ignores(tapAt: sent.addingTimeInterval(0.9), turnStartedAt: sent))
        #expect(StopGuard.ignores(tapAt: sent.addingTimeInterval(1.9), turnStartedAt: sent))
    }

    @Test func stopsOnceTheAnswerHasHadTimeToStart() {
        #expect(!StopGuard.ignores(tapAt: sent.addingTimeInterval(2.5), turnStartedAt: sent))
        #expect(!StopGuard.ignores(tapAt: sent.addingTimeInterval(40), turnStartedAt: sent))
    }

    @Test func stopsATurnWhoseStartIsUnknown() {
        #expect(!StopGuard.ignores(tapAt: sent, turnStartedAt: nil))
    }
}
