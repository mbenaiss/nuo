import EventKit
import Foundation
import Observation

/// What the user lets the bots do on this device, by family of tools (Réglages › Accès des bots).
enum DeviceToolGroup: String, CaseIterable, Identifiable, Sendable {
    case calendars, location, weather, maps, health, workouts, folders

    var id: String { rawValue }

    /// Shared folders are a Mac's own: an iPhone has no folder to share. Santé and les séances are the iPhone's:
    /// a Mac keeps no health data and pairs with no watch.
    static var available: [DeviceToolGroup] {
        #if os(macOS)
        allCases.filter { $0 != .health && $0 != .workouts }
        #else
        allCases.filter { $0 != .folders }
        #endif
    }

    var tools: [String] {
        switch self {
        case .calendars: ["apple_calendars", "apple_events", "apple_event_create", "apple_event_update", "apple_event_delete", "apple_calendar_create", "apple_calendar_update", "apple_calendar_delete"]
        case .location: ["device_location"]
        case .weather: ["weather"]
        case .maps: ["maps_search", "maps_route"]
        case .health: ["health_summary", "health_activity", "health_heart", "health_sleep", "health_workouts", "health_body"]
        case .workouts: ["workout_schedule", "workout_scheduled", "workout_cancel"]
        case .folders: ["mac_folders", "mac_files_list", "mac_files_search", "mac_file_read", "mac_file_write"]
        }
    }

    var title: String {
        switch self {
        case .calendars: String(localized: "Calendars")
        case .location: String(localized: "Location")
        case .weather: String(localized: "Weather")
        case .maps: String(localized: "Maps")
        case .health: String(localized: "Health")
        case .workouts: String(localized: "Workouts")
        case .folders: String(localized: "Folders")
        }
    }

    /// The French name carried by the tool errors the bots read, whatever the app language.
    var toolTitle: String {
        switch self {
        case .calendars: "Calendriers"
        case .location: "Position"
        case .weather: "Météo"
        case .maps: "Plans"
        case .health: "Santé"
        case .workouts: "Séances"
        case .folders: "Dossiers"
        }
    }

    var detail: String {
        switch self {
        case .calendars: String(localized: "Read, create, edit and delete events and calendars, iCloud included.")
        case .location: String(localized: "Give the current location when a bot asks for it.")
        case .weather: String(localized: "Apple Weather, here or elsewhere.")
        case .maps: String(localized: "Search places and work out routes with Apple Maps.")
        case .health: String(localized: "Read activity, heart rate, sleep, workouts and weight in Health. Nothing is written, nothing is kept on the gateway.")
        case .workouts: String(localized: "Schedule a structured workout in Fitness and on the Apple Watch, and cancel it.")
        case .folders: String(localized: "Read, search and write files in this Mac's shared folders.")
        }
    }

    var symbol: String {
        switch self {
        case .calendars: "calendar"
        case .location: "location"
        case .weather: "cloud.sun"
        case .maps: "map"
        case .health: "heart.text.square"
        case .workouts: "figure.run"
        case .folders: "folder"
        }
    }

    static func of(tool: String) -> DeviceToolGroup? { available.first { $0.tools.contains(tool) } }
}

/// Runs the bots' device tools (docs/protocol.md, "Device tools"): requests arrive on the socket while the app is
/// on screen, or as a silent push that wakes it; the device claims each one, then answers over HTTP.
@MainActor
@Observable
final class DeviceToolsCenter {
    static let shared = DeviceToolsCenter()

    struct Activity: Equatable {
        let tool: String
        let at: Date
        let error: String?
    }

    private(set) var lastActivity: Activity?
    /// Bumped when a permission changes, so the settings screen re-reads the statuses.
    private(set) var revision = 0

    @ObservationIgnored private var api: (any NuoAPI)?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var reconnects: Task<Void, Never>?
    @ObservationIgnored private var handled: [String] = []
    @ObservationIgnored private var registered: [String]?
    @ObservationIgnored private let calendars = AppleCalendarTools()
    @ObservationIgnored private let places = PlaceTools()
    #if os(iOS)
    @ObservationIgnored private let health = AppleHealthTools(device: PlatformDevice.name)
    @ObservationIgnored private let workouts = AppleWorkoutTools(device: PlatformDevice.name)
    #endif
    @ObservationIgnored private var isDemo = false
    /// Santé and WorkoutKit only answer about their permissions asynchronously; what the last check said.
    private(set) var healthAsked = false
    private(set) var workoutsAllowed = false

    static var platform: String {
        #if os(macOS)
        "mac"
        #else
        "ios"
        #endif
    }

    private init() {
        DeviceLocator.shared.onChange = { [weak self] in self?.permissionsChanged() }
    }

    func attach(api: any NuoAPI, transport: any LiveTransport, demo: Bool) {
        isDemo = demo
        guard !demo else { return }
        self.api = api
        registered = nil
        listener?.cancel()
        listener = Task { [weak self] in
            for await event in transport.events() {
                guard case let .deviceRequest(id, _, _) = event else { continue }
                await self?.handle(id)
            }
        }
        reconnects?.cancel()
        reconnects = Task { [weak self] in
            for await _ in transport.reconnects() { await self?.register(force: true) }
        }
        Task {
            await refreshAsyncPermissions()
            await register()
        }
    }

