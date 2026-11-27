import Foundation
import Observation
import UIKit
import UserNotifications

protocol NuoMuscuAPI: Sendable {
    func muscu() async throws -> MuscuCatalog
    func finishMuscu(_ body: MuscuFinishedBody) async throws -> MuscuLogged
}

extension NuoClient: NuoMuscuAPI {
    func muscu() async throws -> MuscuCatalog { try await request("GET", "/api/muscu") }

    func finishMuscu(_ body: MuscuFinishedBody) async throws -> MuscuLogged {
        try await request("POST", "/api/muscu/sessions", body: body)
    }
}

/// The Muscu screen: the Coach's sessions from the gateway, the run in progress (saved after every action), the rest
/// timer with its haptic, lock screen activity, watch countdown and notification, and the log sent at the end.
@MainActor
@Observable
final class MuscuStore {
    static let shared = MuscuStore()

    enum Upload: Equatable {
        case idle, sending, sent, failed(String)
    }

    private(set) var catalog: MuscuCatalog?
    private(set) var loadError: String?
    private(set) var loading = false
    /// The session shown before starting; the run's own once started.
    private(set) var selectedId: Int?
    private(set) var run: MuscuRun?
    private(set) var upload: Upload = .idle
    private(set) var loads = MuscuLoads()

    @ObservationIgnored private var api: (any NuoMuscuAPI)?
    @ObservationIgnored private var restAlarm: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let activity = MuscuActivity()
    @ObservationIgnored private var keepsAwake = false

    private enum Keys {
        static let run = "muscu.run"
        static let catalog = "muscu.catalog"
        static let loads = "muscu.loads"
        static let last = "muscu.lastSession"
        /// A finished session closed before the gateway took it: sent again at the next opening.
        static let pending = "muscu.pending"
    }

    private static let restNotification = "muscu.rest"

    private init() {
        // The gym's network is flaky: the last list received is good enough to train.
        if let data = defaults.data(forKey: Keys.catalog), let cached = try? JSONDecoder().decode(MuscuCatalog.self, from: data) {
            catalog = cached
        }
        let local = defaults.data(forKey: Keys.loads).flatMap { try? JSONDecoder().decode(MuscuLoads.self, from: $0) }
        loads = MuscuLoads(gateway: catalog?.loads ?? [:], local: local)
        restoreRun()
    }

    var sessions: [MuscuSession] { catalog?.sessions ?? [] }

    var session: MuscuSession? {
        let id = run?.sessionId ?? selectedId
        return sessions.first { $0.id == id } ?? MuscuPlan.pick(sessions, date: .now, lastId: defaults.object(forKey: Keys.last) as? Int)
    }

    func photo(for name: String) -> String? { catalog?.photos[name] }

    func attach(_ api: any NuoAPI) {
        self.api = api as? any NuoMuscuAPI
    }

