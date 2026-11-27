import Foundation
import Observation

/// One bot's memory. Editing or deleting a fact rewrites the whole text (PUT); adding one appends a dated line (POST).
@MainActor
@Observable
final class MemoryStore {
    let botId: String
    private(set) var memory: BotMemory?
    private(set) var isLoading = false
    private(set) var loadError: String?
    @ObservationIgnored private var api: (any NuoAPI)?
    @ObservationIgnored private var tail: Task<Void, Never>?

    init(botId: String) {
        self.botId = botId
    }

    var document: MemoryDocument { MemoryDocument(memory?.content ?? "") }

    func attach(_ api: any NuoAPI) {
        self.api = api
    }

    func load() async {
        guard let api else { return }
        isLoading = memory == nil
        defer { isLoading = false }
        do {
            memory = try await api.memory(botId: botId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func add(_ fact: String) async throws {
        try await serialized { api in
            self.memory = try await api.addMemory(botId: self.botId, fact: fact)
        }
    }

    func write(_ content: String) async throws {
        try await serialized { api in
            self.memory = try await api.writeMemory(botId: self.botId, content: content)
        }
    }

    func update(_ fact: MemoryDocument.Fact, text: String) async throws {
        try await rewrite { $0.update(fact, text: text) }
    }

    func remove(_ fact: MemoryDocument.Fact) async throws {
        try await rewrite { $0.remove(fact) }
    }

    /// Edits the latest text, not the one on screen: the bot may have added a fact since, and the PUT replaces it all.
    private func rewrite(_ change: @escaping (inout MemoryDocument) -> Bool) async throws {
        try await serialized { api in
            let current = try await api.memory(botId: self.botId)
            self.memory = current
            var document = MemoryDocument(current.content)
            guard change(&document) else { throw MemoryEditError.factChanged }
            self.memory = try await api.writeMemory(botId: self.botId, content: document.content)
        }
    }

    /// One write at a time, each starting from what the previous one left.
    private func serialized(_ work: @escaping @MainActor (any NuoAPI) async throws -> Void) async throws {
        guard let api else { throw NuoError.offline }
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            try await work(api)
        }
        tail = Task { _ = await task.result }
        try await task.value
    }
}

enum MemoryEditError: LocalizedError {
    case factChanged

    var errorDescription: String? {
        String(localized: "This fact was edited or deleted in the meantime: the memory has been reloaded.")
    }
}

/// `-demo -demoMemory [<botId> [-demoMemoryEdit <line>]]` opens the memory screens for screenshots.
enum MemoryDemo {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var opensScreen: Bool { arguments.contains("-demo") && arguments.contains("-demoMemory") }

    private static func value(after flag: String) -> String? {
        guard opensScreen, let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
    }

    static var botId: String? { value(after: "-demoMemory") }
    static var editingLine: Int? { value(after: "-demoMemoryEdit").flatMap(Int.init) }
}
