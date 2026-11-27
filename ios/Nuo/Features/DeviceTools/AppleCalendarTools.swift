import CoreGraphics
import EventKit
import Foundation

/// The `apple_*` tools: the bots read and change this device's EventKit calendars (iCloud, local, Exchange, CalDAV).
@MainActor
final class AppleCalendarTools {
    private let store = EKEventStore()
    private static let maxRange: TimeInterval = 366 * 86400

    func run(_ tool: String, _ args: DeviceToolArgs) throws -> JSONValue {
        try prepare()
        let out: JSONValue
        switch tool {
        case "apple_calendars": out = calendars()
        case "apple_events": out = EventsReader(store: store).read(try eventsQuery(args))
        case "apple_event_create": out = try createEvent(args)
        case "apple_event_update": out = try updateEvent(args)
        case "apple_event_delete": out = try deleteEvent(args)
        case "apple_calendar_create": out = try createCalendar(args)
        case "apple_calendar_update": out = try updateCalendar(args)
        case "apple_calendar_delete": out = try deleteCalendar(args)
        default: throw DeviceToolError("Outil inconnu \(tool).")
        }
        if tool != "apple_calendars", tool != "apple_events" { Task { await CalendarBridge.shared.sync() } }
        return out
    }

    /// Like `run`, with the `apple_events` read off the main thread: a year of events can take seconds to fetch.
    func perform(_ tool: String, _ args: DeviceToolArgs) async throws -> JSONValue {
        guard tool == "apple_events" else { return try run(tool, args) }
        try prepare()
        let query = try eventsQuery(args)
        let reader = EventsReader(store: store)
        return await Task.detached(priority: .userInitiated) { reader.read(query) }.value
    }

