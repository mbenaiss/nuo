import Foundation
import Testing

struct BotWakeTests {
    @Test func theWakeOverviewDecodesWithoutAnyToken() throws {
        let wake = try NuoJSON.decoder().decode(BotWake.self, from: Data("""
        {"email": "work@bots.example.com", "mailAlias": null, "hooksEnabled": true,
         "hooks": [
           {"id": "hook-linear", "name": "Linear", "notify": true, "calls": 12,
            "lastCalledAt": "2026-11-26T09:14:00.000Z", "createdAt": "2026-11-20T08:00:00.000Z"},
           {"id": "hook-github", "name": "GitHub", "notify": false, "calls": 0, "createdAt": "2026-11-21T10:30:00.000Z"}
         ]}
        """.utf8))
        #expect(wake.email == "work@bots.example.com")
        #expect(wake.mailAlias == nil)
        #expect(wake.hooks.map(\.activity) == ["12 calls", "Never called"])
        #expect(wake.hooks[1].lastCalledAt == nil)
    }

    @Test func aGatewayWithoutMailDomainOrHooksHostSaysSo() throws {
        let wake = try NuoJSON.decoder().decode(BotWake.self, from: Data("""
        {"email": null, "mailAlias": null, "hooksEnabled": false, "hooks": []}
        """.utf8))
        #expect(wake.email == nil)
        #expect(!wake.hooksEnabled)
    }

    @Test func aCreatedHookCarriesItsUrlOnce() throws {
        let created = try NuoJSON.decoder().decode(CreatedWakeHook.self, from: Data("""
        {"hook": {"id": "hook-ifttt", "name": "IFTTT", "notify": true, "calls": 0, "createdAt": "2026-11-27T07:45:00.000Z"},
         "token": "nh_Q2hhbnRpZXJMeW9uMjAyNi0xMS0yN19BcnJpdmVlQnVyZWF1",
         "url": "https://hooks.example.com/hooks/nh_Q2hhbnRpZXJMeW9uMjAyNi0xMS0yN19BcnJpdmVlQnVyZWF1"}
        """.utf8))
        #expect(created.url.host == "hooks.example.com")
        #expect(created.url.lastPathComponent == created.token)
        #expect(created.hook.activity == "Never called")
    }

    @Test func aHookNameIsTrimmedAndBounded() {
        #expect(WakeHookName.normalized("  Linear  ") == "Linear")
        #expect(WakeHookName.normalized("   ") == nil)
        #expect(WakeHookName.normalized(String(repeating: "x", count: 61)) == nil)
        #expect(WakeHookName.normalized("Suivi des tickets Atelier Lumen") == "Suivi des tickets Atelier Lumen")
    }

    @Test func aFirstLoadThatFailsShowsItsErrorInsteadOfNothing() {
        #expect(BotWakeDisplay.of(wake: nil, error: "The gateway is unreachable.") == .loadFailed("The gateway is unreachable."))
    }

    @Test func nothingLoadedAndNoErrorKeepsTheSectionHidden() {
        #expect(BotWakeDisplay.of(wake: nil, error: nil) == .hidden)
    }

    @Test func aLaterErrorShowsUnderTheLoadedWakeUps() {
        let wake = BotWake(email: "travel@bots.example.com", mailAlias: nil, hooksEnabled: true, hooks: [])
        #expect(BotWakeDisplay.of(wake: wake, error: nil) == .loaded(wake, error: nil))
        #expect(BotWakeDisplay.of(wake: wake, error: "Webhook limit reached.") == .loaded(wake, error: "Webhook limit reached."))
    }
}
