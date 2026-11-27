import Foundation
import Observation

/// Scheduled tasks of the gateway, optionally limited to one bot.
@MainActor
@Observable
final class SchedulesStore {
    private(set) var tasks: [ScheduledTask] = []
    private(set) var runsByTask: [String: [TaskRun]] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var runningIds: Set<String> = []
    let botId: String?

    @ObservationIgnored private var api: (any NuoAPI)?

    init(botId: String? = nil) {
        self.botId = botId
    }

    func attach(_ api: any NuoAPI) {
        self.api = api
    }

    func task(id: String) -> ScheduledTask? { tasks.first { $0.id == id } }

    func load() async {
        guard let api else { return }
        isLoading = tasks.isEmpty
        defer { isLoading = false }
        do {
            tasks = try await api.schedules(botId: botId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadRuns(taskId: String) async {
        guard let api, let runs = try? await api.scheduleRuns(id: taskId) else { return }
        runsByTask[taskId] = runs
    }

    @discardableResult
    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask {
        guard let api else { throw NuoError.offline }
        let task = try await api.createSchedule(draft)
        upsert(task)
        return task
    }

    @discardableResult
    func update(id: String, patch: ScheduledTaskPatch) async throws -> ScheduledTask {
        guard let api else { throw NuoError.offline }
        let task = try await api.updateSchedule(id: id, patch: patch)
        upsert(task)
        return task
    }

    func setEnabled(_ task: ScheduledTask, _ enabled: Bool) async {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let previous = tasks[index]
        tasks[index].enabled = enabled
        do {
            try await update(id: task.id, patch: ScheduledTaskPatch(enabled: enabled))
            Haptics.selection()
        } catch {
            Haptics.error()
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = previous }
        }
    }

    func delete(_ task: ScheduledTask) async {
        tasks.removeAll { $0.id == task.id }
        do {
            try await api?.deleteSchedule(id: task.id)
            Haptics.success()
        } catch {
            Haptics.error()
            await load()
        }
    }

    /// Starts a run now, then polls until the gateway reports it finished.
    func runNow(_ task: ScheduledTask) async throws {
        guard let api else { throw NuoError.offline }
        runningIds.insert(task.id)
        defer { runningIds.remove(task.id) }
        let run = try await api.runSchedule(id: task.id)
        runsByTask[task.id, default: []].removeAll { $0.id == run.id }
        runsByTask[task.id, default: []].insert(run, at: 0)
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].lastStatus = run.status
            tasks[index].lastRunAt = run.startedAt
            if tasks[index].conversation == "dedicated", !run.conversationId.isEmpty { tasks[index].conversationId = run.conversationId }
        }
        for _ in 0..<60 where runsByTask[task.id]?.first(where: { $0.id == run.id })?.status == "running" {
            try? await Task.sleep(for: .seconds(2))
            await loadRuns(taskId: task.id)
        }
        await load()
    }

    private func upsert(_ task: ScheduledTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
    }
}

/// `-demo -demoTasks [new | edit:<id> | <id> [-demoTaskRuns]]` opens the tasks screen (and the editor or a detail) for screenshots.
enum SchedulesDemo {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var opensScreen: Bool { arguments.contains("-demo") && arguments.contains("-demoTasks") }
    static var target: String? {
        guard opensScreen, let index = arguments.firstIndex(of: "-demoTasks"), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
    }
    static var scrollsToRuns: Bool { opensScreen && arguments.contains("-demoTaskRuns") }
}