    private func prepare() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw DeviceToolError("Nuo n'a pas l'accès complet aux calendriers sur \(PlatformDevice.name) : demande à l'utilisateur de l'autoriser dans Nuo, Réglages › Accès des bots.")
        }
        store.refreshSourcesIfNecessary()
    }

    // MARK: Calendars

    private func calendars() -> JSONValue {
        let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
        let list = store.calendars(for: .event).sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
        return .object(["calendars": .array(list.map { describe($0, isDefault: $0.calendarIdentifier == defaultId) })])
    }

    private func describe(_ c: EKCalendar, isDefault: Bool = false) -> JSONValue {
        .fields([
            "id": .string(c.calendarIdentifier),
            "title": .string(c.title),
            "account": .string(c.source.title),
            "accountType": .string(Self.accountType(c.source)),
            "color": .string(Self.hex(c.cgColor)),
            "writable": .bool(c.allowsContentModifications),
            "isDefault": isDefault ? .bool(true) : nil,
            "subscribed": c.type == .subscription ? .bool(true) : nil,
        ])
    }

    static func accountType(_ s: EKSource) -> String {
        switch s.sourceType {
        case .local: "local"
        case .exchange: "exchange"
        case .calDAV: s.title.localizedCaseInsensitiveContains("icloud") ? "icloud" : "caldav"
        case .mobileMe: "icloud"
        case .subscribed: "subscribed"
        case .birthdays: "birthdays"
        @unknown default: "other"
        }
    }

    private static func hex(_ color: CGColor?) -> String {
        guard let color, let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return "#888888" }
        return DeviceToolColor.hex(red: c[0], green: c[1], blue: c[2])
    }

    private static func cgColor(_ text: String) throws -> CGColor {
        guard let c = DeviceToolColor.parse(text) else { throw DeviceToolError("Couleur invalide « \(text) » : utilise un code comme #34C759.") }
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    /// By id, else by exact name; a name shared by several calendars must be told apart by id.
    private func calendar(_ ref: String, writable: Bool) throws -> EKCalendar {
        let all = store.calendars(for: .event)
        let matches = all.filter { $0.calendarIdentifier == ref }.nilIfEmpty ?? all.filter { $0.title.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard !matches.isEmpty else { throw DeviceToolError("Aucun calendrier « \(ref) » sur \(PlatformDevice.name) (voir apple_calendars).") }
        let usable = writable ? matches.filter(\.allowsContentModifications) : matches
        guard let first = usable.first else { throw DeviceToolError("Le calendrier « \(matches[0].title) » est en lecture seule.") }
        guard usable.count == 1 else {
            throw DeviceToolError("Plusieurs calendriers s'appellent « \(ref) » : précise l'id (\(usable.map { "\($0.calendarIdentifier) dans \($0.source.title)" }.joined(separator: ", "))).")
        }
        return first
    }

    private func createCalendar(_ args: DeviceToolArgs) throws -> JSONValue {
        guard let title = args.string("title") else { throw DeviceToolError("title requis.") }
        let account = args.string("account") ?? "icloud"
        let sources = store.sources
        let source: EKSource?
        switch account.lowercased() {
        case "icloud": source = sources.first { Self.accountType($0) == "icloud" && $0.sourceType == .calDAV }
        case "local": source = sources.first { $0.sourceType == .local }
        default: source = sources.first { $0.title.compare(account, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        guard let source else {
            throw DeviceToolError(account.lowercased() == "icloud"
                ? "Aucun compte iCloud avec Calendrier sur \(PlatformDevice.name) : l'utilisateur doit activer Calendrier dans Réglages › iCloud."
                : "Aucun compte « \(account) » sur \(PlatformDevice.name).")
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        if let color = args.string("color") { calendar.cgColor = try Self.cgColor(color) }
        do { try store.saveCalendar(calendar, commit: true) } catch { throw DeviceToolError("Création du calendrier refusée par \(source.title) : \(error.localizedDescription)") }
        return .object(["calendar": describe(calendar)])
    }

    private func updateCalendar(_ args: DeviceToolArgs) throws -> JSONValue {
        guard let id = args.string("id") else { throw DeviceToolError("id requis.") }
        let calendar = try calendar(id, writable: false)
        guard !calendar.isImmutable else { throw DeviceToolError("Le calendrier « \(calendar.title) » ne peut pas être modifié.") }
        if let title = args.string("title") { calendar.title = title }
        if let color = args.string("color") { calendar.cgColor = try Self.cgColor(color) }
        do { try store.saveCalendar(calendar, commit: true) } catch { throw DeviceToolError("Modification refusée : \(error.localizedDescription)") }
        return .object(["calendar": describe(calendar)])
    }

    private func deleteCalendar(_ args: DeviceToolArgs) throws -> JSONValue {
        guard let id = args.string("id") else { throw DeviceToolError("id requis.") }
        let calendar = try calendar(id, writable: false)
        guard !calendar.isImmutable, calendar.source.sourceType != .birthdays else { throw DeviceToolError("Le calendrier « \(calendar.title) » ne peut pas être supprimé.") }
        let title = calendar.title
        do { try store.removeCalendar(calendar, commit: true) } catch { throw DeviceToolError("Suppression refusée : \(error.localizedDescription)") }
        return .object(["deleted": .string(title)])
    }

    // MARK: Events

    /// Arguments of `apple_events`, checked on the main actor (calendar names) before the read runs elsewhere.
    private func eventsQuery(_ args: DeviceToolArgs) throws -> EventsQuery {
        let today = Calendar.current.startOfDay(for: Date())
        let start = try DeviceToolDate.require(args, "start")?.date ?? today
        var end = try DeviceToolDate.require(args, "end").map { $0.dayOnly ? Calendar.current.date(byAdding: .day, value: 1, to: $0.date)! : $0.date } ?? start.addingTimeInterval(7 * 86400)
        guard end > start else { throw DeviceToolError("end doit être après start.") }
        end = min(end, start.addingTimeInterval(Self.maxRange))
        let calendarIds = try args.strings("calendars")?.map { try calendar($0, writable: false).calendarIdentifier }
        return EventsQuery(start: start, end: end, calendarIds: calendarIds, text: args.string("query"), max: args.int("max", default: 200, range: 1...500))
    }

    private func describe(_ e: EKEvent) -> JSONValue { Self.eventJSON(e) }

    nonisolated static func eventJSON(_ e: EKEvent) -> JSONValue {
        let allDay = e.isAllDay
        let end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: e.endDate))! : e.endDate!
        let attendees = (e.attendees ?? []).map { p in
            JSONValue.fields(["name": .str(p.name), "email": .str(p.url.scheme == "mailto" ? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") : nil), "status": .string(Self.status(p.participantStatus))])
        }
        return .fields([
            "id": .string(e.eventIdentifier),
            "title": .string(e.title ?? ""),
            "start": .string(DeviceToolDate.format(e.startDate, dayOnly: allDay)),
            "end": .string(DeviceToolDate.format(end, dayOnly: allDay)),
            "allDay": allDay ? .bool(true) : nil,
            "calendar": .string(e.calendar.title),
            "calendarId": .string(e.calendar.calendarIdentifier),
            "account": .string(e.calendar.source.title),
            "location": .str(e.location?.nilIfBlank),
            "notes": .str(e.notes?.nilIfBlank.map { String($0.prefix(1500)) }),
            "url": .str(e.url?.absoluteString),
            "recurrence": e.recurrenceRules?.first.map(Self.describe),
            "occurrenceStart": e.hasRecurrenceRules ? .string(DeviceToolDate.format(e.occurrenceDate ?? e.startDate)) : nil,
            "alarms": (e.alarms?.isEmpty == false) ? .array(e.alarms!.map { .number((-$0.relativeOffset / 60).rounded()) }) : nil,
            "availability": e.availability == .free ? .string("free") : e.availability == .tentative ? .string("tentative") : nil,
            "organizer": .str(e.organizer?.name),
            "attendees": attendees.isEmpty ? nil : .array(attendees),
            "canEdit": e.calendar.allowsContentModifications ? nil : .bool(false),
        ])
    }

    nonisolated private static func status(_ s: EKParticipantStatus) -> String {
        switch s {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "pending"
        default: "unknown"
        }
    }

    nonisolated private static func describe(_ r: EKRecurrenceRule) -> JSONValue {
        let frequency = switch r.frequency {
        case .daily: "daily"
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .yearly: "yearly"
        @unknown default: "other"
        }
        return .fields([
            "frequency": .string(frequency),
            "interval": r.interval == 1 ? nil : .number(Double(r.interval)),
            "until": .str(r.recurrenceEnd?.endDate.map { DeviceToolDate.format($0, dayOnly: true) }),
            "count": r.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? .number(Double($0.occurrenceCount)) : nil },
        ])
    }

    static func recurrenceRule(_ args: DeviceToolArgs) throws -> EKRecurrenceRule? {
        guard let frequency = args.string("frequency")?.lowercased(), frequency != "none" else { return nil }
        let f: EKRecurrenceFrequency
        switch frequency {
        case "daily": f = .daily
        case "weekly": f = .weekly
        case "monthly": f = .monthly
        case "yearly": f = .yearly
        default: throw DeviceToolError("Répétition inconnue « \(frequency) » : daily, weekly, monthly, yearly ou none.")
        }
        var end: EKRecurrenceEnd?
        if let until = try DeviceToolDate.require(args, "until") {
            end = EKRecurrenceEnd(end: Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: until.date) ?? until.date)
        } else if let count = args.number("count"), count >= 1 {
            end = EKRecurrenceEnd(occurrenceCount: Int(count))
        }
        return EKRecurrenceRule(recurrenceWith: f, interval: args.int("interval", default: 1, range: 1...365), end: end)
    }

    /// The occurrence the bot means: `occurrence_start` for a repeating event, else the event itself.
    private func event(_ args: DeviceToolArgs) throws -> EKEvent {
        guard let id = args.string("id") else { throw DeviceToolError("id requis (voir apple_events).") }
        guard let master = store.event(withIdentifier: id) else { throw DeviceToolError("Aucun évènement avec l'id \(id) sur \(PlatformDevice.name).") }
        guard let occurrence = try DeviceToolDate.require(args, "occurrence_start"), master.hasRecurrenceRules else { return master }
        let day = Calendar.current.startOfDay(for: occurrence.date)
        let candidates = store.events(matching: store.predicateForEvents(withStart: day, end: day.addingTimeInterval(2 * 86400), calendars: [master.calendar]))
        let match = candidates.first { $0.eventIdentifier == id && abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(occurrence.date)) < 60 }
            ?? candidates.first { $0.eventIdentifier == id && occurrence.dayOnly && Calendar.current.isDate($0.startDate, inSameDayAs: occurrence.date) }
        guard let match else { throw DeviceToolError("Pas d'occurrence de « \(master.title ?? id) » à \(DeviceToolDate.format(occurrence.date)).") }
        return match
    }

    private func span(_ args: DeviceToolArgs) -> EKSpan { args.string("span") == "future" ? .futureEvents : .thisEvent }

    private func apply(_ args: DeviceToolArgs, to e: EKEvent, creating: Bool) throws {
        if let title = args.string("title") { e.title = title }
        let start = try DeviceToolDate.require(args, "start")
        let end = try DeviceToolDate.require(args, "end")
        if let allDay = args.bool("all_day") { e.isAllDay = allDay } else if let start, creating { e.isAllDay = start.dayOnly }
        if let start {
            let duration = creating ? nil : e.endDate.timeIntervalSince(e.startDate)
            e.startDate = start.date
            if end == nil { e.endDate = start.date.addingTimeInterval(duration ?? (e.isAllDay ? 0 : 3600)) }
        }
        if let end {
            // EventKit keeps an all-day end inside the last day; the bot's day end is exclusive.
            e.endDate = e.isAllDay && end.dayOnly ? max(e.startDate, end.date.addingTimeInterval(-1)) : end.date
        }
        guard e.endDate >= e.startDate else { throw DeviceToolError("La fin est avant le début.") }
        if args.has("location") { e.location = args.string("location") }
        if args.has("notes") { e.notes = args.string("notes") }
        if args.has("url") { e.url = args.string("url").flatMap(URL.init(string:)) }
        if let minutes = args.numbers("alarms") { e.alarms = minutes.map { EKAlarm(relativeOffset: -$0 * 60) } }
        if let rule = args.object("recurrence") {
            e.recurrenceRules = try Self.recurrenceRule(rule).map { [$0] }
        }
        switch args.string("availability") {
        case "free": e.availability = .free
        case "tentative": e.availability = .tentative
        case "busy": e.availability = .busy
        default: break
        }
        if let ref = args.string("calendar") { e.calendar = try calendar(ref, writable: true) }
    }

    private func createEvent(_ args: DeviceToolArgs) throws -> JSONValue {
        guard args.string("title") != nil else { throw DeviceToolError("title requis.") }
        guard args.has("start") else { throw DeviceToolError("start requis.") }
        let e = EKEvent(eventStore: store)
        e.calendar = store.defaultCalendarForNewEvents
        try apply(args, to: e, creating: true)
        guard e.calendar != nil else { throw DeviceToolError("Aucun calendrier par défaut sur \(PlatformDevice.name) : précise calendar (voir apple_calendars).") }
        do { try store.save(e, span: .thisEvent, commit: true) } catch { throw DeviceToolError("Création refusée par le calendrier « \(e.calendar.title) » : \(error.localizedDescription)") }
        return .object(["created": describe(e)])
    }

    private func updateEvent(_ args: DeviceToolArgs) throws -> JSONValue {
        let e = try event(args)
        guard e.calendar.allowsContentModifications else { throw DeviceToolError("« \(e.title ?? "") » est dans un calendrier en lecture seule (\(e.calendar.title)).") }
        try apply(args, to: e, creating: false)
        do { try store.save(e, span: span(args), commit: true) } catch { throw DeviceToolError("Modification refusée : \(error.localizedDescription)") }
        return .object(["updated": describe(e)])
    }

    private func deleteEvent(_ args: DeviceToolArgs) throws -> JSONValue {
        let e = try event(args)
        guard e.calendar.allowsContentModifications else { throw DeviceToolError("« \(e.title ?? "") » est dans un calendrier en lecture seule (\(e.calendar.title)).") }
        let summary = describe(e)
        do { try store.remove(e, span: span(args), commit: true) } catch { throw DeviceToolError("Suppression refusée : \(error.localizedDescription)") }
        return .object(["deleted": summary])
    }
}

struct EventsQuery: Sendable {
    let start: Date
    let end: Date
    let calendarIds: [String]?
    let text: String?
    let max: Int
}

/// The `apple_events` read, safe to run off the main actor: EventKit stores may be read from any thread.
private struct EventsReader: @unchecked Sendable {
    let store: EKEventStore

    func read(_ query: EventsQuery) -> JSONValue {
        let calendars = query.calendarIds?.compactMap { store.calendar(withIdentifier: $0) }
        var found = store.events(matching: store.predicateForEvents(withStart: query.start, end: query.end, calendars: calendars))
        if let text = query.text {
            found = found.filter { e in [e.title, e.location, e.notes].contains { $0?.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        }
        found.sort { $0.startDate < $1.startDate }
        return .fields([
            "from": .string(DeviceToolDate.format(query.start)),
            "to": .string(DeviceToolDate.format(query.end)),
            "count": .number(Double(found.count)),
            "truncated": found.count > query.max ? .bool(true) : nil,
            "events": .array(found.prefix(query.max).map(AppleCalendarTools.eventJSON)),
        ])
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
