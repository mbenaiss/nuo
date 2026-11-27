import Foundation

/// In-memory gateway for `-demo` launches (screenshots without the gateway).
final class WatchDemoBackend: WatchAPI, @unchecked Sendable {
    static let empty = WatchDemoBackend(seeded: false)

    private let lock = NSLock()
    private var botList: [Bot]
    private var conversationList: [Conversation]
    private var messageStore: [String: [Message]]

    init(seeded: Bool = true) {
        if seeded {
            let seed = WatchDemoSeed.make()
            botList = seed.bots
            conversationList = seed.conversations
            messageStore = seed.messages
        } else {
            botList = []
            conversationList = []
            messageStore = [:]
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func bots() async throws -> [Bot] { locked { botList } }

    func conversations(botId: String?) async throws -> [Conversation] {
        locked {
            conversationList
                .filter { botId == nil || $0.botId == botId }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private static var newConversationTitle: String { String(localized: "New conversation") }

    func createConversation(botId: String) async throws -> Conversation {
        locked {
            let conversation = Conversation(
                id: "c-\(UUID().uuidString.prefix(8))", botId: botId, title: Self.newConversationTitle,
                useDraft: false, createdAt: Date(), updatedAt: Date())
            conversationList.append(conversation)
            return conversation
        }
    }

    func messages(conversationId: String) async throws -> [Message] {
        locked { messageStore[conversationId] ?? [] }
    }

    func append(_ messages: [Message], to conversationId: String, title: String) {
        locked {
            messageStore[conversationId, default: []] += messages
            if let index = conversationList.firstIndex(where: { $0.id == conversationId }) {
                conversationList[index].updatedAt = Date()
                if conversationList[index].title == Self.newConversationTitle { conversationList[index].title = title }
                let botId = conversationList[index].botId
                if let bot = botList.firstIndex(where: { $0.id == botId }), let answer = messages.last {
                    botList[bot].lastMessageAt = Date()
                    botList[bot].lastMessagePreview = MessageContent.spokenText(answer.text)
                }
            }
        }
    }

    func botId(of conversationId: String) -> String? {
        locked { conversationList.first { $0.id == conversationId }?.botId }
    }
}

@MainActor
final class WatchDemoRunner: WatchTurnRunner {
    private let backend: WatchDemoBackend
    private var pendingAnswer: CheckedContinuation<Bool, Never>?

    init(backend: WatchDemoBackend) {
        self.backend = backend
    }

    func run(conversationId: String, text: String, knownMessageIds: Set<String>, viaPhone: Bool) -> AsyncStream<TurnUpdate> {
        play(conversationId: conversationId, text: text)
    }

    func follow(conversationId: String, prompt: String, knownMessageIds: Set<String>) -> AsyncStream<TurnUpdate> {
        play(conversationId: conversationId, text: prompt)
    }

    func answer(requestId: String, optionId: String) async throws {
        pendingAnswer?.resume(returning: optionId == "allow")
        pendingAnswer = nil
    }

    private func play(conversationId: String, text: String) -> AsyncStream<TurnUpdate> {
        let (stream, continuation) = AsyncStream<TurnUpdate>.makeStream()
        let backend = self.backend
        let task = Task { @MainActor in
            let botId = backend.botId(of: conversationId) ?? "cobot"
            var reply = WatchDemoSeed.reply(botId: botId, prompt: text)
            let started = Date()
            try? await Task.sleep(for: .seconds(AskDemoScript.thinking))
            if botId == "general" {
                let script = AskDemoScript.reply(to: text)
                reply = (script.text, script.tools)
                if let question = script.confirmation {
                    continuation.yield(.toolStarted(id: "demo-confirm", title: String(localized: "Preparing the email")))
                    try? await Task.sleep(for: .milliseconds(700))
                    continuation.yield(.permission(requestId: "demo-confirm", title: question, options: [
                        PermissionOption(id: "allow", name: String(localized: "Send"), kind: "allow_once"),
                        PermissionOption(id: "reject", name: String(localized: "Cancel"), kind: "reject_once"),
                    ], answerable: true))
                    let allowed = await withCheckedContinuation { self.pendingAnswer = $0 }
                    continuation.yield(.permissionResolved)
                    continuation.yield(.toolEnded)
                    if !allowed { reply = (script.refusal ?? String(localized: "OK."), []) }
                }
            }
            for (index, tool) in reply.tools.enumerated() {
                continuation.yield(.toolStarted(id: "demo-tool-\(index)", title: tool))
                try? await Task.sleep(for: .seconds(AskDemoScript.tool))
                continuation.yield(.toolEnded)
            }
            var words = reply.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if let first = words.first { continuation.yield(.delta(first)); words.removeFirst() }
            for word in words {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(55))
                continuation.yield(.delta(" " + word))
            }
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            let steps = reply.tools.enumerated().map { index, title in
                ToolStep(toolCallId: "demo-\(index)", title: title, kind: "fetch", status: .completed, durationMs: 900)
            }
            backend.append([
                Message(id: "u-\(UUID().uuidString)", conversationId: conversationId, role: .user, text: text, createdAt: started),
                Message(id: "a-\(UUID().uuidString)", conversationId: conversationId, role: .assistant, text: reply.text,
                        steps: steps, durationMs: duration, stopReason: .endTurn, createdAt: Date()),
            ], to: conversationId, title: String(text.prefix(30)))
            continuation.yield(.finished(durationMs: duration, steps: steps.count, stopReason: .endTurn))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

enum WatchDemoSeed {
    private static func tool(_ name: String, _ description: String, args: String? = nil) -> BotCommand {
        BotCommand(name: name, description: description, args: args, action: .init(type: "tool"))
    }

    private static func prompt(_ name: String, _ description: String, args: String? = nil) -> BotCommand {
        BotCommand(name: name, description: description, args: args, action: .init(type: "prompt", template: "{args}"))
    }

    private static func config(_ name: String, _ emoji: String, _ color: String, _ description: String, _ commands: [BotCommand]) -> BotConfig {
        BotConfig(
            name: name, emoji: emoji, color: color, description: description, agent: .claude, model: "claude-sonnet-5",
            effort: "medium", instructions: "", toolServers: [], workdir: nil, permissionPolicy: .ask, voice: nil, commands: commands)
    }

    static var flightCard: String {
        let status = String(localized: "On time")
        return #"::flight {"flight":"TO8285","airline":"Skyline Air","from":{"code":"FCO","city":"Rome","time":"14:40","terminal":"1"},"to":{"code":"ORY","city":"Paris Orly","time":"17:05","terminal":"3"},"date":"2026-10-19","status":"\#(status)","gate":"F32","seats":["6D","6E","6F"]}"#
    }

    static func make() -> (bots: [Bot], conversations: [Conversation], messages: [String: [Message]]) {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let cobot = config("Cobot", "🦊", "#FFE8D9", String(localized: "Personal assistant, full access to dev"), [
            tool("etat", String(localized: "Status of the services on dev")),
            prompt("deploy", String(localized: "Deploy a service"), args: "<service>"),
        ])
        let voyages = config(String(localized: "Travel"), "✈️", "#E0EEFF", String(localized: "Flights, statuses, activities"), [
            tool("vol", String(localized: "Live status of a flight"), args: "<flight> [dd/mm]"),
            tool("vols", String(localized: "My next booked flights")),
            prompt("modevol", String(localized: "Get flight mode ready"), args: "[flight]"),
            BotCommand(name: "reset", description: String(localized: "New conversation"), action: .init(type: "app", action: "new_conversation")),
        ])
        let coach = config("Coach", "🏃", "#E3F6E8", String(localized: "Meals, workouts, WHOOP"), [
            tool("seance", String(localized: "Today's workout based on your recovery")),
            tool("whoop", String(localized: "WHOOP recovery and sleep")),
            tool("macros", String(localized: "Today's macros and calories")),
            prompt("semaine", String(localized: "Week in review")),
        ])

        func bot(_ id: String, _ config: BotConfig, _ preview: String, _ minutes: Double) -> Bot {
            Bot(id: id, published: BotVersion(version: 1, config: config, publishedAt: ago(60 * 24)), draft: nil,
                createdAt: ago(60 * 24 * 30), updatedAt: ago(60 * 24), lastMessageAt: ago(minutes), lastMessagePreview: preview)
        }

        var general = config(String(localized: "General"), "🧭", "#EDE7FF", String(localized: "Sees all your bots and hands requests over to them"), [])
        general.overview = true
        let bots = [
            bot("general", general, String(localized: "Noted: 2 reminders added."), 3),
            bot("voyages", voyages, String(localized: "TO8285 Monday: on time, gate F32, boarding 13:55."), 12),
            bot("coach", coach, String(localized: "Today's workout: 6 × 800 m at 4:35/km"), 95),
            bot("cobot", cobot, String(localized: "I merged PR #23, the deployment is in progress."), 240),
        ]

        let conversations = [
            Conversation(id: "c-general-demo", botId: "general", title: String(localized: "From the watch"), useDraft: false, createdAt: ago(1), updatedAt: ago(1)),
            Conversation(id: "c-voyages-1", botId: "voyages", title: String(localized: "Monday flight"), useDraft: false, createdAt: ago(14), updatedAt: ago(12)),
            Conversation(id: "c-coach-1", botId: "coach", title: String(localized: "Today's workout"), useDraft: false, createdAt: ago(100), updatedAt: ago(95)),
            Conversation(id: "c-cobot-1", botId: "cobot", title: String(localized: "Gateway deployment"), useDraft: false, createdAt: ago(250), updatedAt: ago(240)),
            Conversation(id: "c-voyages-2", botId: "voyages", title: String(localized: "Weekend in Lisbon"), useDraft: false, createdAt: ago(60 * 48), updatedAt: ago(60 * 48)),
        ]

        let messages: [String: [Message]] = [
            "c-voyages-1": [
                Message(id: "m1", conversationId: "c-voyages-1", role: .user, text: String(localized: "Is my Monday flight on time?"), createdAt: ago(13)),
                Message(
                    id: "m2", conversationId: "c-voyages-1", role: .assistant,
                    text: String(localized: "demo.watch.flightAnswer", defaultValue: "Yes, **TO8285 Rome → Paris** is announced on time. Boarding opens at 13:55.\n\(flightCard)"),
                    steps: [
                        ToolStep(toolCallId: "t1", title: "booking_lookup", kind: "fetch", status: .completed, durationMs: 2100),
                        ToolStep(toolCallId: "t2", title: "flight_status", kind: "fetch", status: .completed, durationMs: 3900),
                    ],
                    durationMs: 8000, stopReason: .endTurn, createdAt: ago(12)),
            ],
            "c-voyages-2": [
                Message(id: "m3", conversationId: "c-voyages-2", role: .user, text: String(localized: "What's the weather in Lisbon on Sunday?"), createdAt: ago(60 * 48)),
                Message(
                    id: "m4", conversationId: "c-voyages-2", role: .assistant,
                    text: String(localized: "Plenty of sun on Sunday, perfect for Belém.") + "\n::weather {\"location\":\"\(String(localized: "Lisbon"))\",\"temperature\":24,\"condition\":\"\(String(localized: "Sunny"))\",\"high\":26,\"low\":17}",
                    steps: [ToolStep(toolCallId: "t3", title: "weather", kind: "fetch", status: .completed, durationMs: 1200)],
                    durationMs: 4000, stopReason: .endTurn, createdAt: ago(60 * 48)),
            ],
            "c-coach-1": [
                Message(id: "m5", conversationId: "c-coach-1", role: .user, text: String(localized: "What workout today?"), createdAt: ago(100)),
                Message(
                    id: "m6", conversationId: "c-coach-1", role: .assistant,
                    text: String(localized: "demo.watch.workoutAnswer", defaultValue: """
                    Your recovery is **71%**, so we keep the intervals:
                    - 15 min warm-up
                    - **6 × 800 m at 4:35/km**
                    - 10 min cool-down
                    ::facts {"title":"WHOOP this morning","items":[{"key":"Recovery","value":"71%"},{"key":"Sleep","value":"7 h 42"},{"key":"HRV","value":"68 ms"}]}
                    """),
                    steps: [
                        ToolStep(toolCallId: "t4", title: "whoop_today", kind: "fetch", status: .completed, durationMs: 1400),
                        ToolStep(toolCallId: "t5", title: "week_plan", kind: "fetch", status: .completed, durationMs: 900),
                    ],
                    durationMs: 6000, stopReason: .endTurn, createdAt: ago(95)),
            ],
            "c-cobot-1": [
                Message(id: "m7", conversationId: "c-cobot-1", role: .user, text: String(localized: "Merge PR #23 and deploy"), createdAt: ago(250)),
                Message(
                    id: "m8", conversationId: "c-cobot-1", role: .assistant,
                    text: String(localized: "I merged PR #23, the deployment is in progress.") + "\n::callout {\"style\":\"success\",\"title\":\"\(String(localized: "Deployed"))\",\"text\":\"\(String(localized: "The gateway is running v0.1.0."))\"}",
                    steps: [
                        ToolStep(toolCallId: "t6", title: "merge_pr", kind: "execute", status: .completed, durationMs: 2300),
                        ToolStep(toolCallId: "t7", title: "deploy-gateway.sh", kind: "execute", status: .completed, durationMs: 41000),
                    ],
                    durationMs: 47000, stopReason: .endTurn, createdAt: ago(240)),
            ],
        ]
        return (bots, conversations, messages)
    }

    static func reply(botId: String, prompt: String) -> (text: String, tools: [String]) {
        switch botId {
        case "voyages":
            (String(localized: "demo.watch.flightUpdate", defaultValue: "**TO8285** is still on time. Gate F32, boarding at 13:55.\n\(flightCard)"), ["flight_status"])
        case "coach":
            (String(localized: "demo.watch.coachReply", defaultValue: "Recovery at **71%**: keep the intervals, 6 × 800 m at 4:35/km with 2 min of rest.\n::facts {\"items\":[{\"key\":\"Recovery\",\"value\":\"71%\"},{\"key\":\"Target strain\",\"value\":\"14\"}]}"), ["whoop_today", "session_today"])
        default:
            (String(localized: "All services are running on dev, nothing to report.") + "\n::callout {\"style\":\"success\",\"title\":\"OK\",\"text\":\"\(String(localized: "6 containers online."))\"}", ["services_status"])
        }
    }
}
