import SwiftUI

struct ScheduleList: View {
    let store: SchedulesStore
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(MacNavigator.self) private var navigator
    @State private var editing: ScheduleEditorTarget?
    @State private var pendingDelete: ScheduledTask?
    @State private var runError: String?

    private var groups: [(bot: Bot?, botId: String, tasks: [ScheduledTask])] {
        let grouped = Dictionary(grouping: store.tasks, by: \.botId)
        let order = bots.bots.map(\.id)
        return grouped.keys
            .sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
            .map { id in
                let tasks = grouped[id, default: []].sorted { lhs, rhs in
                    if lhs.enabled != rhs.enabled { return lhs.enabled }
                    return (lhs.nextRunAt ?? .distantFuture) < (rhs.nextRunAt ?? .distantFuture)
                }
                return (bots.bot(id: id), id, tasks)
            }
    }

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.schedule) {
            if store.isLoading { SkeletonRows(count: 4) }
            ForEach(groups, id: \.botId) { group in
                Section {
                    ForEach(group.tasks) { task in
                        MacScheduleRow(task: task, running: store.runningIds.contains(task.id)) { value in
                            Task { await store.setEnabled(task, value) }
                        }
                        .tag(task.id)
                        .contextMenu {
                            Button("Run Now") { run(task) }
                            Button("Edit…") { editing = ScheduleEditorTarget(task: task) }
                            Divider()
                            Button("Delete…", role: .destructive) { pendingDelete = task }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(group.bot?.config?.emoji ?? "✨")
                        Text(group.bot?.config?.name ?? String(localized: "Deleted bot"))
                    }
                }
            }
        }
        .overlay {
            if !store.isLoading && store.tasks.isEmpty {
                ContentUnavailableView {
                    Label(store.loadError == nil ? String(localized: "No scheduled tasks") : String(localized: "Tasks unavailable"), systemImage: "calendar.badge.clock")
                } description: {
                    Text(store.loadError ?? String(localized: "For example: today's workout every morning at 7:00."))
                } actions: {
                    Button("New Task") { navigator.newSchedule = true }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { navigator.newSchedule = true } label: { Label("New Task", systemImage: "plus") }
                    .help("New task (⌘N)")
            }
        }
        .sheet(item: $editing) { target in
            ScheduleEditorView(store: store, original: target.task, defaultBotId: nil).frame(minWidth: 560, minHeight: 620)
        }
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Task", role: .destructive) {
                guard let task = pendingDelete else { return }
                if navigator.schedule == task.id { navigator.schedule = nil }
                Task { await store.delete(task) }
            }
        } message: {
            Text("It won't run anymore. Its conversations stay.")
        }
        .alert("Unable to run", isPresented: Binding(get: { runError != nil }, set: { if !$0 { runError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(runError ?? "")
        }
        .task(id: navigator.refreshTick) {
            store.attach(session.api)
            await store.load()
            if navigator.schedule == nil { navigator.schedule = store.tasks.first?.id }
        }
    }

    private func run(_ task: ScheduledTask) {
        Task {
            do {
                try await store.runNow(task)
            } catch {
                Haptics.error()
                runError = error.localizedDescription
            }
        }
    }
}

private struct MacScheduleRow: View {
    let task: ScheduledTask
    let running: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if task.isCommand { Image(systemName: "terminal").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(task.title).font(.body.weight(.medium)).lineLimit(1)
                    if task.createdBy == "bot" { Badge(text: "bot", tint: Color.accentInk, fill: Color.accentSoft) }
                }
                Text(ScheduleText.describe(task.schedule)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    ScheduleStatusDot(status: running ? "running" : task.lastStatus)
                    Text(nextLabel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Toggle("Active", isOn: Binding(get: { task.enabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 3)
        .opacity(task.enabled ? 1 : 0.7)
    }

    private var nextLabel: String {
        if running { return String(localized: "Running…") }
        guard task.enabled else { return String(localized: "Paused") }
        if let next = task.nextRunAt {
            return task.schedule.kind == "once" ? String(localized: "Once, \(ScheduleText.countdown(next))") : String(localized: "Next: \(ScheduleText.relative(next))")
        }
        return task.schedule.kind == "once" ? String(localized: "Finished") : String(localized: "No run planned")
    }
}

struct MemoryBotList: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @Environment(MacNavigator.self) private var navigator
    @State private var memories: [String: BotMemory] = [:]

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.memoryBot) {
            Section {
                ForEach(bots.bots) { bot in
                    HStack(spacing: 10) {
                        BotAvatar(config: bot.config, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bot.config?.name ?? String(localized: "Bot")).font(.body.weight(.medium))
                            Text(detail(bot.id)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(bot.id)
                }
            } footer: {
                Text("Each bot keeps its lasting facts from one conversation to the next, and rereads them at the start of each.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .task(id: navigator.refreshTick) { await load() }
        .onChange(of: navigator.memoryBot) { _, _ in Task { await load() } }
    }

    private func detail(_ botId: String) -> String {
        guard let memory = memories[botId] else { return "…" }
        let count = MemoryDocument(memory.content).facts.count
        let facts = count == 0 ? String(localized: "Empty") : String(localized: "\(count) facts")
        guard count > 0, let updated = memory.updatedAt else { return facts }
        return "\(facts) · \(MemoryDocument.updatedLabel(updated))"
    }

    private func load() async {
        await withTaskGroup(of: (String, BotMemory?).self) { group in
            for bot in bots.bots {
                group.addTask { [api = session.api] in (bot.id, try? await api.memory(botId: bot.id)) }
            }
            for await (id, memory) in group {
                if let memory { memories[id] = memory }
            }
        }
    }
}
