import Foundation

// Mirror of docs/calendar.md: calendar bridge, merged agenda, Google writes and booking pages.
// Kept out of Protocol.swift so the widget, watch and share targets do not compile them.

struct GeoPoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
}

struct CalendarPerson: Codable, Hashable, Sendable {
    var name: String?
    var email: String?

    var display: String { name?.isEmpty == false ? name! : email ?? "?" }
}

struct CalendarAttendee: Codable, Hashable, Sendable, Identifiable {
    var name: String?
    var email: String?
    /// `accepted` `declined` `tentative` `pending` `unknown`.
    var status: String
    var organizer: Bool?

    var id: String { email ?? name ?? status }
    var display: String { name?.isEmpty == false ? name! : email ?? String(localized: "Guest") }
}

/// An EventKit alarm: `offsetSec` from the start (negative = before) or an absolute `at`.
struct EventAlarm: Codable, Hashable, Sendable {
    var offsetSec: Int?
    var at: Date?

    init(offsetSec: Int) { self.offsetSec = offsetSec }
    init(at: Date) { self.at = at }

    func fireDate(start: Date) -> Date? {
        if let at { return at }
        return offsetSec.map { start.addingTimeInterval(TimeInterval($0)) }
    }
}

enum CalendarPrivacy: String, Codable, Sendable, CaseIterable {
    case full, busy
}

/// One device's copy of a calendar (`sources[]` of `GET /api/calendar/calendars`).
struct CalendarSourceInfo: Codable, Hashable, Sendable {
    var deviceId: String
    var deviceName: String?
    var calendarIdentifier: String
    var syncedAt: Date?
    var primary: Bool?
}

/// A calendar as the gateway knows it: one per `account / title` key, whatever the device.
struct CalendarInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var key: String?
    var title: String
    var account: String?
    var type: String?
    /// Effective color (override or device color).
    var color: String?
    var deviceColor: String?
    var colorOverride: String?
    var allowsModifications: Bool
    var enabled: Bool
    var privacy: CalendarPrivacy
    var countsForAvailability: Bool
    var needsResync: Bool?
    var sources: [CalendarSourceInfo]

    var isBusyOnly: Bool { privacy == .busy }
    var lastSync: Date? { sources.compactMap(\.syncedAt).max() }
}

/// An item of the merged agenda: an event (possibly busy-only), a dated reminder or a booking.
struct AgendaItem: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case event, reminder, booking
        case unknown
        init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    var kind: Kind
    var id: String
    var calendarId: String?
    var externalId: String?
    var seriesId: String?
    var title: String?
    var location: String?
    var coordinates: GeoPoint?
    var notes: String?
    var url: String?
    var conferenceUrl: String?
    var start: Date
    var end: Date
    var allDay: Bool
    /// `busy` `free` `tentative` `unavailable`.
    var availability: String?
    /// `confirmed` `tentative` `cancelled`; for bookings `pending` `confirmed`.
    var status: String?
    var attendees: [CalendarAttendee]?
    var attendeesCount: Int?
    var organizer: CalendarPerson?
    var travelTimeSec: Int?
    /// `driving` `transit` `walking` `cycling` when an app computed `travelTimeSec`.
    var travelMode: String?
    var hasAlarms: Bool?
    var alarms: [EventAlarm]?
    var color: String?
    var busyOnly: Bool?
    var editable: Bool?
    // Reminders
    var done: Bool?
    var list: String?
    var priority: Int?
    // Bookings
    var bookingTypeId: String?
    /// Set by the app when an event is the mirror of a booking's Google event.
    var bookingId: String?

    var isBusyOnly: Bool { busyOnly ?? false }
    var isCancelled: Bool { status == "cancelled" }
    var isRecurring: Bool { seriesId != nil }
    var isBooking: Bool { kind == .booking || bookingId != nil }
    var displayTitle: String {
        if isBusyOnly { return String(localized: "Busy") }
        if let title, !title.isEmpty { return title }
        return kind == .reminder ? String(localized: "Reminder") : String(localized: "Untitled")
    }
    /// Unique across kinds: a reminder and an event may share a database id in theory.
    var uid: String { "\(kind.rawValue):\(id)" }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isFree: Bool { availability == "free" }
}

struct AgendaPage: Codable, Sendable {
    var from: Date?
    var to: Date?
    var items: [AgendaItem]
}

// MARK: - Bridge (apps → gateway)

/// `PUT /api/calendar/sources` item: one EventKit calendar of this device.
struct BridgeCalendar: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var color: String?
    var account: String?
    var type: String?
    var allowsModifications: Bool
}

