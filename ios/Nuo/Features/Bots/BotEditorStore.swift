import Foundation
import Observation

/// Edits a bot's draft: every change is saved to the gateway draft (debounced) so "Essayer" runs it as-is.
@MainActor
@Observable
final class BotEditorStore {
    private(set) var bot: Bot
    var config: BotConfig {
        didSet { if config != oldValue { scheduleSave() } }
    }
    private(set) var versions: [BotVersion] = []
    private(set) var saving = false
    private(set) var publishing = false
    var error: String?

    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let bots: BotsStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(bot: Bot, session: SessionStore, bots: BotsStore) {
        self.bot = bot
        self.session = session
        self.bots = bots
        config = bot.draft ?? bot.published?.config ?? DemoSeed.blankConfig(name: String(localized: "New bot"))
    }

    var published: BotConfig? { bot.published?.config }
    var publishedVersion: Int? { bot.published?.version }
    var nextVersion: Int { (publishedVersion ?? 0) + 1 }
    var hasDraft: Bool { published == nil || config != published }

    var subtitle: String {
        guard let version = publishedVersion else { return String(localized: "Never published · draft") }
        return hasDraft ? String(localized: "v\(version) published · draft based on v\(version)") : String(localized: "v\(version) published")
    }

    var changeCount: Int {
        guard let published else { return 0 }
        return ConfigDiff.changedFields(from: published, to: config).count
    }

    var diffLines: [DiffLine] {
        LineDiff.diff(old: ConfigDiff.lines(published), new: ConfigDiff.lines(config))
    }

    var agentInfo: AgentInfo? { bots.agent(config.agent) }
    var agents: [AgentInfo] { bots.agents }
    var tools: [ToolServer] { bots.tools }

    func loadVersions() async {
        versions = (try? await session.api.versions(botId: bot.id)) ?? versions
    }

    func selectAgent(_ agent: AgentInfo) {
        config.agent = agent.id
        let model = agent.models.first { $0.isDefault == true } ?? agent.models.first
        if let model {
            config.model = model.id
            config.effort = model.efforts?.contains("medium") == true ? "medium" : model.efforts?.first
        }
    }

    func selectModel(_ model: ModelInfo) {
        config.model = model.id
        if let efforts = model.efforts, !efforts.isEmpty {
            if config.effort.map(efforts.contains) != true { config.effort = efforts.contains("medium") ? "medium" : efforts.first }
        } else {
            config.effort = nil
        }
    }

    func toggleTool(_ id: String, on: Bool) {
        if on {
            if !config.toolServers.contains(id) { config.toolServers.append(id) }
        } else {
            config.toolServers.removeAll { $0 == id }
        }
    }

    var commands: [BotCommand] { config.commands ?? [] }
    var enabledToolServers: [ToolServer] { tools.filter { config.toolServers.contains($0.id) } }

    func saveCommand(_ command: BotCommand, replacing original: String?) {
        var list = commands
        if let original, let index = list.firstIndex(where: { $0.name == original }) {
            list[index] = command
        } else {
            list.append(command)
        }
        config.commands = list
    }

    func deleteCommand(_ name: String) {
        var list = commands
        list.removeAll { $0.name == name }
        config.commands = list.isEmpty ? nil : list
    }

