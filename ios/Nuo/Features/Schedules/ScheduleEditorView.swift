import SwiftUI

/// Create or edit a scheduled task (a prompt to a bot, or a shell command on the gateway). The schedule is picked from presets; cron stays behind "Advanced".
struct ScheduleEditorView: View {
    let store: SchedulesStore
    let original: ScheduledTask?
    @Environment(BotsStore.self) private var bots
    @Environment(\.dismiss) private var dismiss

    @State private var botId: String?
    @State private var title = ""
    @State private var kind = "prompt"
    @State private var prompt = ""
    @State private var command = ""
    @State private var cwd = ""
    @State private var envFile = ""
    @State private var timeoutSec = TaskAction.defaultTimeoutSec
    @State private var notifyOn = "failure"
    @State private var rule = ScheduleRule()
    @State private var conversation = "dedicated"
    @State private var notify = true
    @State private var enabled = true
    @State private var showsAdvanced = false
    @State private var cronDraft = ""
    @State private var attempted = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmsDelete = false

    init(store: SchedulesStore, original: ScheduledTask?, defaultBotId: String? = nil) {
        self.store = store
        self.original = original
        _botId = State(initialValue: original?.botId ?? defaultBotId)
        guard let original else { return }
        let rule = ScheduleRule(original.schedule)
        _title = State(initialValue: original.title)
        _prompt = State(initialValue: original.prompt)
        if let action = original.action, original.isCommand {
            _kind = State(initialValue: "command")
            _command = State(initialValue: action.command ?? "")
            _cwd = State(initialValue: action.cwd ?? "")
            _envFile = State(initialValue: action.envFile ?? "")
            _timeoutSec = State(initialValue: action.timeoutSec ?? TaskAction.defaultTimeoutSec)
            _notifyOn = State(initialValue: action.notifyOn ?? "failure")
        }
        _rule = State(initialValue: rule)
        _cronDraft = State(initialValue: rule.cronExpression)
        _conversation = State(initialValue: original.conversation)
        _notify = State(initialValue: original.notify)
        _enabled = State(initialValue: original.enabled)
        _showsAdvanced = State(initialValue: rule.preset == .custom)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    kindPicker
                    botSection
                    if isCommand {
                        commandSection
                    } else {
                        taskSection
                    }
                    scheduleSection
                    if isCommand {
                        commandOptionsSection
                    } else {
                        optionsSection
                    }
                    if let saveError {
                        Text(saveError).font(.footnote).foregroundStyle(Color.bad).padding(.horizontal, 4)
                    }
                    if original != nil {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Text("Delete task").font(.body.weight(.medium)).foregroundStyle(Color.bad)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .animation(.snappy(duration: 0.25), value: rule.preset)
                .animation(.snappy(duration: 0.25), value: showsAdvanced)
                .animation(.snappy(duration: 0.25), value: kind)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.canvas)
            .navigationTitle(original == nil ? String(localized: "New Task") : String(localized: "Task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(original == nil ? String(localized: "Create") : String(localized: "Save")) { Task { await save() } }
                            .fontWeight(.semibold)
                            .tint(Color.accent)
                    }
                }
            }
            .confirmationDialog("Delete “\(original?.title ?? "")”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete task", role: .destructive) {
                    guard let original else { return }
                    Task {
                        await store.delete(original)
                        dismiss()
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var selectedBot: Bot? { botId.flatMap { bots.bot(id: $0) } }

    private var isCommand: Bool { kind == "command" }

    private var preview: some View {
        HStack(spacing: 12) {
            if isCommand {
                CommandGlyph(size: 40)
            } else {
                BotAvatar(config: selectedBot?.config, size: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? String(localized: "Task title") : title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(title.isEmpty ? Color.text3 : Color.ink)
                    .lineLimit(1)
                Text(rule.error == nil ? ScheduleText.describe(rule.schedule) : String(localized: "Schedule to complete"))
                    .font(.footnote)
                    .foregroundStyle(Color.text2)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if rule.error == nil, let next = rule.nextRun {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Next").font(.caption2).foregroundStyle(Color.text3)
                    Text(ScheduleText.relative(next)).font(.caption.weight(.semibold)).foregroundStyle(Color.accentInk)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(Color.card.opacity(0.55)), in: .rect(cornerRadius: 20))
        .padding(.top, 8)
    }

    private var botSection: some View {
        EditorSection(title: "Bot") {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(bots.bots) { bot in
                            botChip(bot)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .disabled(original != nil)
                if attempted, botId == nil {
                    Text(isCommand ? String(localized: "Pick the bot to file the command under.") : String(localized: "Pick the bot that will receive the prompt."))
                        .font(.caption).foregroundStyle(Color.bad).padding(.horizontal, 16)
                } else if isCommand, original == nil {
                    Text("No bot is started: it only files the task and its notifications.").font(.caption).foregroundStyle(Color.text3).padding(.horizontal, 16)
                } else if original != nil {
                    Text("A task's bot can't be changed: create another one if needed.").font(.caption).foregroundStyle(Color.text3).padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func botChip(_ bot: Bot) -> some View {
        let isSelected = botId == bot.id
        return Button {
            Haptics.selection()
            botId = bot.id
        } label: {
            HStack(spacing: 6) {
                Text(bot.config?.emoji ?? "✨").font(.system(size: 18))
                Text(bot.config?.name ?? "Bot").font(.subheadline.weight(.semibold)).lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(Color(hex: 0x16161A))
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 40)
            .background(Color(hexString: bot.config?.color ?? "") ?? Color.chip, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.ink : Color.black.opacity(0.08), lineWidth: isSelected ? 2 : 1))
            .opacity(botId == nil || isSelected ? 1 : 0.55)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var taskSection: some View {
        EditorSection(title: "Task") {
            field(String(localized: "Title"), error: attempted && trimmed(title).isEmpty ? String(localized: "Give the task a title.") : nil) {
                TextField("Today's workout", text: $title)
            }
            Divider().overlay(Color.line)
            field(String(localized: "Prompt sent to the bot"),
                  error: attempted && trimmed(prompt).isEmpty ? String(localized: "Write what the bot should do.") : nil,
                  footer: String(localized: "As in chat: /commands and #tools accepted, for example “#gog my meetings this week”.")) {
                TextField("Which workout today?", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
    }

    private var scheduleSection: some View {
        EditorSection(title: "When") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(SchedulePreset.allCases.filter { $0 != .custom || rule.preset == .custom }) { preset in
                        presetButton(preset)
                    }
                }
                presetFields
                if attempted, let error = rule.error {
                    Text(error).font(.caption).foregroundStyle(Color.bad)
                } else if let next = rule.nextRun {
                    Label("Next run: \(next.formatted(Date.FormatStyle(locale: ScheduleText.locale).weekday(.wide).day().month(.wide))) at \(ScheduleText.time(next))",
                          systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(Color.text2)
                        .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 14)
            if rule.preset != .once {
                Divider().overlay(Color.line)
                advanced
            }
        }
    }

    private func presetButton(_ preset: SchedulePreset) -> some View {
        let isSelected = rule.preset == preset
        return Button {
            Haptics.selection()
            if preset == .custom { return }
            rule.preset = preset
            if preset == .weekly, rule.weekdays.isEmpty { rule.weekdays = [1] }
            cronDraft = rule.cronExpression
        } label: {
            HStack(spacing: 8) {
                Image(systemName: preset.symbol).font(.footnote.weight(.semibold)).frame(width: 18)
                Text(preset.label).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.onInk : Color.ink)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(isSelected ? Color.inkFill : Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private var presetFields: some View {
        switch rule.preset {
        case .daily, .weekdays:
            timeRow
        case .weekly:
            weekdayPicker
            timeRow
        case .hourly:
            Stepper(value: Binding(get: { rule.everyHours }, set: { rule.everyHours = $0; cronDraft = rule.cronExpression }), in: 1...12) {
                HStack {
                    Text("Every").foregroundStyle(Color.ink)
                    Text(verbatim: "\(rule.everyHours) h").font(.body.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
                }
            }
            Stepper(value: Binding(get: { rule.minute }, set: { rule.minute = $0; cronDraft = rule.cronExpression }), in: 0...55, step: 5) {
                HStack {
                    Text("At minute").foregroundStyle(Color.ink)
                    Text(verbatim: ":\(String(format: "%02d", rule.minute))").font(.body.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
                }
            }
        case .once:
            DatePicker("On", selection: $rule.onceAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .environment(\.locale, ScheduleText.locale)
                .tint(Color.accent)
        case .custom:
            Text("Custom cron expression, editable under “Advanced”.").font(.subheadline).foregroundStyle(Color.text2)
        }
    }

    private var timeRow: some View {
        DatePicker("Time", selection: Binding(get: { rule.time }, set: { rule.time = $0; cronDraft = rule.cronExpression }), displayedComponents: .hourAndMinute)
            .environment(\.locale, ScheduleText.locale)
            .foregroundStyle(Color.ink)
    }

    private var weekdayPicker: some View {
        let letters = [String(localized: "schedule.day.initial.0", defaultValue: "S"), String(localized: "schedule.day.initial.1", defaultValue: "M"),
                       String(localized: "schedule.day.initial.2", defaultValue: "T"), String(localized: "schedule.day.initial.3", defaultValue: "W"),
                       String(localized: "schedule.day.initial.4", defaultValue: "T"), String(localized: "schedule.day.initial.5", defaultValue: "F"),
                       String(localized: "schedule.day.initial.6", defaultValue: "S")]
        let names = WeekdayNames.long
        return HStack(spacing: 6) {
            ForEach(ScheduleRule.weekOrder, id: \.self) { day in
                let isOn = rule.weekdays.contains(day)
                Button {
                    Haptics.selection()
                    if isOn { rule.weekdays.remove(day) } else { rule.weekdays.insert(day) }
                    cronDraft = rule.cronExpression
                } label: {
                    Text(letters[day])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOn ? Color.onInk : Color.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(isOn ? Color.inkFill : Color.chip, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(names[day])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsAdvanced.toggle()
            } label: {
                HStack {
                    Text("Advanced").foregroundStyle(Color.ink)
                    Spacer()
                    if !showsAdvanced {
                        Text(rule.cronExpression).font(.footnote.monospaced()).foregroundStyle(Color.text3).lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.text3)
                        .rotationEffect(.degrees(showsAdvanced ? 0 : -90))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsAdvanced {
                Divider().overlay(Color.line)
                field(String(localized: "Cron expression"), footer: String(localized: "minute hour day month weekday, e.g. 0 7 * * 1-5")) {
                    TextField("0 7 * * 1-5", text: $cronDraft)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: cronDraft) { _, value in
                            guard value != rule.cronExpression else { return }
                            rule.apply(expression: value)
                        }
                }
                Divider().overlay(Color.line)
                field(String(localized: "Time zone"), error: TimeZone(identifier: rule.timezone) == nil ? String(localized: "Unknown time zone (e.g. Europe/Paris).") : nil) {
                    TextField(ScheduleRule.defaultTimeZone, text: $rule.timezone)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
    }

    private var optionsSection: some View {
        EditorSection(title: "Reply") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    modeButton("dedicated", title: String(localized: "Same conversation"), symbol: "bubble.left")
                    modeButton("new", title: String(localized: "New each time"), symbol: "plus.bubble")
                }
                Text(conversation == "dedicated"
                     ? String(localized: "The bot keeps the thread from one run to the next, in a separate conversation.")
                     : String(localized: "Each run starts from a blank conversation."))
                    .font(.caption)
                    .foregroundStyle(Color.text2)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 12)
            Divider().overlay(Color.line)
            Toggle("Notify me", isOn: $notify)
                .tint(Color.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider().overlay(Color.line)
            Toggle("Active", isOn: $enabled)
                .tint(Color.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 8) {
            choiceButton(String(localized: "Prompt to a bot"), symbol: "bubble.left.and.text.bubble.right", isSelected: !isCommand) { selectKind("prompt") }
            choiceButton(String(localized: "Command"), symbol: "terminal", isSelected: isCommand) { selectKind("command") }
        }
    }

    private func selectKind(_ value: String) {
        kind = value
        // Command tasks live under Cobot unless the user picks another bot.
        if value == "command", botId == nil {
            botId = bots.bots.first { $0.slug == "cobot" || $0.config?.name.lowercased() == "cobot" }?.id
        }
    }

    private var commandSection: some View {
        EditorSection(title: "Command") {
            field(String(localized: "Title"), error: attempted && trimmed(title).isEmpty ? String(localized: "Give the task a title.") : nil) {
                TextField("Cloud budget guard", text: $title)
            }
            Divider().overlay(Color.line)
            field(String(localized: "Command"), error: attempted && trimmed(command).isEmpty ? String(localized: "Write the command to run.") : nil,
                  footer: String(localized: "Run with /bin/bash -c on the gateway, without a bot. ~ and variables work.")) {
                TextField("~/bin/nightly-backup.sh", text: $command, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(1...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Divider().overlay(Color.line)
            field(String(localized: "Folder"), error: pathError(cwd), footer: String(localized: "Empty: the home folder.")) {
                pathField(String(localized: "~/go/src/github.com/…"), text: $cwd)
            }
            Divider().overlay(Color.line)
            field(String(localized: "Env file"), error: pathError(envFile), footer: envFooter) {
                pathField(String(localized: "~/project/.env"), text: $envFile)
            }
            Divider().overlay(Color.line)
            Stepper(value: $timeoutSec, in: 60...86_400, step: 60) {
                HStack {
                    Text("Timeout").foregroundStyle(Color.ink)
                    Spacer()
                    Text(CommandText.duration(seconds: timeoutSec)).font(.body.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var envFooter: String {
        let extra = original?.action?.env?.keys.sorted() ?? []
        let base = String(localized: "KEY=value lines added to the environment, never logged.")
        return extra.isEmpty ? base : String(localized: "\(base) Also set: \(extra.joined(separator: ", ")).")
    }

    private func pathField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func pathError(_ path: String) -> String? {
        let value = trimmed(path)
        guard !value.isEmpty, !(value.hasPrefix("/") || value == "~" || value.hasPrefix("~/")) else { return nil }
        return String(localized: "Absolute path, or starting with ~/.")
    }

    private var commandOptionsSection: some View {
        EditorSection(title: "Notify me") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(CommandText.notifyOptions, id: \.value) { option in
                        choiceButton(option.label, symbol: option.symbol, isSelected: notifyOn == option.value) { notifyOn = option.value }
                    }
                }
                Text(CommandText.notifyHint(notifyOn))
                    .font(.caption)
                    .foregroundStyle(Color.text2)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 12)
            Divider().overlay(Color.line)
            Toggle("Active", isOn: $enabled)
                .tint(Color.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private func modeButton(_ value: String, title: String, symbol: String) -> some View {
        choiceButton(title, symbol: symbol, isSelected: conversation == value) { conversation = value }
    }

    private func choiceButton(_ title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.footnote.weight(.semibold))
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.onInk : Color.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(isSelected ? Color.inkFill : Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    private func field<Content: View>(_ title: String, error: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
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

    // MARK: - Save

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool {
        guard botId != nil, !trimmed(title).isEmpty, rule.error == nil else { return false }
        if isCommand { return !trimmed(command).isEmpty && pathError(cwd) == nil && pathError(envFile) == nil }
        return !trimmed(prompt).isEmpty
    }

    private var commandAction: TaskAction {
        TaskAction(type: "command", command: trimmed(command), cwd: trimmed(cwd).isEmpty ? nil : trimmed(cwd),
                   envFile: trimmed(envFile).isEmpty ? nil : trimmed(envFile), env: original?.action?.env,
                   timeoutSec: timeoutSec, notifyOn: notifyOn)
    }

    private func save() async {
        attempted = true
        guard isValid, let botId else {
            Haptics.error()
            return
        }
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            if isCommand {
                if let original {
                    try await store.update(id: original.id, patch: ScheduledTaskPatch(
                        title: trimmed(title), schedule: rule.schedule, enabled: enabled, action: commandAction))
                } else {
                    try await store.create(ScheduledTaskDraft(
                        botId: botId, title: trimmed(title), prompt: "", schedule: rule.schedule, enabled: enabled, action: commandAction))
                }
            } else if let original {
                try await store.update(id: original.id, patch: ScheduledTaskPatch(
                    title: trimmed(title), prompt: trimmed(prompt), schedule: rule.schedule,
                    enabled: enabled, notify: notify, conversation: conversation, action: original.isCommand ? .prompt : nil))
            } else {
                try await store.create(ScheduledTaskDraft(
                    botId: botId, title: trimmed(title), prompt: trimmed(prompt), schedule: rule.schedule,
                    conversation: conversation, notify: notify, enabled: enabled))
            }
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
            saveError = error.localizedDescription
        }
    }
}
