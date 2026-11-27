import CoreGraphics
import Foundation
import ImageIO
import Observation

struct BrowserTab: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let title: String
    let url: String
}

/// An agent waiting for the user to log in to a site (`browser-login-needed`).
struct BrowserLogin: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let site: String
    let url: String?
}

struct BrowserViewport: Hashable, Sendable, Decodable {
    let width: Int
    let height: Int
}

/// Messages of `GET /api/browser/ws` (docs/protocol.md, « Shared browser »).
enum BrowserEvent: Sendable {
    case status(String)
    case state(BrowserPageState)
    case frame(CGImage, cssSize: CGSize)
    case done
    case error(String)
}

struct BrowserPageState: Sendable, Decodable {
    var tabs: [BrowserTab] = []
    var activeTabId: String?
    var url = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var viewport: BrowserViewport?
    /// Real zoom applied to the page by the browser, so the app need not upscale the frame itself.
    var pageScale: Double = 1
    /// `"text"`, `"password"` or nothing: a plain string, so an unknown kind never fails the whole state.
    var focus: String?
    var logins: [BrowserLogin] = []

    var isEditing: Bool { focus != nil }
    var isEditingPassword: Bool { focus == "password" }
}

enum BrowserCommand: Sendable {
    case ack, ping, done, reload, back, forward
    case click(x: Double, y: Double, clickCount: Int = 1, button: String = "left")
    case mouse(action: String, x: Double, y: Double, button: String = "left")
    case wheel(x: Double, y: Double, dx: Double, dy: Double)
    case key(String, modifiers: Int = 0)
    case text(String)
    case navigate(String)
    case selectTab(String), newTab, closeTab(String)
    case viewport(width: Int, height: Int)
    /// Pixel size of the area showing the frame: the browser paints no more than that.
    case surface(width: Int, height: Int)
    case zoom(Double)

    var json: [String: Any] {
        switch self {
        case .ack: ["type": "ack"]
        case .ping: ["type": "ping"]
        case .done: ["type": "done"]
        case .reload: ["type": "reload"]
        case .back: ["type": "back"]
        case .forward: ["type": "forward"]
        case let .click(x, y, count, button): ["type": "mouse", "action": "click", "x": x, "y": y, "clickCount": count, "button": button]
        case let .mouse(action, x, y, button): ["type": "mouse", "action": action, "x": x, "y": y, "button": button]
        case let .wheel(x, y, dx, dy): ["type": "mouse", "action": "wheel", "x": x, "y": y, "deltaX": dx, "deltaY": dy]
        case let .key(key, modifiers): ["type": "key", "key": key, "modifiers": modifiers]
        case let .text(text): ["type": "text", "text": text]
        case let .navigate(url): ["type": "navigate", "url": url]
        case let .selectTab(id): ["type": "tab.select", "id": id]
        case .newTab: ["type": "tab.new"]
        case let .closeTab(id): ["type": "tab.close", "id": id]
        case let .viewport(width, height): ["type": "viewport", "width": width, "height": height]
        case let .surface(width, height): ["type": "surface", "width": width, "height": height]
        case let .zoom(factor): ["type": "zoom", "factor": factor]
        }
    }
}

/// One live connection to the shared browser; the stream ends when the socket closes.
@MainActor
protocol BrowserTransport: AnyObject {
    func connect() -> AsyncStream<BrowserEvent>
    func send(_ command: BrowserCommand)
    func disconnect()
}

/// The screen's state: the last frame, tabs, address and the agents' login requests.
@MainActor
@Observable
final class BrowserModel {
    enum Phase: Equatable {
        case connecting, starting, ready
        case offline(String)
    }

    private(set) var phase: Phase = .connecting
    private(set) var image: CGImage?
    /// CSS size of the page area the frame shows; taps are sent as fractions of it.
    private(set) var cssSize = CGSize(width: 1280, height: 720)
    private(set) var page = BrowserPageState()
    var notice: String?

    @ObservationIgnored private let transport: any BrowserTransport
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pinger: Task<Void, Never>?
    @ObservationIgnored private var wantedViewport: BrowserViewport?
    @ObservationIgnored private var wantedSurface: (width: Int, height: Int)?
    @ObservationIgnored private var doneHandler: (() -> Void)?

    init(transport: any BrowserTransport) {
        self.transport = transport
    }

