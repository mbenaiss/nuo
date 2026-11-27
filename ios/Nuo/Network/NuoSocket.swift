import Foundation
import Observation

enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case waiting(retryIn: Int)

    var label: String {
        switch self {
        case .idle: String(localized: "Offline")
        case .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        case let .waiting(seconds): String(localized: "Retrying in \(seconds) s")
        }
    }
}

/// A `ChatTransport` the app can start, stop and observe. The socket and the demo backend both implement it.
@MainActor
protocol LiveTransport: ChatTransport {
    var connectionState: ConnectionState { get }
    func start()
    func stop()
    /// Fires every time the link comes back after a drop, so open screens can refetch what they missed.
    func reconnects() -> AsyncStream<Void>
}

/// Multicast fan-out of an event type to any number of `AsyncStream` subscribers.
@MainActor
final class Broadcaster<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    func stream() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(512))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    func yield(_ element: Element) {
        for continuation in continuations.values { continuation.yield(element) }
    }
}

@MainActor
@Observable
final class NuoSocket: LiveTransport {
    private(set) var connectionState: ConnectionState = .idle

    @ObservationIgnored private let auth: AuthSession
    @ObservationIgnored private let session = URLSession(configuration: .default)
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let eventBus = Broadcaster<ServerEvent>()
    @ObservationIgnored private let reconnectBus = Broadcaster<Void>()
    @ObservationIgnored private var hasConnectedOnce = false
    /// Sent again on every connection, since the gateway forgets it with the socket. Nil: never reported.
    @ObservationIgnored var foreground: Bool? {
        didSet {
            guard let foreground, foreground != oldValue, connectionState == .connected else { return }
            Task { try? await send(.presence(active: foreground)) }
        }
    }

    init(auth: AuthSession) {
        self.auth = auth
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionState = .idle
    }

    /// Back in the foreground: a socket the system suspended can be dead without knowing it, and the retry
    /// loop may be sleeping for up to 30 s. Check the link now instead.
    func revive() {
        guard loop != nil else { return start() }
        switch connectionState {
        case .connected:
            guard let task else { return }
            task.sendPing { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in
                    if self?.task === task { task.cancel(with: .goingAway, reason: nil) }
                }
            }
        case .waiting:
            loop?.cancel()
            loop = nil
            start()
        case .idle, .connecting:
            break
        }
    }

    func events() -> AsyncStream<ServerEvent> { eventBus.stream() }

    func reconnects() -> AsyncStream<Void> { reconnectBus.stream() }

    func send(_ event: ClientEvent) async throws {
        guard let task, connectionState == .connected else { throw NuoError.offline }
        let data = try NuoJSON.encoder().encode(event)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    // MARK: - Connection loop

    private static func socketURL(_ baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/api/ws"
        return components.url
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            connectionState = .connecting
            if await connectOnce() {
                attempt = 0
            }
            guard !Task.isCancelled else { return }
            attempt += 1
            let delay = min(30, 1 << min(attempt - 1, 5))
            for remaining in stride(from: delay, to: 0, by: -1) {
                connectionState = .waiting(retryIn: remaining)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
    }

    /// Returns true when the socket opened before it dropped (resets the backoff). Each attempt takes a fresh
    /// access token: the gateway closes the socket when the token it was opened with expires.
    private func connectOnce() async -> Bool {
        let route = await auth.router.route()
        let token: String
        do {
            token = try await auth.token()
        } catch NuoError.reauthRequired {
            loop?.cancel()
            return false
        } catch NuoError.offline {
            _ = await auth.router.alternative(to: route)
            return false
        } catch {
            return false
        }
        guard let url = Self.socketURL(route.baseURL) else { return false }
        var request = URLRequest(url: url)
        for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        // The gateway sends `turns.snapshot` right after the upgrade, and URLSession only delivers a pong once the
        // frames before it are read: waiting on a ping first would wait forever. The first message proves the socket.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { task.cancel(with: .goingAway, reason: nil) }
        }
        let first = try? await task.receive()
        watchdog.cancel()
        guard first != nil, !Task.isCancelled else {
            task.cancel(with: .abnormalClosure, reason: nil)
            if !Task.isCancelled {
                // Refused upgrade: maybe a revoked token, maybe the wrong address for this network.
                await auth.invalidate(token)
                _ = await auth.router.alternative(to: route)
            }
            return false
        }

        connectionState = .connected
        if let foreground { try? await send(.presence(active: foreground)) }
        if hasConnectedOnce { reconnectBus.yield(()) }
        hasConnectedOnce = true

        let pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                try? await self?.send(.ping)
            }
        }
        defer { pinger.cancel() }

        let decoder = NuoJSON.decoder()
        var pending = first
        while !Task.isCancelled {
            do {
                let message: URLSessionWebSocketTask.Message
                if let next = pending {
                    message = next
                    pending = nil
                } else {
                    message = try await task.receive()
                }
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(raw): data = raw
                @unknown default: continue
                }
                if let event = try? decoder.decode(ServerEvent.self, from: data) {
                    eventBus.yield(event)
                }
            } catch {
                break
            }
        }
        task.cancel(with: .abnormalClosure, reason: nil)
        if self.task === task { self.task = nil }
        return true
    }
}
