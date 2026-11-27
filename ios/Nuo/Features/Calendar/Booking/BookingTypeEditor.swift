import SwiftUI

/// Create or edit a booking page: duration, weekly hours (Paris time), buffers, notice, horizon, daily cap,
/// slot step, target Google calendar, location, extra questions, on/off.
struct BookingTypeEditor: View {
    let original: BookingType?
    @Environment(\.dismiss) private var dismiss
    @State private var store = BookingStore.shared
    @State private var draft: BookingTypeDraft
    @State private var hours: [String: [HourRange]]
    @State private var slugEdited: Bool
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmArchive = false

    struct HourRange: Identifiable, Equatable {
        let id = UUID()
        var start: Date
        var end: Date
    }

    init(original: BookingType?) {
        self.original = original
        let base = original.map(BookingTypeDraft.init) ?? BookingTypeDraft(
            slug: "", kind: .opening, title: "", description: nil, durationMin: 30, location: BookingLocation(kind: "google_meet"),
            workingHours: Dictionary(uniqueKeysWithValues: BookingText.weekdays.map { day in
                (day.key, ["sat", "sun"].contains(day.key) ? [] : [["09:30", "12:00"], ["14:00", "18:00"]])
            }),
            bufferBeforeMin: 0, bufferAfterMin: 10, minNoticeMin: 240, maxDaysAhead: 60, maxPerDay: nil, slotStepMin: nil,
            googleCalendar: nil, questions: [], candidateSlots: nil, active: true)
        _draft = State(initialValue: base)
        _hours = State(initialValue: base.workingHours.mapValues { ranges in
            ranges.compactMap { range in
                guard range.count == 2, let start = Self.time(range[0]), let end = Self.time(range[1]) else { return nil }
                return HourRange(start: start, end: end)
            }
        })
        _slugEdited = State(initialValue: original != nil)
    }

