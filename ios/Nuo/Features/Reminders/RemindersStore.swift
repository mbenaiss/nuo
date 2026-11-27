import Foundation
import Observation
import SwiftUI
import WidgetKit

enum ReminderSegment: String, CaseIterable, Identifiable {
    case today, upcoming, overdue, done
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: String(localized: "Today")
        case .upcoming: String(localized: "Upcoming")
        case .overdue: String(localized: "Overdue")
        case .done: String(localized: "Done")
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .upcoming: "calendar"
        case .overdue: "exclamationmark.circle"
        case .done: "checkmark.circle"
        }
    }
}

/// Things-like smart lists, computed locally from every reminder.
enum ReminderBucket: String, CaseIterable, Identifiable {
    case inbox, today, upcoming, anytime, someday, logbook
    var id: String { rawValue }

    var label: String {
        switch self {
        case .inbox: String(localized: "Inbox")
        case .today: String(localized: "Today")
        case .upcoming: String(localized: "Upcoming")
        case .anytime: String(localized: "Anytime")
        case .someday: String(localized: "Someday")
        case .logbook: String(localized: "Logbook")
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .today: "star.fill"
        case .upcoming: "calendar"
        case .anytime: "square.stack"
        case .someday: "archivebox"
        case .logbook: "book.closed"
        }
    }
}

/// Where a reminder is filed: the inbox, an area directly, or a project (optionally under a heading).
enum ReminderDestination: Hashable {
    case inbox
    case area(String)
    case project(String, heading: String?)
}

struct ReminderDayGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let reminders: [Reminder]
}

/// Every reminder, loaded once and split locally so switching segments is instant.
@MainActor
@Observable
final class RemindersStore {
    static let shared = RemindersStore()

    private(set) var reminders: [Reminder] = [] {
        didSet { invalidateCounts() }
    }
    private(set) var loaded = false
    private(set) var isLoading = false
    private(set) var error: String?
    /// Checked rows stay visible a moment, like Things, before leaving their segment.
    private(set) var completing: Set<String> = [] {
        didSet { invalidateCounts() }
    }
    private(set) var areas: [ReminderArea] = [] {
        didSet { memo = [:] }
    }
    /// Every project, open or finished; progress comes from `progress(_:)`, which follows local changes.
    private(set) var projects: [ReminderProject] = [] {
        didSet {
            projectIndex = nil
            memo = [:]
        }
    }
    private(set) var headings: [String: [ProjectHeading]] = [:]
    @ObservationIgnored private var api: (any NuoAPI)?
    // Derived from the properties above and rebuilt after they change: every list screen, the sidebar and the tab
    // badge read them several times per render, over the whole history (done reminders included).
    @ObservationIgnored private var openCache: [Reminder]?
    @ObservationIgnored private var progressCache: [String: (done: Int, total: Int)]?
    @ObservationIgnored private var projectIndex: [String: ReminderProject]?
    @ObservationIgnored private var memo: [String: Any] = [:]
    @ObservationIgnored private var triggerSync = TriggerSync()

    private struct TriggerSync {
        var running = false
        /// Asked for while running: `true` when that request was forced.
        var queued: Bool?
        var signature: Int?
        var at = Date.distantPast
    }
    @ObservationIgnored private var now = Date()

    private static let cacheKey = "reminders"
    private static let areasKey = "reminder-areas"
    private static let projectsKey = "reminder-projects"

    func attach(_ api: any NuoAPI) {
        self.api = api
    }

