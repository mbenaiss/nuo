import Foundation
import Testing

struct AskTargetTests {
    private func bot(_ id: String, _ name: String, overview: Bool = false) throws -> Bot {
        let json = ##"{"name":"\##(name)","emoji":"🤖","color":"#E0EEFF","description":"","agent":"claude","model":"claude-opus-5-5","instructions":"","toolServers":[],"permissionPolicy":"ask""## + (overview ? #","overview":true}"# : "}")
        let config = try JSONDecoder().decode(BotConfig.self, from: Data(json.utf8))
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        return Bot(id: id, published: BotVersion(version: 1, config: config, publishedAt: created), createdAt: created, updatedAt: created)
    }

    private func bots() throws -> [Bot] {
        [try bot("coach", "Coach"), try bot("voyages", "Voyages"), try bot("general", "Général", overview: true), try bot("coach-sportif", "Coach sportif")]
    }

    @Test func theGeneralBotGetsRequestsByDefault() throws {
        let choice = AskTarget.resolve(text: "Ajoute acheter du pain et appeler Julie Martin demain à 9 h", bots: try bots(), explicitBotId: nil, preferredBotId: nil)
        #expect(choice == .init(botId: "general", text: "Ajoute acheter du pain et appeler Julie Martin demain à 9 h"))
    }

    @Test func aBotPickedOnTheWatchWins() throws {
        let choice = AskTarget.resolve(text: "Coach, ma séance du jour ?", bots: try bots(), explicitBotId: "voyages", preferredBotId: "coach")
        #expect(choice?.botId == "voyages")
    }

    @Test func aBotNamedFirstGetsTheRestOfTheSentence() throws {
        let all = try bots()
        #expect(AskTarget.resolve(text: "@Coach ma séance du jour ?", bots: all, explicitBotId: nil, preferredBotId: nil)
            == .init(botId: "coach", text: "Ma séance du jour ?"))
        #expect(AskTarget.resolve(text: "Voyages, mon vol de lundi est à l'heure ?", bots: all, explicitBotId: nil, preferredBotId: nil)
            == .init(botId: "voyages", text: "Mon vol de lundi est à l'heure ?"))
        #expect(AskTarget.resolve(text: "Demande à Coach de me préparer la séance", bots: all, explicitBotId: nil, preferredBotId: nil)
            == .init(botId: "coach", text: "Me préparer la séance"))
        #expect(AskTarget.resolve(text: "coach sportif : 6 × 800 m demain ?", bots: all, explicitBotId: nil, preferredBotId: nil)?.botId == "coach-sportif")
    }

    @Test func aNameInsideTheSentenceDoesNotRedirect() throws {
        let choice = AskTarget.resolve(text: "Rappelle-moi d'écrire au coach demain", bots: try bots(), explicitBotId: nil, preferredBotId: nil)
        #expect(choice?.botId == "general")
    }

    @Test func theSettingsChoiceComesBeforeTheGeneralBot() throws {
        let choice = AskTarget.resolve(text: "Quelle séance aujourd'hui ?", bots: try bots(), explicitBotId: nil, preferredBotId: "coach")
        #expect(choice?.botId == "coach")
        let gone = AskTarget.resolve(text: "Quelle séance aujourd'hui ?", bots: try bots(), explicitBotId: nil, preferredBotId: "bot-supprime")
        #expect(gone?.botId == "general")
    }
}

struct AskQueueTests {
    private let now = Date(timeIntervalSince1970: 1_794_650_400)

    private func ask(_ id: String, minutes: Double = 0) -> WatchAsk {
        WatchAsk(id: id, createdAt: now.addingTimeInterval(minutes * 60), botId: nil, audioFile: "\(id).m4a", seconds: 4.2)
    }

    @Test func requestsLeaveOldestFirstAndStayUntilDelivered() {
        var queue = AskQueue()
        queue.enqueue(ask("pain-julie"))
        queue.enqueue(ask("salon-lyon", minutes: 1))
        queue.enqueue(ask("pain-julie"))
        #expect(queue.items.count == 2)
        #expect(queue.next()?.id == "pain-julie")
        queue.markSending("pain-julie")
        #expect(queue.next(excluding: ["pain-julie"])?.id == "salon-lyon")
        // The iPhone went out of reach before answering: the request waits again, it is not lost.
        queue.markWaiting("pain-julie")
        #expect(queue.next()?.id == "pain-julie")
        #expect(queue.ask(id: "pain-julie")?.attempts == 1)
    }

