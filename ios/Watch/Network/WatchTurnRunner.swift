import Foundation

/// Runs one prompt and reports its progress until the answer is final.
@MainActor
protocol WatchTurnRunner: AnyObject {
    /// `viaPhone`: the bot is out of the watch token's reach (the general bot, a bot with full access), so the iPhone
    /// sends the prompt with the app's access.
    func run(conversationId: String, text: String, knownMessageIds: Set<String>, viaPhone: Bool) -> AsyncStream<TurnUpdate>
    /// A turn the iPhone already started (a spoken request): its answer, as the iPhone relays it and the gateway stores it.
    func follow(conversationId: String, prompt: String, knownMessageIds: Set<String>) -> AsyncStream<TurnUpdate>
    /// The watch's answer to a confirmation, sent by the iPhone (the watch token may not answer one).
    func answer(requestId: String, optionId: String) async throws
}

/// Tries a WebSocket first (fine in the simulator and on Wi-Fi, but watchOS restricts sockets on device),
/// then asks the iPhone to send the prompt and polls the persisted messages until the answer lands.
@MainActor
final class LiveTurnRunner: WatchTurnRunner {
    typealias Relay = @MainActor (_ conversationId: String, _ text: String) async throws -> Void
    typealias Answer = @MainActor (_ requestId: String, _ optionId: String) async throws -> Void

    private let api: any WatchAPI
    private let baseURL: URL
    private let token: String
    private let relay: Relay
    private let answerRelay: Answer
    private let session = URLSession(configuration: .default)

    init(api: any WatchAPI, baseURL: URL, token: String, relay: @escaping Relay, answer: @escaping Answer) {
        self.api = api
        self.baseURL = baseURL
        self.token = token
        self.relay = relay
        answerRelay = answer
    }