    func moveCommands(from source: IndexSet, to destination: Int) {
        var list = commands
        list.move(fromOffsets: source, toOffset: destination)
        config.commands = list
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        guard bot.draft != config || bot.published == nil else { return }
        if bot.draft == nil, config == published { return }
        saving = true
        defer { saving = false }
        do {
            let updated = try await session.api.saveDraft(botId: bot.id, config: config)
            bot = updated
            bots.upsert(updated)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func discard() async {
        saveTask?.cancel()
        do {
            let updated = try await session.api.discardDraft(botId: bot.id)
            bot = updated
            bots.upsert(updated)
            config = updated.draft ?? updated.published?.config ?? config
            saveTask?.cancel()
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    func publish(note: String?) async -> Bool {
        publishing = true
        defer { publishing = false }
        await saveNow()
        do {
            let updated = try await session.api.publish(botId: bot.id, note: note)
            bot = updated
            bots.upsert(updated)
            setConfigSilently(updated.published?.config ?? config)
            await loadVersions()
            Haptics.success()
            return true
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func rollback(to version: BotVersion) async {
        do {
            let updated = try await session.api.rollback(botId: bot.id, version: version.version)
            bot = updated
            bots.upsert(updated)
            setConfigSilently(updated.draft ?? updated.published?.config ?? config)
            await loadVersions()
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func setConfigSilently(_ value: BotConfig) {
        config = value
        saveTask?.cancel()
        saveTask = nil
    }
}

struct DiffLine: Identifiable, Hashable {
    enum Kind { case same, added, removed }
    let id: Int
    let kind: Kind
    let text: String
}

enum ConfigDiff {
    static func lines(_ config: BotConfig?) -> [String] {
        guard let config else { return [] }
        var lines = [
            String(localized: "Name: \(config.emoji) \(config.name)"),
            String(localized: "Description: \(config.description)"),
            String(localized: "Color: \(config.color)"),
            String(localized: "Agent: \(config.agent.rawValue)"),
            String(localized: "Model: \(config.model)") + (config.effort.map { " · \($0)" } ?? ""),
            String(localized: "Tools: \(config.toolServers.sorted().formatted(.list(type: .and)))"),
            String(localized: "Permissions: \(config.permissionPolicy.rawValue)"),
        ]
        if let workdir = config.workdir, !workdir.isEmpty { lines.append(String(localized: "Folder: \(workdir)")) }
        if config.proactive == true { lines.append(String(localized: "Suggestions every morning: yes")) }
        if config.overview == true { lines.append(String(localized: "Access to all bots: yes")) }
        for command in config.commands ?? [] {
            lines.append(String(localized: "Command /\(command.name): \(command.kind.label)") + (command.args.map { " \($0)" } ?? "") + " · \(command.description)")
        }
        lines.append(String(localized: "Instructions:"))
        lines.append(contentsOf: config.instructions.components(separatedBy: "\n"))
        return lines
    }

    static func changedFields(from old: BotConfig, to new: BotConfig) -> [String] {
        var fields: [String] = []
        if old.name != new.name || old.emoji != new.emoji || old.color != new.color { fields.append("identité") }
        if old.description != new.description { fields.append("description") }
        if old.agent != new.agent || old.model != new.model || old.effort != new.effort { fields.append("cerveau") }
        if old.instructions != new.instructions { fields.append("instructions") }
        if Set(old.toolServers) != Set(new.toolServers) { fields.append("outils") }
        if old.permissionPolicy != new.permissionPolicy { fields.append("permissions") }
        if (old.workdir ?? "") != (new.workdir ?? "") { fields.append("dossier") }
        if (old.commands ?? []) != (new.commands ?? []) { fields.append("commandes") }
        if (old.proactive ?? false) != (new.proactive ?? false) { fields.append("propositions") }
        if (old.overview ?? false) != (new.overview ?? false) { fields.append("accès aux bots") }
        return fields
    }
}

enum LineDiff {
    /// Plain LCS line diff; configs are a few dozen lines so O(n·m) is fine.
    static func diff(old: [String], new: [String]) -> [DiffLine] {
        let n = old.count, m = new.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        func push(_ kind: DiffLine.Kind, _ text: String) { result.append(DiffLine(id: result.count, kind: kind, text: text)) }
        while i < n, j < m {
            if old[i] == new[j] {
                push(.same, old[i]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                push(.removed, old[i]); i += 1
            } else {
                push(.added, new[j]); j += 1
            }
        }
        while i < n { push(.removed, old[i]); i += 1 }
        while j < m { push(.added, new[j]); j += 1 }
        return result
    }
}
