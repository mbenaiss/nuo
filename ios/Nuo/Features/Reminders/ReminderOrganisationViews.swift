import SwiftUI

/// Things-like project progress: a ring holding a pie that fills as reminders get done.
struct ProjectProgressRing: View {
    var progress: Double
    var size: CGFloat = 18
    var tint: Color = ProjectProgressRing.defaultTint
    var finished = false

    static let defaultTint = Color(hex: 0x3B82F6)

    var body: some View {
        ZStack {
            if finished {
                Circle().fill(tint)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(tint, lineWidth: max(1.5, size * 0.09))
                ProgressPie(progress: min(max(progress, 0), 1))
                    .fill(tint)
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .animation(.snappy(duration: 0.35), value: progress)
        .accessibilityLabel(finished ? String(localized: "Completed") : String(localized: "\(Int((progress * 100).rounded())) % completed"))
    }
}

private struct ProgressPie: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * progress), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Where a reminder is filed, as the store and the editor speak of it.
enum ReminderFiling {
    static func destination(of reminder: Reminder) -> ReminderDestination {
        if let project = reminder.projectId { return .project(project, heading: reminder.headingId) }
        if let area = reminder.areaId { return .area(area) }
        return .inbox
    }

    /// « 🇯🇵 Voyage au Japon › Avant le départ », « 🏠 Maison », « Boîte de réception ».
    @MainActor static func label(_ destination: ReminderDestination, store: RemindersStore) -> String {
        switch destination {
        case .inbox:
            return ReminderBucket.inbox.label
        case let .area(id):
            return store.area(id: id).map { titled($0.emoji, $0.title) } ?? String(localized: "Area")
        case let .project(id, heading):
            let project = store.project(id: id).map { titled($0.emoji, $0.title) } ?? String(localized: "Project")
            guard let heading, let title = store.headings(ofProject: id).first(where: { $0.id == heading })?.title else { return project }
            return "\(project) › \(title)"
        }
    }

    static func titled(_ emoji: String?, _ title: String) -> String {
        guard let emoji, !emoji.isEmpty else { return title }
        return "\(emoji) \(title)"
    }

    /// The patch that files a reminder there; a heading alone implies its project.
    static func patch(_ destination: ReminderDestination) -> [String: JSONValue] {
        switch destination {
        case .inbox: ["projectId": .null, "areaId": .null]
        case let .area(id): ["areaId": .string(id)]
        case let .project(id, heading): heading.map { ["headingId": .string($0)] } ?? ["projectId": .string(id), "headingId": .null]
        }
    }

