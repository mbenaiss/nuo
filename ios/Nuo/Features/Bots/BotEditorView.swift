import SwiftUI

struct BotEditorView: View {
    let botId: String
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @State private var store: BotEditorStore?

    var body: some View {
        Group {
            if let store {
                BotEditorForm(store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.canvas)
            }
        }
        .task {
            guard store == nil else { return }
            let bot = (try? await session.api.bot(id: botId)) ?? bots.bot(id: botId)
            if let bot { store = BotEditorStore(bot: bot, session: session, bots: bots) }
        }
    }
}

private enum EditorPage: Hashable {
    case agent, instructions, diff, versions, commands
}

private struct BotEditorForm: View {
    @Bindable var store: BotEditorStore
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var path: [EditorPage] = []
    @State private var showsDiscard = false
    @State private var showsPublish = false
    @State private var publishNote = ""
    @State private var showsEmoji = false
    @State private var editingCommand: CommandEditTarget?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    identity
                    brain
                    instructions
                    toolsSection
                    CommandsSection(store: store, onEdit: { editingCommand = $0 }, onReorder: { path.append(.commands) })
                        .id("commands")
                    permissions
                    toolRulesSection
                    initiative
                    BotWakeSection(botId: store.bot.id)
                    advanced
                    versionsSection
                    if store.hasDraft && store.publishedVersion != nil {
                        Button(role: .destructive) { showsDiscard = true } label: {
                            Text("Discard changes").font(.body.weight(.medium)).foregroundStyle(Color.bad).frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                    }
                    if let error = store.error {
                        Text(error).font(.footnote).foregroundStyle(Color.bad).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                guard let focus = DemoDirector.editorFocus else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo("commands", anchor: .top)
                if focus.hasPrefix("command:"), let command = store.commands.first(where: { "command:\($0.name)" == focus }) {
                    try? await Task.sleep(for: .milliseconds(300))
                    editingCommand = CommandEditTarget(original: command)
                }
            }
            }
            .background(Color.canvas)
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task { await store.saveNow() }
                        dismiss()
                    }
                    .tint(Color.ink)
                }
                // The status sits under the title: as a trailing item it got truncated next to the tools button.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Edit").font(.headline).foregroundStyle(Color.ink)
                        HStack(spacing: 4) {
                            if store.saving { ProgressView().controlSize(.mini) }
                            Text(store.hasDraft ? String(localized: "Draft") : String(localized: "Published"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(store.hasDraft ? Color.accent : Color.good)
                        }
                    }
                    .fixedSize()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { MachineToolsView() } label: {
                        Image(systemName: "wrench.and.screwdriver").foregroundStyle(Color.ink)
                    }
                    .accessibilityLabel("Dev tools")
                }
            }
            .navigationDestination(for: EditorPage.self) { page in
                switch page {
                case .agent: AgentPicker(store: store)
                case .instructions: InstructionsEditor(text: $store.config.instructions)
                case .diff: DiffView(lines: store.diffLines, version: store.publishedVersion)
                case .versions: VersionsView(store: store)
                case .commands: CommandsReorderView(store: store)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $showsDiscard, titleVisibility: .visible) {
                Button("Revert to v\(store.publishedVersion ?? 0)", role: .destructive) { Task { await store.discard() } }
            } message: {
                Text("The draft will be deleted.")
            }
            .alert("Publish v\(store.nextVersion)", isPresented: $showsPublish) {
                TextField("Note (optional)", text: $publishNote)
                Button("Publish") {
                    Task {
                        if await store.publish(note: publishNote.isEmpty ? nil : publishNote) { publishNote = "" }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New conversations will use this version.")
            }
            .sheet(item: $editingCommand) { target in
                CommandEditorSheet(store: store, original: target.original)
            }
            .sheet(isPresented: $showsEmoji) {
                AppearancePicker(emoji: $store.config.emoji, color: $store.config.color)
                    .presentationDetents([.medium])
            }
            .task { await store.loadVersions() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { showsEmoji = true } label: {
                BotAvatar(config: store.config, size: 62)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill").font(.title3).symbolRenderingMode(.palette).foregroundStyle(Color.onInk, Color.inkFill).offset(x: 6, y: 6)
                    }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Change emoji and color")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $store.config.name).font(.title2.bold()).foregroundStyle(Color.ink)
                Text(store.subtitle).font(.footnote).foregroundStyle(Color.text2)
            }
        }
        .padding(.top, 8)
    }

    private var identity: some View {
        EditorSection(title: "Identity") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(Color.text2)
                TextField("What is this bot for?", text: $store.config.description, axis: .vertical)
                    .lineLimit(1...3)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
    }

    private var brain: some View {
        EditorSection(title: "Brain") {
            NavigationLink(value: EditorPage.agent) {
                EditorRow(title: "Agent", value: store.agentInfo?.displayName ?? store.config.agent.rawValue.capitalized)
            }
            .buttonStyle(.plain)
            Divider().overlay(Color.line)
            Menu {
                ForEach(store.agentInfo?.models ?? []) { model in
                    Button {
                        store.selectModel(model)
                    } label: {
                        if model.id == store.config.model { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                    }
                }
            } label: {
                EditorRow(title: "Model", value: shortModelName(store.agentInfo?.models.first { $0.id == store.config.model }?.name ?? store.config.model), chevron: "chevron.up.chevron.down")
            }
            .buttonStyle(.plain)
            if let efforts = store.agentInfo?.models.first(where: { $0.id == store.config.model })?.efforts, !efforts.isEmpty {
                Divider().overlay(Color.line)
                Menu {
                    ForEach(efforts, id: \.self) { effort in
                        Button {
                            store.config.effort = effort
                        } label: {
                            if effort == store.config.effort { Label(Effort.label(effort), systemImage: "checkmark") } else { Text(Effort.label(effort)) }
                        }
                    }
                } label: {
                    EditorRow(title: "Effort", value: Effort.label(store.config.effort), chevron: "chevron.up.chevron.down")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var instructions: some View {
        EditorSection(title: "Instructions") {
            NavigationLink(value: EditorPage.instructions) {
                Text(store.config.instructions.isEmpty ? String(localized: "Write the bot's instructions…") : store.config.instructions)
                    .font(.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(store.config.instructions.isEmpty ? Color.text3 : Color.ink.opacity(0.85))
                    .lineLimit(7)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if store.publishedVersion != nil && store.changeCount > 0 {
                HStack(spacing: 8) {
                    Badge(text: String(localized: "\(store.changeCount) changes") + " vs v\(store.publishedVersion!)", tint: Color.accentInk, fill: Color.accentSoft)
                    NavigationLink(value: EditorPage.diff) {
                        Badge(text: String(localized: "View diff"))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
    }

    private var toolsSection: some View {
        EditorSection(title: "Tools") {
            if store.tools.isEmpty {
                Text("No tool servers available").font(.subheadline).foregroundStyle(Color.text2).padding(16)
            }
            ForEach(Array(store.tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 { Divider().overlay(Color.line) }
                Toggle(isOn: Binding(get: { store.config.toolServers.contains(tool.id) }, set: { store.toggleTool(tool.id, on: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.body).foregroundStyle(Color.ink)
                        Text(String(localized: "\(tool.tools.count) tools") + " · \(tool.description)")
                            .font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                    }
                }
                .tint(Color.accent)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private var permissions: some View {
        EditorSection(title: "Permissions") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Permissions", selection: $store.config.permissionPolicy) {
                    Text("Ask").tag(PermissionPolicy.ask)
                    Text("Auto").tag(PermissionPolicy.auto)
                    Text("Read-only").tag(PermissionPolicy.readonly)
                }
                .pickerStyle(.segmented)
                Text(policyHint).font(.caption).foregroundStyle(Color.text2)
            }
            .padding(16)
        }
    }

    private var toolRulesSection: some View {
        EditorSection(title: "Tool rules") {
            let rules = store.toolRules
            if rules.isEmpty {
                Text("No rules. On a permission request, “Always for this tool” or “Block this tool” adds one here.")
                    .font(.caption).foregroundStyle(Color.text2).padding(16)
            }
            ForEach(Array(rules.enumerated()), id: \.element.key) { index, item in
                if index > 0 { Divider().overlay(Color.line) }
                HStack(spacing: 12) {
                    Image(systemName: item.rule == .allow ? "checkmark.circle.fill" : "nosign")
                        .foregroundStyle(item.rule == .allow ? Color.accent : Color.bad)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ToolRuleLabel.name(item.key)).font(.body).foregroundStyle(Color.ink)
                        Text(ToolRuleLabel.state(item.rule)).font(.caption).foregroundStyle(Color.text2)
                    }
                    Spacer()
                    Button("Remove") { Task { await store.removeToolRule(item.key) } }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.bad)
                        .accessibilityLabel("Remove the rule for \(ToolRuleLabel.name(item.key))")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private var policyHint: String {
        switch store.config.permissionPolicy {
        case .ask: String(localized: "The bot asks before each sensitive action (command, write).")
        case .auto: String(localized: "The bot acts without asking. Keep this for bots you trust.")
        case .readonly: String(localized: "The bot can read but never edit or run anything.")
        }
    }

    private var initiative: some View {
        EditorSection(title: "Initiative") {
            Toggle(isOn: Binding(get: { store.config.proactive == true }, set: { store.config.proactive = $0 ? true : nil })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggestions every morning").font(.body).foregroundStyle(Color.ink)
                    Text("At 9 am, the bot looks at its memory, your exchanges and your calendar, then suggests up to 3 things it can do for you. It only acts with your approval and writes nothing if it has nothing useful.")
                        .font(.caption).foregroundStyle(Color.text2)
                }
            }
            .tint(Color.accent)
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Color.line).padding(.leading, 16)
            Toggle(isOn: Binding(get: { store.config.overview == true }, set: { store.config.overview = $0 ? true : nil })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Access to all bots").font(.body).foregroundStyle(Color.ink)
                    Text("The bot finds and reads all your conversations with all bots, and puts your questions to the bot that can answer them. Keep this for a general-purpose bot: a bot that reads emails or web pages does not need it.")
                        .font(.caption).foregroundStyle(Color.text2)
                }
            }
            .tint(Color.accent)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private var advanced: some View {
        EditorSection(title: "Advanced") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Working folder on dev").font(.caption).foregroundStyle(Color.text2)
                TextField("Bot folder (default)", text: Binding(get: { store.config.workdir ?? "" }, set: { store.config.workdir = $0.isEmpty ? nil : $0 }))
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
    }

    @ViewBuilder
    private var versionsSection: some View {
        if !store.versions.isEmpty {
            EditorSection(title: "Versions") {
                ForEach(Array(store.versions.prefix(3).enumerated()), id: \.element.id) { index, version in
                    if index > 0 { Divider().overlay(Color.line) }
                    VersionRow(version: version, isCurrent: version.version == store.publishedVersion)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                if store.versions.count > 0 {
                    Divider().overlay(Color.line)
                    NavigationLink(value: EditorPage.versions) {
                        EditorRow(title: "History and restore", value: "\(store.versions.count)")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Try") {
                Task {
                    await store.saveNow()
                    let botId = store.bot.id
                    dismiss()
                    try? await Task.sleep(for: .milliseconds(300))
                    router.openChat(botId: botId, useDraft: true)
                }
            }
            .buttonStyle(InkButtonStyle(prominent: false))
            Button {
                showsPublish = true
            } label: {
                if store.publishing { ProgressView().tint(Color.onInk) } else { Text("Publish v\(store.nextVersion)") }
            }
            .buttonStyle(InkButtonStyle())
            .disabled(!store.hasDraft || store.publishing)
            .opacity(store.hasDraft ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(LinearGradient(colors: [Color.canvas.opacity(0), Color.canvas], startPoint: .top, endPoint: .center))
    }
}

struct EditorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.line))
    }
}

struct EditorRow: View {
    let title: LocalizedStringKey
    let value: String
    var chevron = "chevron.right"

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Color.ink)
            Spacer()
            Text(value).foregroundStyle(Color.text2).lineLimit(1)
            Image(systemName: chevron).font(.caption.weight(.semibold)).foregroundStyle(Color.text3)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct VersionRow: View {
    let version: BotVersion
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("v\(version.version)").font(.body.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(version.note ?? String(localized: "No note")).font(.subheadline).foregroundStyle(Color.ink).lineLimit(1)
                Text(version.publishedAt.relativeLabel).font(.caption).foregroundStyle(Color.text3)
            }
            Spacer()
            if isCurrent { Badge(text: String(localized: "Live"), dot: Color.good) }
        }
    }
}

private struct AgentPicker: View {
    let store: BotEditorStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(store.agents) { agent in
                Button {
                    guard agent.available else { return }
                    store.selectAgent(agent)
                    Haptics.selection()
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.displayName).font(.body.weight(.medium)).foregroundStyle(agent.available ? Color.ink : Color.text3)
                            HStack(spacing: 6) {
                                if !agent.available {
                                    Badge(text: String(localized: "Unavailable"))
                                } else if !agent.authenticated {
                                    Badge(text: String(localized: "Sign-in required"), dot: Color(hex: 0xF5A623))
                                } else {
                                    Badge(text: String(localized: "Ready"), dot: Color.good)
                                }
                                Text(agent.note ?? String(localized: "\(agent.models.count) models")).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                            }
                        }
                        Spacer()
                        if agent.id == store.config.agent {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InstructionsEditor: View {
    @Binding var text: String
    @AppStorage("nuo.editor.monospace") private var monospace = false
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(monospace ? .system(.callout, design: .monospaced) : .body)
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .focused($focused)
            .background(Color.canvas)
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        monospace.toggle()
                    } label: {
                        Image(systemName: monospace ? "textformat" : "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityLabel(monospace ? String(localized: "Regular font") : String(localized: "Monospaced font"))
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("\(text.count) characters").font(.caption).foregroundStyle(Color.text3)
                }
            }
            .onAppear { focused = true }
    }
}

private struct DiffView: View {
    let lines: [DiffLine]
    let version: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(symbol(line.kind)).foregroundStyle(tint(line.kind)).frame(width: 12)
                        Text(line.text.isEmpty ? " " : line.text).foregroundStyle(line.kind == .same ? Color.text2 : Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(background(line.kind))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.line))
            .padding(16)
        }
        .background(Color.canvas)
        .navigationTitle(version.map { String(localized: "Draft vs v\($0)") } ?? String(localized: "Draft"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func symbol(_ kind: DiffLine.Kind) -> String {
        switch kind { case .same: " "; case .added: "+"; case .removed: "−" }
    }

    private func tint(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .same: .text3; case .added: .good; case .removed: .bad }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: Color.card
        case .added: Color.good.opacity(0.12)
        case .removed: Color.bad.opacity(0.10)
        }
    }
}

private struct VersionsView: View {
    let store: BotEditorStore
    @State private var pending: BotVersion?

    var body: some View {
        List {
            ForEach(store.versions) { version in
                VersionRow(version: version, isCurrent: version.version == store.publishedVersion)
                    .listRowBackground(Color.card)
                    .swipeActions(edge: .trailing) {
                        if version.version != store.publishedVersion {
                            Button("Restore") { pending = version }.tint(Color.accent)
                        }
                    }
                    .contextMenu {
                        if version.version != store.publishedVersion {
                            Button { pending = version } label: { Label("Restore this version", systemImage: "clock.arrow.circlepath") }
                        }
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Versions")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Restore v\(pending?.version ?? 0)?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Publish a copy of v\(pending?.version ?? 0)") {
                guard let version = pending else { return }
                Task { await store.rollback(to: version) }
            }
        } message: {
            Text("A new version, v\(store.nextVersion), will be published with this configuration.")
        }
    }
}

private struct AppearancePicker: View {
    @Binding var emoji: String
    @Binding var color: String
    @Environment(\.dismiss) private var dismiss

    private let emojis = ["🦊", "✈️", "🏃", "🤖", "🧠", "📚", "🍳", "💼", "🏠", "🎵", "📈", "🛠️", "🌍", "🧘", "💬", "✨", "🐙", "🦉", "🌱", "⚡️"]
    private let colors = ["#FFE8D9", "#E0EEFF", "#E3F6E8", "#F1E8FF", "#FFF4CC", "#FFE0E6", "#E0F7F7", "#ECEAE4"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    BotAvatar(emoji: emoji, color: color, size: 84).padding(.top, 8)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                        ForEach(colors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hexString: hex) ?? .chip)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().strokeBorder(hex == color ? Color.ink : Color.line, lineWidth: hex == color ? 2 : 1))
                                .onTapGesture { Haptics.selection(); color = hex }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                        ForEach(emojis, id: \.self) { item in
                            Text(item)
                                .font(.title)
                                .frame(width: 54, height: 54)
                                .background(item == emoji ? Color.chip : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .onTapGesture { Haptics.selection(); emoji = item }
                        }
                    }
                    TextField("Other emoji", text: Binding(get: { "" }, set: { if let first = $0.first { emoji = String(first) } }))
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(20)
            }
            .background(Color.canvas)
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}
