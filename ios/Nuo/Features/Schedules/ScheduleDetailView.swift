import SwiftUI

struct ScheduleDetailView: View {
    let store: SchedulesStore
    let taskId: String
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ScheduleEditorTarget?
    @State private var confirmsDelete = false
    @State private var runError: String?

    private var task: ScheduledTask? { store.task(id: taskId) }

    var body: some View {
        Group {
            if let task {
                content(task)
            } else {
                ContentUnavailableView("Task deleted", systemImage: "calendar.badge.minus")
            }
        }
        .background(Color.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let task {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = ScheduleEditorTarget(task: task) }
                }
            }
        }
        .sheet(item: $editing) { target in
            ScheduleEditorView(store: store, original: target.task)
        }
        .confirmationDialog("Delete “\(task?.title ?? "")”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete task", role: .destructive) {
                guard let task else { return }
                Task {
                    await store.delete(task)
                    dismiss()
                }
            }
        } message: {
            Text("It will no longer run. Its conversations are kept.")
        }
        .task { await store.loadRuns(taskId: taskId) }
        .refreshable {
            await store.load()
            await store.loadRuns(taskId: taskId)
        }
    }

    private func content(_ task: ScheduledTask) -> some View {
        let bot = bots.bot(id: task.botId)
        let running = store.runningIds.contains(task.id)
        return ScrollViewReader { proxy in
        GroupedList {
            Section {
                VStack(spacing: 10) {
                    if task.isCommand {
                        CommandGlyph(size: 64)
                    } else {
                        BotAvatar(config: bot?.config, size: 64)
                    }
                    Text(task.title).font(.title2.bold()).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                    Text(ScheduleText.describe(task.schedule)).font(.subheadline).foregroundStyle(Color.text2)
                    HStack(spacing: 6) {
                        if task.isCommand { Badge(text: String(localized: "Command"), tint: Color.accentInk, fill: Color.accentSoft) }
                        Badge(text: bot?.config?.name ?? "Bot")
                        if task.createdBy == "bot" { Badge(text: String(localized: "created by the bot"), tint: Color.accentInk, fill: Color.accentSoft) }
                        if !task.enabled { Badge(text: String(localized: "Paused")) }
                    }
                    actions(task, running: running)
                        .padding(.top, 6)
                    if let runError {
                        Text(runError).font(.footnote).foregroundStyle(Color.bad)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                // Buttons span the same width as the cards below.
                .listRowInsets(EdgeInsets(top: Spacing.xs, leading: 0, bottom: 0, trailing: 0))
            }

            Section {
                LabeledContent("Next") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(nextText(task)).foregroundStyle(Color.text2)
                        if task.enabled, let next = task.nextRunAt {
                            Text(ScheduleText.countdown(next)).font(.caption).foregroundStyle(Color.accentInk)
                        }
                    }
                }
                LabeledContent("Last") {
                    HStack(spacing: 6) {
                        if task.lastRunAt != nil { ScheduleStatusDot(status: running ? "running" : task.lastStatus) }
                        Text(task.lastRunAt.map(ScheduleText.runDate) ?? String(localized: "Never")).foregroundStyle(Color.text2)
                    }
                }
                if let action = task.action, task.isCommand {
                    Picker("Notify me", selection: Binding(get: { action.notifyOn ?? "failure" }, set: { value in
                        var changed = action
                        changed.notifyOn = value
                        Task { try? await store.update(id: task.id, patch: ScheduledTaskPatch(action: changed)) }
                    })) {
                        ForEach(CommandText.notifyOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .tint(Color.text2)
                } else {
                    LabeledContent("Reply") {
                        Text(task.conversation == "dedicated" ? String(localized: "Same conversation") : String(localized: "New each time")).foregroundStyle(Color.text2)
                    }
                    Toggle("Notify me", isOn: Binding(get: { task.notify }, set: { value in
                        Task { try? await store.update(id: task.id, patch: ScheduledTaskPatch(notify: value)) }
                    }))
                    .tint(Color.accent)
                }
                Toggle("Active", isOn: Binding(get: { task.enabled }, set: { value in
                    Task { await store.setEnabled(task, value) }
                }))
                .tint(Color.accent)
            }
            .listRowBackground(Color.card)

            if let action = task.action, task.isCommand {
                commandSection(action)
            }

            Section {
                let runs = store.runsByTask[task.id] ?? []
                if runs.isEmpty {
                    Text("Not run yet.").font(.subheadline).foregroundStyle(Color.text2)
                }
                let expandedRun = runs.contains { $0.id == router.focusedRunId } ? router.focusedRunId : runs.first?.id
                ForEach(runs) { run in
                    if task.isCommand {
                        CommandRunRow(run: run, expanded: run.id == expandedRun)
                            .id(run.id)
                    } else {
                        Button {
                            router.openChat(botId: task.botId, conversationId: run.conversationId)
                        } label: {
                            RunRow(run: run)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                SectionHeader(title: String(localized: "History"))
            }
            .listRowBackground(Color.card)

            if !task.isCommand {
                Section {
                    Text(task.prompt)
                        .font(.callout)
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                } header: {
                    SectionHeader(title: "Prompt")
                }
                .listRowBackground(Color.card)
            }

            Section {
                Button("Delete task", role: .destructive) { confirmsDelete = true }
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: store.runsByTask[task.id]?.map(\.id), initial: true) { _, ids in
            guard let focus = router.focusedRunId, ids?.contains(focus) == true else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation { proxy.scrollTo(focus, anchor: .top) }
                router.focusedRunId = nil
            }
        }
        .task {
            guard SchedulesDemo.scrollsToRuns else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if let last = store.runsByTask[task.id]?.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
        }
    }

    @ViewBuilder
    private func actions(_ task: ScheduledTask, running: Bool) -> some View {
        let run = Button {
            Task { await runNow(task) }
        } label: {
            if running {
                HStack(spacing: 8) { ProgressView().controlSize(.small).tint(Color.onInk); Text("Running…") }
            } else {
                Label("Run now", systemImage: "play.fill")
            }
        }
        .disabled(running)
        let open = task.isCommand ? nil : task.conversationId.map { id in
            Button {
                router.openChat(botId: task.botId, conversationId: id)
            } label: {
                Label("Open conversation", systemImage: "bubble.left")
            }
        }
        #if os(macOS)
        HStack(spacing: 8) {
            run.buttonStyle(.borderedProminent)
            if let open { open.buttonStyle(.bordered) }
        }
        .controlSize(.large)
        #else
        VStack(spacing: 8) {
            run.buttonStyle(InkButtonStyle())
            if let open { open.buttonStyle(InkButtonStyle(prominent: false)) }
        }
        #endif
    }

    private func commandSection(_ action: TaskAction) -> some View {
        Section {
            ScrollView(.horizontal) {
                Text("$ \(action.command ?? "")")
                    .font(.callout.monospaced())
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            LabeledContent("Folder") {
                Text(action.cwd ?? "~").font(.footnote.monospaced()).foregroundStyle(Color.text2).lineLimit(2).truncationMode(.head)
            }
            if let envFile = action.envFile {
                LabeledContent("Env file") {
                    Text(envFile).font(.footnote.monospaced()).foregroundStyle(Color.text2).lineLimit(2).truncationMode(.head)
                }
            }
            if let env = action.env, !env.isEmpty {
                LabeledContent("Variables") {
                    Text(env.keys.sorted().joined(separator: ", ")).font(.footnote.monospaced()).foregroundStyle(Color.text2).lineLimit(2)
                }
            }
            LabeledContent("Timeout") {
                Text(CommandText.duration(seconds: action.timeoutSec ?? TaskAction.defaultTimeoutSec)).foregroundStyle(Color.text2)
            }
        } header: {
            SectionHeader(title: String(localized: "Command"))
        } footer: {
            Text("Run by the gateway with /bin/bash, without a bot or conversation.").font(.caption).foregroundStyle(Color.text3)
        }
        .listRowBackground(Color.card)
    }

    private func nextText(_ task: ScheduledTask) -> String {
        guard task.enabled else { return String(localized: "Paused") }
        guard let next = task.nextRunAt else { return task.schedule.kind == "once" ? String(localized: "Finished") : "—" }
        return ScheduleText.runDate(next)
    }

    private func runNow(_ task: ScheduledTask) async {
        runError = nil
        Haptics.send()
        do {
            try await store.runNow(task)
        } catch {
            Haptics.error()
            runError = error.localizedDescription
        }
    }
}

private struct RunRow: View {
    let run: TaskRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScheduleStatusDot(status: run.status).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(ScheduleText.runDate(run.startedAt)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Spacer()
                    if let ended = run.endedAt {
                        Text(durationLabel(Int(ended.timeIntervalSince(run.startedAt) * 1000)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.text3)
                    } else if run.status == "running" {
                        Text("Running…").font(.caption).foregroundStyle(Color.text3)
                    }
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Color.text3)
                }
                if let error = run.error {
                    Text(error).font(.footnote).foregroundStyle(Color.bad).lineLimit(2)
                } else if let preview = run.preview {
                    Text(ResponseBlockParser.plainText(preview)).font(.footnote).foregroundStyle(Color.text2).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