    static func apply(_ destination: ReminderDestination, to draft: inout ReminderDraft) {
        switch destination {
        case .inbox: break
        case let .area(id): draft.areaId = id
        case let .project(id, heading):
            draft.projectId = id
            draft.headingId = heading
        }
    }
}

/// « Déplacer vers » : the inbox, then each area with its open projects and their headings.
struct ReminderDestinationPicker: View {
    let selection: ReminderDestination
    let onPick: (ReminderDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var store = RemindersStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.inbox, title: ReminderBucket.inbox.label, icon: .symbol(ReminderBucket.inbox.symbol), level: 0)
                }
                let loose = store.openProjects(in: nil)
                if !loose.isEmpty {
                    Section("Projects") {
                        ForEach(loose) { projectRows($0) }
                    }
                }
                ForEach(store.sortedAreas) { area in
                    Section {
                        row(.area(area.id), title: area.title, icon: .emoji(area.emoji, fallback: "square.stack"), level: 0, bold: true)
                        ForEach(store.openProjects(in: area.id)) { projectRows($0) }
                    }
                }
            }
            .navigationTitle("Move To")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .task {
                // Headings only come with a project's detail; fetch those not loaded yet.
                for project in store.projects where project.isOpen && store.headings[project.id] == nil {
                    await store.loadProject(project.id)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }

    @ViewBuilder
    private func projectRows(_ project: ReminderProject) -> some View {
        row(.project(project.id, heading: nil), title: project.title, icon: .emoji(project.emoji, fallback: "circle.dashed"), level: 1)
        ForEach(store.headings(ofProject: project.id)) { heading in
            row(.project(project.id, heading: heading.id), title: heading.title, icon: .symbol("text.line.first.and.arrowtriangle.forward"), level: 2)
        }
    }

    private enum Icon {
        case symbol(String)
        case emoji(String?, fallback: String)
    }

    private func row(_ destination: ReminderDestination, title: String, icon: Icon, level: Int, bold: Bool = false) -> some View {
        Button {
            Haptics.selection()
            onPick(destination)
            dismiss()
        } label: {
            HStack(spacing: Spacing.sm) {
                Group {
                    switch icon {
                    case let .symbol(name):
                        Image(systemName: name).foregroundStyle(Color.text2)
                    case let .emoji(emoji?, _) where !emoji.isEmpty:
                        Text(emoji)
                    case let .emoji(_, fallback):
                        Image(systemName: fallback).foregroundStyle(Color.text2)
                    }
                }
                .font(level == 2 ? .footnote : .body)
                .frame(width: 24)
                Text(title)
                    .font(level == 2 ? .subheadline : bold ? .body.weight(.semibold) : .body)
                    .foregroundStyle(level == 2 ? Color.text2 : Color.ink)
                    .lineLimit(1)
                Spacer(minLength: Spacing.xs)
                if destination == selection {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accent)
                }
            }
            .padding(.leading, CGFloat(level) * Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.card)
    }
}

/// Checklist of a reminder: check, rename, add, delete and drag items.
struct ReminderChecklistSection: View {
    @Binding var items: [ChecklistItem]
    /// Called after each discrete change (check, add, delete, move, rename submitted).
    var onChange: () -> Void = {}
    @State private var newItem = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        Section {
            ForEach(Array(items.indices), id: \.self) { index in
                HStack(spacing: Spacing.sm) {
                    Button {
                        Haptics.selection()
                        guard index < items.count else { return }
                        withAnimation(.snappy(duration: 0.2)) { items[index].done.toggle() }
                        onChange()
                    } label: {
                        Image(systemName: isDone(index) ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundStyle(isDone(index) ? Color.good : Color.text3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isDone(index) ? String(localized: "Uncheck") : String(localized: "Check"))
                    TextField("", text: title(index), prompt: Text("Item"))
                        .labelsHidden()
                        .foregroundStyle(isDone(index) ? Color.text3 : Color.ink)
                        .strikethrough(isDone(index), color: Color.text3)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                        .onSubmit(onChange)
                }
            }
            .onDelete { offsets in
                items.remove(atOffsets: offsets)
                onChange()
            }
            .onMove { from, to in
                items.move(fromOffsets: from, toOffset: to)
                onChange()
            }
            HStack(spacing: Spacing.sm) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accent)
                    .frame(width: 22)
                TextField("", text: $newItem, prompt: Text("Add an item"))
                    .labelsHidden()
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    .focused($addFocused)
                    .submitLabel(.next)
                    .onSubmit(add)
            }
        } header: {
            HStack {
                Text("Checklist")
                Spacer()
                if !items.isEmpty {
                    Text(verbatim: "\(items.filter(\.done).count)/\(items.count)").monospacedDigit()
                }
            }
        }
        .listRowBackground(Color.card)
    }

    private func isDone(_ index: Int) -> Bool { index < items.count && items[index].done }

    private func title(_ index: Int) -> Binding<String> {
        Binding(get: { index < items.count ? items[index].title : "" },
                set: { if index < items.count { items[index].title = $0 } })
    }

    private func add() {
        let title = newItem.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) { items.append(ChecklistItem(title: title, done: false)) }
        newItem = ""
        addFocused = true
        onChange()
    }
}