    private static func time(_ text: String) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return AgendaCalendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date(timeIntervalSinceReferenceDate: 0))
    }

    private static func text(_ date: Date) -> String {
        let parts = AgendaCalendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private var baseURL: String {
        let url = store.types.compactMap(\.url).first ?? "https://rdv…/x"
        return String(url[..<(url.lastIndex(of: "/") ?? url.endIndex)]).replacingOccurrences(of: "https://", with: "") + "/"
    }

    var body: some View {
        NavigationStack {
            GroupedList {
                Section {
                    TextField("Title (“30-minute meeting”)", text: $draft.title)
                        .font(.headline)
                        .onChange(of: draft.title) { _, title in
                            if !slugEdited { draft.slug = store.slug(for: title, excluding: original?.id) }
                        }
                    HStack(spacing: 0) {
                        Text(baseURL).foregroundStyle(Color.text3).lineLimit(1)
                        TextField("link", text: Binding(get: { draft.slug }, set: { draft.slug = $0.lowercased(); slugEdited = true }))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    .font(.callout.monospaced())
                    TextField("Description (optional)", text: Binding(get: { draft.description ?? "" }, set: { draft.description = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Active page", isOn: $draft.active)
                }
                Section("Appointment") {
                    Picker("Duration", selection: $draft.durationMin) {
                        ForEach([15, 20, 30, 45, 60, 90, 120], id: \.self) { Text(AgendaText.duration(Double($0) * 60)).tag($0) }
                    }
                    Picker("Meeting place", selection: $draft.location.kind) {
                        Label("Google Meet", systemImage: "video").tag("google_meet")
                        Label("Phone", systemImage: "phone").tag("phone")
                        Label("Address", systemImage: "mappin.and.ellipse").tag("address")
                        Label("Custom", systemImage: "text.bubble").tag("custom")
                    }
                    if draft.location.kind != "google_meet" {
                        TextField(draft.location.kind == "phone" ? String(localized: "Number") : draft.location.kind == "address" ? String(localized: "Address") : String(localized: "Details"),
                                  text: Binding(get: { draft.location.value ?? "" }, set: { draft.location.value = $0.isEmpty ? nil : $0 }))
                    }
                    Picker("Google Calendar", selection: $draft.googleCalendar) {
                        Text("Default").tag(String?.none)
                        ForEach(store.googleCalendars) { calendar in
                            Text(calendar.label).tag(String?.some(calendar.target))
                        }
                    }
                }
                Section {
                    ForEach(BookingText.weekdays, id: \.key) { day in
                        dayRow(day.key, label: day.label)
                    }
                } header: {
                    Text("Hours (Paris time)")
                }
                Section("Rules") {
                    Stepper("Buffer before: \(draft.bufferBeforeMin) min", value: $draft.bufferBeforeMin, in: 0...120, step: 5)
                    Stepper("Buffer after: \(draft.bufferAfterMin) min", value: $draft.bufferAfterMin, in: 0...120, step: 5)
                    Picker("Minimum notice", selection: $draft.minNoticeMin) {
                        ForEach([0, 60, 120, 240, 720, 1440, 2880], id: \.self) { Text(BookingText.notice($0)).tag($0) }
                    }
                    Stepper("Up to \(draft.maxDaysAhead) days ahead", value: $draft.maxDaysAhead, in: 1...365, step: draft.maxDaysAhead < 14 ? 1 : 7)
                    Toggle("Limit per day", isOn: Binding(get: { draft.maxPerDay != nil }, set: { draft.maxPerDay = $0 ? 3 : nil }))
                    if let max = draft.maxPerDay {
                        Stepper("At most \(max) bookings per day", value: Binding(get: { max }, set: { draft.maxPerDay = $0 }), in: 1...20)
                    }
                    Picker("Slots every", selection: $draft.slotStepMin) {
                        Text("Appointment length").tag(Int?.none)
                        ForEach([15, 30, 60], id: \.self) { Text("\($0) min").tag(Int?.some($0)) }
                    }
                }
                Section {
                    ForEach($draft.questions) { $question in
                        questionEditor($question)
                    }
                    .onDelete { draft.questions.remove(atOffsets: $0) }
                    if draft.questions.count < 10 {
                        Button { addQuestion() } label: { Label("Add a question", systemImage: "plus.circle") }
                    }
                } header: {
                    Text("Questions")
                } footer: {
                    Text("Name and email are always asked.")
                }
                if let failure {
                    Section { Text(failure).font(.footnote).foregroundStyle(Color.bad) }
                }
                if let original {
                    Section {
                        Button("Archive this page", role: .destructive) { confirmArchive = true }
                    } footer: {
                        Text("The link stops working; bookings already made are kept.")
                    }
                    .confirmationDialog("Archive “\(original.title)”?", isPresented: $confirmArchive) {
                        Button("Archive", role: .destructive) {
                            Task {
                                await store.archive(original)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(original == nil ? String(localized: "New Page") : draft.kind == .proposal ? String(localized: "Proposal") : String(localized: "Edit Page"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? String(localized: "Create") : String(localized: "Save"), action: save)
                        .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || draft.slug.isEmpty || saving)
                }
            }
            .task { await store.loadGoogleCalendars() }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 640, idealHeight: 760)
        #endif
    }

    @ViewBuilder
    private func dayRow(_ key: String, label: String) -> some View {
        let ranges = hours[key] ?? []
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(label, isOn: Binding(get: { !ranges.isEmpty }, set: { open in
                hours[key] = open ? [HourRange(start: Self.time("09:30")!, end: Self.time("12:00")!), HourRange(start: Self.time("14:00")!, end: Self.time("18:00")!)] : []
            }))
            ForEach(Array(ranges.enumerated()), id: \.element.id) { index, range in
                HStack(spacing: Spacing.xs) {
                    DatePicker("From", selection: rangeBinding(key, index, \.start), displayedComponents: .hourAndMinute).labelsHidden()
                    Text("–").foregroundStyle(Color.text3)
                    DatePicker("To", selection: rangeBinding(key, index, \.end), displayedComponents: .hourAndMinute).labelsHidden()
                    Spacer()
                    Button {
                        hours[key]?.remove(at: index)
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Color.text3) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove range")
                    // Kept on every row (hidden but the last) so the minus buttons line up.
                    Button {
                        let start = range.end.addingTimeInterval(3600)
                        hours[key]?.append(HourRange(start: start, end: start.addingTimeInterval(7200)))
                    } label: { Image(systemName: "plus.circle.fill").foregroundStyle(Color.accent) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add range")
                        .opacity(index == ranges.count - 1 ? 1 : 0)
                        .disabled(index != ranges.count - 1)
                }
                .padding(.leading, Spacing.md)
            }
        }
    }

    private func rangeBinding(_ key: String, _ index: Int, _ path: WritableKeyPath<HourRange, Date>) -> Binding<Date> {
        Binding(get: { hours[key]?[safe: index]?[keyPath: path] ?? Date() }, set: { value in
            guard hours[key]?.indices.contains(index) == true else { return }
            hours[key]?[index][keyPath: path] = value
        })
    }

    private func questionEditor(_ question: Binding<BookingQuestion>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField("Question", text: question.label)
            HStack {
                Picker("Type", selection: question.type) {
                    Text("Text").tag("text")
                    Text("Long text").tag("longtext")
                    Text("Phone").tag("phone")
                    Text("Choice").tag("select")
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Toggle("Required", isOn: question.required).fixedSize()
            }
            if question.wrappedValue.type == "select" {
                TextField("Choices separated by commas", text: Binding(
                    get: { question.wrappedValue.options?.joined(separator: ", ") ?? "" },
                    set: { question.wrappedValue.options = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .font(.callout)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    private func addQuestion() {
        var index = draft.questions.count + 1
        while draft.questions.contains(where: { $0.id == "question_\(index)" }) { index += 1 }
        draft.questions.append(BookingQuestion(id: "question_\(index)", label: "", type: "text", required: false))
    }

    private func save() {
        saving = true
        failure = nil
        var final = draft
        final.title = draft.title.trimmingCharacters(in: .whitespaces)
        final.workingHours = Dictionary(uniqueKeysWithValues: BookingText.weekdays.map { day in
            (day.key, (hours[day.key] ?? []).sorted { $0.start < $1.start }.map { [Self.text($0.start), Self.text($0.end)] })
        })
        final.questions = draft.questions.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }.map { question in
            var copy = question
            if copy.type != "select" { copy.options = nil }
            return copy
        }
        Task {
            do {
                _ = try await store.save(final, id: original?.id)
                dismiss()
            } catch {
                Haptics.error()
                failure = error.localizedDescription
                saving = false
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
