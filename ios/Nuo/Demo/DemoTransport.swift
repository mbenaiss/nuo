import Foundation
import Observation

/// Scripted stand-in for the gateway socket in demo mode. `idle` is the inert transport used before pairing.
@MainActor
@Observable
final class DemoTransport: LiveTransport {
    static let idle = DemoTransport(backend: nil)

    private(set) var connectionState: ConnectionState = .idle
    @ObservationIgnored private let backend: DemoBackend?
    @ObservationIgnored private let eventBus = Broadcaster<ServerEvent>()
    @ObservationIgnored private let reconnectBus = Broadcaster<Void>()
    @ObservationIgnored private var cancelled: Set<String> = []
    @ObservationIgnored private var permissionWaiters: [String: CheckedContinuation<String, Never>] = [:]
    @ObservationIgnored private var ledger = TurnLedger()

    init(backend: DemoBackend?) {
        self.backend = backend
        if backend != nil, DemoTurns.enabled { ledger.apply(.turnsSnapshot([DemoTurns.working])) }
    }

    func start() {
        guard backend != nil, connectionState == .idle else { return }
        connectionState = .connecting
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            connectionState = .connected
            publishSnapshot()
        }
    }

    /// Every event goes through the ledger so `turns.snapshot` matches what was streamed, as on the gateway.
    private func publish(_ event: ServerEvent) {
        ledger.apply(event)
        eventBus.yield(event)
    }

    private func publishSnapshot() {
        publish(.turnsSnapshot(Array(ledger.turns.values)))
    }

    func stop() { connectionState = .idle }
    func events() -> AsyncStream<ServerEvent> { eventBus.stream() }
    func reconnects() -> AsyncStream<Void> { reconnectBus.stream() }

    func send(_ event: ClientEvent) async throws {
        guard backend != nil else { throw NuoError.offline }
        switch event {
        case let .prompt(conversationId, text, attachments, _, _, _, voice, _, _, _):
            cancelled.remove(conversationId)
            Task { await run(conversationId: conversationId, text: text, attachments: attachments, voice: voice) }
        case let .cancel(conversationId):
            cancelled.insert(conversationId)
            if let turn = ledger.turn(conversationId), turn.messageId == DemoTurns.messageId {
                for step in turn.steps where step.status == .running {
                    publish(.toolEnd(conversationId: conversationId, messageId: turn.messageId, toolCallId: step.toolCallId, status: .failed, durationMs: 0))
                }
                let duration = Int(Date().timeIntervalSince(turn.startedAt) * 1000)
                publish(.messageEnd(conversationId: conversationId, messageId: turn.messageId, durationMs: duration, steps: turn.steps.count, stopReason: .cancelled))
                await backend?.endWorkingTurn(stopReason: .cancelled)
            }
        case .turnsSync:
            publishSnapshot()
        case let .permission(requestId, optionId, _):
            permissionWaiters.removeValue(forKey: requestId)?.resume(returning: optionId)
        case .ping:
            eventBus.yield(.pong)
        case .presence:
            break
        }
    }

    // MARK: - Scripts

    private struct Script {
        var steps: [(title: String, kind: String, ms: Int)] = []
        var text: String
        var permission: String?
        var fails = false
        /// Tool commands skip the agent: one quick step and the tool's text in a single delta.
        var direct = false
        /// Characters per delta, a few by default; long answers stream faster, like a real agent.
        var chunk: Int?
    }

    /// Answers the demo commands under their English or French name, whatever the language the demo runs in.
    private func commandScript(_ line: SlashLine) -> Script? {
        let flight = line.args.split(separator: " ").first.map { $0.uppercased() } ?? "TO8285"
        switch line.name {
        case "seance", "workout":
            return Script(steps: [("session_today", "fetch", 380)], text: String(localized: "demo.transport.workout", defaultValue: """
            **Short intervals** · recovery 71%, green light.
            - Warm-up, 15 min in Z2
            - **6 × 800 m at 4:35/km**, 2 min jog recovery
            - Cool-down, 10 min
            """), direct: true)
        case "vol", "flight":
            return Script(steps: [("flight_status \(flight)", "fetch", 420)],
                          text: String(localized: "**\(flight)** on time · gate **F32**, boarding 13:55.") + "\n" + DemoSeed.flightCard(flight), direct: true)
        case "vols", "flights":
            return Script(steps: [("booking_lookup", "fetch", 350)], text: String(localized: "demo.transport.flights", defaultValue: """
            - **Mon, Oct 19** TO8285 Rome → Orly, 14:40
            - **Fri, Nov 6** TP433 Orly → Lisbon, 07:15
            """), direct: true)
        case "favoris", "favorites":
            return Script(steps: [("favorites", "fetch", 260)], text: String(localized: "Your favorites: **TUN ⇄ ORY**, **ORY → LIS**, favorite airport **Orly T3**."), direct: true)
        case "macros":
            return Script(steps: [("macros", "fetch", 310)], text: String(localized: "demo.transport.macros", defaultValue: """
            ::facts {"title":"Today's macros","items":[["Calories","1,840 / 2,450 kcal"],["Protein","132 / 165 g"],["Carbs","190 / 280 g"],["Fat","58 / 75 g"]]}
            """), direct: true)
        case "plan":
            return Script(steps: [("week_plan", "fetch", 450)], text: String(localized: "demo.transport.plan", defaultValue: """
            - **Mon** Easy run, 45 min Z2
            - **Wed** Intervals, 6 × 800 m
            - **Fri** Upper-body strength
            - **Sun** Long run, 1 h 30
            """), direct: true)
        case "jour", "day":
            return Script(steps: [("day_summary", "fetch", 330)], text: String(localized: "Solid day: **9,840 steps**, strain **12.4**, sleep **7 h 22**. Go to bed before 11 pm to keep your recovery up."), direct: true)
        case "etat", "status":
            return Script(steps: [("services_status", "execute", 410)], text: String(localized: "demo.transport.status", defaultValue: """
            ::callout {"style":"success","title":"Everything is up","text":"nuo-gateway, lumen-api and postgres are responding. Last deployment 4 h ago."}
            """), direct: true)
        default:
            return nil
        }
    }

    /// Picks the scripted answer from keywords, in English or French, so the demo answers in both languages.
    private func script(for prompt: String, hasImage: Bool, voice: Bool) -> Script {
        // A pasted text comes back reread, to profile a long streamed answer.
        if prompt.utf8.count > 5_000 {
            let excerpt = String(prompt.utf8.prefix(60_000)) ?? prompt
            let count = excerpt.split(separator: "\n").count
            return Script(steps: [("Read texte-colle.txt", "read", 300)],
                          text: String(localized: "Here's your text, reread:") + "\n\n```\n\(excerpt)\n```\n\n" + String(localized: "**\(count) lines** reread."), chunk: 240)
        }
        let lower = prompt.lowercased()
        func mentions(_ words: String...) -> Bool { words.contains { lower.contains($0) } }
        if let line = SlashLine.parse(prompt), let script = commandScript(line) {
            return script
        }
        if prompt.contains(QuestionReply.arrow) {
            return Script(
                steps: [("home_assistant remote.pair salon", "execute", 900)],
                text: String(localized: "On it: I'm re-pairing the living room remote, and the vacuum is cleaning the rooms you picked."))
        }
        if mentions("télécommande", "remote") {
            return Script(
                steps: [("home_assistant devices --area salon", "fetch", 700)],
                text: String(localized: "demo.transport.remote", defaultValue: """
                The living room remote hasn't responded since this morning. Two questions before I act:
                ::question {"question":"Which one first?","options":["Re-pair the remote","Remove the device"],"multiple":false}
                ::question {"question":"Which rooms should the vacuum clean meanwhile?","options":["Living room","Kitchen","Bedroom"],"multiple":true}
                """))
        }
        if mentions("how did", "comment s'est passé") {
            return Script(steps: [("whoop_workout today", "fetch", 900)], text: DemoCards.session)
        }
        if mentions("parcel", "package", "colis") {
            return Script(steps: [("parcel_track NLX48152026773", "fetch", 1000)], text: DemoCards.parcel())
        }
        if mentions("house", "maison") {
            return Script(steps: [("home_assistant states --all", "fetch", 1100)], text: DemoCards.house)
        }
        if lower.contains("#gog") {
            return Script(
                steps: [("gog calendar events --from tomorrow --to tomorrow", "execute", 1100)],
                text: String(localized: "demo.transport.gog", defaultValue: """
                Tomorrow you have **3 appointments**:
                - **09:30** Nuo weekly sync · Google Meet, 30 min
                - **12:45** Team lunch · Bistro, Paris 9th
                - **17:00** Dentist · Dental office, 8 rue Saint-Lazare

                Your longest free slot is **14:00 → 16:30**. Should I block it for focus time?
                """))
        }
        if lower.hasPrefix("code-barres scanné") || lower.hasPrefix("barcode scanned") {
            let code = prompt.filter(\.isNumber)
            if code == DemoProducts.peachIcedTea {
                return Script(steps: [("food_lookup \(code)", "fetch", 700)], text: DemoCards.drink(code))
            }
            return Script(
                steps: [("food_lookup \(code)", "fetch", 700)],
                text: String(localized: "Here's the product sheet.") + "\n::product {\"barcode\":\"\(code)\",\"portion_g\":\(DemoProducts.portion(code))}\n"
                    + String(localized: "How much did you have? I'll log it in today's macros."))
        }
        if mentions("poke") {
            return Script(steps: [("log_food", "execute", 600), ("macros", "fetch", 300)], text: DemoCards.meal)
        }
        if lower.hasPrefix("j'ai mangé") || lower.hasPrefix("i ate") || lower.hasPrefix("i had") {
            return Script(
                steps: [("log_food", "execute", 600), ("macros", "fetch", 300)],
                text: String(localized: "demo.transport.mealLogged", defaultValue: "Got it.\n::callout {\"style\":\"success\",\"title\":\"Meal logged\",\"text\":\"You have 610 kcal and 33 g of protein left for today.\"}"))
        }
        if voice {
            return Script(text: String(localized: "Got it. I'm on it and I'll get back to you in a few minutes."))
        }
        if hasImage || lower.contains("image") {
            return Script(
                steps: [("analyse_image", "read", 900)],
                text: String(localized: "Nice photo! It looks like a sunset over the hills. I can crop it or make a square version if you like.")
                    + "\n::image {\"url\":\"/api/media/demo-edit.jpg\",\"caption\":\"" + String(localized: "Cropped to 4:3") + "\"}")
        }
        if mentions("vol", "flight", "avion", "plane") {
            return Script(
                steps: [("booking_lookup", "fetch", 900), ("flight_status TO8285", "fetch", 1400)],
                text: String(localized: "Yes, **TO8285 Rome → Paris** is on time. Boarding opens at 13:55, so plan to be at the airport around 12:40.")
                    + "\n" + DemoSeed.flightCard(airline: false))
        }
        if mentions("météo", "meteo", "temps", "weather") {
            return Script(
                steps: [("weather_forecast Paris", "fetch", 800)],
                text: String(localized: "demo.transport.weather", defaultValue: "Tomorrow in Paris: cloudy, **61 to 75 °F**, with a 45% drizzle risk late in the day.\n::weather {\"location\":\"Paris\",\"temperature\":64,\"condition\":\"Cloudy\",\"icon\":\"cloud\",\"high\":75,\"low\":59,\"forecast\":[{\"day\":\"Today\",\"high\":75,\"low\":59,\"icon\":\"cloud\"},{\"day\":\"Sun\",\"high\":75,\"low\":61,\"icon\":\"rain\"},{\"day\":\"Mon\",\"high\":77,\"low\":55,\"icon\":\"partly\"},{\"day\":\"Tue\",\"high\":73,\"low\":54,\"icon\":\"sun\"}]}"))
        }
        if mentions("supprim", "nettoie", "rm ", "delete", "clean") {
            return Script(
                steps: [("du -sh build", "execute", 600)],
                text: String(localized: "Done: the `build` folder is deleted, **2.4 GB** freed."),
                permission: String(localized: "Run rm -rf build?"))
        }
        if mentions("erreur", "error") {
            return Script(text: String(localized: "Looking into it…"), fails: true)
        }
        return Script(
            steps: [("search", "fetch", 700)],
            text: String(localized: "demo.transport.summary", defaultValue: """
            Here's a quick summary:

            ## Key points
            - **Nuo** connects the iPhone to the agents running on `dev`.
            - Each bot has its own *instructions*, model and tools.
            - Answers can include rich cards.

            | Bot | Model | Tools |
            |---|---|---|
            | Cobot | Opus 5.5 | 3 |
            | Travel | Sonnet 5 | 2 |

            ```swift
            let reply = try await bot.ask("Hello")
            ```
            """))
    }

    private func run(conversationId: String, text: String, attachments: [Attachment], voice: Bool) async {
        guard let backend else { return }
        let userMessage = Message(id: "u-\(UUID().uuidString.prefix(6))", conversationId: conversationId, role: .user, text: text, attachments: attachments.isEmpty ? nil : attachments, createdAt: Date())
        let messageId = "a-\(UUID().uuidString.prefix(6))"
        let started = Date()
        let script = script(for: text, hasImage: !attachments.isEmpty, voice: voice)
        var steps: [ToolStep] = []
        var output = ""

        let botId = await backend.botId(conversationId: conversationId)
        func emit(_ event: ServerEvent) { publish(event) }
        func finish(_ reason: StopReason) async {
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            if !output.hasPrefix("::notice"), let context = await backend.addContext(conversationId: conversationId, tokens: 900 + output.count * 2) {
                emit(.context(conversationId: conversationId, context: context))
            }
            emit(.messageEnd(conversationId: conversationId, messageId: messageId, durationMs: duration, steps: steps.count, stopReason: reason))
            let reply = Message(id: messageId, conversationId: conversationId, role: .assistant, text: output, steps: steps, durationMs: duration, stopReason: reason, createdAt: started)
            await backend.record(conversationId: conversationId, messages: [userMessage, reply])
        }

        if SlashLine.parse(text)?.name == BotCommand.compactName {
            emit(.messageStart(conversationId: conversationId, messageId: messageId, at: started, botId: botId, phase: .queued))
            try? await Task.sleep(for: .milliseconds(1800))
            guard let (before, context) = await backend.compact(conversationId: conversationId) else { return }
            let notice = String(localized: "Conversation compacted")
            output = Message.noticeLine(kind: "compacted", text: notice, beforeTokens: before, afterTokens: context.usedTokens)
            emit(.notice(conversationId: conversationId, kind: "compacted", text: notice, beforeTokens: before, afterTokens: context.usedTokens))
            emit(.context(conversationId: conversationId, context: context))
            await finish(.endTurn)
            return
        }

        emit(.messageStart(conversationId: conversationId, messageId: messageId, at: started, botId: botId, phase: .queued))
        try? await Task.sleep(for: .milliseconds(script.direct ? 40 : 250))
        emit(.turnPhase(conversationId: conversationId, messageId: messageId, phase: .thinking))

        if script.fails {
            try? await Task.sleep(for: .milliseconds(900))
            emit(.error(conversationId: conversationId, message: String(localized: "The agent stopped responding (timed out).")))
            emit(.messageEnd(conversationId: conversationId, messageId: messageId, durationMs: Int(Date().timeIntervalSince(started) * 1000), steps: 0, stopReason: .error))
            return
        }

        if let question = script.permission {
            try? await Task.sleep(for: .milliseconds(500))
            let requestId = "p-\(UUID().uuidString.prefix(6))"
            let options = [
                PermissionOption(id: "allow_once", name: String(localized: "Allow once"), kind: "allow_once"),
                PermissionOption(id: "allow_always", name: String(localized: "Always allow"), kind: "allow_always"),
                PermissionOption(id: "reject_once", name: String(localized: "Deny"), kind: "reject_once"),
            ]
            let answer = await withCheckedContinuation { continuation in
                permissionWaiters[requestId] = continuation
                emit(.permissionRequest(conversationId: conversationId, requestId: requestId, title: question, options: options, offer: ToolRuleOffer(tool: "Bash", rules: [.allow, .block])))
            }
            emit(.turnPhase(conversationId: conversationId, messageId: messageId, phase: .thinking))
            if answer.hasPrefix("reject") {
                output = String(localized: "OK, I didn't delete anything.")
                emit(.messageDelta(conversationId: conversationId, messageId: messageId, text: output))
                await finish(.endTurn)
                return
            }
        }

        for (index, step) in script.steps.enumerated() {
            if cancelled.contains(conversationId) { await finish(.cancelled); return }
            let id = "\(messageId)-t\(index)"
            steps.append(ToolStep(toolCallId: id, title: step.title, kind: step.kind, status: .running))
            emit(.toolStart(conversationId: conversationId, messageId: messageId, toolCallId: id, title: step.title, kind: step.kind))
            try? await Task.sleep(for: .milliseconds(step.ms))
            steps[index].status = .completed
            steps[index].durationMs = step.ms
            emit(.toolEnd(conversationId: conversationId, messageId: messageId, toolCallId: id, status: .completed, durationMs: step.ms))
        }

        if script.direct {
            output = script.text
            emit(.messageDelta(conversationId: conversationId, messageId: messageId, text: output))
            await finish(.endTurn)
            return
        }

        var buffer = Substring(script.text)
        while !buffer.isEmpty {
            if cancelled.contains(conversationId) { await finish(.cancelled); return }
            let lineEnd = buffer.firstIndex(of: "\n") ?? buffer.endIndex
            let isCard = buffer.hasPrefix("::")
            let size = isCard ? buffer.distance(from: buffer.startIndex, to: lineEnd) : script.chunk ?? Int.random(in: 2...7)
            let chunk = String(buffer.prefix(max(1, size)))
            buffer = buffer.dropFirst(chunk.count)
            output += chunk
            emit(.messageDelta(conversationId: conversationId, messageId: messageId, text: chunk))
            try? await Task.sleep(for: .milliseconds(isCard ? 200 : 22))
        }
        await finish(.endTurn)
    }
}