/// One occurrence pushed by the bridge.
struct BridgeEvent: Codable, Hashable, Sendable {
    var externalId: String
    var seriesId: String?
    var title: String?
    var location: String?
    var coordinates: GeoPoint?
    var notes: String?
    var url: String?
    var start: Date
    var end: Date
    var allDay: Bool
    var availability: String
    var status: String?
    var attendees: [CalendarAttendee]?
    var attendeesCount: Int?
    var organizer: CalendarPerson?
    var travelTimeSec: Int?
    var hasAlarms: Bool?
    var alarms: [EventAlarm]?

    /// What a busy-only calendar may send: times, availability and alarms, never a title or a place.
    var busyOnly: BridgeEvent {
        BridgeEvent(externalId: externalId, seriesId: seriesId, start: start, end: end, allDay: allDay, availability: availability,
                    hasAlarms: hasAlarms, alarms: alarms)
    }
}

struct SyncWindow: Codable, Hashable, Sendable {
    var from: Date
    var to: Date
}

struct SyncCalendarBatch: Codable, Sendable {
    var calendarId: String
    var window: SyncWindow
    var events: [BridgeEvent]
    var deleted: [String]
    var complete: Bool
}

struct SyncRequest: Codable, Sendable {
    var syncId: String
    var calendars: [SyncCalendarBatch]
}

struct SyncResult: Codable, Sendable {
    var upserted: Int?
    var deleted: Int?
    var removedStale: Int?
}

// MARK: - Google

struct GoogleCalendar: Codable, Hashable, Sendable, Identifiable {
    var target: String
    var account: String
    var id: String
    var title: String
    var primary: Bool?
    var accessRole: String?

    var label: String { primary == true ? "\(title) (principal)" : title }
}

/// Body of `POST /api/calendar/events`: Google sends the invitations.
struct GoogleEventDraft: Codable, Sendable {
    var title: String
    /// ISO instant, or `YYYY-MM-DD` for all-day events (end exclusive).
    var start: String
    var end: String
    var allDay: Bool?
    var location: String?
    var notes: String?
    var attendees: [String]?
    var meet: Bool?
    var target: String?
}

struct GoogleEventResult: Codable, Sendable {
    var googleEventId: String
    var target: String
    var htmlLink: String?
    var meetUrl: String?
}

// MARK: - Booking

enum BookingKind: String, Codable, Sendable, CaseIterable {
    case opening, proposal
}

struct BookingLocation: Codable, Hashable, Sendable {
    /// `google_meet` `phone` `address` `custom`.
    var kind: String
    var value: String?
}

struct BookingQuestion: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    /// `text` `longtext` `phone` `select`.
    var type: String
    var required: Bool
    var options: [String]?
}

struct BookingSlot: Codable, Hashable, Sendable, Identifiable {
    var start: Date
    var end: Date
    var id: Date { start }
}

/// Wall-clock ranges per weekday, `Europe/Paris`: `"mon": [["09:00","12:00"]]`.
typealias WorkingHours = [String: [[String]]]

struct BookingType: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var slug: String
    var kind: BookingKind
    var title: String
    var description: String?
    var durationMin: Int
    var location: BookingLocation
    var workingHours: WorkingHours
    var bufferBeforeMin: Int
    var bufferAfterMin: Int
    var minNoticeMin: Int
    var maxDaysAhead: Int
    var maxPerDay: Int?
    var slotStepMin: Int?
    var googleCalendar: String?
    var questions: [BookingQuestion]
    var candidateSlots: [BookingSlot]?
    var active: Bool
    var archived: Bool?
    var url: String?
    var createdAt: Date?
    var updatedAt: Date?

    var shareURL: URL? { url.flatMap(URL.init(string:)) }
}

/// Body of `POST /api/booking/types` and `PATCH /api/booking/types/:id`. Nullable settings are always written,
/// so clearing `maxPerDay`, `slotStepMin` or `googleCalendar` reaches the gateway as `null`.
struct BookingTypeDraft: Encodable, Sendable {
    var slug: String
    var kind: BookingKind
    var title: String
    var description: String?
    var durationMin: Int
    var location: BookingLocation
    var workingHours: WorkingHours
    var bufferBeforeMin: Int
    var bufferAfterMin: Int
    var minNoticeMin: Int
    var maxDaysAhead: Int
    var maxPerDay: Int?
    var slotStepMin: Int?
    var googleCalendar: String?
    var questions: [BookingQuestion]
    var candidateSlots: [BookingSlot]?
    var active: Bool

