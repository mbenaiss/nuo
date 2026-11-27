import SwiftUI

/// "Tasks": prompts the gateway sends to bots, and commands it runs, on a schedule, grouped by bot.
struct SchedulesView: View {
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    @State private var store: SchedulesStore
    @State private var selected: String?
    @State private var editor: ScheduleEditorTarget?
    @State private var pendingDelete: ScheduledTask?
    @State private var appliedDemo = false
    @State private var focusTaskId: String?

    init(botId: String? = nil, focusTaskId: String? = nil) {
        _store = State(initialValue: SchedulesStore(botId: botId))
        _focusTaskId = State(initialValue: focusTaskId)
    }

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
        List {
            Section {
                intro
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if store.isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if store.tasks.isEmpty {
                emptyState.listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.botId) { group in
                Section {
                    ForEach(group.tasks) { task in
                        ScheduleRow(task: task, running: store.runningIds.contains(task.id)) {
                            selected = task.id
                        } onToggle: { value in
                            Task { await store.setEnabled(task, value) }
                        }
                        .listRowBackground(Color.card)
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = task } label: { Label("Delete", systemImage: "trash") }
                            Button { editor = ScheduleEditorTarget(task: task) } label: { Label("Edit", systemImage: "pencil") }
                                .tint(Color.text2)
                        }
                        .contextMenu {
                            Button { editor = ScheduleEditorTarget(task: task) } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { pendingDelete = task } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    if store.botId == nil { groupHeader(group.bot, count: group.tasks.count) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle(store.botId.flatMap { bots.bot(id: $0)?.config?.name }.map { String(localized: "Tasks · \($0)") } ?? String(localized: "Tasks"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.tap()
                    editor = ScheduleEditorTarget(task: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New task")
            }
        }
        .navigationDestination(item: $selected) { id in
            ScheduleDetailView(store: store, taskId: id)
        }
        .sheet(item: $editor) { target in
            ScheduleEditorView(store: store, original: target.task, defaultBotId: store.botId)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete task", role: .destructive) {
                guard let task = pendingDelete else { return }
                Task { await store.delete(task) }
            }
        } message: {
            Text("It will no longer run. Its conversations are kept.")
        }
        .task {
            store.attach(session.api)
            await store.load()
            if let id = focusTaskId {
                focusTaskId = nil
                selected = id
            }
            applyDemo()
        }
        .refreshable { await store.load() }
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(Color.accentInk)
                .frame(width: 38, height: 38)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Your bots run these prompts on their own and notify you of the answer. They can also create some when you ask “remind me…”. Commands run on the gateway, without a bot.")
                .font(.subheadline)
                .foregroundStyle(Color.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock").font(.largeTitle).foregroundStyle(Color.text3)
            Text(store.loadError == nil ? String(localized: "No scheduled tasks") : String(localized: "Tasks unavailable")).font(.headline).foregroundStyle(Color.ink)
            Text(store.loadError ?? String(localized: "For example: today's workout every morning at 7:00."))
                .font(.subheadline).foregroundStyle(Color.text2).multilineTextAlignment(.center)
            if store.loadError == nil {
                Button("New task") { editor = ScheduleEditorTarget(task: nil) }
                    .buttonStyle(InkButtonStyle())
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func groupHeader(_ bot: Bot?, count: Int) -> some View {
        HStack(spacing: 8) {
            BotAvatar(config: bot?.config, size: 24)
            Text(bot?.config?.name ?? String(localized: "Deleted bot"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
                .textCase(nil)
            Spacer()
            Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.text3)
        }
    }

    private func applyDemo() {
        guard !appliedDemo, let target = SchedulesDemo.target else { return }
        appliedDemo = true
        if target == "new" {
            editor = ScheduleEditorTarget(task: nil)
        } else if target.hasPrefix("edit:") {
            editor = ScheduleEditorTarget(task: store.task(id: String(target.dropFirst(5))))
        } else if store.task(id: target) != nil {
            selected = target
        }
    }
}

struct ScheduleEditorTarget: Identifiable {
    let id = UUID()
    let task: ScheduledTask?
}

private struct ScheduleRow: View {
    let task: ScheduledTask
    let running: Bool
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if task.isCommand {
                            Image(systemName: "terminal")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.text2)
                                .accessibilityHidden(true)
                        }
                        Text(task.title).font(.body.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                        if task.isCommand {
                            Badge(text: String(localized: "Command"))
                        } else if task.createdBy == "bot" {
                            Badge(text: String(localized: "created by the bot"), tint: Color.accentInk, fill: Color.accentSoft)
                        }
                    }
                    Text(ScheduleText.describe(task.schedule))
                        .font(.subheadline)
                        .foregroundStyle(task.enabled ? Color.text2 : Color.text3)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ScheduleStatusDot(status: running ? "running" : task.lastStatus)
                        Text(nextLabel).font(.caption).foregroundStyle(Color.text3).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("Active", isOn: Binding(get: { task.enabled }, set: onToggle))
                .labelsHidden()
                .tint(Color.accent)
        }
        .padding(.vertical, 4)
        .opacity(task.enabled ? 1 : 0.75)
        .accessibilityElement(children: .contain)
    }

    private var nextLabel: String {
        if running { return String(localized: "Running…") }
        guard task.enabled else { return String(localized: "Paused") }
        if let next = task.nextRunAt {
            return task.schedule.kind == "once" ? String(localized: "One time, \(ScheduleText.countdown(next))") : String(localized: "Next: \(ScheduleText.relative(next))")
        }
        return task.schedule.kind == "once" ? String(localized: "Finished") : String(localized: "No run planned")
    }
}

struct ScheduleStatusDot: View {
    let status: String?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case "ok": .good
        case "error": .bad
        case "running": Color(hex: 0xF5A623)
        default: .text3.opacity(0.6)
        }
    }

    private var label: String {
        switch status {
        case "ok": String(localized: "Last run succeeded")
        case "error": String(localized: "Last run failed")
        case "running": String(localized: "Running")
        default: String(localized: "Never run")
        }
    }
}
