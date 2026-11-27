#if os(iOS)
import SwiftUI
import UIKit

enum OrganisationField: Hashable { case title, emoji }

struct ProjectEditorTarget: Identifiable {
    let id = UUID()
    let project: ReminderProject?
    /// Area of a new project.
    var areaId: String?
    var focus: OrganisationField = .title
}

struct AreaEditorTarget: Identifiable {
    let id = UUID()
    let area: ReminderArea?
    var focus: OrganisationField = .title
}

/// New or edited project: emoji, name, notes, area, deadline, « Un jour ».
struct ProjectEditorSheet: View {
    let target: ProjectEditorTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(RemindersNavigator.self) private var nav
    @State private var store = RemindersStore.shared
    @State private var title = ""
    @State private var emoji = ""
    @State private var notes = ""
    @State private var areaId: String?
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var someday = false
    @State private var saving = false
    @FocusState private var focus: OrganisationField?
    @State private var emojiFocused = false

    private var original: ReminderProject? { target.project }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Spacing.sm) {
                        EmojiField(emoji: $emoji, placeholder: "🎯", isFocused: $emojiFocused)
                        TextField("Project name", text: $title)
                            .font(.title3.weight(.semibold))
                            .focused($focus, equals: .title)
                            .submitLabel(.done)
                    }
                    EmojiSuggestions(selection: $emoji, choices: ["🎯", "📊", "🚀", "✈️", "🏠", "💼", "📱", "🛠️", "📚", "🏋️", "💰", "🎉", "🌱", "❤️"])
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...8)
                        .foregroundStyle(Color.text2)
                }
                .listRowBackground(Color.card)

                Section {
                    Picker(selection: $areaId) {
                        Text("None").tag(String?.none)
                        ForEach(store.sortedAreas) { area in
                            Text(ReminderFiling.titled(area.emoji, area.title)).tag(String?.some(area.id))
                        }
                    } label: {
                        Label("Area", systemImage: "square.stack.3d.up").foregroundStyle(Color.ink)
                    }
                    Toggle(isOn: $hasDeadline.animation(.snappy)) {
                        Label("Deadline", systemImage: "flag").foregroundStyle(Color.ink)
                    }
                    if hasDeadline {
                        DatePicker("Date", selection: $deadline, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .environment(\.locale, ValueFormat.locale)
                    }
                    Toggle(isOn: $someday) {
                        Label("Someday", systemImage: "archivebox").foregroundStyle(Color.ink)
                    }
                } footer: {
                    Text("A “Someday” project and its reminders leave “Anytime” until you bring them back.")
                }
                .listRowBackground(Color.card)
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle(original == nil ? String(localized: "New Project") : String(localized: "Project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? String(localized: "Create") : String(localized: "OK")) { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: fill)
    }

    private func fill() {
        if let original {
            title = original.title
            emoji = original.emoji ?? ""
            notes = original.notes ?? ""
            areaId = original.areaId
            hasDeadline = original.deadlineDate != nil
            deadline = original.deadlineDate ?? Date()
            someday = original.someday
        } else {
            areaId = target.areaId
        }
        if target.focus == .emoji { emojiFocused = true } else { focus = .title }
    }

    private var deadlineString: String? {
        guard hasDeadline else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: deadline)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmoji = emoji.trimmingCharacters(in: .whitespaces)
        guard let original else {
            let draft = ProjectDraft(title: cleanTitle, notes: cleanNotes.isEmpty ? nil : cleanNotes, emoji: cleanEmoji.isEmpty ? nil : cleanEmoji,
                                     areaId: areaId, deadline: deadlineString, someday: someday)
            if let project = await store.createProject(draft) {
                dismiss()
                nav.path.append(.project(project.id))
            }
            return
        }
        var patch: [String: JSONValue] = [:]
        if cleanTitle != original.title { patch["title"] = .string(cleanTitle) }
        if cleanNotes != (original.notes ?? "") { patch["notes"] = cleanNotes.isEmpty ? .null : .string(cleanNotes) }
        if cleanEmoji != (original.emoji ?? "") { patch["emoji"] = cleanEmoji.isEmpty ? .null : .string(cleanEmoji) }
        if areaId != original.areaId { patch["areaId"] = areaId.map(JSONValue.string) ?? .null }
        if deadlineString != original.deadline { patch["deadline"] = deadlineString.map(JSONValue.string) ?? .null }
        if someday != original.someday { patch["someday"] = .bool(someday) }
        if !patch.isEmpty { await store.updateProject(original.id, patch: patch) }
        Haptics.success()
        dismiss()
    }
}

