import SwiftUI

/// Calendars as the gateway knows them, grouped by account: shown or not, full or busy-only, counted for
/// availability, color. Plus the state of this device's bridge.
struct CalendarSettingsView: View {
    @State private var store = CalendarStore.shared
    @State private var bridge = CalendarBridge.shared
    @State private var botAccess = DeviceToolsCenter.shared

    private var groups: [(account: String, calendars: [CalendarInfo])] {
        let grouped = Dictionary(grouping: store.calendars) { $0.account ?? String(localized: "On this device") }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.title < $1.title }) }
    }

    var body: some View {
        GroupedList {
            Section {
                bridgeStatus
                if bridge.access == .full || bridge.isDemo {
                    Button {
                        Task { await bridge.sync(full: true) }
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if bridge.isSyncing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(bridge.isSyncing || bridge.isDemo)
                }
                if !store.writableCalendars.isEmpty {
                    Picker("Default calendar", selection: Binding(get: { bridge.defaultCalendarId }, set: { if let id = $0 { bridge.setDefaultCalendar(id) } })) {
                        ForEach(store.writableCalendars) { calendar in
                            Text(calendar.title).tag(String?.some(calendar.id))
                        }
                    }
                }
                Toggle("Dated reminders in the calendar", isOn: $store.showsReminders)
            } header: {
                Text("This device")
            } footer: {
                Text("The Mac is the main bridge; the iPhone takes over when it is off. Both can sync: the gateway keeps only one copy of each calendar.")
            }
            if bridge.access != .full, !bridge.isDemo {
                Section { CalendarAccessCard().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            }
            Section {
                Toggle("Bot access", isOn: Binding(
                    get: { _ = botAccess.revision; return botAccess.isEnabled(.calendars) },
                    set: { botAccess.setEnabled(.calendars, $0) }))
            } footer: {
                Text("Your bots read, create, edit and delete your events and calendars, iCloud included, through this device when you ask them to.")
            }
            EventAlertSettingsSections()
            ForEach(groups, id: \.account) { group in
                Section(group.account) {
                    ForEach(group.calendars) { calendar in
                        NavigationLink {
                            CalendarDetailSettings(calendarId: calendar.id)
                        } label: {
                            CalendarSettingsRow(calendar: calendar)
                        }
                    }
                }
            }
            if store.calendars.isEmpty, store.loaded {
                Section {
                    Text("No calendar is synced yet. Open Nuo on the Mac (or allow access here) to send them to the gateway.")
                        .font(.footnote).foregroundStyle(Color.text2)
                }
            }
        }
        .navigationTitle("Calendars")
        .task { await store.load() }
    }

    private var bridgeStatus: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: bridge.access == .full || bridge.isDemo ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(bridge.access == .full || bridge.isDemo ? Color.good : Color(hex: 0xF59E0B))
            VStack(alignment: .leading, spacing: 2) {
                Text(bridge.isDemo ? String(localized: "Demo mode") : bridge.access == .full ? String(localized: "Calendar access allowed") : String(localized: "Calendar access required"))
                    .foregroundStyle(Color.ink)
                if let lastSync = bridge.lastSync {
                    Text("Last synced \(lastSync.relativeLabel)").font(.caption).foregroundStyle(Color.text2)
                } else if let error = bridge.lastError {
                    Text(error).font(.caption).foregroundStyle(Color.bad).lineLimit(2)
                }
            }
        }
    }
}

struct CalendarSettingsRow: View {
    let calendar: CalendarInfo

    var body: some View {
        HStack(spacing: Spacing.sm) {
            CalendarDot(color: Color(hexString: calendar.color ?? "") ?? Color.text3, size: 12)
                .opacity(calendar.enabled ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.title).foregroundStyle(calendar.enabled ? Color.ink : Color.text3)
                Text(summary).font(.caption).foregroundStyle(Color.text2)
            }
            Spacer(minLength: 0)
            if calendar.isBusyOnly { Image(systemName: "eye.slash").foregroundStyle(Color.text3).accessibilityLabel("Busy only") }
        }
    }

    private var summary: String {
        if !calendar.enabled { return String(localized: "Hidden, not synced") }
        var parts = [calendar.isBusyOnly ? String(localized: "Busy only") : String(localized: "Everything")]
        if !calendar.countsForAvailability { parts.append(String(localized: "not counted for availability")) }
        if calendar.needsResync == true { parts.append(String(localized: "resync pending")) }
        return parts.joined(separator: " · ")
    }
}