    private enum Keys: String, CodingKey {
        case slug, kind, title, description, durationMin, location, workingHours, bufferBeforeMin, bufferAfterMin
        case minNoticeMin, maxDaysAhead, maxPerDay, slotStepMin, googleCalendar, questions, candidateSlots, active
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(slug, forKey: .slug)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(durationMin, forKey: .durationMin)
        try c.encode(location, forKey: .location)
        try c.encode(workingHours, forKey: .workingHours)
        try c.encode(bufferBeforeMin, forKey: .bufferBeforeMin)
        try c.encode(bufferAfterMin, forKey: .bufferAfterMin)
        try c.encode(minNoticeMin, forKey: .minNoticeMin)
        try c.encode(maxDaysAhead, forKey: .maxDaysAhead)
        try c.encode(maxPerDay, forKey: .maxPerDay)
        try c.encode(slotStepMin, forKey: .slotStepMin)
        try c.encode(googleCalendar, forKey: .googleCalendar)
        try c.encode(questions, forKey: .questions)
        try c.encodeIfPresent(candidateSlots, forKey: .candidateSlots)
        try c.encode(active, forKey: .active)
    }
}

extension BookingTypeDraft {
    init(_ type: BookingType) {
        self.init(slug: type.slug, kind: type.kind, title: type.title, description: type.description, durationMin: type.durationMin,
                  location: type.location, workingHours: type.workingHours, bufferBeforeMin: type.bufferBeforeMin,
                  bufferAfterMin: type.bufferAfterMin, minNoticeMin: type.minNoticeMin, maxDaysAhead: type.maxDaysAhead,
                  maxPerDay: type.maxPerDay, slotStepMin: type.slotStepMin, googleCalendar: type.googleCalendar,
                  questions: type.questions, candidateSlots: type.candidateSlots, active: type.active)
    }
}

struct BookingInvitee: Codable, Hashable, Sendable {
    var name: String
    var email: String
    var timezone: String?
    var notes: String?
    var answers: [String: String]?
}

struct Booking: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var typeId: String
    var typeTitle: String?
    var start: Date
    var end: Date
    /// `pending` `confirmed` `cancelled` `rescheduled` `failed`.
    var status: String
    var invitee: BookingInvitee
    var googleEventId: String?
    var googleTarget: String?
    var meetUrl: String?
    var rescheduledFrom: String?
    var cancelReason: String?
    var createdAt: Date?

    var isActive: Bool { status == "confirmed" || status == "pending" }
}

struct BookingSlotsReply: Codable, Sendable {
    var timezone: String?
    var durationMin: Int?
    var slots: [BookingSlot]
}

/// Calendar and booking routes of docs/calendar.md.
protocol NuoCalendarAPI: Sendable {
    func putCalendarSources(_ calendars: [BridgeCalendar]) async throws -> [CalendarInfo]
    func syncCalendar(_ request: SyncRequest) async throws -> SyncResult
    /// Mirrors one occurrence right after an EventKit write; returns the stored, privacy-filtered item.
    func syncEvent(calendarId: String, event: BridgeEvent) async throws -> AgendaItem?
    func deleteSyncedEvents(calendarId: String, externalIds: [String]) async throws
    func calendarList() async throws -> [CalendarInfo]
    /// Partial update (`enabled`, `privacy`, `countsForAvailability`, `colorOverride`; `.null` clears the override).
    func patchCalendar(id: String, patch: [String: JSONValue]) async throws -> CalendarInfo
    func agenda(from: Date, to: Date, bookings: Bool) async throws -> [AgendaItem]
    func createGoogleEvent(_ draft: GoogleEventDraft) async throws -> GoogleEventResult
    func googleCalendars() async throws -> [GoogleCalendar]
    /// Stores the travel time computed for « Partir maintenant » (`nil` clears it); returns the updated event.
    func setEventTravel(id: String, travelTimeSec: Int?, mode: String?) async throws -> AgendaItem?

    func bookingTypes() async throws -> [BookingType]
    func createBookingType(_ draft: BookingTypeDraft) async throws -> BookingType
    func updateBookingType(id: String, draft: BookingTypeDraft) async throws -> BookingType
    /// Archives the type; its bookings stay.
    func archiveBookingType(id: String) async throws
    func bookingSlots(typeId: String, from: Date, to: Date) async throws -> [BookingSlot]
    /// Upcoming `pending` and `confirmed` bookings, or every status with `all: true`.
    func bookings(all: Bool) async throws -> [Booking]
    func cancelBooking(id: String, reason: String?) async throws -> Booking
}
