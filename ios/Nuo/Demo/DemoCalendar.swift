import Foundation

/// In-memory calendars, events, booking types and bookings for `-demo`. Names, places and links are invented.
actor DemoCalendar {
    static let shared = DemoCalendar()

    private var calendars: [CalendarInfo]
    private var events: [AgendaItem]
    private var types: [BookingType]
    private var bookingList: [Booking]

    private init() {
        let seed = DemoCalendarSeed.make(now: Date())
        calendars = seed.calendars
        events = seed.events
        types = seed.types
        bookingList = seed.bookings
    }

    private func pause() async { try? await Task.sleep(for: .milliseconds(120)) }

    private func calendar(identifier: String) -> CalendarInfo? {
        calendars.first { $0.id == identifier || $0.sources.contains { $0.calendarIdentifier == identifier } }
    }

    // MARK: Calendars

    func calendarList() async -> [CalendarInfo] {
        await pause()
        return calendars
    }

    func patchCalendar(id: String, patch: [String: JSONValue]) throws -> CalendarInfo {
        guard let index = calendars.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        if let enabled = patch["enabled"]?.bool { calendars[index].enabled = enabled }
        if let privacy = patch["privacy"]?.string.flatMap(CalendarPrivacy.init(rawValue:)) { calendars[index].privacy = privacy }
        if let counts = patch["countsForAvailability"]?.bool { calendars[index].countsForAvailability = counts }
        if let color = patch["colorOverride"] {
            calendars[index].colorOverride = color.string
            calendars[index].color = color.string ?? calendars[index].deviceColor
        }
        return calendars[index]
    }

    // MARK: Agenda

    func agenda(from: Date, to: Date, bookings includeBookings: Bool) async -> [AgendaItem] {
        await pause()
        let enabled = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0) })
        var items = events.compactMap { event -> AgendaItem? in
            guard event.start < to, event.end >= from, let calendarId = event.calendarId, let calendar = enabled[calendarId], calendar.enabled else { return nil }
            var item = event
            item.color = calendar.color
            item.editable = calendar.allowsModifications
            if calendar.isBusyOnly {
                item = AgendaItem(kind: .event, id: event.id, calendarId: calendarId, externalId: event.externalId, start: event.start, end: event.end,
                                  allDay: event.allDay, availability: event.availability, hasAlarms: event.hasAlarms, alarms: event.alarms,
                                  color: calendar.color, busyOnly: true)
            }
            return item
        }
        let reminders = await DemoWorkspace.shared.reminders(scope: .all, list: nil) + DemoWorkspace.shared.reminders(scope: .done, list: nil)
        for reminder in reminders {
            guard let due = reminder.dueAt, due >= from, due < to else { continue }
            items.append(AgendaItem(kind: .reminder, id: reminder.id, title: reminder.title, start: due, end: due, allDay: false,
                                    done: reminder.isDone, list: reminder.list, priority: reminder.priority))
        }
        if includeBookings {
            for booking in bookingList where booking.isActive && booking.start < to && booking.end > from {
                items.append(AgendaItem(kind: .booking, id: booking.id, title: "\(booking.typeTitle ?? String(localized: "demo.calendar.booking", defaultValue: "Booking")) · \(booking.invitee.name)",
                                        start: booking.start, end: booking.end, allDay: false, status: booking.status, bookingTypeId: booking.typeId))
            }
        }
        return items.sorted { $0.start < $1.start }
    }

    // MARK: Bridge writes (the demo has no EventKit: the app mirrors straight here)

    func putSources(_ list: [BridgeCalendar]) -> [CalendarInfo] { calendars }

    func sync(_ request: SyncRequest) -> SyncResult {
        var upserted = 0
        for batch in request.calendars {
            for event in batch.events {
                _ = upsert(calendarIdentifier: batch.calendarId, event: event)
                upserted += 1
            }
            events.removeAll { batch.deleted.contains($0.externalId ?? "") }
        }
        return SyncResult(upserted: upserted, deleted: 0, removedStale: 0)
    }

    func upsert(calendarIdentifier: String, event: BridgeEvent) -> AgendaItem? {
        guard let calendar = calendar(identifier: calendarIdentifier) else { return nil }
        var item = AgendaItem(kind: .event, id: "ev-\(event.externalId)", calendarId: calendar.id, externalId: event.externalId, seriesId: event.seriesId,
                              title: event.title, location: event.location, coordinates: event.coordinates, notes: event.notes, url: event.url,
                              conferenceUrl: Self.conference(in: [event.url, event.location, event.notes]),
                              start: event.start, end: event.end, allDay: event.allDay, availability: event.availability, status: event.status,
                              attendees: event.attendees, attendeesCount: event.attendees?.count, organizer: event.organizer,
                              travelTimeSec: event.travelTimeSec, hasAlarms: event.hasAlarms, alarms: event.alarms, color: calendar.color,
                              busyOnly: calendar.isBusyOnly, editable: calendar.allowsModifications)
        if let index = events.firstIndex(where: { $0.externalId == event.externalId }) {
            item.id = events[index].id
            // Like the gateway: a travel time stored by the app survives the bridge's writes.
            if item.travelTimeSec == nil, events[index].travelMode != nil {
                item.travelTimeSec = events[index].travelTimeSec
                item.travelMode = events[index].travelMode
            }
            events[index] = item
        } else {
            events.append(item)
        }
        return item
    }

    func setTravel(id: String, seconds: Int?, mode: String?) -> AgendaItem? {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return nil }
        events[index].travelTimeSec = seconds
        events[index].travelMode = seconds == nil ? nil : mode
        var item = events[index]
        item.color = calendar(identifier: item.calendarId ?? "")?.color
        return item
    }

    func delete(externalIds: [String]) {
        events.removeAll { externalIds.contains($0.externalId ?? "") }
    }

    func createGoogleEvent(_ draft: GoogleEventDraft) -> GoogleEventResult {
        let start = NuoJSON.parseDate(draft.start) ?? ValueFormat.parseDate(draft.start) ?? Date()
        let end = NuoJSON.parseDate(draft.end) ?? ValueFormat.parseDate(draft.end) ?? start.addingTimeInterval(3600)
        let id = "g-\(UUID().uuidString.prefix(8))"
        let meet = draft.meet == true ? "https://meet.google.com/\(id.suffix(3))-demo-rel" : nil
        let attendees = draft.attendees?.map { CalendarAttendee(name: nil, email: $0, status: "pending") }
        _ = upsert(calendarIdentifier: "demo-pro", event: BridgeEvent(
            externalId: id, title: draft.title, location: draft.location, notes: draft.notes, url: meet, start: start, end: end,
            allDay: draft.allDay ?? false, availability: "busy", status: "confirmed", attendees: attendees,
            organizer: CalendarPerson(name: "Alex", email: "alex@example.com"), hasAlarms: true))
        return GoogleEventResult(googleEventId: id, target: draft.target ?? "alex@example.com/primary", meetUrl: meet)
    }

    func googleCalendars() -> [GoogleCalendar] {
        [
            GoogleCalendar(target: "alex@example.com/primary", account: "alex@example.com", id: "primary", title: "Alex", primary: true, accessRole: "owner"),
            GoogleCalendar(target: "alex@example.com/lumen", account: "alex@example.com", id: "lumen", title: "Lumen Studio", primary: false, accessRole: "owner"),
        ]
    }

    // MARK: Booking

    func bookingTypes() async -> [BookingType] {
        await pause()
        return types.filter { $0.archived != true }
    }

    func createType(_ draft: BookingTypeDraft) throws -> BookingType {
        guard !types.contains(where: { $0.slug == draft.slug && $0.archived != true }) else {
            throw NuoError.server(status: 409, message: String(localized: "This link is already in use."))
        }
        let type = DemoCalendarSeed.type(from: draft, id: "bt-\(UUID().uuidString.prefix(6))")
        types.append(type)
        return type
    }

    func updateType(id: String, draft: BookingTypeDraft) throws -> BookingType {
        guard let index = types.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        var type = DemoCalendarSeed.type(from: draft, id: id)
        type.createdAt = types[index].createdAt
        types[index] = type
        return type
    }

    func archiveType(id: String) {
        guard let index = types.firstIndex(where: { $0.id == id }) else { return }
        types[index].archived = true
        types[index].active = false
    }

    func slots(typeId: String, from: Date, to: Date) -> [BookingSlot] {
        guard let type = types.first(where: { $0.id == typeId }) else { return [] }
        let busy = events.filter { !$0.isFree && !$0.allDay }.map { ($0.start, $0.end) } + bookingList.filter(\.isActive).map { ($0.start, $0.end) }
        return DemoCalendarSeed.freeSlots(type: type, from: from, to: to, busy: busy)
    }

    func bookings(all: Bool) async -> [Booking] {
        await pause()
        let now = Date()
        return bookingList.filter { all || ($0.isActive && $0.end > now) }.sorted { $0.start < $1.start }
    }

    func cancel(id: String, reason: String?) throws -> Booking {
        guard let index = bookingList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        bookingList[index].status = "cancelled"
        bookingList[index].cancelReason = reason
        let title = "\(bookingList[index].typeTitle ?? "") · \(bookingList[index].invitee.name)"
        events.removeAll { $0.title == title && $0.start == bookingList[index].start }
        return bookingList[index]
    }

    static func conference(in texts: [String?]) -> String? {
        let pattern = #"https://(?:meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com|whereby\.com|meet\.jit\.si)/\S+"#
        for text in texts.compactMap({ $0 }) {
            if let range = text.range(of: pattern, options: .regularExpression) { return String(text[range]) }
        }
        return nil
    }
}

