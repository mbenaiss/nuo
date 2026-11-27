import Foundation

/// Demo areas and projects, and where the seeded reminders are filed (Things-like).
enum DemoProjectsSeed {
    static var areas: [ReminderArea] {
        [
            ReminderArea(id: "area-lumen", title: "Lumen Studio", emoji: "💼", position: 1),
            ReminderArea(id: "area-maison", title: String(localized: "demo.reminders.list.home", defaultValue: "Home"), emoji: "🏠", position: 2),
            ReminderArea(id: "area-sante", title: String(localized: "demo.reminders.list.health", defaultValue: "Health"), emoji: "🏃", position: 3),
            ReminderArea(id: "area-perso", title: String(localized: "demo.reminders.list.personal", defaultValue: "Personal"), emoji: "✨", position: 4),
        ]
    }

    static var projects: [ReminderProject] {
        let deadline = Calendar.current.date(byAdding: .day, value: 12, to: Date())!
        let day = deadline.formatted(.iso8601.year().month().day())
        return [
            project("prj-trimestre", String(localized: "Quarter close"), "📊", area: "area-lumen", deadline: day, notes: String(localized: "Revenue, VAT and follow-ups before filing."), position: 1),
            project("prj-nordline", String(localized: "Nordline engagement"), "📱", area: "area-lumen", position: 2),
            project("prj-japon", String(localized: "Trip to Japan"), "🇯🇵", area: "area-perso", notes: String(localized: "April 2027, two weeks."), position: 3),
            project("prj-half-marathon", String(localized: "Half marathon"), "🏃", area: "area-sante", position: 4),
            project("prj-home-server", String(localized: "Rebuild the homelab"), "🖥️", area: nil, someday: true, position: 5),
        ]
    }

    static var headings: [ProjectHeading] {
        [
            ProjectHeading(id: "hd-japon-avant", projectId: "prj-japon", title: String(localized: "Before leaving"), position: 1),
            ProjectHeading(id: "hd-japon-sur-place", projectId: "prj-japon", title: String(localized: "Once there"), position: 2),
        ]
    }

    private static func project(_ id: String, _ title: String, _ emoji: String, area: String?, deadline: String? = nil, notes: String? = nil,
                                someday: Bool = false, position: Double) -> ReminderProject {
        ReminderProject(id: id, title: title, notes: notes, emoji: emoji, areaId: area, deadline: deadline, someday: someday, status: .open,
                        position: position, openCount: 0, doneCount: 0, progress: 0)
    }

    private static let filing: [String: (project: String?, heading: String?, area: String?)] = [
        "rem-01": ("prj-trimestre", nil, nil),
        "rem-03": ("prj-trimestre", nil, nil),
        "rem-11": ("prj-trimestre", nil, nil),
        "rem-17": ("prj-trimestre", nil, nil),
        "rem-07": ("prj-nordline", nil, nil),
        "rem-20": ("prj-nordline", nil, nil),
        "rem-10": ("prj-japon", "hd-japon-avant", nil),
        "rem-15": ("prj-home-server", nil, nil),
        "rem-02": (nil, nil, "area-maison"),
        "rem-05": (nil, nil, "area-maison"),
        "rem-06": (nil, nil, "area-maison"),
        "rem-19": (nil, nil, "area-maison"),
        "rem-04": (nil, nil, "area-sante"),
        "rem-08": (nil, nil, "area-sante"),
        "rem-09": (nil, nil, "area-perso"),
        "rem-12": (nil, nil, "area-perso"),
        "rem-18": (nil, nil, "area-perso"),
    ]

    /// Files the seeded reminders and embeds their project and area like the gateway; the book to read goes to « Un jour ».
    static func file(_ reminders: [Reminder]) -> [Reminder] {
        let projects = Self.projects
        let areas = Self.areas
        return reminders.enumerated().map { index, reminder in
            var reminder = reminder
            reminder.position = Double(index + 1)
            if reminder.id == "rem-14" { reminder.someday = true }
            if reminder.id == "rem-10" { reminder.checklist = [ChecklistItem(title: String(localized: "Valid passport"), done: true), ChecklistItem(title: String(localized: "ID photo"), done: false)] }
            guard let place = filing[reminder.id] else { return reminder }
            reminder.projectId = place.project
            reminder.headingId = place.heading
            let project = projects.first { $0.id == place.project }
            reminder.project = project.map { ReminderRef(id: $0.id, title: $0.title, emoji: $0.emoji) }
            let areaId = place.area ?? project?.areaId
            reminder.areaId = areaId
            reminder.area = areas.first { $0.id == areaId }.map { ReminderRef(id: $0.id, title: $0.title, emoji: $0.emoji) }
            return reminder
        }
    }
}
