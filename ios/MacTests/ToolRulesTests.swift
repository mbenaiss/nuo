import Foundation
import Testing

struct ToolRulesTests {
    private func decode(_ json: String) throws -> ServerEvent {
        try JSONDecoder().decode(ServerEvent.self, from: Data(json.utf8))
    }

    private let options = """
    [{"id":"allow_once","name":"Autoriser","kind":"allow_once"},{"id":"allow_always","name":"Toujours autoriser","kind":"allow_always"},
     {"id":"reject_once","name":"Refuser","kind":"reject_once"}]
    """

    @Test func aCardForANamedToolOffersToRememberIt() throws {
        let event = try decode("""
        {"type":"permission.request","conversationId":"conv-factures","requestId":"perm-edf","title":"mcp__nuo__gmail_search",
         "options":\(options),"tool":"nuo/gmail_search","rules":["allow","block"]}
        """)
        guard case let .permissionRequest(conversationId, requestId, _, _, offer) = event else {
            Issue.record("expected permission.request, got \(event)")
            return
        }
        #expect(conversationId == "conv-factures")
        #expect(requestId == "perm-edf")
        #expect(offer?.tool == "nuo/gmail_search")
        #expect(offer?.rules == [.allow, .block])
    }

    @Test func aRememberedAllowReplacesTheAgentsSessionAllow() throws {
        let agent = try JSONDecoder().decode([PermissionOption].self, from: Data(options.utf8))
        let both = try #require(ToolRuleOffer(tool: "nuo/gmail_search", rules: [.allow, .block]))
        #expect(both.cardOptions(agent).map(\.kind) == ["allow_once", "reject_once"])
        let blockOnly = try #require(ToolRuleOffer(tool: "nuo/gmail_send", rules: [.block]))
        #expect(blockOnly.cardOptions(agent).map(\.kind) == ["allow_once", "allow_always", "reject_once"])
    }

    @Test func sendingAnEmailCanOnlyBeBlocked() throws {
        let event = try decode("""
        {"type":"permission.request","conversationId":"conv-devis","requestId":"perm-envoi","title":"Envoyer l'e-mail",
         "options":\(options),"tool":"nuo/gmail_send","rules":["block"]}
        """)
        guard case let .permissionRequest(_, _, _, _, offer) = event else {
            Issue.record("expected permission.request, got \(event)")
            return
        }
        #expect(offer?.rules == [.block])
    }

    @Test func aCardFromAnOlderGatewayOrAnUnnamedToolOffersNothing() throws {
        let event = try decode("""
        {"type":"permission.request","conversationId":"conv-maison","requestId":"perm-rm","title":"Run rm?","options":\(options)}
        """)
        guard case let .permissionRequest(_, _, _, _, offer) = event else {
            Issue.record("expected permission.request, got \(event)")
            return
        }
        #expect(offer == nil)
    }

    @Test func aRememberedAnswerCarriesItsRuleAndAPlainOneDoesNot() throws {
        let remembered = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientEvent.permission(requestId: "perm-edf", optionId: "allow_once", rule: .allow))) as? [String: String]
        #expect(remembered == ["type": "permission", "requestId": "perm-edf", "optionId": "allow_once", "rule": "allow"])
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientEvent.permission(requestId: "perm-edf", optionId: "reject_once"))) as? [String: String]
        #expect(plain == ["type": "permission", "requestId": "perm-edf", "optionId": "reject_once"])
    }

    @Test func aRuleAnswersOnceWhateverTheAgentOffers() throws {
        let options = try JSONDecoder().decode([PermissionOption].self, from: Data(self.options.utf8))
        #expect(ToolRule.allow.answer(in: options)?.id == "allow_once")
        #expect(ToolRule.block.answer(in: options)?.id == "reject_once")
        #expect(ToolRule.allow.answer(in: options.filter { $0.kind.hasPrefix("reject") }) == nil)
    }

    @Test func aRunningTurnKeepsTheOfferOfItsCard() throws {
        let permission = try JSONDecoder().decode(TurnSnapshot.Permission.self, from: Data("""
        {"requestId":"perm-billet","title":"mcp__nuo__gmail_search","options":\(options),"tool":"nuo/gmail_search","rules":["allow","block"]}
        """.utf8))
        #expect(permission.offer == ToolRuleOffer(tool: "nuo/gmail_search", rules: [.allow, .block]))
    }

    @Test func savingTheBotKeepsItsToolRules() throws {
        let json = ##"{"name":"Maison","emoji":"🏡","color":"#E0EEFF","description":"Travaux, factures, rendez-vous","agent":"claude","model":"claude-sonnet-4-5","instructions":"Tu gères la maison.","toolServers":[],"permissionPolicy":"ask","toolRules":{"nuo/gmail_search":"allow","Bash":"block"}}"##
        let maison = try JSONDecoder().decode(BotConfig.self, from: Data(json.utf8))
        #expect(maison.toolRules == ["nuo/gmail_search": .allow, "Bash": .block])
        let again = try JSONDecoder().decode(BotConfig.self, from: JSONEncoder().encode(maison))
        #expect(again == maison)
        var without = maison
        without.toolRules = nil
        #expect(!(String(data: try JSONEncoder().encode(without), encoding: .utf8) ?? "").contains("toolRules"))
    }

    @Test func theSettingsListEachRuleInWords() {
        #expect(ToolRuleLabel.line("nuo/gmail_search", .allow) == "Search emails (Gmail): always allowed")
        #expect(ToolRuleLabel.line("nuo/gmail_send", .block) == "Send an email (Gmail): blocked")
        #expect(ToolRuleLabel.line("nuo/apple_event_delete", .block) == "Delete an event (Calendar): blocked")
        #expect(ToolRuleLabel.line("nuo/mac_file_write", .block) == "Write a file (Mac): blocked")
        #expect(ToolRuleLabel.line("Bash", .block) == "Terminal commands: blocked")
    }

    @Test func anUnknownToolStillReadsAsWords() {
        #expect(ToolRuleLabel.name("fitness/whoop_today") == "Today's WHOOP recovery (Fitness coach)")
        #expect(ToolRuleLabel.name("whoop/whoop_today") == "Whoop: today")
        #expect(ToolRuleLabel.name("notion/pages_search") == "Notion: pages search")
        #expect(ToolRuleLabel.name("nuo/parcel_track") == "Nuo: parcel track")
        #expect(ToolRuleLabel.name("ExitPlanMode") == "ExitPlanMode")
    }
}