extension DemoBackend {
    private var demoCalendar: DemoCalendar { DemoCalendar.shared }

    func putCalendarSources(_ calendars: [BridgeCalendar]) async throws -> [CalendarInfo] { await demoCalendar.putSources(calendars) }
    func syncCalendar(_ request: SyncRequest) async throws -> SyncResult { await demoCalendar.sync(request) }
    func syncEvent(calendarId: String, event: BridgeEvent) async throws -> AgendaItem? {
        await demoCalendar.upsert(calendarIdentifier: calendarId, event: event)
    }
    func deleteSyncedEvents(calendarId: String, externalIds: [String]) async throws { await demoCalendar.delete(externalIds: externalIds) }
    func calendarList() async throws -> [CalendarInfo] { await demoCalendar.calendarList() }
    func patchCalendar(id: String, patch: [String: JSONValue]) async throws -> CalendarInfo { try await demoCalendar.patchCalendar(id: id, patch: patch) }
    func agenda(from: Date, to: Date, bookings: Bool) async throws -> [AgendaItem] { await demoCalendar.agenda(from: from, to: to, bookings: bookings) }
    func createGoogleEvent(_ draft: GoogleEventDraft) async throws -> GoogleEventResult { await demoCalendar.createGoogleEvent(draft) }
    func googleCalendars() async throws -> [GoogleCalendar] { await demoCalendar.googleCalendars() }
    func setEventTravel(id: String, travelTimeSec: Int?, mode: String?) async throws -> AgendaItem? {
        await demoCalendar.setTravel(id: id, seconds: travelTimeSec, mode: mode)
    }
    func bookingTypes() async throws -> [BookingType] { await demoCalendar.bookingTypes() }
    func createBookingType(_ draft: BookingTypeDraft) async throws -> BookingType { try await demoCalendar.createType(draft) }
    func updateBookingType(id: String, draft: BookingTypeDraft) async throws -> BookingType { try await demoCalendar.updateType(id: id, draft: draft) }
    func archiveBookingType(id: String) async throws { await demoCalendar.archiveType(id: id) }
    func bookingSlots(typeId: String, from: Date, to: Date) async throws -> [BookingSlot] { await demoCalendar.slots(typeId: typeId, from: from, to: to) }
    func bookings(all: Bool) async throws -> [Booking] { await demoCalendar.bookings(all: all) }
    func cancelBooking(id: String, reason: String?) async throws -> Booking { try await demoCalendar.cancel(id: id, reason: reason) }
}

