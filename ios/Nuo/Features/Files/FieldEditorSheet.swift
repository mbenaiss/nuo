import SwiftUI

/// Edits one value, with the control that suits its type.
struct FieldEditorSheet: View {
    let column: DataColumn
    let value: JSONValue
    let refTitle: String?
    let onSave: (JSONValue) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date()
    @State private var hasDate = true
    @State private var selection: Set<String> = []
    @State private var saving = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch column.type {
                case .money: MoneyKeypad(text: $text)
                case .date, .datetime: dateEditor
                case .select, .multiselect: optionsEditor
                case .ref: RefPicker(column: column, currentId: value.string, currentTitle: refTitle) { id in save(id.map(JSONValue.string) ?? .null) }
                case .longtext: longTextEditor
                default: lineEditor
                }
            }
            .background(Color.canvas)
            .navigationTitle(column.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                if column.type != .ref && column.type != .select {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") { save(newValue) }.disabled(saving || !isValid)
                    }
                }
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .onAppear(perform: fill)
    }

    private var detents: Set<PresentationDetent> {
        switch column.type {
        case .money: [.height(520)]
        case .text, .url, .number, .percent: [.height(260)]
        case .select: [.medium, .large]
        default: [.large]
        }
    }

    private func fill() {
        switch column.type {
        case .money:
            text = value.double.map { MoneyKeypad.editableText($0) } ?? ""
        case .percent:
            text = value.double.map { ValueFormat.number($0 * 100) } ?? ""
        case .number:
            text = value.double.map(ValueFormat.number) ?? ""
        case .date, .datetime:
            if let parsed = value.string.flatMap(ValueFormat.parseDate) { date = parsed } else { hasDate = value.isNull ? false : true }
            if value.isNull { hasDate = true }
        case .select:
            selection = value.string.map { [$0] } ?? []
        case .multiselect:
            selection = Set(value.stringArray)
        default:
            text = value.string ?? ""
        }
    }

    private var isValid: Bool {
        switch column.type {
        case .money, .number, .percent: text.isEmpty || Self.parseNumber(text) != nil
        case .url: text.isEmpty || URL(string: text)?.scheme != nil
        default: true
        }
    }

    private var newValue: JSONValue {
        switch column.type {
        case .money: return Self.parseNumber(text).map { .number(($0 * 100).rounded() / 100) } ?? .null
        case .number: return Self.parseNumber(text).map(JSONValue.number) ?? .null
        case .percent: return Self.parseNumber(text).map { .number($0 / 100) } ?? .null
        case .date: return hasDate ? .string(ValueFormat.dayString(date)) : .null
        case .datetime: return hasDate ? .string(NuoJSON.formatDate(date)) : .null
        case .select: return selection.first.map(JSONValue.string) ?? .null
        case .multiselect: return .array((column.options ?? []).map(\.value).filter(selection.contains).map(JSONValue.string))
        default:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .null : .string(trimmed)
        }
    }

    static func parseNumber(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: "."))
    }

    private func save(_ value: JSONValue) {
        saving = true
        Task {
            let ok = await onSave(value)
            saving = false
            if ok { dismiss() }
        }
    }

    // MARK: Editors

    private var lineEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(column.label, text: $text)
                    .font(.title3)
                    .focused($fieldFocused)
                    .keyboardType(column.type == .url ? .URL : [.number, .percent].contains(column.type) ? .decimalPad : .default)
                    .textInputAutocapitalization(column.type == .url ? .never : .sentences)
                    .autocorrectionDisabled(column.type == .url)
                    .submitLabel(.done)
                    .onSubmit { if isValid { save(newValue) } }
                if column.type == .percent { Text("%").font(.title3).foregroundStyle(Color.text2) }
            }
            .padding(16)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line))
            if !isValid { Text(column.type == .url ? String(localized: "Invalid address.") : String(localized: "Invalid number.")).font(.footnote).foregroundStyle(Color.bad) }
            Spacer()
        }
        .padding(16)
        .onAppear { fieldFocused = true }
    }

    private var longTextEditor: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line))
            .padding(16)
    }

    private var dateEditor: some View {
        Form {
            Section {
                DatePicker(column.label, selection: $date, displayedComponents: column.type == .datetime ? [.date, .hourAndMinute] : [.date])
                    .datePickerStyle(.graphical)
                    .environment(\.locale, ValueFormat.locale)
                HStack(spacing: 8) {
                    ForEach([(String(localized: "Today"), 0), (String(localized: "Tomorrow"), 1), (String(localized: "In 30 d"), 30)], id: \.1) { label, days in
                        Button {
                            Haptics.selection()
                            date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
                        } label: { ChipButtonLabel(title: label) }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listRowBackground(Color.card)
            if !value.isNull {
                Section {
                    Button("Clear date", role: .destructive) {
                        hasDate = false
                        save(.null)
                    }
                }
                .listRowBackground(Color.card)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var optionsEditor: some View {
        List {
            Section {
                ForEach(column.options ?? []) { option in
                    Button {
                        Haptics.selection()
                        if column.type == .select {
                            selection = [option.value]
                            save(.string(option.value))
                        } else if selection.contains(option.value) {
                            selection.remove(option.value)
                        } else {
                            selection.insert(option.value)
                        }
                    } label: {
                        HStack {
                            OptionChip(option: option)
                            Spacer()
                            if selection.contains(option.value) {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Color.card)
            if column.type == .select, !value.isNull {
                Section {
                    Button("None", role: .destructive) { save(.null) }
                }
                .listRowBackground(Color.card)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

/// Large figure with a calculator-like keypad: no keyboard juggling for amounts.
struct MoneyKeypad: View {
    @Binding var text: String

    static func editableText(_ value: Double) -> String {
        let cents = (value * 100).rounded() / 100
        if cents.rounded() == cents { return String(Int(cents)) }
        return String(format: "%.2f", cents).replacingOccurrences(of: ".", with: ",")
    }

    private var display: String {
        guard !text.isEmpty, let value = FieldEditorSheet.parseNumber(text) else { return text == "-" ? "−0 €" : "0 €" }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let integer = abs(value).rounded(.towardZero)
        var result = (value < 0 || text.hasPrefix("-") ? "−" : "") + Int(integer).formatted(.number.locale(ValueFormat.locale))
        if parts.count > 1 { result += "," + parts[1] }
        return result + " €"
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text(display)
                .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: text)
                .padding(.horizontal, 20)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "±", "0", ","], id: \.self) { key in
                    keyButton(key)
                }
            }
            HStack(spacing: 10) {
                Button {
                    Haptics.selection()
                    text = ""
                } label: {
                    Text("Clear").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Button {
                    Haptics.selection()
                    if !text.isEmpty { text.removeLast() }
                } label: {
                    Image(systemName: "delete.left").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .accessibilityLabel("Delete last digit")
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(Color.ink)
        }
        .padding(16)
    }

    private func keyButton(_ key: String) -> some View {
        Button {
            Haptics.selection()
            press(key)
        } label: {
            Text(key)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line))
        }
        .buttonStyle(PressableStyle())
    }

    private func press(_ key: String) {
        switch key {
        case "±":
            if text.hasPrefix("-") { text.removeFirst() } else { text = "-" + text }
        case ",":
            if !text.contains(",") { text += text.isEmpty || text == "-" ? "0," : "," }
        default:
            if let comma = text.firstIndex(of: ","), text.distance(from: comma, to: text.endIndex) > 2 { return }
            if text == "0" { text = key } else if text == "-0" { text = "-" + key } else { text += key }
        }
    }
}

/// Searches the target collection of a `ref` column.
struct RefPicker: View {
    let column: DataColumn
    let currentId: String?
    let currentTitle: String?
    let onPick: (String?) -> Void
    @Environment(SessionStore.self) private var session
    @State private var search = ""
    @State private var debouncer = Debouncer()
    @State private var rows: [DataRow] = []
    @State private var loading = true

    var body: some View {
        List {
            if let currentId {
                Section {
                    HStack {
                        Text(currentTitle ?? currentId).foregroundStyle(Color.ink)
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Color.accent)
                    }
                    Button("Remove link", role: .destructive) { onPick(nil) }
                } header: {
                    SectionHeader(title: String(localized: "Current"))
                }
                .listRowBackground(Color.card)
            }
            Section {
                if loading && rows.isEmpty {
                    ForEach(0..<6, id: \.self) { _ in SkeletonBar(width: 180, height: 12).padding(.vertical, 6) }
                } else if rows.isEmpty {
                    Text("No results").foregroundStyle(Color.text2)
                }
                ForEach(rows) { row in
                    Button {
                        Haptics.selection()
                        onPick(row.id)
                    } label: {
                        HStack {
                            Text(row.title).foregroundStyle(Color.ink)
                            Spacer()
                            if row.id == currentId { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionHeader(title: FilesHomeStore.shared.collection(column.ref ?? "")?.label ?? String(localized: "Choose"))
            }
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .onChange(of: search) { _, value in debouncer.send(value) }
        .task(id: debouncer.value) { await load(debouncer.value) }
    }

    private func load(_ text: String) async {
        guard let target = column.ref else { return }
        loading = true
        defer { loading = false }
        if let page = try? await session.api.rows(collection: target, query: DataQuery(search: text), limit: 40, cursor: nil) {
            rows = page.rows
        }
    }
}