    func load() async {
        guard let api else { return }
        if !loaded, let cached = await WorkspaceCache.shared.value([Reminder].self, Self.cacheKey) {
            reminders = cached
            areas = await WorkspaceCache.shared.value([ReminderArea].self, Self.areasKey) ?? []
            projects = await WorkspaceCache.shared.value([ReminderProject].self, Self.projectsKey) ?? []
            loaded = true
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let all = api.reminders(scope: .all, list: nil)
            async let done = api.reminders(scope: .done, list: nil)
            async let fetchedAreas = api.reminderAreas()
            async let fetchedProjects = api.reminderProjects(status: "all")
            if let fetchedAreas = try? await fetchedAreas, let fetchedProjects = try? await fetchedProjects {
                withAnimation(.snappy) {
                    areas = fetchedAreas
                    projects = fetchedProjects
                }
                WorkspaceCache.shared.store(fetchedAreas, Self.areasKey)
                WorkspaceCache.shared.store(fetchedProjects, Self.projectsKey)
            }
            var merged = Dictionary(uniqueKeysWithValues: try await all.map { ($0.id, $0) })
            for reminder in (try? await done) ?? [] { merged[reminder.id] = reminder }
            now = Date()
            withAnimation(.snappy) { reminders = Array(merged.values) }
            loaded = true
            error = nil
            persist()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func persist() {
        WorkspaceCache.shared.store(reminders, Self.cacheKey)
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentity.scoped("reminders"))
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentity.scoped("reminders.lock"))
        syncTriggers(force: false)
    }

    /// One sync at a time, and none when no dated or placed reminder changed since a recent one: each sync is
    /// several round trips to the notification center, and saves come in bursts (a check, a reload, a project).
    private func syncTriggers(force: Bool) {
        guard !triggerSync.running else {
            triggerSync.queued = force || (triggerSync.queued ?? false)
            return
        }
        var hasher = Hasher()
        for reminder in reminders where !reminder.isDone && (reminder.effectiveDate != nil || reminder.place != nil) {
            hasher.combine(reminder)
        }
        let signature = hasher.finalize()
        if !force, triggerSync.signature == signature, Date().timeIntervalSince(triggerSync.at) < 300 { return }
        triggerSync.running = true
        let snapshot = reminders
        Task {
            await ReminderNotifications.sync(snapshot)
            let queued = triggerSync.queued
            triggerSync = TriggerSync(signature: signature, at: Date())
            if let queued { syncTriggers(force: queued) }
        }
    }

    // MARK: Segments

    var lists: [String] {
        Array(Set(reminders.map(\.list))).sorted()
    }

