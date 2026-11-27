import CoreLocation
import Foundation
import Observation
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Saved places (« Maison », « Bureau »…), shared by the quick-add parser, the place picker and the Lieux screen.
@MainActor
@Observable
final class PlacesStore {
    static let shared = PlacesStore()

    private(set) var places: [Place] = []
    private(set) var loaded = false
    private(set) var error: String?
    @ObservationIgnored private var api: (any NuoAPI)?

    func attach(_ api: any NuoAPI) { self.api = api }

    func load() async {
        guard let api else { return }
        if !loaded, let cached = await WorkspaceCache.shared.value([Place].self, "places") {
            places = cached
            loaded = true
        }
        do {
            places = try await api.places().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loaded = true
            error = nil
            WorkspaceCache.shared.store(places, "places")
            EventNotifications.scheduleRefresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func create(_ draft: PlaceDraft) async -> Place? {
        guard let api else { return nil }
        do {
            let place = try await api.createPlace(draft)
            places.append(place)
            WorkspaceCache.shared.store(places, "places")
            return place
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
            return nil
        }
    }

    @discardableResult
    func update(_ id: String, patch: [String: JSONValue]) async -> Place? {
        guard let api else { return nil }
        do {
            let place = try await api.updatePlace(id: id, patch: patch)
            if let index = places.firstIndex(where: { $0.id == id }) { places[index] = place }
            WorkspaceCache.shared.store(places, "places")
            // Reminders embed the place: reload them so the triggers use the new radius or name.
            await RemindersStore.shared.load()
            return place
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
            return nil
        }
    }

    func delete(_ place: Place) async {
        guard let api else { return }
        withAnimation(.snappy) { places.removeAll { $0.id == place.id } }
        WorkspaceCache.shared.store(places, "places")
        try? await api.deletePlace(id: place.id)
    }

    func place(id: String) -> Place? { places.first { $0.id == id } }
}

/// « When In Use » authorization, which iOS requires for location notification triggers. Asked the first time a place
/// is attached. The app never reads the position: no location updates, iOS matches the registered regions itself.
@MainActor
@Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    override private init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isDenied: Bool { status == .denied || status == .restricted }
    var isAuthorized: Bool {
        #if os(iOS)
        status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        status == .authorizedAlways
        #endif
    }

    /// Asks once; returns when the user answered (or immediately when already decided).
    func requestIfNeeded() async {
        guard status == .notDetermined, !ProcessInfo.processInfo.arguments.contains("-demoScreen") else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.status = status
            guard status != .notDetermined else { return }
            let waiting = self.waiters
            self.waiters = []
            waiting.forEach { $0.resume() }
            if self.isAuthorized { await LocationTriggers.sync(RemindersStore.shared.reminders) }
        }
    }

    static func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

/// Location triggers of open reminders: one `UNLocationNotificationTrigger` each, `reminder-loc-<id>`.
enum LocationTriggers {
    static let prefix = "reminder-loc-"
    /// iOS monitors about 20 regions per app.
    static let limit = 20

    static func identifier(_ reminderId: String) -> String { prefix + reminderId }

    static func label(_ trigger: String?) -> String { trigger == "leave" ? String(localized: "on leaving") : String(localized: "on arrival") }

    @MainActor
    static func sync(_ reminders: [Reminder]) async {
        // Region triggers do not exist on macOS: the iPhone, which goes to these places, fires them.
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }
        let access = LocationAccess.shared
        let settings = await center.notificationSettings()
        guard access.isAuthorized, settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
            return
        }
        // Ranked by priority then due date, never by where the user is.
        let candidates = reminders.filter { !$0.isDone && $0.place != nil }.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let a = lhs.effectiveDate ?? .distantFuture, b = rhs.effectiveDate ?? .distantFuture
            if a != b { return a < b }
            return lhs.createdAt < rhs.createdAt
        }
        let wanted = Array(candidates.prefix(limit))
        let wantedById = Dictionary(uniqueKeysWithValues: wanted.map { (identifier($0.id), $0) })
        var current: Set<String> = []
        var stale: [String] = []
        for request in pending {
            if let reminder = wantedById[request.identifier], matches(request, reminder) {
                current.insert(request.identifier)
            } else {
                stale.append(request.identifier)
            }
        }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for reminder in wanted where !current.contains(identifier(reminder.id)) {
            guard let place = reminder.place else { continue }
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon),
                                          radius: min(max(place.radiusM, 100), 1000), identifier: identifier(reminder.id))
            region.notifyOnEntry = !reminder.leavesPlace
            region.notifyOnExit = reminder.leavesPlace
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = "📍 \(place.name) · \(label(reminder.placeTrigger))"
            content.sound = .default
            content.categoryIdentifier = ReminderNotifications.category
            content.threadIdentifier = ReminderNotifications.category
            content.userInfo = ["reminderId": reminder.id]
            let trigger = UNLocationNotificationTrigger(region: region, repeats: reminder.repeat != nil)
            try? await center.add(UNNotificationRequest(identifier: identifier(reminder.id), content: content, trigger: trigger))
        }
        #endif
    }

    #if os(iOS)
    private static func matches(_ request: UNNotificationRequest, _ reminder: Reminder) -> Bool {
        guard let trigger = request.trigger as? UNLocationNotificationTrigger, let region = trigger.region as? CLCircularRegion,
              let place = reminder.place else { return false }
        return abs(region.center.latitude - place.lat) < 0.00001 && abs(region.center.longitude - place.lon) < 0.00001
            && abs(region.radius - min(max(place.radiusM, 100), 1000)) < 1
            && region.notifyOnExit == reminder.leavesPlace && trigger.repeats == (reminder.repeat != nil)
            && request.content.title == reminder.title
    }
    #endif

    static func cancel(_ reminderId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(reminderId)])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(reminderId)])
    }
}

/// « 📍 Maison · en arrivant ».
struct PlaceChip: View {
    let name: String
    let trigger: String?
    var compact = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: trigger == "leave" ? "figure.walk.departure" : "mappin.and.ellipse")
                .font((compact ? Font.caption2 : .caption).weight(.semibold))
            Text("\(name) · \(LocationTriggers.label(trigger))").lineLimit(1)
        }
        .font(compact ? .caption : .subheadline)
        .foregroundStyle(Color(hex: 0x0E7C66))
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, compact ? 2 : 5)
        .background(Color(hex: 0x14B8A6).opacity(0.13), in: Capsule())
    }
}

/// Shown when location reminders exist but iOS cannot fire them.
struct LocationDeniedBanner: View {
    var body: some View {
        Button(action: LocationAccess.openSettings) {
            HStack(spacing: 10) {
                Image(systemName: "location.slash.fill").foregroundStyle(Color(hex: 0xE58A00))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Place reminders inactive").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text("Allow location access “While Using the App” in Settings so they can fire.")
                        .font(.caption).foregroundStyle(Color.text2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Text("Settings").font(.caption.weight(.semibold)).foregroundStyle(Color.accentInk)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(hex: 0xF59E0B).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}
