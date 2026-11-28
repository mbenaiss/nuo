import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Pairing, gateway address, live connection and app-wide preferences.
@MainActor
@Observable
final class SessionStore {
    nonisolated static var defaultGateway: String { AppIdentity.defaultGateway }

    /// `locked`: launched while the iPhone was locked, the device key cannot be read yet. Never shown as pairing,
    /// since pairing again would replace that key.
    enum Phase: Equatable { case locked, pairing, ready }

    let isDemo: Bool
    private(set) var phase: Phase
    #if os(macOS)
    @ObservationIgnored private var isForeground = true
    #else
    // iOS may launch the app in the background (push, refresh): it is in front only once the scene says so.
    @ObservationIgnored private var isForeground = false
    #endif
    private(set) var gatewayURL: URL
    private(set) var api: any NuoAPI
    private(set) var transport: any LiveTransport
    /// Running turns across all conversations; subscribed before the socket opens so no snapshot is missed.
    let turns = TurnTracker()
    private(set) var health: HealthInfo?
    private(set) var gatewayReachable: Bool?
    private(set) var profile: GatewayProfile?

    var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var userName: String {
        didSet { UserNamePreference(defaults: .standard, isDemo: isDemo).save(userName) }
    }

    var connectionState: ConnectionState { transport.connectionState }
    /// Why the pairing screen is shown again (revoked device, security upgrade), if it is not the first pairing.
    private(set) var pairingNotice: String?
    @ObservationIgnored private var reauthObserver: NSObjectProtocol?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored private var authSession: AuthSession?

    private enum Keys {
        static let gateway = AppIdentity.local(.gatewayURL)
        static let appearance = AppIdentity.local(.appearance)
    }

