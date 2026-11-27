import Foundation
import Network

/// Picks how to reach the gateway: the home address (Caddy, LAN/VPN) when it answers quickly, else the internet
/// address (Cloudflare Tunnel + Access headers). The choice is remembered per network, so at home it is instant.
actor GatewayRouter {
    private let lan: URL
    private var internet: URL?
    private var internetHeaders: [String: String]
    private var networkKey = "unknown"
    private var choices: [String: Bool]
    private var probing: Task<Bool, Never>?
    private let monitor = NWPathMonitor()

    private static let choicesKey = AppIdentity.local(.routeChoices)
    private static let lanProbeTimeout: TimeInterval = 1.5

    init(lan: URL, internet: URL?, internetHeaders: [String: String]) {
        self.lan = lan
        self.internet = internet
        self.internetHeaders = internetHeaders
        choices = (UserDefaults.standard.dictionary(forKey: Self.choicesKey) as? [String: Bool]) ?? [:]
        monitor.pathUpdateHandler = { [weak self] path in
            let key = Self.key(for: path)
            Task { await self?.setNetwork(key) }
        }
        monitor.start(queue: DispatchQueue(label: AppIdentity.scoped("path")))
    }

    deinit { monitor.cancel() }

    static func fromSharedCredentials(fallbackLAN: URL) -> GatewayRouter {
        GatewayRouter(lan: SharedCredentials.gatewayURL ?? fallbackLAN, internet: SharedCredentials.publicURL, internetHeaders: SharedCredentials.accessHeaders())
    }

    var lanRoute: GatewayRoute { GatewayRoute(baseURL: lan, headers: [:], isInternet: false) }
    var internetRoute: GatewayRoute? { internet.map { GatewayRoute(baseURL: $0, headers: internetHeaders, isInternet: true) } }

    func route() async -> GatewayRoute {
        guard let internetRoute else { return lanRoute }
        // Paired remotely, the "home" address is the public one: without the Access headers Cloudflare refuses it.
        if lan.host() == internetRoute.baseURL.host() { return internetRoute }
        if let useInternet = choices[networkKey] { return useInternet ? internetRoute : lanRoute }
        let task = probing ?? Task { await Self.lanAnswers(lan) == false }
        probing = task
        let useInternet = await task.value
        probing = nil
        remember(useInternet)
        return useInternet ? internetRoute : lanRoute
    }

    /// The home address answered with something that is not the gateway (e.g. Cloudflare Access refusing a
    /// request without its headers): stop preferring it on this network.
    func homeRefused() {
        remember(true)
    }

    /// A public address or Access token configured on the gateway after this device was paired.
    func updateInternet(_ url: URL?, headers: [String: String]) {
        internet = url
        internetHeaders = headers
    }

    /// The other address, after `failed` could not reach the gateway at all.
    func alternative(to failed: GatewayRoute) -> GatewayRoute? {
        let other = failed.isInternet ? lanRoute : internetRoute
        if let other { remember(other.isInternet) }
        return other
    }

    private func remember(_ useInternet: Bool) {
        choices[networkKey] = useInternet
        UserDefaults.standard.set(choices, forKey: Self.choicesKey)
    }

    private func setNetwork(_ key: String) {
        networkKey = key
    }

    private static func lanAnswers(_ lan: URL) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = lanProbeTimeout
        configuration.timeoutIntervalForResource = lanProbeTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "/api/health", relativeTo: lan) else { return false }
        let response = try? await session.data(from: url).1
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Identifies "this network" without location data: interface kinds, names and the default gateways.
    private static func key(for path: NWPath) -> String {
        guard path.status == .satisfied else { return "offline" }
        let interfaces = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.joined(separator: ",")
        return "\(interfaces)|\(gateways)"
    }
}
