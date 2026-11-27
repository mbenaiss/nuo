import SwiftUI

/// Propose times: pick a few free times from the agenda, get a link that books one of them.
struct ProposalFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var calendarStore = CalendarStore.shared
    @State private var store = BookingStore.shared
    @State private var duration = 30
    @State private var selected: Set<Date> = []
    @State private var title = ""
    @State private var locationKind = "google_meet"
    @State private var locationValue = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var created: BookingType?

    private static let days = 14
    private static let dayStartHour = 9
    private static let dayEndHour = 19
    private static let noticeMinutes = 120
    private static let maxSlots = 50

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    BookingShareView(type: created, embedded: true)
                } else {
                    form
                }
            }
            .navigationTitle("Propose Times")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 720)
        #endif
    }

    private var form: some View {
        GroupedList {
            Section {
                TextField("Title (“Website redesign check-in”)", text: $title).font(.headline)
                Picker("Duration", selection: $duration) {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text(AgendaText.duration(Double($0) * 60)).tag($0) }
                }
                Picker("Meeting place", selection: $locationKind) {
                    Text("Google Meet").tag("google_meet")
                    Text("Phone").tag("phone")
                    Text("Address").tag("address")
                }
                if locationKind != "google_meet" {
                    TextField(locationKind == "phone" ? String(localized: "Number") : String(localized: "Address"), text: $locationValue)
                }
            }
            ForEach(freeSlotsByDay, id: \.day) { group in
                Section {
                    WrapLayout(spacing: Spacing.xs) {
                        ForEach(group.slots, id: \.self) { start in slotChip(start) }
                    }
                    .padding(.vertical, Spacing.xxs)
                } header: {
                    Text(AgendaText.dayTitle(group.day))
                }
            }
            if freeSlotsByDay.isEmpty {
                Section { Text("No free slots in the next two weeks.").font(.footnote).foregroundStyle(Color.text2) }
            }
            if let failure {
                Section { Text(failure).font(.footnote).foregroundStyle(Color.bad) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: create) {
                Text(selected.isEmpty ? String(localized: "Choose slots") : String(localized: "Create link · \(selected.count) slots"))
            }
            .buttonStyle(InkButtonStyle())
            .disabled(selected.isEmpty || saving)
            .opacity(selected.isEmpty ? 0.45 : 1)
            .padding(.horizontal, Spacing.gutter)
            .padding(.bottom, Spacing.xs)
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onChange(of: duration) { _, _ in selected = selected.filter { start in freeSlotsByDay.contains { $0.slots.contains(start) } } }
    }

    private func slotChip(_ start: Date) -> some View {
        let on = selected.contains(start)
        return Button {
            Haptics.selection()
            if on { selected.remove(start) } else if selected.count < Self.maxSlots { selected.insert(start) }
        } label: {
            Text(AgendaText.time(start))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(on ? Color.onInk : Color.ink)
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: Spacing.xxl + Spacing.xxs)
                .background(on ? Color.inkFill : Color.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Free half hours between 9:00 and 19:00 on weekdays, against events of calendars that count for availability.
    private var freeSlotsByDay: [(day: Date, slots: [Date])] {
        let calendar = AgendaCalendar.current
        let earliest = Date().addingTimeInterval(Double(Self.noticeMinutes) * 60)
        let counting = Set(calendarStore.calendars.filter(\.countsForAvailability).map(\.id))
        let length = Double(duration) * 60
        return AgendaCalendar.days(from: Date(), count: Self.days).compactMap { day in
            guard !calendar.isDateInWeekend(day) else { return nil }
            let busy = calendarStore.items(on: day).filter { item in
                item.kind == .event && !item.allDay && !item.isFree && !item.isCancelled && (item.calendarId.map(counting.contains) ?? true)
            }
            var slots: [Date] = []
            var start = calendar.date(bySettingHour: Self.dayStartHour, minute: 0, second: 0, of: day) ?? day
            let close = calendar.date(bySettingHour: Self.dayEndHour, minute: 0, second: 0, of: day) ?? day
            while start.addingTimeInterval(length) <= close {
                let end = start.addingTimeInterval(length)
                if start >= earliest, !busy.contains(where: { $0.start < end && $0.end > start }) { slots.append(start) }
                start = start.addingTimeInterval(30 * 60)
            }
            return slots.isEmpty ? nil : (day, slots)
        }
    }

    private func create() {
        saving = true
        failure = nil
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Appointment proposal") : title.trimmingCharacters(in: .whitespaces)
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let draft = BookingTypeDraft(
            slug: "\(store.slug(for: name).prefix(30))-\(suffix)", kind: .proposal, title: name, description: nil, durationMin: duration,
            location: BookingLocation(kind: locationKind, value: locationKind == "google_meet" || locationValue.isEmpty ? nil : locationValue),
            workingHours: Dictionary(uniqueKeysWithValues: BookingText.weekdays.map { ($0.key, []) }),
            bufferBeforeMin: 0, bufferAfterMin: 0, minNoticeMin: 60, maxDaysAhead: Self.days + 1, maxPerDay: nil, slotStepMin: nil,
            googleCalendar: nil, questions: [],
            candidateSlots: selected.sorted().map { BookingSlot(start: $0, end: $0.addingTimeInterval(Double(duration) * 60)) }, active: true)
        Task {
            do {
                let type = try await store.save(draft, id: nil)
                withAnimation(.snappy) { created = type }
            } catch {
                Haptics.error()
                failure = error.localizedDescription
                saving = false
            }
        }
    }
}
