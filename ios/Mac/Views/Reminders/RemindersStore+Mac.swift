import Foundation

/// Mac-only views over the shared store: grouping of the smart lists, filing and drag helpers.
extension RemindersStore {
    /// Inbox, area or project (with its heading) the reminder is filed in.
    func macDestination(of reminder: Reminder) -> ReminderDestination {
        if let projectId = reminder.projectId { return .project(projectId, heading: reminder.headingId) }
        if let areaId = reminder.areaId { return .area(areaId) }
        return .inbox
    }

    /// « 🏠 Maison », « 📊 Clôture du trimestre », shown under a reminder outside its own list.
    func macCaption(of reminder: Reminder) -> String? {
        if let id = reminder.projectId {
            let project = project(id: id)
            let title = project?.title ?? reminder.project?.title
            return title.map { Self.macLabel($0, emoji: project?.emoji ?? reminder.project?.emoji) }
        }
        if let id = reminder.areaId {
            let area = area(id: id)
            let title = area?.title ?? reminder.area?.title
            return title.map { Self.macLabel($0, emoji: area?.emoji ?? reminder.area?.emoji) }
        }
        return nil
    }

    static func macLabel(_ title: String, emoji: String?) -> String {
        guard let emoji, !emoji.isEmpty else { return title }
        return "\(emoji) \(title)"
    }

    /// Groups of one smart list as the Mac shows them.
    func macGroups(_ list: ReminderSmartList) -> [ReminderDayGroup] {
        switch list {
        case .today:
            let today = items(in: .today)
            let now = Date()
            let overdue = today.filter { ($0.effectiveDate ?? .distantFuture) < now }
            let late = Set(overdue.map(\.id))
            let rest = today.filter { !late.contains($0.id) }
            var groups: [ReminderDayGroup] = []
            if !overdue.isEmpty { groups.append(ReminderDayGroup(id: "overdue", title: String(localized: "Overdue"), subtitle: nil, reminders: overdue)) }
            if !rest.isEmpty { groups.append(ReminderDayGroup(id: "today", title: overdue.isEmpty ? "" : String(localized: "Today"), subtitle: nil, reminders: rest)) }
            return groups
        case .upcoming:
            return groups(.upcoming)
        case .logbook:
            return groups(.done)
        case .inbox:
            let items = items(in: .inbox)
            return items.isEmpty ? [] : [ReminderDayGroup(id: "inbox", title: "", subtitle: nil, reminders: items)]
        case .anytime, .someday:
            let bucket = list.bucket!
            return memoized("mac.\(bucket.rawValue)") { groupedByContainer(items(in: bucket)) }
        case let .area(id):
            let items = openReminders(inArea: id)
            return items.isEmpty ? [] : [ReminderDayGroup(id: "area", title: "", subtitle: nil, reminders: items)]
        case .project:
            return []
        }
    }

    /// Things' Anytime and Someday: loose reminders first, then one group per area and project, in sidebar order.
    private func groupedByContainer(_ items: [Reminder]) -> [ReminderDayGroup] {
        var groups: [ReminderDayGroup] = []
        let loose = items.filter(\.isUnfiled)
        if !loose.isEmpty { groups.append(ReminderDayGroup(id: "loose", title: "", subtitle: nil, reminders: loose)) }
        func add(_ id: String, _ title: String, _ reminders: [Reminder]) {
            if !reminders.isEmpty { groups.append(ReminderDayGroup(id: id, title: title, subtitle: nil, reminders: reminders)) }
        }
        for project in openProjects(in: nil) {
            add(project.id, Self.macLabel(project.title, emoji: project.emoji), items.filter { $0.projectId == project.id })
        }
        for area in sortedAreas {
            add(area.id, Self.macLabel(area.title, emoji: area.emoji), items.filter { $0.areaId == area.id && $0.projectId == nil })
            for project in openProjects(in: area.id) {
                add(project.id, Self.macLabel(project.title, emoji: project.emoji), items.filter { $0.projectId == project.id })
            }
        }
        let placed = Set(groups.flatMap { $0.reminders.map(\.id) })
        add("other", String(localized: "Others"), items.filter { !placed.contains($0.id) })
        return groups
    }

    /// Open reminders of a project directly under `heading` (`nil`: before the first heading).
    func macOpenReminders(inProject id: String, heading: String?) -> [Reminder] {
        let known = Set(headings(ofProject: id).map(\.id))
        return openReminders(inProject: id).filter { reminder in
            guard let headingId = reminder.headingId, known.contains(headingId) else { return heading == nil }
            return headingId == heading
        }
    }

    /// `List.onMove` inside one group: one position write between the new neighbours.
    func macMove(_ group: [Reminder], from source: IndexSet, to destination: Int) {
        guard let index = source.first, source.count == 1, group.indices.contains(index) else { return }
        let moved = group[index]
        var rest = group
        rest.remove(at: index)
        let insert = destination > index ? destination - 1 : destination
        guard insert != index else { return }
        let previous = insert > 0 ? rest[insert - 1] : nil
        let next = insert < rest.count ? rest[insert] : nil
        Task { await reorder(moved, after: previous, before: next) }
    }

    func macMove(_ ids: [String], to destination: ReminderDestination) {
        for reminder in ids.compactMap(reminder(id:)) where macDestination(of: reminder) != destination {
            Task { await move(reminder, to: destination) }
        }
    }

    /// Days left before a project's deadline (negative once passed).
    func macDaysLeft(_ project: ReminderProject) -> Int? {
        guard let deadline = project.deadlineDate else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: deadline)).day
    }

    func macProgress(_ project: ReminderProject) -> Double {
        let counts = progress(project)
        return counts.total == 0 ? 0 : Double(counts.done) / Double(counts.total)
    }
}

enum ProjectDeadlineText {
    /// « 28 oct. », « Demain », « Il y a 2 j ».
    static func short(_ date: Date, daysLeft: Int?) -> String {
        switch daysLeft {
        case 0?: String(localized: "Today")
        case 1?: String(localized: "Tomorrow")
        case let days? where days < 0: String(localized: "\(-days) d ago")
        default: date.formatted(Date.FormatStyle(locale: .current).day().month(.abbreviated))
        }
    }

    static func iso(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }
}
