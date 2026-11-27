import EventKit
import MapKit
import SwiftUI

/// Every field of an agenda item, with “Join”, a map, attendees and the EventKit actions (edit, duplicate,
/// delete). A sheet on iPhone, the inspector on the Mac.
struct EventDetailView: View {
    let uid: String
    /// The item as it was when opened, while the store reloads.
    let seed: AgendaItem
    var onClose: (() -> Void)?

    @State private var store = CalendarStore.shared
    @State private var bookings = BookingStore.shared
    @State private var bridge = CalendarBridge.shared
    @State private var editor: EventEditorTarget?
    @State private var confirmDelete = false
    @State private var failure: String?
    @State private var showsAllAttendees = false
    @State private var showsAllNotes = false
    @Environment(\.openURL) private var openURL

    /// Invitations can carry hundreds of attendees and pages of notes: building them all would hold the sheet.
    private static let attendeesShown = 8
    private static let notesShown = 600

    private var item: AgendaItem { store.item(uid: uid) ?? seed }
    private var calendarInfo: CalendarInfo? { store.calendar(id: item.calendarId) }
    private var booking: Booking? {
        let id = item.bookingId ?? (item.kind == .booking ? item.id : nil)
        return id.flatMap { id in bookings.bookings.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                if let conference = item.conference { joinCard(conference) }
                whenSection
                if item.kind == .reminder { reminderSection }
                if let booking { bookingSection(booking) }
                if let location = item.location, !location.isEmpty, item.conference?.absoluteString != location { locationSection(location) }
                if showsLeave { EventLeaveSection(item: item) }
                if let attendees = item.attendees, !attendees.isEmpty { attendeesSection(attendees) }
                if let url = item.url, item.conference?.absoluteString != url, let link = URL(string: url) { linkSection(link) }
                if let notes = item.notes, !notes.isEmpty { notesSection(notes) }
                if item.isBusyOnly { busyOnlyNote }
                if let failure { StaleBanner(message: failure) }
                if bridge.canEdit(item) { actions }
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.canvas)
        .sheet(item: $editor) { target in
            EventEditorView(target: target)
        }
        .confirmationDialog("Delete “\(item.displayTitle)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if item.isRecurring {
                Button("This event only", role: .destructive) { delete(.thisEvent) }
                Button("All following events", role: .destructive) { delete(.futureEvents) }
            } else {
                Button("Delete event", role: .destructive) { delete(.thisEvent) }
            }
        } message: {
            Text(calendarInfo.map { String(localized: "It will be deleted from the “\($0.title)” calendar on all your devices.") } ?? "")
        }
        .task { if bookings.bookings.isEmpty, item.isBooking { await bookings.load() } }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.tint)
                .frame(width: CalendarMetrics.colorBarWidth)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    if item.isBooking { Text(verbatim: "📅").font(.title3) }
                    Text(item.displayTitle)
                        .font(.title2.bold())
                        .foregroundStyle(Color.ink)
                        .strikethrough(item.isCancelled)
                        .textSelection(.enabled)
                }
                HStack(spacing: Spacing.xs) {
                    if let calendarInfo {
                        CalendarDot(color: item.tint, size: 8)
                        Text(calendarInfo.title).font(.subheadline).foregroundStyle(Color.text2)
                        if let account = calendarInfo.account { Text("· \(account)").font(.subheadline).foregroundStyle(Color.text3).lineLimit(1) }
                    } else if item.kind == .reminder {
                        Label(ReminderStyle.listLabel(item.list ?? "inbox"), systemImage: ReminderStyle.symbol(forList: item.list ?? "inbox"))
                            .font(.subheadline).foregroundStyle(Color.text2)
                    } else if item.kind == .booking {
                        Text("Booked through your booking page").font(.subheadline).foregroundStyle(Color.text2)
                    }
                }
                if item.status == "tentative" || item.status == "cancelled" || item.status == "pending" {
                    Badge(text: item.status == "cancelled" ? String(localized: "Canceled") : item.status == "pending" ? String(localized: "Being created") : String(localized: "Tentative"))
                        .padding(.top, Spacing.xxs)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func joinCard(_ url: URL) -> some View {
        Button {
            Haptics.tap()
            openURL(url)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "video.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Join").font(.headline)
                    Text(AgendaText.conferenceName(url.absoluteString)).font(.caption).opacity(0.85)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(CardMetrics.padding)
            .background(Color(hex: 0x1A73E8), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    private var whenSection: some View {
        DetailCard {
            DetailLine(symbol: "calendar", title: dateLine, subtitle: item.allDay ? nil : "\(AgendaText.range(item)) · \(AgendaText.duration(item.duration))")
            if item.isRecurring {
                Divider().overlay(Color.line)
                DetailLine(symbol: "repeat", title: String(localized: "Recurring event"), subtitle: nil)
            }
            if let travel = item.travelTimeSec, travel > 0, let departure = item.departure {
                Divider().overlay(Color.line)
                DetailLine(symbol: item.travelModeLabel?.symbol ?? "car", title: AgendaText.travel(travel),
                           subtitle: ([String(localized: "Leave for \(AgendaText.time(departure))")] + [item.travelModeLabel?.phrase].compactMap { $0 }).joined(separator: " · "))
            }
            if let alerts = alertLine {
                Divider().overlay(Color.line)
                DetailLine(symbol: "bell", title: alerts.title, subtitle: alerts.subtitle)
            }
            if item.kind == .event {
                Divider().overlay(Color.line)
                DetailLine(symbol: item.isFree ? "circle.dashed" : "circle.fill",
                           title: item.isFree ? String(localized: "Free") : item.availability == "tentative" ? String(localized: "Tentative") : String(localized: "Busy"),
                           subtitle: calendarInfo?.countsForAvailability == false ? String(localized: "Doesn't count toward your availability") : nil)
            }
        }
    }

    private var alertLine: (title: String, subtitle: String?)? {
        guard item.kind == .event else { return nil }
        if let alarms = item.alarms, !alarms.isEmpty {
            return (alarms.map { $0.label(start: item.start, allDay: item.allDay) }.joined(separator: ", "), nil)
        }
        if item.hasAlarms == true { return (String(localized: "Alert enabled"), nil) }
        if !item.allDay, let minutes = EventAlertSettings.shared.defaultAlertMinutes, EventAlertSettings.shared.eventsEnabled {
            return (AgendaText.alarm(minutes), String(localized: "Nuo default alert"))
        }
        return nil
    }

    private var showsLeave: Bool {
        item.kind == .event && !item.allDay && !item.isBusyOnly && !item.isCancelled && item.end > Date()
            && EventAlertSettings.shared.leaveEnabled && EventNotifications.hasPhysicalPlace(item)
    }

    private var dateLine: String {
        let first = AgendaText.dayTitle(item.start)
        if item.allDay, item.spansDays, let last = item.days.last { return "\(first) → \(AgendaText.dayTitle(last))" }
        if let subtitle = AgendaText.daySubtitle(item.start) { return "\(first), \(subtitle)" }
        return first
    }

    private var reminderSection: some View {
        DetailCard {
            Button {
                store.toggleReminder(item)
            } label: {
                HStack {
                    ReminderCheckbox(done: item.done == true, priority: item.priority ?? 0) { store.toggleReminder(item) }
                    Text(item.done == true ? String(localized: "Marked done") : String(localized: "Mark as done")).foregroundStyle(Color.ink)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Divider().overlay(Color.line)
            Button {
                onClose?()
                WorkspaceRouter.shared.openReminder(id: item.id)
            } label: {
                DetailLine(symbol: "checklist", title: String(localized: "Open in Reminders"), subtitle: nil, chevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func bookingSection(_ booking: Booking) -> some View {
        DetailCard {
            DetailLine(symbol: "person.crop.circle", title: booking.invitee.name, subtitle: booking.invitee.email)
            if let answers = booking.invitee.answers, !answers.isEmpty {
                Divider().overlay(Color.line)
                ForEach(answers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    DetailLine(symbol: "text.bubble", title: value, subtitle: bookings.type(id: booking.typeId)?.questions.first { $0.id == key }?.label ?? key)
                }
            }
            if let notes = booking.invitee.notes, !notes.isEmpty {
                Divider().overlay(Color.line)
                DetailLine(symbol: "note.text", title: notes, subtitle: String(localized: "Message"))
            }
            if let zone = booking.invitee.timezone, zone != TimeZone.current.identifier {
                Divider().overlay(Color.line)
                DetailLine(symbol: "globe", title: zone.replacingOccurrences(of: "_", with: " "), subtitle: String(localized: "Invitee's time zone"))
            }
        }
    }

    private func locationSection(_ location: String) -> some View {
        DetailCard(padding: 0) {
            if let point = item.coordinates {
                EventMapPreview(point: point, tint: item.tint)
            }
            Button { openInMaps(location) } label: {
                DetailLine(symbol: "mappin.and.ellipse", title: location, subtitle: String(localized: "Open in Maps"), chevron: true)
                    .padding(CardMetrics.padding)
            }
            .buttonStyle(.plain)
        }
    }

    private func attendeesSection(_ attendees: [CalendarAttendee]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader(title: "\(attendees.count) attendees")
            DetailCard {
                let shown = showsAllAttendees ? attendees : Array(attendees.prefix(Self.attendeesShown))
                ForEach(Array(shown.enumerated()), id: \.offset) { index, attendee in
                    let status = AgendaText.attendeeStatus(attendee.status)
                    HStack(spacing: Spacing.sm) {
                        Text(initials(attendee.display))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.text2)
                            .frame(width: Spacing.xxl, height: Spacing.xxl)
                            .background(Color.chip, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: Spacing.xxs) {
                                Text(attendee.display).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                                if attendee.organizer == true { Badge(text: String(localized: "Organizer")) }
                            }
                            if let email = attendee.email, attendee.name != nil {
                                Text(email).font(.caption).foregroundStyle(Color.text3).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: status.symbol).foregroundStyle(status.color).accessibilityLabel(status.label)
                    }
                    if index < shown.count - 1 { Divider().overlay(Color.line) }
                }
                if shown.count < attendees.count {
                    Divider().overlay(Color.line)
                    Button("Show all \(attendees.count) attendees") { showsAllAttendees = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentInk)
                }
            }
        }
    }

    private func linkSection(_ link: URL) -> some View {
        DetailCard {
            Link(destination: link) {
                DetailLine(symbol: "link", title: link.host() ?? link.absoluteString, subtitle: link.absoluteString, chevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader(title: "Notes")
            let truncated = !showsAllNotes && notes.count > Self.notesShown
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(truncated ? String(notes.prefix(Self.notesShown)) + "…" : notes)
                    .font(.callout)
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if truncated {
                    Button("Show more") { showsAllNotes = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentInk)
                }
            }
            .card()
        }
    }

    private var busyOnlyNote: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "eye.slash").foregroundStyle(Color.text2)
            Text("This calendar is in “busy” mode: only the times leave the device, with no title or place.")
                .font(.footnote).foregroundStyle(Color.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CardMetrics.compactPadding)
        .background {
            HatchPattern(color: Color.text3.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                editor = EventEditorTarget(item: item, draft: EventDraft(item))
            } label: { Label("Edit", systemImage: "pencil") }
                .buttonStyle(InkButtonStyle())
            Button {
                var copy = EventDraft(item)
                copy.title = item.title ?? ""
                editor = EventEditorTarget(item: nil, draft: copy)
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .buttonStyle(InkButtonStyle(prominent: false))
            Button(role: .destructive) { confirmDelete = true } label: {
                Image(systemName: "trash").accessibilityLabel("Delete")
            }
            .buttonStyle(InkButtonStyle(prominent: false, destructive: true))
            .frame(width: Spacing.xxl * 2)
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: Actions

    private func delete(_ span: EKSpan) {
        Task {
            do {
                try await bridge.delete(item, span: span)
                onClose?()
            } catch {
                Haptics.error()
                failure = error.localizedDescription
            }
        }
    }

    private func openInMaps(_ location: String) {
        var components = URLComponents(string: "https://maps.apple.com/")!
        if let point = item.coordinates {
            components.queryItems = [URLQueryItem(name: "ll", value: "\(point.lat),\(point.lon)"), URLQueryItem(name: "q", value: location)]
        } else {
            components.queryItems = [URLQueryItem(name: "q", value: location)]
        }
        if let url = components.url { openURL(url) }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct DetailCard<Content: View>: View {
    var padding: CGFloat = CardMetrics.padding
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.line))
    }
}

struct DetailLine: View {
    let symbol: String
    let title: String
    let subtitle: String?
    var chevron = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Color.text2)
                .frame(width: Spacing.xl)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Color.text2).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3).padding(.top, Spacing.xxs) }
        }
        .contentShape(Rectangle())
    }
}

/// A still of the event's place. A live `Map` builds its renderer on the main thread while the sheet slides in
/// (a few hundred ms the first time); the snapshot renders off it and is kept for the next opening.
struct EventMapPreview: View {
    let point: GeoPoint
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: PlatformImage?

    var body: some View {
        let dark = colorScheme == .dark
        // The still is an overlay so its own width never widens the card: the card sizes it.
        Color.chip
            .frame(height: CalendarMetrics.mapPreviewHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = MapSnapshots.shared.cached(point, dark: dark) ?? image {
                    Image(platformImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, tint)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: "\(point.lat),\(point.lon),\(dark)") {
                guard MapSnapshots.shared.cached(point, dark: dark) == nil else { return }
                let snapshot = await MapSnapshots.shared.image(point, dark: dark)
                withAnimation(.easeOut(duration: 0.2)) { image = snapshot }
            }
    }
}

@MainActor
final class MapSnapshots {
    static let shared = MapSnapshots()

    private struct Still: @unchecked Sendable {
        let image: PlatformImage
    }

    private var images: [String: PlatformImage] = [:]
    private var running: [String: Task<PlatformImage?, Never>] = [:]

    private static func key(_ point: GeoPoint, dark: Bool) -> String {
        String(format: "%.5f,%.5f,%d", point.lat, point.lon, dark ? 1 : 0)
    }

    func cached(_ point: GeoPoint, dark: Bool) -> PlatformImage? { images[Self.key(point, dark: dark)] }

    func image(_ point: GeoPoint, dark: Bool) async -> PlatformImage? {
        let key = Self.key(point, dark: dark)
        if let image = images[key] { return image }
        if let task = running[key] { return await task.value }
        let height = CalendarMetrics.mapPreviewHeight
        // Setting up the snapshotter is heavy on first use: keep all of it off the main thread.
        let task = Task<PlatformImage?, Never> {
            await Task.detached(priority: .userInitiated) { () -> Still? in
                let options = MKMapSnapshotter.Options()
                options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
                                                    latitudinalMeters: 900, longitudinalMeters: 900)
                // Wide enough for an iPhone card or the Mac inspector; the view crops it around the centre.
                options.size = CGSize(width: 520, height: height)
                #if canImport(UIKit)
                options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
                #else
                options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                #endif
                guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
                return Still(image: snapshot.image)
            }.value?.image
        }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image {
            if images.count > 40 { images.removeAll() }
            images[key] = image
        }
        return image
    }
}
