import SwiftUI
import UserNotifications

/// “Notifications” and “Leave now” sections of the calendar settings (iPhone and Mac).
struct EventAlertSettingsSections: View {
    @State private var settings = EventAlertSettings.shared
    @State private var places = PlacesStore.shared
    @State private var status: UNAuthorizationStatus?
    @State private var showsPlaces = false

    private var origin: Place? { settings.defaultOrigin(in: places.places) }

    var body: some View {
        notificationsSection
            .task { await readStatus() }
            .sheet(isPresented: $showsPlaces) { PlacesView() }
        leaveSection
        #if DEBUG
        Section {
            Button("Test an alert and a departure") {
                Task { await EventNotifications.fireSamples() }
            }
        } footer: {
            Text("Debug: both notifications arrive in 3 and 6 seconds.")
        }
        #endif
    }

    private var notificationsSection: some View {
        Section {
            if status == .notDetermined {
                Button("Allow notifications") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        await readStatus()
                        EventNotifications.scheduleRefresh(after: .zero)
                    }
                }
            } else if status == .denied {
                Text("Nuo notifications are turned off in Settings.").font(.footnote).foregroundStyle(Color.bad)
            }
            Toggle("Event notifications", isOn: $settings.eventsEnabled)
            Picker("Default alert", selection: $settings.defaultAlertMinutes) {
                Text("No alert set").tag(Int?.none)
                ForEach(EventAlertSettings.defaultAlertChoices, id: \.self) { minutes in
                    Text("\(minutes) min before").tag(Int?.some(minutes))
                }
            }
            .disabled(!settings.eventsEnabled)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Alerts for your events, and the default alert for those that have none. To avoid duplicates, turn off notifications of the Calendar app in Settings.")
        }
    }

    private var leaveSection: some View {
        Section {
            Toggle("Leave now", isOn: $settings.leaveEnabled)
            Group {
                Picker("Leave from", selection: Binding(get: { origin?.id }, set: { settings.originPlaceId = $0 })) {
                    if origin == nil { Text("To choose").tag(String?.none) }
                    ForEach(places.places) { place in
                        Text(place.name).tag(String?.some(place.id))
                    }
                }
                Picker("Travel mode", selection: $settings.mode) {
                    ForEach(TravelMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                Picker("Margin", selection: $settings.marginMinutes) {
                    ForEach(EventAlertSettings.marginChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? String(localized: "No margin") : String(localized: "\(minutes) min")).tag(minutes)
                    }
                }
                Button("Manage my places") { showsPlaces = true }
            }
            .disabled(!settings.leaveEnabled)
        } footer: {
            Text(origin == nil && settings.leaveEnabled
                 ? String(localized: "Add a place called “Home” or choose your starting point to get “Leave now”.")
                 : String(localized: "For events with a place: travel time computed with Maps from the chosen place (never from your location), traffic included."))
        }
    }

    private func readStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// “Leave now” of one event in its detail: the travel line, the origin and an off switch.
struct EventLeaveSection: View {
    let item: AgendaItem
    @State private var settings = EventAlertSettings.shared
    @State private var places = PlacesStore.shared

    private var override: LeaveOverride { settings.override(for: item) ?? LeaveOverride() }
    private var origin: Place? { settings.origin(for: item, in: places.places) }

    var body: some View {
        DetailCard {
            Toggle(isOn: Binding(get: { !override.disabled }, set: { enabled in
                var next = override
                next.disabled = !enabled
                settings.setOverride(next, for: item)
                if !enabled { Task { await CalendarStore.shared.storeTravel(item, seconds: nil, mode: nil) } }
            })) {
                Label("Leave now", systemImage: "figure.walk.departure")
            }
            .tint(Color.accent)
            if !override.disabled {
                Divider().overlay(Color.line)
                HStack {
                    Label("Leave from", systemImage: "house").foregroundStyle(Color.ink)
                    Spacer(minLength: Spacing.sm)
                    Menu {
                        Button(settings.defaultOrigin(in: places.places).map { String(localized: "Default (\($0.name))") } ?? String(localized: "Default")) {
                            var next = override
                            next.originPlaceId = nil
                            settings.setOverride(next, for: item)
                        }
                        ForEach(places.places) { place in
                            Button(place.name) {
                                var next = override
                                next.originPlaceId = place.id
                                settings.setOverride(next, for: item)
                            }
                        }
                    } label: {
                        Text(origin?.name ?? String(localized: "To choose")).foregroundStyle(Color.accentInk)
                    }
                    .fixedSize()
                }
            }
        }
    }
}

extension AgendaItem {
    /// “Leave for 1:30 PM”: start − travel − the “Leave now” margin.
    @MainActor var departure: Date? {
        guard let travel = travelTimeSec, travel > 0, !allDay else { return nil }
        return start.addingTimeInterval(-TimeInterval(travel) - EventAlertSettings.shared.margin)
    }

    var travelModeLabel: TravelMode? { travelMode.flatMap(TravelMode.init(rawValue:)) }
}

extension EventAlarm {
    /// “15 min before”, “The day before at 9:00 AM”, “Thu 9:00 AM”.
    func label(start: Date, allDay: Bool) -> String {
        if let offsetSec, !allDay {
            if offsetSec == 0 { return String(localized: "At time of event") }
            let minutes = abs(offsetSec) / 60
            return offsetSec < 0 ? AgendaText.alarm(minutes) : String(localized: "\(AgendaText.duration(TimeInterval(minutes * 60))) after")
        }
        guard let date = fireDate(start: start) else { return String(localized: "Alert") }
        let calendar = AgendaCalendar.current
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: start), calendar.isDate(date, inSameDayAs: dayBefore) {
            return String(localized: "The day before at \(AgendaText.time(date))")
        }
        if calendar.isDate(date, inSameDayAs: start) { return String(localized: "The same day at \(AgendaText.time(date))") }
        return "\(AgendaText.shortDay(date)) \(AgendaText.time(date))"
    }
}