    func load() async {
        guard let api else {
            loadError = String(localized: "This gateway doesn't have the Gym screen.")
            return
        }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await api.muscu()
            catalog = fresh
            loadError = nil
            if let data = try? JSONEncoder().encode(fresh) { defaults.set(data, forKey: Keys.catalog) }
            let local = defaults.data(forKey: Keys.loads).flatMap { try? JSONDecoder().decode(MuscuLoads.self, from: $0) }
            loads = MuscuLoads(gateway: fresh.loads, local: local)
            if run == nil { restoreRun() }
            if let run, run.isFinished, !run.uploaded { await send() }
            await sendPending()
        } catch {
            loadError = catalog == nil ? error.localizedDescription : nil
        }
    }

    func select(_ id: Int) {
        guard run == nil else { return }
        Haptics.selection()
        selectedId = id
    }

    // MARK: - Run

    func start() {
        guard let session, run == nil else { return }
        Haptics.send()
        defaults.set(session.id, forKey: Keys.last)
        run = MuscuRun(session: session, loads: loads, now: .now)
        upload = .idle
        changed()
    }

    func completeSet() {
        mutate { run, session in run.completeSet(in: session, loads: &loads, now: .now) }
        if let data = try? JSONEncoder().encode(loads) { defaults.set(data, forKey: Keys.loads) }
        if run?.isFinished == true { Haptics.success() } else { Haptics.send() }
    }

    func skipSet() { mutate { run, session in run.skipSet(in: session, now: .now) } }
    func switchBlock(to block: Int) { mutate { run, _ in run.switchBlock(to: block) } }
    func addRest(_ seconds: Int) { mutate { run, _ in run.addRest(seconds: seconds) } }
    func endRest() { mutate { run, _ in run.endRest() } }
    func setReps(_ reps: Int, key: String) { mutate(haptic: false) { run, _ in run.setReps(reps, key: key) } }
    func setKg(_ kg: Double?, key: String) { mutate(haptic: false) { run, _ in run.setKg(kg, key: key) } }

    func replace(block: Int, exercise: Int, with name: String) {
        let loads = self.loads
        mutate { run, session in run.replaceExercise(block: block, exercise: exercise, with: name, in: session, loads: loads) }
    }

    /// "Finish" before the last set: what was done is logged.
    func finishNow() {
        mutate { run, _ in run.finish(now: .now) }
        Haptics.success()
    }

    /// Leaves the session without logging it.
    func abandon() {
        run = nil
        upload = .idle
        changed()
    }

    /// Closes the recap of a finished session; one the gateway has not taken yet is kept to be sent later.
    func close() {
        guard let run, run.isFinished else { return }
        if !run.uploaded, !run.log.isEmpty, let data = try? JSONEncoder().encode(run.finishedBody()) {
            defaults.set(data, forKey: Keys.pending)
        }
        abandon()
    }

    private func sendPending() async {
        guard let api, let data = defaults.data(forKey: Keys.pending),
              let body = try? JSONDecoder().decode(MuscuFinishedBody.self, from: data) else { return }
        // The run id makes a second send of the same session harmless.
        if (try? await api.finishMuscu(body)) != nil { defaults.removeObject(forKey: Keys.pending) }
    }

    func send() async {
        guard let api, var run, run.isFinished, !run.uploaded, upload != .sending else { return }
        guard !run.log.isEmpty else {
            run.uploaded = true
            self.run = run
            changed()
            return
        }
        upload = .sending
        do {
            _ = try await api.finishMuscu(run.finishedBody())
            run.uploaded = true
            // The user may have closed the recap meanwhile.
            if self.run?.id == run.id { self.run = run }
            upload = .sent
            changed()
        } catch {
            upload = .failed(error.localizedDescription)
        }
    }

    // MARK: - App lifecycle

    /// The rest's notification only matters while the app is not on screen; in front, the in-app haptic says it.
    func scenePhaseChanged(active: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.restNotification])
        guard !active, let rest = run?.rest, let session else { return }
        let left = rest.until.timeIntervalSinceNow
        guard left > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Rest over")
        content.body = run.map { "\(session.name) · \($0.stepLabel(in: session))" } ?? session.name
        content.sound = .default
        content.userInfo = ["url": MuscuActivityAttributes.link.absoluteString]
        center.add(UNNotificationRequest(identifier: Self.restNotification, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: left, repeats: false)))
    }

    // MARK: - Internals

    private func mutate(haptic: Bool = true, _ change: (inout MuscuRun, MuscuSession) -> Void) {
        guard var run, let session = sessions.first(where: { $0.id == run.sessionId }) else { return }
        change(&run, session)
        self.run = run
        if haptic && !run.isFinished { Haptics.tap() }
        changed()
        if run.isFinished, !run.uploaded { Task { await send() } }
    }

    private func restoreRun() {
        run = MuscuRun.restore(defaults.data(forKey: Keys.run), sessions: sessions, now: .now)
        // Without the sessions yet (first launch, offline), the saved run waits for them.
        if run == nil, !sessions.isEmpty { defaults.removeObject(forKey: Keys.run) }
        changed(save: false)
    }

    /// Saves the run, then puts the rest everywhere it shows: alarm in the app, lock screen, watch, screen kept on.
    private func changed(save: Bool = true) {
        if save {
            if let run, let data = try? JSONEncoder().encode(run) { defaults.set(data, forKey: Keys.run) } else { defaults.removeObject(forKey: Keys.run) }
        }
        let running = run.map { !$0.isFinished } ?? false
        // Only on a change: voice mode keeps the screen on too.
        if running != keepsAwake {
            keepsAwake = running
            UIApplication.shared.isIdleTimerDisabled = running
        }
        armRestAlarm()
        guard let run, let session = sessions.first(where: { $0.id == run.sessionId }), running else {
            activity.end()
            WatchSync.shared.sendMuscuRest(nil)
            return
        }
        activity.update(session: session, run: run)
        WatchSync.shared.sendMuscuRest(run.rest.map {
            MuscuRestLink.Rest(until: $0.until, total: $0.total, title: $0.kind == .block ? String(localized: "Block change") : String(localized: "Rest"),
                               next: run.stepLabel(in: session))
        })
    }

    private func armRestAlarm() {
        restAlarm?.cancel()
        guard let until = run?.rest?.until else { return }
        restAlarm = Task { [weak self] in
            let left = until.timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            guard !Task.isCancelled, let self, self.run?.rest?.until == until else { return }
            Haptics.success()
            self.mutate(haptic: false) { run, _ in run.endRest() }
        }
    }
}