    // MARK: Settings

    private static func key(_ g: DeviceToolGroup) -> String { AppIdentity.local(.deviceTools, g.rawValue) }

    func isEnabled(_ g: DeviceToolGroup) -> Bool { UserDefaults.standard.object(forKey: Self.key(g)) as? Bool ?? true }

    func setEnabled(_ g: DeviceToolGroup, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key(g))
        revision += 1
        Task { await register() }
    }

    /// Weather and maps need no permission of their own; « ici » uses the position when it is allowed.
    func isAuthorized(_ g: DeviceToolGroup) -> Bool {
        switch g {
        case .calendars: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .location: DeviceLocator.shared.isAuthorized
        case .weather, .maps: true
        case .health: healthAsked
        case .workouts: workoutsAllowed
        case .folders: hasFolders
        }
    }

    /// Asks the user, from Réglages › Accès des bots. Santé never says what was granted, only that it was asked.
    func requestAccess(_ g: DeviceToolGroup) async {
        #if os(iOS)
        switch g {
        case .health: _ = await AppleHealthTools.requestAccess()
        case .workouts: _ = await AppleWorkoutTools.requestAccess()
        default: return
        }
        await refreshAsyncPermissions()
        permissionsChanged()
        #endif
    }

    private func refreshAsyncPermissions() async {
        #if os(iOS)
        let asked = await AppleHealthTools.wasAsked()
        let allowed = AppleWorkoutTools.isSupported ? await AppleWorkoutTools.isAllowed() : false
        guard asked != healthAsked || allowed != workoutsAllowed else { return }
        healthAsked = asked
        workoutsAllowed = allowed
        revision += 1
        await register()
        #endif
    }

    private var hasFolders: Bool {
        #if os(macOS)
        !FolderAccess.shared.folders.isEmpty
        #else
        false
        #endif
    }

    var tools: [String] { DeviceToolGroup.available.filter { isEnabled($0) && isAuthorized($0) }.flatMap(\.tools) }

    /// Back on screen: a permission may have changed in the system settings.
    func permissionsChanged() {
        revision += 1
        Task {
            await refreshAsyncPermissions()
            await register()
        }
    }

    private func register(force: Bool = false) async {
        guard !isDemo, let api = api as? any NuoDeviceAPI else { return }
        let tools = tools
        guard force || tools != registered else { return }
        do {
            try await api.setDeviceCapabilities(platform: Self.platform, tools: tools)
            registered = tools
        } catch {
            registered = nil
        }
    }

    // MARK: Requests

    /// A silent push from the gateway; false when it is not a device request.
    func handlePush(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard let id = userInfo["deviceRequest"] as? String else { return false }
        if api == nil, let restored = ReminderNotifications.api() { api = restored }
        await handle(id)
        return true
    }

    /// The socket and a push can both bring the same request; the gateway gives it to one device only.
    private func handle(_ id: String) async {
        guard !handled.contains(id), let api = api as? any NuoDeviceAPI else { return }
        handled.append(id)
        if handled.count > 50 { handled.removeFirst(handled.count - 50) }
        guard let request = try? await api.claimDeviceRequest(id: id) else { return }
        let result = await execute(request)
        if case let .failure(error) = result { lastActivity = Activity(tool: request.tool, at: Date(), error: error.message) }
        else { lastActivity = Activity(tool: request.tool, at: Date(), error: nil) }
        try? await api.answerDeviceRequest(id: request.id, result: result)
    }

    func execute(_ request: DeviceRequest) async -> Result<JSONValue, DeviceToolError> {
        guard let group = DeviceToolGroup.of(tool: request.tool) else { return .failure(DeviceToolError("Outil inconnu \(request.tool) sur \(PlatformDevice.name).")) }
        guard isEnabled(group) else {
            return .failure(DeviceToolError("L'utilisateur a désactivé l'accès « \(group.toolTitle) » pour les bots sur \(PlatformDevice.name) (Nuo, Réglages › Accès des bots)."))
        }
        let args = DeviceToolArgs(request.args)
        do {
            switch group {
            case .calendars: return .success(try await calendars.perform(request.tool, args))
            case .folders: return .success(try await runFolderTool(request.tool, args))
            case .location, .weather, .maps: return .success(try await places.run(request.tool, args))
            case .health, .workouts: return .success(try await runHealthTool(group, request.tool, args))
            }
        } catch let error as DeviceToolError {
            return .failure(error)
        } catch {
            return .failure(DeviceToolError(error.localizedDescription))
        }
    }

    private func runHealthTool(_ group: DeviceToolGroup, _ tool: String, _ args: DeviceToolArgs) async throws -> JSONValue {
        #if os(iOS)
        return group == .health ? try await health.perform(tool, args) : try await workouts.perform(tool, args)
        #else
        throw DeviceToolError("Santé et les séances n'existent que sur l'iPhone.")
        #endif
    }

    /// File access stays off the main thread: a search may walk thousands of files.
    private func runFolderTool(_ tool: String, _ args: DeviceToolArgs) async throws -> JSONValue {
        #if os(macOS)
        let tools = LocalFolderTools(roots: FolderAccess.shared.roots)
        return try await Task.detached { try tools.run(tool, args) }.value
        #else
        throw DeviceToolError("Les dossiers partagés n'existent que sur Mac.")
        #endif
    }
}
