import Foundation
import Observation
import SwiftUI

/// Booking types (Openings and Proposals), upcoming bookings and the Google calendars a type may write to.
@MainActor
@Observable
final class BookingStore {
    static let shared = BookingStore()

    private(set) var types: [BookingType] = []
    private(set) var bookings: [Booking] = []
    private(set) var googleCalendars: [GoogleCalendar] = []
    private(set) var loaded = false
    private(set) var isLoading = false
    private(set) var error: String?

    @ObservationIgnored private var api: (any NuoAPI)?

    private enum Keys {
        static let types = "booking.types"
        static let bookings = "booking.bookings"
    }

    func attach(_ api: any NuoAPI) {
        self.api = api
    }

    var openings: [BookingType] { types.filter { $0.kind == .opening } }
    var proposals: [BookingType] { types.filter { $0.kind == .proposal } }

    func type(id: String) -> BookingType? { types.first { $0.id == id } }

    func load() async {
        guard let api else { return }
        if !loaded {
            if let cached = await WorkspaceCache.shared.value([BookingType].self, Keys.types) { types = cached; loaded = true }
            if let cached = await WorkspaceCache.shared.value([Booking].self, Keys.bookings) { bookings = cached }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedTypes = api.bookingTypes()
            async let fetchedBookings = api.bookings(all: false)
            let (newTypes, newBookings) = try await (fetchedTypes, fetchedBookings)
            withAnimation(.snappy) {
                types = newTypes
                bookings = newBookings
            }
            loaded = true
            error = nil
            WorkspaceCache.shared.store(types, Keys.types)
            WorkspaceCache.shared.store(bookings, Keys.bookings)
        } catch {
            self.error = error.localizedDescription
            loaded = true
        }
    }

    func loadGoogleCalendars() async {
        guard let api, googleCalendars.isEmpty else { return }
        googleCalendars = (try? await api.googleCalendars()) ?? []
    }

    func save(_ draft: BookingTypeDraft, id: String?) async throws -> BookingType {
        guard let api else { throw NuoError.offline }
        let saved = if let id { try await api.updateBookingType(id: id, draft: draft) } else { try await api.createBookingType(draft) }
        Haptics.success()
        withAnimation(.snappy) {
            if let index = types.firstIndex(where: { $0.id == saved.id }) { types[index] = saved } else { types.append(saved) }
        }
        WorkspaceCache.shared.store(types, Keys.types)
        return saved
    }

    func setActive(_ type: BookingType, _ active: Bool) async {
        var draft = BookingTypeDraft(type)
        draft.active = active
        _ = try? await save(draft, id: type.id)
    }

    func archive(_ type: BookingType) async {
        guard let api else { return }
        withAnimation(.snappy) { types.removeAll { $0.id == type.id } }
        do {
            try await api.archiveBookingType(id: type.id)
        } catch {
            self.error = error.localizedDescription
            await load()
        }
    }

    /// Cancelling deletes the Google event; the gateway asks for Face ID when its policy says so.
    func cancel(_ booking: Booking, reason: String?) async -> Bool {
        guard let api else { return false }
        do {
            let updated = try await api.cancelBooking(id: booking.id, reason: reason)
            Haptics.success()
            withAnimation(.snappy) { bookings.removeAll { $0.id == updated.id } }
            WorkspaceCache.shared.store(bookings, Keys.bookings)
            CalendarStore.shared.scheduleRefresh()
            return true
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            return false
        }
    }

    func slots(for type: BookingType, days: Int = 14) async -> [BookingSlot] {
        guard let api else { return [] }
        let start = Date()
        return (try? await api.bookingSlots(typeId: type.id, from: start, to: AgendaCalendar.add(days, to: start))) ?? []
    }

    func bookings(of typeId: String) -> [Booking] { bookings.filter { $0.typeId == typeId } }

    /// Slug derived from a title: “30-minute meeting” → `30-minute-meeting`, made unique among types.
    func slug(for title: String, excluding id: String? = nil) -> String {
        let folded = ReminderParser.fold(title)
        var slug = String(folded.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        slug = String(slug.prefix(36))
        if slug.isEmpty { slug = "rdv" }
        let taken = Set(types.filter { $0.id != id }.map(\.slug))
        var candidate = slug
        var counter = 2
        while taken.contains(candidate) {
            candidate = "\(slug)-\(counter)"
            counter += 1
        }
        return candidate
    }
}

enum BookingText {
    static func location(_ location: BookingLocation) -> (label: String, symbol: String) {
        switch location.kind {
        case "google_meet": ("Google Meet", "video")
        case "phone": (location.value.map { String(localized: "Phone · \($0)") } ?? String(localized: "Phone"), "phone")
        case "address": (location.value ?? String(localized: "Address"), "mappin.and.ellipse")
        default: (location.value ?? String(localized: "Custom"), "text.bubble")
        }
    }

    static func notice(_ minutes: Int) -> String {
        if minutes == 0 { return String(localized: "No notice") }
        if minutes % 1440 == 0 { return String(localized: "\(minutes / 1440) days") }
        return AgendaText.duration(TimeInterval(minutes * 60))
    }

    static func status(_ status: String) -> (label: String, color: Color) {
        switch status {
        case "confirmed": (String(localized: "Confirmed"), Color.good)
        case "pending": (String(localized: "In progress"), Color(hex: 0xF59E0B))
        case "cancelled": (String(localized: "Canceled"), Color.text3)
        case "rescheduled": (String(localized: "Rescheduled"), Color.text3)
        case "failed": (String(localized: "Failed"), Color.bad)
        default: (status, Color.text3)
        }
    }

    /// Gateway weekday keys with their position in `Calendar.weekdaySymbols` (Sunday first).
    private static let weekdayKeys: [(key: String, index: Int)] = [
        ("mon", 1), ("tue", 2), ("wed", 3), ("thu", 4), ("fri", 5), ("sat", 6), ("sun", 0),
    ]

    static var weekdays: [(key: String, label: String, short: String)] {
        let calendar = AgendaCalendar.current
        return weekdayKeys.map { day in
            (day.key, AgendaText.capitalized(calendar.weekdaySymbols[day.index]),
             AgendaText.capitalized(calendar.shortWeekdaySymbols[day.index]))
        }
    }

    /// Summary of the weekdays that have working hours.
    static func hours(_ hours: WorkingHours) -> String {
        let open = weekdays.filter { !(hours[$0.key] ?? []).isEmpty }
        guard !open.isEmpty else { return String(localized: "No hours") }
        return open.map(\.short).joined(separator: ", ")
    }
}