enum DemoCalendarSeed {
    struct Seed {
        var calendars: [CalendarInfo]
        var events: [AgendaItem]
        var types: [BookingType]
        var bookings: [Booking]
    }

    static let baseURL = "https://nuo.example.com/book"

    private static func calendar(_ id: String, _ title: String, account: String, type: String, color: String, privacy: CalendarPrivacy = .full,
                                 counts: Bool = true, writable: Bool = true, now: Date) -> CalendarInfo {
        CalendarInfo(id: id, key: "\(account.lowercased()) / \(title.lowercased())", title: title, account: account, type: type,
                     color: color, deviceColor: color, colorOverride: nil, allowsModifications: writable, enabled: true, privacy: privacy,
                     countsForAvailability: counts, needsResync: false,
                     sources: [CalendarSourceInfo(deviceId: "demo-mac", deviceName: "MacBook Pro", calendarIdentifier: "demo-\(id.dropFirst(2))",
                                                  syncedAt: now.addingTimeInterval(-240), primary: true)])
    }

    static func make(now: Date) -> Seed {
        let calendars = [
            calendar("k_perso", String(localized: "demo.calendar.personal", defaultValue: "Personal"), account: "iCloud", type: "caldav", color: "#34A853", now: now),
            calendar("k_pro", String(localized: "Lumen Studio Work"), account: "alex@example.com", type: "caldav", color: "#3B82F6", now: now),
            calendar("k_helio", "Helio Labs", account: "Exchange", type: "exchange", color: "#A855F7", privacy: .busy, writable: false, now: now),
            calendar("k_famille", String(localized: "demo.calendar.family", defaultValue: "Family"), account: "iCloud", type: "caldav", color: "#F43F5E", counts: false, now: now),
        ]
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.date(byAdding: .day, value: day, to: today)!)!
        }
        func dayStart(_ day: Int) -> Date { cal.date(byAdding: .day, value: day, to: today)! }

        var events: [AgendaItem] = []
        var counter = 0
        func add(_ calendarId: String, _ title: String, _ start: Date, _ end: Date, allDay: Bool = false, location: String? = nil,
                 coordinates: GeoPoint? = nil, notes: String? = nil, url: String? = nil, availability: String = "busy", status: String = "confirmed",
                 attendees: [CalendarAttendee]? = nil, organizer: CalendarPerson? = nil, travel: Int? = nil, mode: String? = nil, series: String? = nil,
                 alarms: Bool = true, alerts: [Int] = [15]) {
            counter += 1
            let external = series.map { "\($0)@\(NuoJSON.formatDate(start))" } ?? "demo-\(counter)"
            events.append(AgendaItem(kind: .event, id: "ev-\(counter)", calendarId: calendarId, externalId: external, seriesId: series, title: title,
                                     location: location, coordinates: coordinates, notes: notes, url: url,
                                     conferenceUrl: DemoCalendar.conference(in: [url, location, notes]), start: start, end: end, allDay: allDay,
                                     availability: availability, status: status, attendees: attendees, attendeesCount: attendees?.count,
                                     organizer: organizer, travelTimeSec: travel, travelMode: travel == nil ? nil : mode, hasAlarms: alarms,
                                     alarms: alarms ? alerts.map { EventAlarm(offsetSec: -$0 * 60) } : nil))
        }
        let me = CalendarAttendee(name: "Alex", email: "alex@example.com", status: "accepted", organizer: true)
        let organizer = CalendarPerson(name: "Alex", email: "alex@example.com")

        // Recurring series, expanded like the bridge does.
        for day in -7...21 {
            let date = dayStart(day)
            let weekday = cal.component(.weekday, from: date)
            if weekday == 2 {
                add("k_pro", String(localized: "Lumen Studio weekly"), at(day, 9), at(day, 9, 30), url: "https://meet.google.com/qvx-tmda-rkp",
                    attendees: [me, CalendarAttendee(name: String(localized: "Lumen Studio design"), email: "design@lumen.example.com", status: "accepted"),
                                CalendarAttendee(name: String(localized: "Lumen Studio product"), email: "product@lumen.example.com", status: "tentative")],
                    organizer: organizer, series: "series-point-lumen")
            }
            if (2...6).contains(weekday) {
                add("k_helio", "Daily", at(day, 9, 45), at(day, 10), series: "series-daily")
            }
            if weekday == 3 || weekday == 5 {
                add("k_perso", String(localized: "demo.calendar.run", defaultValue: "Run"), at(day, 7), at(day, 8), location: "Parc Monceau",
                    coordinates: GeoPoint(lat: 48.8796, lon: 2.3092), series: "series-run", alarms: false)
            }
            if weekday == 1 {
                add("k_famille", String(localized: "Family dinner"), at(day, 19, 30), at(day, 22), location: String(localized: "Mom and Dad's, Sceaux"),
                    coordinates: GeoPoint(lat: 48.7765, lon: 2.2905), series: "series-diner", alarms: false)
            }
        }

        // Past days, so the agenda scrolls back.
        add("k_pro", String(localized: "Lumen Studio invoicing"), at(-2, 10), at(-2, 11), notes: String(localized: "Send October's invoices."))
        add("k_helio", String(localized: "Architecture review"), at(-1, 14), at(-1, 16))
        add("k_perso", String(localized: "Movie night"), at(-1, 20, 30), at(-1, 22, 45), location: String(localized: "Movie theater, Odéon"), coordinates: GeoPoint(lat: 48.8519, lon: 2.3389))

        // Today.
        add("k_perso", String(localized: "Team lunch"), at(0, 12, 30), at(0, 13, 45), location: String(localized: "Bistro, 172 bd Saint-Germain"),
            coordinates: GeoPoint(lat: 48.8540, lon: 2.3326), travel: 1500, mode: "transit", alerts: [15])
        add("k_helio", String(localized: "Sprint review"), at(0, 14), at(0, 15, 30))
        add("k_pro", String(localized: "Call with the accountant"), at(0, 17), at(0, 17, 30),
            notes: String(localized: "2026 accounts and corporate tax installments.") + "\nhttps://meet.google.com/fhw-pzkn-yte",
            attendees: [me, CalendarAttendee(name: String(localized: "Accounting firm"), email: "contact@accounting.example.com", status: "accepted")], organizer: organizer,
            alerts: [10])
        add("k_perso", String(localized: "demo.calendar.gym", defaultValue: "Gym"), at(0, 19), at(0, 20), location: String(localized: "Rue de Clichy, Paris 9th"), alarms: false)

        // Tomorrow.
        add("k_pro", String(localized: "Nuo design workshop"), at(1, 10), at(1, 12), location: "Station F, 5 parvis Alan Turing",
            coordinates: GeoPoint(lat: 48.8341, lon: 2.3707), notes: String(localized: "Calendar, bookings and widgets."), travel: 1500, mode: "driving", alerts: [30, 1440])
        add("k_helio", String(localized: "Product committee"), at(1, 14), at(1, 16))
        add("k_perso", String(localized: "demo.calendar.dentist", defaultValue: "Dentist"), at(1, 16, 30), at(1, 17, 15), location: String(localized: "Dental office, 8 rue Saint-Lazare"),
            coordinates: GeoPoint(lat: 48.8768, lon: 2.3330), alerts: [60])

        // Trip.
        add("k_perso", String(localized: "Trip to Rome"), dayStart(3), dayStart(7), allDay: true, availability: "free", alarms: false)
        add("k_perso", String(localized: "Flight Paris → Rome"), at(3, 14, 40), at(3, 17, 5), location: String(localized: "Paris-Orly Airport"),
            coordinates: GeoPoint(lat: 48.7262, lon: 2.3652), notes: String(localized: "TO8284 · seat 14C"), travel: 2700, mode: "driving", alerts: [120])
        add("k_famille", String(localized: "Block party"), dayStart(4), dayStart(5), allDay: true, availability: "free", alarms: true)
        add("k_perso", String(localized: "Flight Rome → Paris"), at(6, 18, 10), at(6, 20, 40), location: String(localized: "Rome Fiumicino Airport"),
            coordinates: GeoPoint(lat: 41.8003, lon: 12.2389), notes: "TO8285")

        // Next week.
        let callTitle = String(localized: "30-min call")
        add("k_pro", "\(callTitle) · Studio Paprika", at(8, 11), at(8, 11, 30), url: "https://meet.google.com/jdp-rdvx-qwe",
            attendees: [me, CalendarAttendee(name: "Studio Paprika", email: "contact@paprika.example", status: "accepted")], organizer: organizer)
        add("k_helio", String(localized: "Roadmap workshop"), at(9, 10), at(9, 12))
        add("k_perso", String(localized: "demo.calendar.physio", defaultValue: "Physio"), at(9, 18, 30), at(9, 19, 15), location: String(localized: "Physio clinic, Rue Lamarck, Paris 18th"))
        add("k_pro", String(localized: "Lumen Studio drinks"), at(10, 19), at(10, 22), location: "Rooftop, 5 rue de la Chaussée-d'Antin",
            coordinates: GeoPoint(lat: 48.8723, lon: 2.3333))
        add("k_perso", String(localized: "Sofa delivery"), at(11, 8), at(11, 12), availability: "tentative", status: "tentative")
        add("k_pro", String(localized: "Hexa client demo"), at(12, 15), at(12, 16), location: "https://zoom.us/j/9123456789",
            attendees: [me, CalendarAttendee(name: String(localized: "Hexa team"), email: "team@hexa.example", status: "pending")], organizer: organizer)

        // `-demoCalendarVolume 800` adds filler events over the loaded window, to profile a busy agenda.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-demoCalendarVolume"), index + 1 < arguments.count, let volume = Int(arguments[index + 1]) {
            let ids = calendars.map(\.id)
            let places = [(String(localized: "Café, 8 rue des Martyrs"), GeoPoint(lat: 48.8786, lon: 2.3398)), (String(localized: "Office, 24 rue de Paradis"), GeoPoint(lat: 48.8758, lon: 2.3520))]
            for n in 0..<volume {
                let day = n % 211 - 30, hour = 8 + n % 11, place = n % 3 == 0 ? places[n % 2] : nil
                add(ids[n % ids.count], String(localized: "Meeting \(n)"), at(day, hour, n % 2 * 30), at(day, hour + 1, n % 2 * 30), location: place?.0,
                    coordinates: place?.1, notes: n % 4 == 0 ? String(localized: "Agenda \(n)") : nil, url: n % 5 == 0 ? "https://meet.google.com/abc-\(n)" : nil,
                    attendees: n % 6 == 0 ? [me, CalendarAttendee(name: String(localized: "Guest \(n)"), email: "guest\(n)@example.com", status: "pending")] : nil)
            }
        }

        let discoveryTitle = String(localized: "Project discovery")
        let types = [
            BookingType(id: "bt-rdv30", slug: "rdv-30", kind: .opening, title: callTitle,
                        description: String(localized: "A quick video call."), durationMin: 30, location: BookingLocation(kind: "google_meet"),
                        workingHours: ["mon": [["09:30", "12:00"], ["14:00", "18:00"]], "tue": [["14:00", "18:00"]], "wed": [["09:30", "12:00"]],
                                       "thu": [["14:00", "18:00"]], "fri": [["09:30", "12:00"]], "sat": [], "sun": []],
                        bufferBeforeMin: 10, bufferAfterMin: 10, minNoticeMin: 240, maxDaysAhead: 30, maxPerDay: 4, slotStepMin: 30,
                        googleCalendar: "alex@example.com/primary",
                        questions: [BookingQuestion(id: "sujet", label: String(localized: "demo.calendar.topic", defaultValue: "Topic"), type: "text", required: true)],
                        candidateSlots: [], active: true, url: "\(baseURL)/rdv-30", createdAt: now.addingTimeInterval(-40 * 86400)),
            BookingType(id: "bt-decouverte", slug: "decouverte", kind: .opening, title: discoveryTitle,
                        description: String(localized: "Tell me about your project: needs, timeline, budget."), durationMin: 45,
                        location: BookingLocation(kind: "address", value: String(localized: "Lumen Studio, 24 rue de Paradis, Paris 10th")),
                        workingHours: ["mon": [], "tue": [["10:00", "12:00"]], "wed": [], "thu": [["10:00", "12:00"]], "fri": [], "sat": [], "sun": []],
                        bufferBeforeMin: 15, bufferAfterMin: 15, minNoticeMin: 1440, maxDaysAhead: 45, maxPerDay: 2, slotStepMin: nil,
                        googleCalendar: nil,
                        questions: [BookingQuestion(id: "societe", label: String(localized: "demo.calendar.company", defaultValue: "Company"), type: "text", required: false),
                                    BookingQuestion(id: "budget", label: "Budget", type: "select", required: false, options: ["< 10 k€", "10–50 k€", "> 50 k€"])],
                        candidateSlots: [], active: true, url: "\(baseURL)/decouverte", createdAt: now.addingTimeInterval(-12 * 86400)),
        ]
        let bookings = [
            Booking(id: "bk-1", typeId: "bt-rdv30", typeTitle: callTitle, start: at(8, 11), end: at(8, 11, 30), status: "confirmed",
                    invitee: BookingInvitee(name: "Studio Paprika", email: "contact@paprika.example", timezone: "Europe/Paris", notes: nil, answers: ["sujet": String(localized: "App redesign")]),
                    meetUrl: "https://meet.google.com/jdp-rdvx-qwe", createdAt: now.addingTimeInterval(-2 * 86400)),
            Booking(id: "bk-2", typeId: "bt-rdv30", typeTitle: callTitle, start: at(1, 17, 30), end: at(1, 18), status: "pending",
                    invitee: BookingInvitee(name: "Nordline Logistique", email: "contact@nordline.example", timezone: "Europe/Paris",
                                            notes: String(localized: "A question about the engagement"), answers: ["sujet": String(localized: "Freelance engagement")]),
                    createdAt: now.addingTimeInterval(-600)),
            Booking(id: "bk-3", typeId: "bt-decouverte", typeTitle: discoveryTitle, start: at(2, 10), end: at(2, 10, 45), status: "confirmed",
                    invitee: BookingInvitee(name: "Kiosk Labs", email: "contact@kiosk-labs.example", timezone: "Europe/Rome", notes: nil, answers: ["societe": "Kiosk Labs", "budget": "10–50 k€"]),
                    createdAt: now.addingTimeInterval(-86400)),
        ]
        return Seed(calendars: calendars, events: events, types: types, bookings: bookings)
    }

    static func type(from draft: BookingTypeDraft, id: String) -> BookingType {
        BookingType(id: id, slug: draft.slug, kind: draft.kind, title: draft.title, description: draft.description, durationMin: draft.durationMin,
                    location: draft.location, workingHours: draft.workingHours, bufferBeforeMin: draft.bufferBeforeMin, bufferAfterMin: draft.bufferAfterMin,
                    minNoticeMin: draft.minNoticeMin, maxDaysAhead: draft.maxDaysAhead, maxPerDay: draft.maxPerDay, slotStepMin: draft.slotStepMin,
                    googleCalendar: draft.googleCalendar, questions: draft.questions,
                    candidateSlots: draft.candidateSlots?.map { BookingSlot(start: $0.start, end: $0.start.addingTimeInterval(Double(draft.durationMin) * 60)) },
                    active: draft.active, url: "\(baseURL)/\(draft.slug)", createdAt: Date(), updatedAt: Date())
    }

    /// Same rules as the gateway, without DST subtleties: working hours, buffers, notice, horizon and busy times.
    static func freeSlots(type: BookingType, from: Date, to: Date, busy: [(Date, Date)]) -> [BookingSlot] {
        let cal = Calendar.current
        let keys = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let earliest = max(from, Date().addingTimeInterval(Double(type.minNoticeMin) * 60))
        let latest = min(to, Date().addingTimeInterval(Double(type.maxDaysAhead) * 86400))
        let duration = Double(type.durationMin) * 60
        let step = Double(type.slotStepMin ?? type.durationMin) * 60
        var slots: [BookingSlot] = []
        var day = cal.startOfDay(for: earliest)
        while day < latest {
            let ranges = type.workingHours[keys[cal.component(.weekday, from: day) - 1]] ?? []
            for range in ranges where range.count == 2 {
                guard let open = time(range[0], on: day), let close = time(range[1], on: day) else { continue }
                var start = open
                while start.addingTimeInterval(duration) <= close {
                    let end = start.addingTimeInterval(duration)
                    let padded = (start.addingTimeInterval(-Double(type.bufferBeforeMin) * 60), end.addingTimeInterval(Double(type.bufferAfterMin) * 60))
                    if start >= earliest, end <= latest, !busy.contains(where: { $0.0 < padded.1 && $0.1 > padded.0 }) {
                        slots.append(BookingSlot(start: start, end: end))
                    }
                    start = start.addingTimeInterval(step)
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return slots
    }

    private static func time(_ text: String, on day: Date) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }
}