    func run(conversationId: String, text: String, knownMessageIds: Set<String>, viaPhone: Bool) -> AsyncStream<TurnUpdate> {
        let (stream, continuation) = AsyncStream<TurnUpdate>.makeStream()
        let task = Task { @MainActor in
            await self.drive(conversationId: conversationId, text: text, known: knownMessageIds, viaPhone: viaPhone, continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func follow(conversationId: String, prompt: String, knownMessageIds: Set<String>) -> AsyncStream<TurnUpdate> {
        let (stream, continuation) = AsyncStream<TurnUpdate>.makeStream()
        let task = Task { @MainActor in
            await self.followRelayed(conversationId: conversationId, known: knownMessageIds, continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func answer(requestId: String, optionId: String) async throws {
        try await answerRelay(requestId, optionId)
    }

    /// The iPhone's live events when it is in reach, the stored messages in any case: whichever ends the turn first.
    private func followRelayed(conversationId: String, known: Set<String>, _ out: AsyncStream<TurnUpdate>.Continuation) async {
        let feed = PhoneTurnFeed.shared.updates(conversationId: conversationId)
        let (done, signal) = AsyncStream<Void>.makeStream()
        // Once the iPhone's live text flows, the stored copy only ends the turn: its full text would make the answer stutter.
        let liveText = LiveTextFlag()
        let live = Task { @MainActor in
            for await update in feed {
                if case .delta = update { liveText.seen = true }
                out.yield(update)
                if update.endsTurn { break }
            }
            signal.yield()
        }
        let (polled, polledOut) = AsyncStream<TurnUpdate>.makeStream()
        let stored = Task { @MainActor in
            await self.poll(conversationId: conversationId, known: known, polledOut)
            polledOut.finish()
        }
        let relay = Task { @MainActor in
            for await update in polled {
                if case .replace = update, liveText.seen { continue }
                out.yield(update)
            }
            signal.yield()
        }
        for await _ in done { break }
        live.cancel()
        stored.cancel()
        relay.cancel()
    }

    private func drive(conversationId: String, text: String, known: Set<String>, viaPhone: Bool, _ out: AsyncStream<TurnUpdate>.Continuation) async {
        if !viaPhone, let socket = await openSocket() {
            defer { socket.cancel(with: .goingAway, reason: nil) }
            let prompt = ClientEvent.prompt(conversationId: conversationId, text: text, voice: false)
            if let data = try? NuoJSON.encoder().encode(prompt),
               (try? await socket.send(.string(String(decoding: data, as: UTF8.self)))) != nil {
                if await pump(socket, conversationId: conversationId, out) { return }
                await poll(conversationId: conversationId, known: known, out)
                return
            }
        }
        PhoneTurnFeed.shared.reset(conversationId: conversationId)
        do {
            try await relay(conversationId, text)
        } catch {
            out.yield(.failed(error.localizedDescription))
            return
        }
        await followRelayed(conversationId: conversationId, known: known, out)
    }

    private var socketURL: URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/api/ws"
        return components.url
    }

    private func openSocket() async -> URLSessionWebSocketTask? {
        guard let url = socketURL else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(GatewayLanguage.acceptLanguage(), forHTTPHeaderField: GatewayLanguage.header)
        let task = session.webSocketTask(with: request)
        task.resume()
        let opened = await withTaskGroup(of: Bool.self) { group in
            // The gateway sends `turns.snapshot` first, and URLSession delivers a pong only after earlier frames are
            // read: the first message, not a ping, proves the socket. The watch has no use for the snapshot itself.
            group.addTask { (try? await task.receive()) != nil }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return false
            }
            let first = await group.next() ?? false
            if !first { task.cancel(with: .abnormalClosure, reason: nil) }
            group.cancelAll()
            return first
        }
        return opened ? task : nil
    }

    /// Returns true once the turn ended; false when the socket dropped first.
    private func pump(_ socket: URLSessionWebSocketTask, conversationId: String, _ out: AsyncStream<TurnUpdate>.Continuation) async -> Bool {
        let keepAlive = Task {
            var elapsed = 0
            while !Task.isCancelled, elapsed < 300 {
                try? await Task.sleep(for: .seconds(20))
                elapsed += 20
                if let data = try? NuoJSON.encoder().encode(ClientEvent.ping) {
                    try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
                }
            }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { keepAlive.cancel() }
        let decoder = NuoJSON.decoder()
        while !Task.isCancelled {
            guard let message = try? await socket.receive() else { return false }
            let data: Data
            switch message {
            case let .string(text): data = Data(text.utf8)
            case let .data(raw): data = raw
            @unknown default: continue
            }
            guard let event = try? decoder.decode(ServerEvent.self, from: data), event.conversationId == conversationId else { continue }
            switch event {
            case let .messageDelta(_, _, text): out.yield(.delta(text))
            case let .toolStart(_, _, toolCallId, title, _): out.yield(.toolStarted(id: toolCallId, title: title))
            case let .toolDetail(_, _, toolCallId, detail): out.yield(.toolDetail(id: toolCallId, detail: detail))
            case .toolEnd: out.yield(.toolEnded)
            case let .messageEnd(_, _, durationMs, steps, stopReason, _, _, _):
                out.yield(.finished(durationMs: durationMs, steps: steps, stopReason: stopReason))
                return true
            case let .error(_, message):
                out.yield(.failed(message))
                return true
            case let .permissionRequest(_, requestId, title, options, _):
                out.yield(.permission(requestId: requestId, title: title, options: options, answerable: false))
            default: break
            }
        }
        return false
    }

    private func poll(conversationId: String, known: Set<String>, _ out: AsyncStream<TurnUpdate>.Continuation) async {
        let deadline = Date().addingTimeInterval(300)
        var lastText = ""
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            guard let messages = try? await api.messages(conversationId: conversationId) else { continue }
            guard let answer = messages.last(where: { $0.role == .assistant && !known.contains($0.id) }) else { continue }
            if answer.text != lastText {
                lastText = answer.text
                out.yield(.replace(answer.text))
            }
            if let stopReason = answer.stopReason {
                out.yield(.finished(durationMs: answer.durationMs ?? 0, steps: answer.steps?.count ?? 0, stopReason: stopReason))
                return
            }
        }
        if !Task.isCancelled { out.yield(.failed(String(localized: "No reply yet. Try again later."))) }
    }
}

@MainActor
private final class LiveTextFlag {
    var seen = false
}