    init(demo: Bool) {
        isDemo = demo
        let defaults = UserDefaults.standard
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        userName = UserNamePreference(defaults: defaults, isDemo: demo).load()
        let gateway = AppIdentity.gatewayURL
        gatewayURL = gateway

        if demo {
            let backend = DemoBackend()
            api = backend
            transport = DemoTransport(backend: backend)
            phase = ProcessInfo.processInfo.arguments.contains("pairing") ? .pairing : .ready
        } else {
            let restored = AuthSession.restoreState(fallbackLAN: gateway)
            if case let .paired(auth) = restored {
                api = NuoClient(baseURL: gateway, auth: auth)
                transport = NuoSocket(auth: auth)
                authSession = auth
                profile = SharedCredentials.profile
                phase = .ready
                Task { await auth.syncNetwork() }
            } else {
                api = NuoClient(baseURL: gateway, auth: nil)
                transport = DemoTransport.idle
                if case .waitForUnlock = restored {
                    phase = .locked
                } else {
                    phase = .pairing
                    if AuthSession.hasLegacyPairing { pairingNotice = Self.upgradeNotice }
                }
            }
        }
        if phase == .ready { startTransport() }
        if !demo {
            #if os(iOS)
            // A launch while locked may stay in the background until the user opens the app: pick up the pairing
            // as soon as the Keychain opens, not only when a scene becomes active.
            unlockObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreIfUnlocked() }
            }
            #elseif os(macOS)
            // A visible window stays active while the screen is locked, so no scene change follows the unlock.
            unlockObserver = DistributedNotificationCenter.default().addObserver(forName: Self.screenUnlocked, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreIfUnlocked() }
            }
            #endif
            reauthObserver = NotificationCenter.default.addObserver(forName: AuthSession.reauthNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.confirmRevocation() }
            }
        }
    }

    @ObservationIgnored private var pairingInFlight = false

    #if os(macOS)
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    #endif

    /// Picks up the existing pairing once the Keychain can be read again; shows pairing only when it answered that
    /// this device has none. A pairing in progress has already replaced the key: nothing to pick up then.
    func restoreIfUnlocked() {
        guard !isDemo, phase != .ready, !pairingInFlight else { return }
        switch AuthSession.restoreState(fallbackLAN: gatewayURL) {
        case let .paired(auth):
            profile = SharedCredentials.profile
            pairingNotice = nil
            connect(url: gatewayURL, auth: auth)
            Task { await auth.syncNetwork() }
        case .unpaired:
            guard phase == .locked else { return }
            phase = .pairing
            if AuthSession.hasLegacyPairing { pairingNotice = Self.upgradeNotice }
        case .waitForUnlock:
            break
        }
    }

    private static var upgradeNotice: String {
        String(localized: "Stronger security: Nuo now uses a key of its own on this device and two-factor authentication. Pair it again with `bun run pair` and your 2FA code.")
    }

    @ObservationIgnored private var confirmingRevocation = false

    func confirmRevocation() {
        guard !confirmingRevocation, let auth = authSession else { return }
        confirmingRevocation = true
        Task {
            let revoked = await auth.confirmRevoked()
            confirmingRevocation = false
            if revoked {
                requirePairing(notice: String(localized: "The gateway no longer allows this device (revoked or old pairing). Pair it again with a pairing code and your 2FA code."))
            }
        }
    }

    private func requirePairing(notice: String) {
        guard phase == .ready, !isDemo else { return }
        unpair()
        pairingNotice = notice
    }

    /// A demo never shows the gateway the build was configured with: screenshots of it get published.
    var gatewayDisplay: String { isDemo ? "gateway.example.com" : gatewayURL.host() ?? gatewayURL.absoluteString }

    /// The « Navigateur » screen streams the gateway's shared browser; the demo renders a local page.
    func makeBrowserTransport() -> any BrowserTransport {
        if !isDemo, let authSession { return LiveBrowserTransport(auth: authSession) }
        return DemoBrowserTransport()
    }

    static func normalizedURL(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    /// `secondFactor` is the current TOTP code, or one of the recovery codes.
    func pair(gateway: String, profile profileName: String, code: String, secondFactor: String) async throws {
        guard let url = Self.normalizedURL(gateway) else { throw NuoError.invalidURL }
        let digits = code.filter(\.isNumber)
        if isDemo {
            try await Task.sleep(for: .milliseconds(600))
            guard digits.count == 6 else { throw NuoError.server(status: 400, message: String(localized: "Invalid or expired code.")) }
            phase = .ready
            startTransport()
            return
        }
        let factor = secondFactor.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        pairingInFlight = true
        defer { pairingInFlight = false }
        let auth = try await AuthSession.pair(lanURL: url, profile: name, code: digits, secondFactor: factor, deviceName: PlatformDevice.name)
        UserDefaults.standard.set(url.absoluteString, forKey: Keys.gateway)
        profile = SharedCredentials.profile
        pairingNotice = nil
        connect(url: url, auth: auth)
    }

    func unpair() {
        transport.stop()
        if !isDemo {
            AuthSession.forget()
            authSession = nil
            api = NuoClient(baseURL: gatewayURL, auth: nil)
            transport = DemoTransport.idle
        }
        profile = nil
        health = nil
        phase = .pairing
    }

    private func connect(url: URL, auth: AuthSession) {
        transport.stop()
        authSession = auth
        gatewayURL = url
        api = NuoClient(baseURL: url, auth: auth)
        transport = NuoSocket(auth: auth)
        phase = .ready
        startTransport()
    }

    private func startTransport() {
        (transport as? NuoSocket)?.foreground = isForeground
        turns.attach(transport)
        transport.start()
    }

    func refreshHealth() async {
        do {
            health = try await api.health()
            gatewayReachable = true
        } catch {
            gatewayReachable = false
        }
    }

    func refreshProfile() async {
        guard profile == nil, let authSession else { return }
        profile = await authSession.syncProfile()
    }

    /// Socket goes quiet in the background; reconnect as soon as the app is active again.
    func setForeground(_ active: Bool) {
        isForeground = active
        (transport as? NuoSocket)?.foreground = active
    }

    func handleScenePhase(active: Bool) {
        setForeground(active)
        guard active else { return }
        restoreIfUnlocked()
        revive()
    }

    /// Checks the socket and the network after the app was away (foreground again, Mac woken from sleep), without
    /// changing whether it counts as in front.
    func revive() {
        guard phase == .ready else { return }
        if let socket = transport as? NuoSocket {
            socket.revive()
        } else {
            transport.start()
        }
        if transport.connectionState == .connected {
            let transport = self.transport
            Task { try? await transport.send(.turnsSync) }
        }
        Task { await refreshHealth() }
        if let authSession { Task { await authSession.syncNetwork() } }
    }

    var mediaLoader: MediaLoader {
        let api = self.api
        return MediaLoader { path in
            if path.hasPrefix("http://") || path.hasPrefix("https://"), !path.contains("/api/media/") {
                let (data, _) = try await URLSession.shared.data(from: URL(string: path)!)
                return data
            }
            return try await api.media(path: path)
        }
    }

    func agentStatus(_ id: AgentID) -> AgentInfo? {
        health?.agents.first { $0.id == id }
    }
}
