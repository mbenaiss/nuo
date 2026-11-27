import Foundation
import Testing

struct BotConfigProactiveTests {
    private func config(_ extra: String = "") throws -> BotConfig {
        let json = ##"{"name":"Maison","emoji":"🏡","color":"#E0EEFF","description":"Travaux, factures, rendez-vous","agent":"claude","model":"claude-sonnet-4-5","instructions":"Tu gères la maison.","toolServers":[],"permissionPolicy":"ask""## + extra + "}"
        return try JSONDecoder().decode(BotConfig.self, from: Data(json.utf8))
    }

    @Test func readsTheMorningProposalsSetting() throws {
        #expect(try config(#","proactive":true"#).proactive == true)
    }

    @Test func aGatewayWithoutTheSettingLeavesItOff() throws {
        #expect(try config().proactive == nil)
    }

    @Test func offIsNotSentSoTheDraftMatchesThePublishedConfig() throws {
        var maison = try config(#","proactive":true"#)
        maison.proactive = nil
        let sent = try #require(String(data: JSONEncoder().encode(maison), encoding: .utf8))
        #expect(!sent.contains("proactive"))
        #expect(maison == (try config()))
    }

    @Test func savingTheBotKeepsTheLanguageSetOnTheGateway() throws {
        let tutor = try config(#","language":"English""#)
        let sent = try #require(String(data: JSONEncoder().encode(tutor), encoding: .utf8))
        #expect(sent.contains(#""language":"English""#))
        #expect(!String(data: try JSONEncoder().encode(try config()), encoding: .utf8)!.contains("language"))
    }
}