    private var endOfToday: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
    }

    func items(_ segment: ReminderSegment) -> [Reminder] {
        let now = Date()
        let end = endOfToday
        switch segment {
        case .overdue, .today, .upcoming:
            return open.filter { Self.isIn(segment, $0, now: now, endOfToday: end) }.sorted(by: Self.byDate)
        case .done:
            return reminders.filter { $0.isDone && !completing.contains($0.id) }.sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
        }
    }

    /// Counts skip the sort of `items(_:)`, which dominated the badge and the home screen with long lists.
    func count(_ segment: ReminderSegment) -> Int {
        let now = Date()
        let end = endOfToday
        switch segment {
        case .overdue, .today, .upcoming:
            return open.count { Self.isIn(segment, $0, now: now, endOfToday: end) }
        case .done:
            return reminders.count { $0.isDone && !completing.contains($0.id) }
        }
    }

    private static func isIn(_ segment: ReminderSegment, _ reminder: Reminder, now: Date, endOfToday end: Date) -> Bool {
        switch segment {
        case .overdue: (reminder.effectiveDate ?? .distantFuture) < now
        case .today: reminder.effectiveDate.map { $0 >= now && $0 < end } ?? false
        case .upcoming: (reminder.effectiveDate ?? .distantFuture) >= end
        case .done: reminder.isDone
        }
    }

    var hasLocationReminders: Bool { reminders.contains { !$0.isDone && $0.place != nil } }

    /// Re-registers time and place triggers (app back in the foreground).
    func refreshTriggers() {
        syncTriggers(force: true)
    }

    /// Overdue + due today: the tab badge.
    var badgeCount: Int { count(.overdue) + count(.today) }

    private static func byDate(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        let a = lhs.effectiveDate ?? .distantFuture
        let b = rhs.effectiveDate ?? .distantFuture
        if a != b { return a < b }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.createdAt < rhs.createdAt
    }

    func groups(_ segment: ReminderSegment) -> [ReminderDayGroup] {
        let items = items(segment)
        let calendar = Calendar.current
        switch segment {
        case .today, .overdue:
            return items.isEmpty ? [] : [ReminderDayGroup(id: segment.rawValue, title: "", subtitle: nil, reminders: items)]
        case .upcoming:
            var groups: [ReminderDayGroup] = []
            let placeOnly = items.filter { $0.effectiveDate == nil && $0.place != nil }
            let dated = Dictionary(grouping: items.filter { $0.effectiveDate != nil }) { calendar.startOfDay(for: $0.effectiveDate!) }
            for day in dated.keys.sorted() {
                groups.append(ReminderDayGroup(id: day.ISO8601Format(), title: Self.dayTitle(day), subtitle: Self.daySubtitle(day), reminders: dated[day]!))
            }
            if !placeOnly.isEmpty {
                groups.insert(ReminderDayGroup(id: "place", title: String(localized: "By place"), subtitle: nil, reminders: placeOnly), at: 0)
            }
            let undated = items.filter { $0.effectiveDate == nil && $0.place == nil }
            if !undated.isEmpty { groups.append(ReminderDayGroup(id: "none", title: String(localized: "No date"), subtitle: nil, reminders: undated)) }
            return groups
        case .done:
            let byDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.doneAt ?? Date()) }
            return byDay.keys.sorted(by: >).map { day in
                ReminderDayGroup(id: day.ISO8601Format(), title: Self.dayTitle(day), subtitle: nil, reminders: byDay[day]!)
            }
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: day).day ?? 0
        if (2...6).contains(days) { return day.formatted(.dateTime.weekday(.wide).locale(ValueFormat.locale)).capitalized }
        return day.formatted(Date.FormatStyle(locale: ValueFormat.locale).weekday(.abbreviated).day().month(.wide)).capitalized
    }

    static func daySubtitle(_ day: Date) -> String? {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: day).day ?? 0
        guard (1...6).contains(days) else { return nil }
        return day.formatted(Date.FormatStyle(locale: ValueFormat.locale).day().month(.wide))
    }

    // MARK: Actions

    func apply(_ reminder: Reminder) {
        upsert(reminder)
        persist()
    }

    private func upsert(_ reminder: Reminder) {
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index] = reminder
        } else {
            reminders.append(reminder)
        }
    }

    func toggleDone(_ reminder: Reminder) {
        guard let api else { return }
        let done = !reminder.isDone
        if done {
            Haptics.success()
            ReminderNotifications.cancel(reminder.id)
            completing.insert(reminder.id)
            mutateLocally(reminder.id) { $0.doneAt = Date() }
        } else {
            Haptics.tap()
            mutateLocally(reminder.id) { $0.doneAt = nil }
        }
        Task {
            let result = try? await api.setReminderDone(id: reminder.id, done: done)
            if done { try? await Task.sleep(for: .milliseconds(700)) }
            withAnimation(.snappy(duration: 0.35)) {
                completing.remove(reminder.id)
                if let result { apply(result) }
            }
            if result == nil { await load() }
        }
    }

    func snooze(_ reminder: Reminder, until: Date) {
        guard let api else { return }
        Haptics.selection()
        withAnimation(.snappy) { mutateLocally(reminder.id) { $0.snoozedUntil = until } }
        Task {
            if let result = try? await api.snoozeReminder(id: reminder.id, until: until) {
                withAnimation(.snappy) { apply(result) }
            } else {
                await load()
            }
        }
    }

    @discardableResult
    func create(_ draft: ReminderDraft) async -> Reminder? {
        guard let api else { return nil }
        do {
            let reminder = try await api.createReminder(draft)
            Haptics.success()
            withAnimation(.snappy) { apply(reminder) }
            return reminder
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            return nil
        }
    }

    func update(_ id: String, patch: [String: JSONValue]) async -> Bool {
        guard let api, !patch.isEmpty else { return true }
        do {
            let reminder = try await api.updateReminder(id: id, patch: patch)
            withAnimation(.snappy) { apply(reminder) }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(_ reminder: Reminder) {
        guard let api else { return }
        ReminderNotifications.cancel(reminder.id)
        withAnimation(.snappy) { reminders.removeAll { $0.id == reminder.id } }
        persist()
        Task {
            do {
                try await api.deleteReminder(id: reminder.id)
            } catch {
                Haptics.error()
                self.error = error.localizedDescription
                withAnimation(.snappy) { apply(reminder) }
                refreshTriggers()
            }
        }
    }

    func clearError() {
        error = nil
    }

    private func mutateLocally(_ id: String, _ change: (inout Reminder) -> Void) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        change(&reminders[index])
    }

    func reminder(id: String) -> Reminder? { reminders.first { $0.id == id } }

    // MARK: Smart lists, areas and projects

    private func invalidateCounts() {
        openCache = nil
        progressCache = nil
        memo = [:]
    }

    /// Lists that depend only on the stored data (no clock), kept until reminders, projects or areas change.
    func memoized<Value>(_ key: String, _ compute: () -> Value) -> Value {
        // Read the sources so the calling view keeps observing them.
        _ = (reminders, completing, projects, areas)
        if let value = memo[key] as? Value { return value }
        let value = compute()
        memo[key] = value
        return value
    }

    private var open: [Reminder] {
        // Read before the cache so the calling view keeps observing them.
        let reminders = self.reminders, completing = self.completing
        if let openCache { return openCache }
        let open = reminders.filter { !$0.isDone || completing.contains($0.id) }
        openCache = open
        return open
    }

    private func inSomeday(_ reminder: Reminder) -> Bool {
        reminder.isSomeday || (reminder.projectId.flatMap(project(id:))?.someday ?? false)
    }

    private static func byPosition(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        let a = lhs.position ?? 0, b = rhs.position ?? 0
        return a != b ? a < b : lhs.createdAt < rhs.createdAt
    }

    /// Today = due before midnight (overdue first); the others like in Things.
    func items(in list: ReminderBucket) -> [Reminder] {
        let end = endOfToday
        switch list {
        case .inbox, .anytime, .someday:
            return memoized("items.\(list.rawValue)") { open.filter { isIn(list, $0, endOfToday: end) }.sorted(by: Self.byPosition) }
        case .today, .upcoming:
            return open.filter { isIn(list, $0, endOfToday: end) }.sorted(by: Self.byDate)
        case .logbook:
            return items(ReminderSegment.done)
        }
    }

    func count(in list: ReminderBucket) -> Int {
        guard list != .logbook else { return 0 }
        let end = endOfToday
        return open.count { isIn(list, $0, endOfToday: end) }
    }

    private func isIn(_ list: ReminderBucket, _ reminder: Reminder, endOfToday end: Date) -> Bool {
        switch list {
        case .inbox: reminder.isUnfiled && !reminder.isSomeday && reminder.dueAt == nil && reminder.place == nil
        case .today: (reminder.effectiveDate ?? .distantFuture) < end
        case .upcoming: (reminder.effectiveDate ?? .distantPast) >= end
        case .anytime: !inSomeday(reminder)
        case .someday: inSomeday(reminder)
        case .logbook: false
        }
    }

    func project(id: String) -> ReminderProject? {
        let projects = self.projects
        if projectIndex == nil { projectIndex = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        return projectIndex?[id]
    }
    func area(id: String) -> ReminderArea? { areas.first { $0.id == id } }

    var sortedAreas: [ReminderArea] { areas.sorted { ($0.position, $0.title) < ($1.position, $1.title) } }

    /// Open projects of an area (`nil`: those without one), someday ones last.
    func openProjects(in areaId: String?) -> [ReminderProject] {
        projects.filter { $0.isOpen && $0.areaId == areaId }.sorted { ($0.someday ? 1 : 0, $0.position) < ($1.someday ? 1 : 0, $1.position) }
    }

    var finishedProjects: [ReminderProject] {
        projects.filter { !$0.isOpen }.sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    /// Done / total reminders of the project, from local data so a check moves the ring at once.
    func progress(_ project: ReminderProject) -> (done: Int, total: Int) {
        let reminders = self.reminders, completing = self.completing
        if progressCache == nil {
            var counts: [String: (done: Int, total: Int)] = [:]
            for reminder in reminders {
                guard let projectId = reminder.projectId else { continue }
                counts[projectId, default: (0, 0)].total += 1
                if reminder.isDone && !completing.contains(reminder.id) { counts[projectId, default: (0, 0)].done += 1 }
            }
            progressCache = counts
        }
        return progressCache?[project.id] ?? (0, 0)
    }

    func openReminders(inProject id: String) -> [Reminder] { open.filter { $0.projectId == id }.sorted(by: Self.byPosition) }

    func doneReminders(inProject id: String) -> [Reminder] {
        reminders.filter { $0.projectId == id && $0.isDone && !completing.contains($0.id) }.sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    /// Reminders filed directly in the area (not in one of its projects).
    func openReminders(inArea id: String) -> [Reminder] { open.filter { $0.areaId == id && $0.projectId == nil }.sorted(by: Self.byPosition) }

    func headings(ofProject id: String) -> [ProjectHeading] { (headings[id] ?? []).sorted { $0.position < $1.position } }

    /// Fetches a project's headings and reminders (done ones included).
    func loadProject(_ id: String) async {
        guard let api, let detail = try? await api.project(id: id) else { return }
        withAnimation(.snappy) {
            headings[id] = detail.headings
            replaceProject(detail.project)
            for reminder in detail.reminders { upsert(reminder) }
        }
        // Once for the whole project: per reminder, each save re-encoded every reminder and reloaded the widgets.
        if !detail.reminders.isEmpty { persist() }
    }

    private func replaceProject(_ project: ReminderProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project } else { projects.append(project) }
        WorkspaceCache.shared.store(projects, Self.projectsKey)
    }

    private func replaceArea(_ area: ReminderArea) {
        if let index = areas.firstIndex(where: { $0.id == area.id }) { areas[index] = area } else { areas.append(area) }
        WorkspaceCache.shared.store(areas, Self.areasKey)
    }

    private func attempt<T>(_ body: (any NuoAPI) async throws -> T) async -> T? {
        guard let api else { return nil }
        do {
            return try await body(api)
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createArea(title: String, emoji: String? = nil) async -> ReminderArea? {
        guard let area = await attempt({ try await $0.createArea(title: title, emoji: emoji) }) else { return nil }
        withAnimation(.snappy) { replaceArea(area) }
        return area
    }

    func updateArea(_ id: String, patch: [String: JSONValue]) async {
        guard let area = await attempt({ try await $0.updateArea(id: id, patch: patch) }) else { return }
        withAnimation(.snappy) { replaceArea(area) }
    }

    func deleteArea(_ id: String) async {
        guard await attempt({ try await $0.deleteArea(id: id) }) != nil else { return }
        withAnimation(.snappy) { areas.removeAll { $0.id == id } }
        await load()
    }

    @discardableResult
    func createProject(_ draft: ProjectDraft) async -> ReminderProject? {
        guard let project = await attempt({ try await $0.createProject(draft) }) else { return nil }
        Haptics.success()
        withAnimation(.snappy) { replaceProject(project) }
        return project
    }

    func updateProject(_ id: String, patch: [String: JSONValue]) async {
        guard let project = await attempt({ try await $0.updateProject(id: id, patch: patch) }) else { return }
        withAnimation(.snappy) { replaceProject(project) }
        if patch["areaId"] != nil { await load() }
    }

    /// Completes (or cancels) the project; its open reminders are completed with it unless `keepOpen`.
    func finishProject(_ id: String, cancel: Bool = false, keepOpen: Bool = false) async {
        guard let project = await attempt({ try await $0.finishProject(id: id, cancel: cancel, keepOpenReminders: keepOpen) }) else { return }
        Haptics.success()
        withAnimation(.snappy) {
            replaceProject(project)
            if !keepOpen {
                for index in reminders.indices where reminders[index].projectId == id && !reminders[index].isDone { reminders[index].doneAt = Date() }
            }
        }
        persist()
    }

    func reopenProject(_ id: String) async {
        guard let project = await attempt({ try await $0.reopenProject(id: id) }) else { return }
        withAnimation(.snappy) { replaceProject(project) }
    }

    func deleteProject(_ id: String) async {
        guard await attempt({ try await $0.deleteProject(id: id) }) != nil else { return }
        withAnimation(.snappy) {
            projects.removeAll { $0.id == id }
            reminders.removeAll { $0.projectId == id }
            headings[id] = nil
        }
        WorkspaceCache.shared.store(projects, Self.projectsKey)
        persist()
    }

    @discardableResult
    func createHeading(in projectId: String, title: String) async -> ProjectHeading? {
        guard let heading = await attempt({ try await $0.createHeading(projectId: projectId, title: title) }) else { return nil }
        withAnimation(.snappy) { headings[projectId, default: []].append(heading) }
        return heading
    }

    func renameHeading(_ heading: ProjectHeading, to title: String) async {
        guard let updated = await attempt({ try await $0.updateHeading(id: heading.id, patch: ["title": .string(title)]) }) else { return }
        withAnimation(.snappy) {
            if let index = headings[heading.projectId]?.firstIndex(where: { $0.id == heading.id }) { headings[heading.projectId]![index] = updated }
        }
    }

    func deleteHeading(_ heading: ProjectHeading) async {
        guard await attempt({ try await $0.deleteHeading(id: heading.id) }) != nil else { return }
        withAnimation(.snappy) {
            headings[heading.projectId]?.removeAll { $0.id == heading.id }
            for index in reminders.indices where reminders[index].headingId == heading.id { reminders[index].headingId = nil }
        }
        persist()
    }

    /// Files a reminder in the inbox, an area or a project.
    func move(_ reminder: Reminder, to destination: ReminderDestination) async {
        Haptics.selection()
        _ = await update(reminder.id, patch: ReminderFiling.patch(destination))
    }

    func setSomeday(_ reminder: Reminder, _ someday: Bool) async {
        _ = await update(reminder.id, patch: ["someday": .bool(someday)])
    }

    func setChecklist(_ reminder: Reminder, _ items: [ChecklistItem]) async {
        mutateLocally(reminder.id) { $0.checklist = items.isEmpty ? nil : items }
        let value: JSONValue = .array(items.map { .object(["title": .string($0.title), "done": .bool($0.done)]) })
        _ = await update(reminder.id, patch: ["checklist": value])
    }

    /// Moves `reminder` between two neighbours (Things-like drag); positions are midpoints, so one write is enough.
    func reorder(_ reminder: Reminder, after previous: Reminder?, before next: Reminder?) async {
        let low = previous?.position ?? ((next?.position ?? 1) - 1)
        let high = next?.position ?? (low + 2)
        let position = (low + high) / 2
        withAnimation(.snappy) { mutateLocally(reminder.id) { $0.position = position } }
        _ = await update(reminder.id, patch: ["position": .number(position)])
    }
}