/// New or renamed area: an emoji and a name.
struct AreaEditorSheet: View {
    let target: AreaEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var store = RemindersStore.shared
    @State private var title = ""
    @State private var emoji = ""
    @State private var saving = false
    @FocusState private var focus: OrganisationField?
    @State private var emojiFocused = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Spacing.sm) {
                        EmojiField(emoji: $emoji, placeholder: "📁", isFocused: $emojiFocused)
                        TextField("Area name", text: $title)
                            .font(.title3.weight(.semibold))
                            .focused($focus, equals: .title)
                            .submitLabel(.done)
                            .onSubmit { Task { await save() } }
                    }
                    EmojiSuggestions(selection: $emoji, choices: ["💼", "🏠", "🏃", "✨", "💰", "👨‍👩‍👧", "🎨", "📚", "🌍", "🛠️", "❤️", "🎓"])
                } footer: {
                    Text("An area groups projects and ongoing reminders: Work, Home, Health…")
                }
                .listRowBackground(Color.card)
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle(target.area == nil ? String(localized: "New Area") : String(localized: "Area"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.area == nil ? String(localized: "Create") : String(localized: "OK")) { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            title = target.area?.title ?? ""
            emoji = target.area?.emoji ?? ""
            if target.focus == .emoji { emojiFocused = true } else { focus = .title }
        }
    }

    private func save() async {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmoji = emoji.trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty, !saving else { return }
        saving = true
        defer { saving = false }
        if let area = target.area {
            var patch: [String: JSONValue] = [:]
            if cleanTitle != area.title { patch["title"] = .string(cleanTitle) }
            if cleanEmoji != (area.emoji ?? "") { patch["emoji"] = cleanEmoji.isEmpty ? .null : .string(cleanEmoji) }
            if !patch.isEmpty { await store.updateArea(area.id, patch: patch) }
        } else if await store.createArea(title: cleanTitle, emoji: cleanEmoji.isEmpty ? nil : cleanEmoji) == nil {
            return
        }
        Haptics.success()
        dismiss()
    }
}

/// One emoji in a square tile; typing opens the emoji keyboard and keeps only the last character.
struct EmojiField: View {
    @Binding var emoji: String
    var placeholder: String
    @Binding var isFocused: Bool

    var body: some View {
        EmojiTextField(text: $emoji, placeholder: placeholder, isFocused: $isFocused)
            .frame(width: 44, height: 44)
            .background(Color.chip, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(isFocused ? Color.accent : .clear, lineWidth: 1.5)
            }
            .accessibilityLabel("Emoji")
    }
}

private struct EmojiTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFocused: Bool

    final class Field: UITextField {
        // The only public way to open the emoji keyboard.
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 24)
        field.placeholder = placeholder
        field.tintColor = .clear
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        if field.text != text { field.text = text }
        if isFocused, !field.isFirstResponder {
            Task { @MainActor in field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isFocused: $isFocused) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let text: Binding<String>
        let isFocused: Binding<Bool>
        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textFieldDidBeginEditing(_ textField: UITextField) { isFocused.wrappedValue = true }
        func textFieldDidEndEditing(_ textField: UITextField) { isFocused.wrappedValue = false }

        @MainActor @objc func changed(_ field: UITextField) {
            let value = field.text ?? ""
            let last = value.last.map(String.init) ?? ""
            if field.text != last { field.text = last }
            text.wrappedValue = last
        }
    }
}

struct EmojiSuggestions: View {
    @Binding var selection: String
    let choices: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.xs) {
                ForEach(choices, id: \.self) { choice in
                    Button {
                        Haptics.selection()
                        selection = selection == choice ? "" : choice
                    } label: {
                        Text(choice)
                            .font(.system(size: 20))
                            .frame(width: 36, height: 36)
                            .background(selection == choice ? Color.accentSoft : Color.chip,
                                        in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, CardMetrics.rowInset, for: .scrollContent)
        .listRowInsets(EdgeInsets(top: Spacing.xs, leading: 0, bottom: Spacing.xs, trailing: 0))
    }
}
#endif
