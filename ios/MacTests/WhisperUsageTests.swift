import Testing

struct WhisperUsageTests {
    @Test func aRunningPassKeepsTheModel() {
        #expect(WhisperUsage.inUse(busy: 1, holders: 0, callerHolds: false))
    }

    @Test func aMeetingHoldingTheModelKeepsItFromADictation() {
        #expect(WhisperUsage.inUse(busy: 0, holders: 1, callerHolds: false))
    }

    @Test func theOnlyHolderMaySwapItsOwnModel() {
        #expect(!WhisperUsage.inUse(busy: 0, holders: 1, callerHolds: true))
        #expect(WhisperUsage.inUse(busy: 0, holders: 2, callerHolds: true))
    }

    @Test func anIdleModelCanGo() {
        #expect(!WhisperUsage.inUse(busy: 0, holders: 0, callerHolds: false))
    }
}
