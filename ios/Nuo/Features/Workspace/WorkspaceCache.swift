import CryptoKit
import Foundation

/// Last result of each screen, in memory (instant back navigation) and on disk (instant display at launch).
/// Disk I/O and coding run off the main actor.
@MainActor
final class WorkspaceCache {
    static let shared = WorkspaceCache()

    /// Separates the demo from a real gateway, and gateways from one another.
    var namespace = "default"
    private var memory: [String: any Sendable] = [:]
    private var order: [String] = []
    private let memoryLimit = 80

    private nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func fullKey(_ key: String) -> String { "\(namespace)|\(key)" }

    func memoryValue<T: Sendable>(_ type: T.Type, _ key: String) -> T? {
        memory[fullKey(key)] as? T
    }

    func value<T: Codable & Sendable>(_ type: T.Type, _ key: String) async -> T? {
        let full = fullKey(key)
        if let hit = memory[full] as? T { return hit }
        let url = Self.fileURL(full)
        let decoded: T? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? NuoJSON.decoder().decode(T.self, from: data)
        }.value
        if let decoded { remember(full, decoded) }
        return decoded
    }

    /// `persist: false` keeps it in memory only (search results, later pages).
    func store<T: Codable & Sendable>(_ value: T, _ key: String, persist: Bool = true) {
        let full = fullKey(key)
        remember(full, value)
        guard persist else { return }
        let url = Self.fileURL(full)
        Task.detached(priority: .utility) {
            guard let data = try? NuoJSON.encoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func remove(_ key: String) {
        let full = fullKey(key)
        memory[full] = nil
        let url = Self.fileURL(full)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }

    private func remember(_ key: String, _ value: any Sendable) {
        if memory[key] == nil { order.append(key) }
        memory[key] = value
        if order.count > memoryLimit {
            let evicted = order.removeFirst()
            memory[evicted] = nil
        }
    }

    private nonisolated static func fileURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }
}
