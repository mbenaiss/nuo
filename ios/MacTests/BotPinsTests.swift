import Foundation
import Testing

struct BotPinsTests {
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: "BotPinsTests-\(UUID().uuidString)")!
    }

    private func bot(_ id: String, _ name: String, overview: Bool = false, lastMessage minutesAgo: Double? = nil) throws -> Bot {
        let json = ##"{"name":"\##(name)","emoji":"🤖","color":"#E0EEFF","description":"","agent":"claude","model":"claude-opus-5-5","instructions":"","toolServers":[],"permissionPolicy":"readonly""## + (overview ? #","overview":true}"# : "}")
        let config = try JSONDecoder().decode(BotConfig.self, from: Data(json.utf8))
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        return Bot(id: id, published: BotVersion(version: 1, config: config, publishedAt: created), createdAt: created, updatedAt: created,
                   lastMessageAt: minutesAgo.map { Date(timeIntervalSinceNow: -$0 * 60) })
    }

    private func bots() throws -> [Bot] {
        [
            try bot("cobot", "Cobot", lastMessage: 30),
            try bot("voyages", "Voyages", lastMessage: 5),
            try bot("forma", "Forma"),
            try bot("general", "Général", overview: true, lastMessage: 120),
            try bot("coach", "Coach", lastMessage: 60),
        ]
    }

    @Test func theBotThatSeesEveryBotIsPinnedUntilTheUserChooses() throws {
        let pins = BotPins(defaults: defaults)
        let (pinned, others) = pins.split(try bots())
        #expect(pinned.map(\.id) == ["general"])
        #expect(others.map(\.id) == ["voyages", "cobot", "coach", "forma"])
    }

    @Test func pinsKeepTheirOrderAndSurviveARelaunch() throws {
        let all = try bots()
        var pins = BotPins(defaults: defaults)
        pins.setPinned(all[4], true, among: all)
        pins.setPinned(all[0], true, among: all)
        #expect(pins.split(all).pinned.map(\.id) == ["general", "coach", "cobot"])

        pins.setPinned(all[3], false, among: all)
        let relaunched = BotPins(defaults: defaults)
        #expect(relaunched.split(all).pinned.map(\.id) == ["coach", "cobot"])
        #expect(relaunched.split(all).others.map(\.id) == ["voyages", "general", "forma"])
    }

    @Test func theSidebarKeepsTheOtherBotsInTheirUsualOrder() throws {
        let pins = BotPins(defaults: defaults)
        #expect(pins.pinnedFirst(try bots()).map(\.id) == ["general", "cobot", "voyages", "forma", "coach"])
    }
}
