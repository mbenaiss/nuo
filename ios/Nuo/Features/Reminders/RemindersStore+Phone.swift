#if os(iOS)
import SwiftUI

/// Screens of the Rappels tab, pushed over the Things-like home.
enum ReminderRoute: Hashable {
    case list(ReminderBucket)
    case project(String)
    case area(String)
}

/// A titled run of rows in an iPhone list: a day, a project or an area.
struct PhoneReminderGroup: Identifiable {
    let id: String
    var title = ""
    var subtitle: String?
    var emoji: String?
    /// Tapping the header opens it.
    var route: ReminderRoute?
    let reminders: [Reminder]
}

/// The open reminders of a project under one heading (`nil`: before the first heading).
struct PhoneHeadingSection: Identifiable {
    let heading: ProjectHeading?
    let reminders: [Reminder]
    var id: String { heading?.id ?? "none" }
}

extension RemindersStore {
    func phoneGroups(_ bucket: ReminderBucket) -> [PhoneReminderGroup] {
        let items = items(in: bucket)
        guard !items.isEmpty else { return [] }
        switch bucket {
        case .inbox, .today:
            return [PhoneReminderGroup(id: bucket.rawValue, reminders: items)]
        case .upcoming:
            let calendar = Calendar.current
            let byDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.effectiveDate ?? Date()) }
            return byDay.keys.sorted().map { day in
                PhoneReminderGroup(id: day.ISO8601Format(), title: Self.dayTitle(day), subtitle: Self.daySubtitle(day), reminders: byDay[day]!)
            }
        case .anytime, .someday:
            return memoized("phone.\(bucket.rawValue)") { phoneGroupsByContainer(items) }
        case .logbook:
            return groups(.done).map { PhoneReminderGroup(id: $0.id, title: $0.title, reminders: $0.reminders) }
        }
    }

    /// Like Things' Anytime: loose reminders first, then each area followed by its projects, then projects without an area.
    private func phoneGroupsByContainer(_ items: [Reminder]) -> [PhoneReminderGroup] {
        var groups: [PhoneReminderGroup] = []
        let loose = items.filter(\.isUnfiled)
        if !loose.isEmpty { groups.append(PhoneReminderGroup(id: "loose", reminders: loose)) }
        func appendProjects(_ projects: [ReminderProject]) {
            for project in projects {
                let rows = items.filter { $0.projectId == project.id }
                if !rows.isEmpty {
                    groups.append(PhoneReminderGroup(id: project.id, title: project.title, emoji: project.emoji, route: .project(project.id), reminders: rows))
                }
            }
        }
        for area in sortedAreas {
            let rows = items.filter { $0.areaId == area.id && $0.projectId == nil }
            if !rows.isEmpty {
                groups.append(PhoneReminderGroup(id: area.id, title: area.title, emoji: area.emoji, route: .area(area.id), reminders: rows))
            }
            appendProjects(projects.filter { $0.areaId == area.id }.sorted { $0.position < $1.position })
        }
        appendProjects(projects.filter { $0.areaId == nil || area(id: $0.areaId!) == nil }.sorted { $0.position < $1.position })
        let shown = Set(groups.flatMap { $0.reminders.map(\.id) })
        let orphans = items.filter { !shown.contains($0.id) }
        if !orphans.isEmpty { groups.append(PhoneReminderGroup(id: "orphans", title: String(localized: "Other"), reminders: orphans)) }
        return groups
    }

    func phoneSections(ofProject id: String) -> [PhoneHeadingSection] {
        let open = openReminders(inProject: id)
        let headings = headings(ofProject: id)
        let known = Set(headings.map(\.id))
        var sections = [PhoneHeadingSection(heading: nil, reminders: open.filter { $0.headingId.map { !known.contains($0) } ?? true })]
        for heading in headings {
            sections.append(PhoneHeadingSection(heading: heading, reminders: open.filter { $0.headingId == heading.id }))
        }
        return sections
    }

    /// Applies a List `onMove` in `items` with one write: the moved reminder lands between its new neighbours.
    func phoneMove(_ items: [Reminder], from: IndexSet, to: Int) {
        guard let source = from.first, source < items.count else { return }
        let moved = items[source]
        var reordered = items
        reordered.move(fromOffsets: from, toOffset: to)
        guard let index = reordered.firstIndex(where: { $0.id == moved.id }) else { return }
        Haptics.selection()
        Task {
            await reorder(moved, after: index > 0 ? reordered[index - 1] : nil,
                          before: index + 1 < reordered.count ? reordered[index + 1] : nil)
        }
    }

    func phoneOpenCount(inProject id: String) -> Int {
        reminders.filter { $0.projectId == id && !$0.isDone }.count
    }
}

extension ReminderBucket {
    /// How rows of this list label their date: time only under a day, the full date elsewhere.
    var rowSegment: ReminderSegment {
        switch self {
        case .today: .today
        case .upcoming: .upcoming
        case .logbook: .done
        case .inbox, .anytime, .someday: .overdue
        }
    }

    var tint: Color {
        switch self {
        case .inbox: Color(hex: 0x3B82F6)
        case .today: Color(hex: 0xF5B400)
        case .upcoming: Color.bad
        case .anytime: Color(hex: 0x14B8A6)
        case .someday: Color(hex: 0xB59A6A)
        case .logbook: Color.good
        }
    }

    var filledSymbol: String {
        switch self {
        case .inbox: "tray.fill"
        case .today: "star.fill"
        case .upcoming: "calendar"
        case .anytime: "square.stack.3d.up.fill"
        case .someday: "archivebox.fill"
        case .logbook: "checkmark.circle.fill"
        }
    }
}
#endif
