import EventKit
import SwiftUI

struct EventEditorTarget: Identifiable {
    let id = UUID()
    /// nil for a new event.
    let item: AgendaItem?
    var draft: EventDraft
}

/// New or existing event, written through EventKit on this device (any writable calendar); with guests or a
/// Meet link it is created in Google, which sends the invitations.
struct EventEditorView: View {
    let target: EventEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventDraft
    @State private var guests = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var askSpan = false
    @State private var store = CalendarStore.shared
    @FocusState private var titleFocused: Bool

    init(target: EventEditorTarget) {
        self.target = target
        var draft = target.draft
        if draft.calendarId == nil { draft.calendarId = CalendarBridge.shared.defaultCalendarId }
        _draft = State(initialValue: draft)
        _guests = State(initialValue: target.draft.attendees.joined(separator: ", "))
    }

    private var isNew: Bool { target.item == nil }
    private var guestList: [String] {
        guests.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") && $0.contains(".") }
    }
    private var viaGoogle: Bool { isNew && (!guestList.isEmpty || draft.meet) }

    var body: some View {
        NavigationStack {
            GroupedList {
                Section {
                    TextField("Title", text: $draft.title)
                        .font(.headline)
                        .focused($titleFocused)
                    TextField("Location or video link", text: Binding(get: { draft.location ?? "" }, set: { draft.location = $0.isEmpty ? nil : $0 }))
                }
                Section {
                    Toggle("All day", isOn: allDayBinding)
                    DatePicker("Starts", selection: startBinding, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: endBinding, in: draft.start..., displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    if isNew || target.item?.isRecurring == false {
                        Picker("Repeats", selection: $draft.recurrence) {
                            Text("Never").tag(EventRecurrence?.none)
                            Text("Every day").tag(EventRecurrence?.some(.daily))
                            Text("Weekdays").tag(EventRecurrence?.some(.weekdays))
                            Text("Every week").tag(EventRecurrence?.some(.weekly([AgendaCalendar.current.component(.weekday, from: draft.start) - 1])))
                            Text("Every month").tag(EventRecurrence?.some(.monthly))
                            Text("Every year").tag(EventRecurrence?.some(.yearly))
                        }
                    }
                }
                Section {
                    if !viaGoogle {
                        CalendarPicker(selection: $draft.calendarId)
                    }
                    Picker("Alert", selection: $draft.alarmMinutes) {
                        Text("No alert set").tag(Int?.none)
                        ForEach([0, 5, 10, 15, 30, 60, 120, 1440], id: \.self) { minutes in
                            Text(AgendaText.alarm(minutes)).tag(Int?.some(minutes))
                        }
                    }
                    Picker("Availability", selection: $draft.free) {
                        Text("Busy").tag(false)
                        Text("Free").tag(true)
                    }
                }
                if isNew {
                    Section {
                        TextField("Guests (email addresses)", text: $guests)
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        Toggle("Google Meet link", isOn: $draft.meet)
                    } footer: {
                        Text(viaGoogle
                             ? String(localized: "Created in your Google Calendar, which sends the invitations. It will show up here after the next sync.")
                             : String(localized: "With guests or a Meet link, the event is created in Google so it can send the invitations."))
                    }
                }
                Section {
                    TextField("URL", text: Binding(get: { draft.url ?? "" }, set: { draft.url = $0.isEmpty ? nil : $0 }))
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .lineLimit(3...8)
                }
                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(Color.bad) }
                }
            }
            .navigationTitle(isNew ? String(localized: "New Event") : String(localized: "Edit"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? String(localized: "Add") : String(localized: "Save")) {
                        if target.item?.isRecurring == true { askSpan = true } else { save(.thisEvent) }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .confirmationDialog("Recurring event", isPresented: $askSpan, titleVisibility: .visible) {
                Button("This event only") { save(.thisEvent) }
                Button("All following events") { save(.futureEvents) }
            }
            .onAppear { if isNew && draft.title.isEmpty { titleFocused = true } }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 560, idealHeight: 640)
        #endif
    }

    private var allDayBinding: Binding<Bool> {
        Binding(get: { draft.allDay }, set: { allDay in
            let calendar = AgendaCalendar.current
            draft.allDay = allDay
            if allDay {
                draft.start = calendar.startOfDay(for: draft.start)
                draft.end = max(calendar.date(byAdding: .day, value: 1, to: draft.start)!, calendar.startOfDay(for: draft.end))
            } else {
                draft.start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start) ?? draft.start
                draft.end = draft.start.addingTimeInterval(Double(CalendarMetrics.defaultDurationMinutes) * 60)
            }
        })
    }

    /// Moving the start keeps the duration, like Calendar, and a weekly repetition follows it to its new weekday.
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { start in
            let calendar = AgendaCalendar.current
            if case let .weekly(days) = draft.recurrence {
                draft.recurrence = .weekly(WallClock.weekdays(days, movingFrom: draft.start, to: start, calendar: calendar))
            }
            draft.end = WallClock.end(keeping: draft.start, draft.end, newStart: start, allDay: draft.allDay, minimum: 900, calendar: calendar)
            draft.start = start
        })
    }

    /// An all-day end is shown inclusive and stored exclusive.
    private var endBinding: Binding<Date> {
        let calendar = AgendaCalendar.current
        return Binding(get: { draft.allDay ? WallClock.inclusiveDay(fromExclusiveEnd: draft.end, calendar: calendar) : draft.end },
                       set: { draft.end = draft.allDay ? WallClock.exclusiveEnd(fromInclusiveDay: $0, calendar: calendar) : $0 })
    }

    private func save(_ span: EKSpan) {
        saving = true
        failure = nil
        var final = draft
        final.title = draft.title.trimmingCharacters(in: .whitespaces)
        final.attendees = isNew ? guestList : []
        final.meet = isNew && draft.meet
        Task {
            do {
                if let item = target.item {
                    try await CalendarBridge.shared.update(item, with: final, span: span)
                } else {
                    try await CalendarBridge.shared.create(final)
                }
                dismiss()
            } catch {
                Haptics.error()
                failure = error.localizedDescription
                saving = false
            }
        }
    }
}
