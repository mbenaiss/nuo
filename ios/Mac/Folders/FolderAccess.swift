import AppKit
import Foundation
import Observation

/// A folder of this Mac the user shared with the bots, kept as a security-scoped bookmark across launches.
struct LocalFolder: Codable, Identifiable, Hashable, Sendable {
    var path: String
    var bookmark: Data
    var lastUsed: Date

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var prompt: PromptFolder { PromptFolder(name: name, path: path) }
}

/// The folders the bots may read and write (`mac_*` device tools), and the one each conversation works in.
@MainActor
@Observable
final class FolderAccess {
    static let shared = FolderAccess()

    private(set) var folders: [LocalFolder] = []
    @ObservationIgnored private var reachable: [String: URL] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    private static let foldersKey = "nuo.folders"
    private static let conversationsKey = "nuo.folders.byConversation"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.foldersKey).flatMap { try? JSONDecoder().decode([LocalFolder].self, from: $0) } ?? []
        folders = saved.compactMap(open).sorted { $0.lastUsed > $1.lastUsed }
        if folders.count != saved.count { save() }
    }

    /// Folders the tools may touch, most recent first.
    var roots: [URL] { folders.compactMap { reachable[$0.path] } }

    /// Asks for a folder with the system panel, which is what grants the sandboxed app access to it.
    func choose() -> LocalFolder? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Share with Bots")
        panel.message = String(localized: "The bots will be able to read, search and write files in this folder.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return add(url)
    }

    @discardableResult
    func add(_ url: URL) -> LocalFolder? {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = reachable[path] { existing.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()
        reachable[path] = url
        let folder = LocalFolder(path: path, bookmark: bookmark, lastUsed: Date())
        folders.removeAll { $0.path == path }
        folders.insert(folder, at: 0)
        save()
        return folder
    }

    func remove(_ folder: LocalFolder) {
        reachable.removeValue(forKey: folder.path)?.stopAccessingSecurityScopedResource()
        folders.removeAll { $0.path == folder.path }
        var byConversation = conversations
        byConversation = byConversation.filter { $0.value != folder.path }
        defaults.set(byConversation, forKey: Self.conversationsKey)
        save()
    }

    func folder(for conversationId: String?) -> LocalFolder? {
        guard let conversationId, let path = conversations[conversationId] else { return nil }
        return folders.first { $0.path == path }
    }

    func assign(_ folder: LocalFolder?, to conversationId: String) {
        var byConversation = conversations
        byConversation[conversationId] = folder?.path
        defaults.set(byConversation, forKey: Self.conversationsKey)
        guard let folder, let index = folders.firstIndex(where: { $0.path == folder.path }) else { return }
        folders[index].lastUsed = Date()
        folders.sort { $0.lastUsed > $1.lastUsed }
        save()
    }

    private var conversations: [String: String] { defaults.dictionary(forKey: Self.conversationsKey) as? [String: String] ?? [:] }

    /// Resolves a saved bookmark and opens its scope; nil when the folder is gone.
    private func open(_ folder: LocalFolder) -> LocalFolder? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        var opened = folder
        opened.path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            opened.bookmark = fresh
        }
        reachable[opened.path] = url
        return opened
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: Self.foldersKey) }
        DeviceToolsCenter.shared.permissionsChanged()
    }
}
