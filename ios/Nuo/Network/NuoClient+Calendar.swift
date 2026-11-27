import Foundation

extension NuoClient {
    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    private func value(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? text
    }

    // MARK: Bridge

    func putCalendarSources(_ calendars: [BridgeCalendar]) async throws -> [CalendarInfo] {
        struct Reply: Decodable { let calendars: [CalendarInfo] }
        let reply: Reply = try await request("PUT", "/api/calendar/sources", body: ["calendars": calendars])
        return reply.calendars
    }

    func syncCalendar(_ syncRequest: SyncRequest) async throws -> SyncResult {
        try await request("POST", "/api/calendar/sync", body: syncRequest)
    }

    func syncEvent(calendarId: String, event: BridgeEvent) async throws -> AgendaItem? {
        struct Body: Encodable { let calendarId: String; let event: BridgeEvent }
        struct Reply: Decodable { let event: AgendaItem? }
        let reply: Reply = try await request("POST", "/api/calendar/sync/events", body: Body(calendarId: calendarId, event: event))
        return reply.event
    }

    func deleteSyncedEvents(calendarId: String, externalIds: [String]) async throws {
        struct Body: Encodable { let calendarId: String; let deleted: [String] }
        try await send("POST", "/api/calendar/sync/events", body: Body(calendarId: calendarId, deleted: externalIds))
    }

    // MARK: Read

    func calendarList() async throws -> [CalendarInfo] { try await request("GET", "/api/calendar/calendars") }

    func patchCalendar(id: String, patch: [String: JSONValue]) async throws -> CalendarInfo {
        try await request("PATCH", "/api/calendar/calendars/\(segment(id))", body: patch)
    }

    func agenda(from: Date, to: Date, bookings: Bool) async throws -> [AgendaItem] {
        var path = "/api/calendar/events?from=\(value(NuoJSON.formatDate(from)))&to=\(value(NuoJSON.formatDate(to)))"
        if bookings { path += "&bookings=1" }
        let page: AgendaPage = try await request("GET", path)
        return page.items
    }

    // MARK: Google

    func createGoogleEvent(_ draft: GoogleEventDraft) async throws -> GoogleEventResult {
        try await request("POST", "/api/calendar/events", body: draft)
    }

    func googleCalendars() async throws -> [GoogleCalendar] { try await request("GET", "/api/calendar/google/calendars") }

    func setEventTravel(id: String, travelTimeSec: Int?, mode: String?) async throws -> AgendaItem? {
        struct Body: Encodable {
            let travelTimeSec: Int?
            let mode: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(travelTimeSec, forKey: .travelTimeSec)
                try c.encodeIfPresent(mode, forKey: .mode)
            }
            enum CodingKeys: String, CodingKey { case travelTimeSec, mode }
        }
        struct Reply: Decodable { let event: AgendaItem? }
        let reply: Reply = try await request("PUT", "/api/calendar/events/\(segment(id))/travel", body: Body(travelTimeSec: travelTimeSec, mode: mode))
        return reply.event
    }

    // MARK: Booking

    func bookingTypes() async throws -> [BookingType] { try await request("GET", "/api/booking/types") }

    func createBookingType(_ draft: BookingTypeDraft) async throws -> BookingType {
        try await request("POST", "/api/booking/types", body: draft)
    }

    func updateBookingType(id: String, draft: BookingTypeDraft) async throws -> BookingType {
        try await request("PATCH", "/api/booking/types/\(segment(id))", body: draft)
    }

    func archiveBookingType(id: String) async throws { try await send("DELETE", "/api/booking/types/\(segment(id))") }

    func bookingSlots(typeId: String, from: Date, to: Date) async throws -> [BookingSlot] {
        let path = "/api/booking/types/\(segment(typeId))/slots?from=\(value(NuoJSON.formatDate(from)))&to=\(value(NuoJSON.formatDate(to)))"
        let reply: BookingSlotsReply = try await request("GET", path)
        return reply.slots
    }

    func bookings(all: Bool) async throws -> [Booking] {
        try await request("GET", all ? "/api/booking/bookings?status=all" : "/api/booking/bookings")
    }

    func cancelBooking(id: String, reason: String?) async throws -> Booking {
        struct Body: Encodable { let reason: String? }
        return try await request("POST", "/api/booking/bookings/\(segment(id))/cancel", body: Body(reason: reason))
    }
}