    @Test func aDeliveredRequestDropsItsAudioAndLinksToTheAnswer() throws {
        var queue = AskQueue()
        queue.enqueue(ask("pain-julie"))
        let result = queue.markDelivered("pain-julie", conversationId: "c-general-7", botId: "general", transcript: "Ajoute acheter du pain")
        let delivered = try #require(result)
        #expect(delivered.audioFile == nil)
        #expect(delivered.deliveredConversationId == "c-general-7")
        #expect(queue.waiting.isEmpty)
        #expect(queue.next() == nil)
    }

    @Test func onlyTheLastDeliveredRequestsAreKept() {
        var queue = AskQueue()
        for index in 0..<8 {
            queue.enqueue(ask("demande-\(index)", minutes: Double(index)))
            queue.markDelivered("demande-\(index)", conversationId: nil, botId: nil, transcript: nil)
        }
        #expect(queue.delivered.count == AskQueue.keepDelivered)
        #expect(queue.delivered.first?.id == "demande-3")
    }

    @Test func theQueueSurvivesARelaunch() throws {
        var queue = AskQueue()
        queue.enqueue(ask("pain-julie"))
        queue.markSending("pain-julie")
        let restored = try JSONDecoder().decode(AskQueue.self, from: JSONEncoder().encode(queue))
        #expect(restored == queue)
        // A request caught mid-handover by a relaunch is handed over again once its word is overdue.
        #expect(restored.next(now: Date().addingTimeInterval(AskQueue.resendAfter + 1))?.id == "pain-julie")
    }
}

struct ConfirmationTests {
    @Test func confirmAndCancelArePickedFromTheAgentsOptions() {
        let options = [
            PermissionOption(id: "always", name: "Toujours autoriser", kind: "allow_always"),
            PermissionOption(id: "once", name: "Autoriser", kind: "allow_once"),
            PermissionOption(id: "no", name: "Refuser", kind: "reject_once"),
        ]
        let choice = ConfirmationChoice.pick(options)
        #expect(choice.confirm?.id == "once")
        #expect(choice.cancel?.id == "no")
    }

    @Test func unusualOptionsAreConfirmedOnTheIPhone() {
        let choice = ConfirmationChoice.pick([
            PermissionOption(id: "go", name: "Envoyer", kind: "allow"),
            PermissionOption(id: "stop", name: "Ne pas envoyer", kind: "reject_always"),
        ])
        #expect(choice.confirm == nil)
        // Refusing for good is a choice made on the iPhone too.
        #expect(choice.cancel == nil)
        #expect(ConfirmationChoice.pick([]).confirm == nil)
    }

    @Test func latencyUsesTheGivenLocale() {
        #expect(AskLatency.label(1.84, locale: Locale(identifier: "en_US")) == "Answered in 1.8 s")
        #expect(AskLatency.label(1.84, locale: Locale(identifier: "fr_FR")) == "Answered in 1,8 s")
    }
}

struct AskDemoTests {
    private let friday = Date(timeIntervalSince1970: 1_794_650_400)

    @Test func theDemoAddsTwoReminders() {
        let reply = AskDemoScript.reply(to: AskDemoScript.reminders, now: friday)
        #expect(reply.confirmation == nil)
        #expect(reply.text.components(separatedBy: "::callout").count == 3)
        #expect(reply.text.contains("Call Julie Martin"))
    }

    @Test func theDemoPutsTheMeetingOnThursdayAt2pm() {
        let reply = AskDemoScript.reply(to: AskDemoScript.event, now: friday)
        #expect(reply.text.contains("::event"))
        #expect(reply.text.contains("T14:00"))
    }

    @Test func theDemoAnswersWithinThreeSecondsOfTheEndOfSpeech() {
        #expect(abs(AskDemoScript.latency(for: AskDemoScript.reminders) - 2.95) < 0.001)
        #expect(abs(AskDemoScript.latency(for: AskDemoScript.event) - 2.05) < 0.001)
    }

    @Test func sendingAnEmailWaitsForAConfirmation() {
        let reply = AskDemoScript.reply(to: AskDemoScript.email, now: friday)
        #expect(reply.confirmation?.contains("julie.martin@example.com") == true)
        #expect(reply.refusal != nil)
    }
}