struct CalendarDetailSettings: View {
    let calendarId: String
    @State private var store = CalendarStore.shared

    private static let palette = ["#FF6A2B", "#F43F5E", "#E5484D", "#F59E0B", "#EAB308", "#34A853", "#14B8A6", "#1BADF8", "#3B82F6", "#6366F1", "#A855F7", "#8B8A91"]

    private var calendar: CalendarInfo? { store.calendar(id: calendarId) }

    var body: some View {
        GroupedList {
            if let calendar {
                Section {
                    Toggle("Show and sync", isOn: binding(calendar.enabled, key: "enabled"))
                } footer: {
                    Text("When hidden, its events are no longer sent to the gateway and those already sent are deleted.")
                }
                Section {
                    Picker("Details sent", selection: Binding(get: { calendar.privacy }, set: { value in
                        Task { await store.patchCalendar(calendarId, ["privacy": .string(value.rawValue)]) }
                    })) {
                        Text("Everything").tag(CalendarPrivacy.full)
                        Text("Busy only").tag(CalendarPrivacy.busy)
                    }
                    #if os(iOS)
                    .pickerStyle(.segmented)
                    #endif
                    Toggle("Counts toward my availability", isOn: binding(calendar.countsForAvailability, key: "countsForAvailability"))
                } footer: {
                    Text(calendar.isBusyOnly
                         ? String(localized: "Only the times leave the device: no title, place or attendees. Agents and the calendar see “Busy”.")
                         : String(localized: "Titles, places, notes and attendees are sent to your gateway. Booking pages only ever show free slots."))
                }
                .disabled(!calendar.enabled)
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 6), spacing: Spacing.sm) {
                        ForEach(Self.palette, id: \.self) { hex in
                            Button {
                                Task { await store.patchCalendar(calendarId, ["colorOverride": .string(hex)]) }
                            } label: {
                                Circle()
                                    .fill(Color(hexString: hex) ?? Color.text3)
                                    .frame(width: Spacing.xxl, height: Spacing.xxl)
                                    .overlay {
                                        if calendar.color?.uppercased() == hex {
                                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Color \(hex)")
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    if calendar.colorOverride != nil {
                        Button("Device color") {
                            Task { await store.patchCalendar(calendarId, ["colorOverride": .null]) }
                        }
                    }
                }
                Section("Devices") {
                    ForEach(calendar.sources, id: \.calendarIdentifier) { source in
                        HStack {
                            Image(systemName: (source.deviceName ?? "").localizedCaseInsensitiveContains("mac") ? "laptopcomputer" : "iphone")
                                .foregroundStyle(Color.text2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.deviceName ?? String(localized: "Device")).foregroundStyle(Color.ink)
                                Text(source.syncedAt.map { String(localized: "Synced \($0.relativeLabel)") } ?? String(localized: "Never synced"))
                                    .font(.caption).foregroundStyle(Color.text2)
                            }
                            Spacer()
                            if source.primary == true { Badge(text: String(localized: "Source")) }
                        }
                    }
                }
                Section {
                    LabeledContent("Account", value: calendar.account ?? "—")
                    LabeledContent("Type", value: Self.typeLabel(calendar.type))
                    LabeledContent("Editable", value: calendar.allowsModifications ? String(localized: "Yes") : String(localized: "Read only"))
                }
            }
        }
        .navigationTitle(calendar?.title ?? String(localized: "calendar.name", defaultValue: "Calendar"))
    }

    private func binding(_ value: Bool, key: String) -> Binding<Bool> {
        Binding(get: { value }, set: { newValue in
            Task { await store.patchCalendar(calendarId, [key: .bool(newValue)]) }
        })
    }

    private static func typeLabel(_ type: String?) -> String {
        switch type {
        case "caldav": "CalDAV (iCloud, Google…)"
        case "exchange": "Exchange"
        case "subscription": String(localized: "Subscription")
        case "birthday": String(localized: "Birthdays")
        case "local": "Local"
        default: "—"
        }
    }
}
