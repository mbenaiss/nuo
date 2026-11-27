import SwiftUI

struct CommandEditTarget: Identifiable {
    let id = UUID()
    var original: BotCommand?
}

struct CommandsSection: View {
    let store: BotEditorStore
    let onEdit: (CommandEditTarget) -> Void
    let onReorder: () -> Void
    @State private var pendingDelete: BotCommand?

    var body: some View {
        EditorSection(title: "Commands") {
            let commands = store.commands
            if commands.isEmpty {
                Text("Shortcuts to type with / in the chat: call a tool, run a prompt, open a link.")
                    .font(.subheadline)
                    .foregroundStyle(Color.text2)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
            ForEach(Array(commands.enumerated()), id: \.element.name) { index, command in
                if index > 0 { Divider().overlay(Color.line).padding(.leading, 62) }
                Button { onEdit(CommandEditTarget(original: command)) } label: {
                    CommandRow(command: command)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { onEdit(CommandEditTarget(original: command)) } label: { Label("Edit", systemImage: "pencil") }
                    if index > 0 {
                        Button { move(index, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                    }
                    if index < commands.count - 1 {
                        Button { move(index, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                    }
                    Divider()
                    Button(role: .destructive) { pendingDelete = command } label: { Label("Delete", systemImage: "trash") }
                }
            }
            Divider().overlay(Color.line)
            HStack(spacing: 0) {
                Button {
                    Haptics.tap()
                    onEdit(CommandEditTarget(original: nil))
                } label: {
                    Label("Add a command", systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if commands.count > 1 {
                    Button(action: onReorder) {
                        Text("Reorder")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.text2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .confirmationDialog(
            "Delete /\(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete command", role: .destructive) {
                if let name = pendingDelete?.name { withAnimation(.snappy) { store.deleteCommand(name) } }
            }
        }
    }

    private func move(_ index: Int, by delta: Int) {
        Haptics.selection()
        withAnimation(.snappy) {
            store.moveCommands(from: IndexSet(integer: index), to: delta > 0 ? index + 2 : index - 1)
        }
    }
}

struct CommandRow: View {
    let command: BotCommand

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 34, height: 34)
                .background(Color.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/\(command.name)").font(.subheadline.monospaced().weight(.semibold)).foregroundStyle(Color.ink).fixedSize()
                    if let args = command.args, !args.isEmpty {
                        Text(args).font(.caption.monospaced()).foregroundStyle(Color.text3).lineLimit(1)
                    }
                }
                Text(command.description).font(.footnote).foregroundStyle(Color.text2).lineLimit(1)
            }
            Spacer(minLength: 6)
            Badge(text: command.kind.shortLabel, tint: badgeTint, fill: badgeFill)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.text3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var badgeTint: Color {
        switch command.kind {
        case .tool: Color.accentInk
        case .prompt: Color(hex: 0x6D4AD6)
        case .open: Color(hex: 0x2563EB)
        case .app: Color.good
        }
    }

    private var badgeFill: Color {
        switch command.kind {
        case .tool: Color.accentSoft
        case .prompt: Color(hex: 0x8B5CF6).opacity(0.14)
        case .open: Color(hex: 0x3B82F6).opacity(0.13)
        case .app: Color.good.opacity(0.13)
        }
    }
}

struct CommandsReorderView: View {
    let store: BotEditorStore

    var body: some View {
        List {
            ForEach(store.commands) { command in
                CommandRow(command: command)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.card)
            }
            .onMove { store.moveCommands(from: $0, to: $1) }
            .onDelete { offsets in
                for name in offsets.map({ store.commands[$0].name }) { store.deleteCommand(name) }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Commands")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CommandEditorSheet: View {
    let store: BotEditorStore
    let original: BotCommand?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var args = ""
    @State private var kind: CommandKind = .tool
    @State private var server = ""
    @State private var tool = ""
    @State private var params = ""
    @State private var template = ""
    @State private var model: String?
    @State private var effort: String?
    @State private var url = ""
    @State private var appAction: AppCommandAction = .newConversation
    @State private var confirmsDelete = false
    @FocusState private var templateFocused: Bool

    init(store: BotEditorStore, original: BotCommand?) {
        self.store = store
        self.original = original
        guard let original else { return }
        let action = original.action
        _name = State(initialValue: original.name)
        _summary = State(initialValue: original.description)
        _args = State(initialValue: original.args ?? "")
        _kind = State(initialValue: original.kind)
        _server = State(initialValue: action.server ?? "")
        _tool = State(initialValue: action.tool ?? "")
        _params = State(initialValue: (action.params ?? []).joined(separator: ", "))
        _template = State(initialValue: action.template ?? "")
        _model = State(initialValue: action.model)
        _effort = State(initialValue: action.effort)
        _url = State(initialValue: action.url ?? "")
        _appAction = State(initialValue: original.appAction ?? .newConversation)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    identitySection
                    typeSection
                    actionSection
                    if original != nil {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Text("Delete command").font(.body.weight(.medium)).foregroundStyle(Color.bad)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .animation(.snappy(duration: 0.25), value: kind)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.canvas)
            .navigationTitle(original == nil ? String(localized: "New command") : String(localized: "Command"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Color.accent)
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Delete /\(original?.name ?? "")?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete command", role: .destructive) {
                    if let name = original?.name { store.deleteCommand(name) }
                    Haptics.success()
                    dismiss()
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var preview: some View {
        HStack(spacing: 12) {
            Image(systemName: draftCommand.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentInk)
                .frame(width: 38, height: 38)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/\(name.isEmpty ? String(localized: "command") : name)")
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(name.isEmpty ? Color.text3 : Color.ink)
                    if !args.isEmpty {
                        Text(args).font(.footnote.monospaced()).foregroundStyle(Color.text3).lineLimit(1)
                    }
                }
                Text(summary.isEmpty ? String(localized: "Description") : summary)
                    .font(.footnote)
                    .foregroundStyle(summary.isEmpty ? Color.text3 : Color.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular.tint(Color.card.opacity(0.55)), in: .rect(cornerRadius: 20))
        .padding(.top, 8)
        .accessibilityLabel("Preview in the chat")
    }

    private var identitySection: some View {
        EditorSection(title: "Command") {
            field("Name", error: nameError) {
                HStack(spacing: 2) {
                    Text("/").foregroundStyle(Color.text3)
                    TextField("flight", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: name) { _, value in
                            let cleaned = value.lowercased().replacingOccurrences(of: " ", with: "_")
                            if cleaned != value { name = cleaned }
                        }
                }
                .font(.body.monospaced())
            }
            Divider().overlay(Color.line)
            field("Description") {
                TextField("Flight status", text: $summary)
            }
            Divider().overlay(Color.line)
            field("Arguments (hint shown)", footer: "Leave empty if the command takes nothing: it runs as soon as it is chosen.") {
                TextField("<flight> [dd/mm]", text: $args)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private var typeSection: some View {
        EditorSection(title: "Type") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(CommandKind.allCases) { option in
                        Button {
                            Haptics.selection()
                            kind = option
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: option.symbol).font(.subheadline.weight(.semibold))
                                Text(option.label).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(kind == option ? Color.onInk : Color.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(kind == option ? Color.inkFill : Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                Text(kind.hint).font(.caption).foregroundStyle(Color.text2).contentTransition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        switch kind {
        case .tool: toolSection
        case .prompt: promptSection
        case .open: openSection
        case .app: appSection
        }
    }

    private var toolSection: some View {
        EditorSection(title: "Tool") {
            if store.enabledToolServers.isEmpty && server.isEmpty {
                Text("First enable a tool server in the bot's Tools section.")
                    .font(.subheadline).foregroundStyle(Color.text2).padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                Menu {
                    ForEach(store.enabledToolServers) { item in
                        Button {
                            server = item.id
                            if !item.tools.contains(tool) { tool = item.tools.first ?? "" }
                        } label: {
                            if item.id == server { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                        }
                    }
                } label: {
                    EditorRow(title: "Server", value: serverName, chevron: "chevron.up.chevron.down")
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.line)
                Menu {
                    ForEach(selectedServer?.tools ?? [], id: \.self) { item in
                        Button {
                            tool = item
                        } label: {
                            if item == tool { Label(item, systemImage: "checkmark") } else { Text(item) }
                        }
                    }
                } label: {
                    EditorRow(title: "Tool", value: tool.isEmpty ? String(localized: "Choose") : tool, chevron: "chevron.up.chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(selectedServer == nil)
                Divider().overlay(Color.line)
                field("Parameters", footer: "Names separated by commas. The words typed after the command fill them in order, the last one gets the rest.") {
                    TextField("flight, date", text: $params)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
    }

    private var promptSection: some View {
        EditorSection(title: "Prompt") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $template)
                    .font(.body)
                    .focused($templateFocused)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if template.isEmpty {
                            Text("Review my training week. {args}")
                                .foregroundStyle(Color.text3)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    Button {
                        template += template.isEmpty || template.hasSuffix(" ") || template.hasSuffix("\n") ? "{args}" : " {args}"
                        templateFocused = true
                    } label: {
                        Badge(text: "+ {args}", tint: Color.accentInk, fill: Color.accentSoft)
                    }
                    .buttonStyle(.plain)
                    Text("replaced by the text typed after the command").font(.caption).foregroundStyle(Color.text2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Divider().overlay(Color.line)
            Menu {
                Button { model = nil; effort = nil } label: {
                    if model == nil { Label("Bot model", systemImage: "checkmark") } else { Text("Bot model") }
                }
                ForEach(store.agentInfo?.models ?? []) { item in
                    Button {
                        model = item.id
                        if let effort, item.efforts?.contains(effort) != true { self.effort = nil }
                    } label: {
                        if item.id == model { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                    }
                }
            } label: {
                EditorRow(title: "Model", value: modelLabel, chevron: "chevron.up.chevron.down")
            }
            .buttonStyle(.plain)
            if !efforts.isEmpty {
                Divider().overlay(Color.line)
                Menu {
                    Button { effort = nil } label: {
                        if effort == nil { Label("Bot effort", systemImage: "checkmark") } else { Text("Bot effort") }
                    }
                    ForEach(efforts, id: \.self) { item in
                        Button { effort = item } label: {
                            if item == effort { Label(Effort.label(item), systemImage: "checkmark") } else { Text(Effort.label(item)) }
                        }
                    }
                } label: {
                    EditorRow(title: "Effort", value: effort.map(Effort.label) ?? String(localized: "Bot default"), chevron: "chevron.up.chevron.down")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var openSection: some View {
        EditorSection(title: "Link") {
            field("URL", error: !url.isEmpty && validURL == nil ? String(localized: "An http(s) address is expected") : nil, footer: "Opens in the app, without leaving the conversation.") {
                TextField("https://app.whoop.com", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private var appSection: some View {
        EditorSection(title: "Action") {
            ForEach(Array(AppCommandAction.allCases.enumerated()), id: \.element) { index, option in
                if index > 0 { Divider().overlay(Color.line).padding(.leading, 52) }
                Button {
                    Haptics.selection()
                    appAction = option
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 24)
                        Text(option.label).foregroundStyle(Color.ink)
                        Spacer()
                        if appAction == option {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, error: String? = nil, footer: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Color.text2)
            content()
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.bad)
            } else if let footer {
                Text(footer).font(.caption).foregroundStyle(Color.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Model

    private var selectedServer: ToolServer? { store.tools.first { $0.id == server } }
    private var serverName: String { selectedServer?.name ?? (server.isEmpty ? String(localized: "Choose") : server) }

    private var modelLabel: String {
        guard let model else { return String(localized: "Bot default") }
        return shortModelName(store.agentInfo?.models.first { $0.id == model }?.name ?? model)
    }

    private var efforts: [String] {
        store.agentInfo?.models.first { $0.id == (model ?? store.config.model) }?.efforts ?? []
    }

    private var validURL: URL? {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { return nil }
        return parsed
    }

    private var nameError: String? {
        guard !name.isEmpty else { return nil }
        if !BotCommand.isValidName(name) { return String(localized: "Lowercase letters, digits and _ only, 24 characters max") }
        if name != original?.name, store.commands.contains(where: { $0.name == name }) { return String(localized: "The command /\(name) already exists") }
        return nil
    }

    private var isValid: Bool {
        guard !name.isEmpty, nameError == nil, !summary.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .tool: return !server.isEmpty && !tool.isEmpty
        case .prompt: return !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .open: return validURL != nil
        case .app: return true
        }
    }

    private var draftCommand: BotCommand {
        var action = BotCommand.Action(type: kind.rawValue)
        switch kind {
        case .tool:
            action.server = server
            action.tool = tool
            let names = params.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            action.params = names.isEmpty ? nil : names
            if original?.kind == .tool { action.fixedArgs = original?.action.fixedArgs }
        case .prompt:
            action.template = template
            action.model = model
            action.effort = effort
        case .open:
            action.url = url.trimmingCharacters(in: .whitespaces)
        case .app:
            action.action = appAction.rawValue
        }
        let hint = args.trimmingCharacters(in: .whitespaces)
        return BotCommand(name: name, description: summary.trimmingCharacters(in: .whitespaces), args: hint.isEmpty ? nil : hint, action: action)
    }

    private func save() {
        store.saveCommand(draftCommand, replacing: original?.name)
        Haptics.success()
        dismiss()
    }
}