    var activeTab: BrowserTab? { page.tabs.first { $0.id == page.activeTabId } }
    var isMobileLayout: Bool { page.viewport != nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled else { return }
                self.transport.send(.ping)
            }
        }
    }

    func stop() {
        loop?.cancel()
        pinger?.cancel()
        loop = nil
        pinger = nil
        transport.disconnect()
        phase = .connecting
    }

    func send(_ command: BrowserCommand) {
        guard phase == .ready else { return }
        transport.send(command)
    }

    /// « Terminé »: tells waiting agents the user is done, then closes once the gateway confirms (or soon after).
    func finish(_ close: @escaping () -> Void) {
        guard phase == .ready, !page.logins.isEmpty else { return close() }
        doneHandler = close
        transport.send(.done)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.completeDone()
        }
    }

    /// A narrow page on the phone; nil gives the browser's own desktop layout.
    func setViewport(_ viewport: BrowserViewport?) {
        wantedViewport = viewport
        guard phase == .ready else { return }
        transport.send(.viewport(width: viewport?.width ?? 0, height: viewport?.height ?? 0))
    }

    /// How many pixels the frame is actually drawn into: sending a bigger one would only cost time on the wire.
    func setSurface(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        wantedSurface = (width, height)
        guard phase == .ready else { return }
        transport.send(.surface(width: width, height: height))
    }

    func setZoom(_ factor: Double) {
        send(.zoom(max(1, min(5, factor))))
    }

    private func completeDone() {
        guard let handler = doneHandler else { return }
        doneHandler = nil
        handler()
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            phase = .connecting
            var opened = false
            for await event in transport.connect() {
                opened = true
                apply(event)
            }
            guard !Task.isCancelled else { return }
            attempt = opened ? 1 : attempt + 1
            let delay = min(15, 1 << min(attempt, 4))
            phase = .offline(String(localized: "Browser unreachable, retrying in \(delay) s"))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func apply(_ event: BrowserEvent) {
        switch event {
        case let .status(status):
            switch status {
            case "starting": phase = .starting
            case "ready":
                phase = .ready
                if let wantedViewport { transport.send(.viewport(width: wantedViewport.width, height: wantedViewport.height)) }
                if let wantedSurface { transport.send(.surface(width: wantedSurface.width, height: wantedSurface.height)) }
            default: phase = .offline(String(localized: "Browser stopped"))
            }
        case let .state(state):
            page = state
        case let .frame(decoded, cssSize):
            image = decoded
            self.cssSize = cssSize
        case .done:
            completeDone()
        case let .error(message):
            notice = message
        }
    }
}

/// `GET /api/browser/ws` with the device's access token, on the route (home or tunnel) the app uses.
@MainActor
final class LiveBrowserTransport: BrowserTransport {
    private let auth: AuthSession
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?

    init(auth: AuthSession) {
        self.auth = auth
    }

    func connect() -> AsyncStream<BrowserEvent> {
        let (stream, continuation) = AsyncStream<BrowserEvent>.makeStream(bufferingPolicy: .unbounded)
        let runner = Task { @MainActor [weak self] in
            await self?.receive(into: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in runner.cancel() }
        return stream
    }

    func send(_ command: BrowserCommand) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: command.json) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive(into continuation: AsyncStream<BrowserEvent>.Continuation) async {
        let route = await auth.router.route()
        guard let token = try? await auth.token(), var components = URLComponents(url: route.baseURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/api/browser/ws"
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        for (name, value) in route.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        self.task = task
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if self.task === task { self.task = nil }
        }
        let received = await Self.pump(task, into: continuation)
        if !received {
            // Refused upgrade: maybe an expired token, maybe the wrong address for this network.
            await auth.invalidate(token)
            _ = await auth.router.alternative(to: route)
        }
    }
}

extension LiveBrowserTransport {
    /**
     Reads the socket off the main actor: a frame is decoded here, and acknowledged as soon as it is, since the
     browser only paints the next one once the app has caught up.
     */
    private nonisolated static func pump(_ task: URLSessionWebSocketTask, into continuation: AsyncStream<BrowserEvent>.Continuation) async -> Bool {
        var received = false
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { break }
            received = true
            switch message {
            case let .data(raw):
                guard let event = BrowserWire.decodeFrame(raw) else { continue }
                continuation.yield(event)
                acknowledge(task)
            case let .string(text):
                guard let event = BrowserWire.decode(Data(text.utf8)) else { continue }
                continuation.yield(event)
                // A gateway not yet updated still sends frames as JSON; it waits for the same acknowledgement.
                if case .frame = event { acknowledge(task) }
            @unknown default:
                continue
            }
        }
        return received
    }

    private nonisolated static func acknowledge(_ task: URLSessionWebSocketTask) {
        task.send(.string(#"{"type":"ack"}"#)) { _ in }
    }
}

enum BrowserWire {
    private struct Envelope: Decodable {
        let type: String
        let phase: String?
        let data: String?
        let width: Double?
        let height: Double?
        let message: String?
    }

    static func decode(_ data: Data) -> BrowserEvent? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        switch envelope.type {
        case "status": return .status(envelope.phase ?? "")
        case "state": return (try? decoder.decode(BrowserPageState.self, from: data)).map(BrowserEvent.state)
        case "frame":
            guard let base64 = envelope.data, let jpeg = Data(base64Encoded: base64), let image = decodeImage(jpeg) else { return nil }
            return .frame(image, cssSize: CGSize(width: envelope.width ?? 1280, height: envelope.height ?? 720))
        case "done": return .done
        case "error": return .error(envelope.message ?? String(localized: "Browser error"))
        default: return nil
        }
    }

    static func decodeFrame(_ raw: Data) -> BrowserEvent? {
        guard let (size, jpeg) = BrowserFrameWire.split(raw), let image = decodeImage(jpeg) else { return nil }
        return .frame(image, cssSize: size)
    }

    static func decodeImage(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil) else { return nil }
        // Decoded now, on this thread: a lazily decoded image would be decoded again while drawing, on the main one.
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
