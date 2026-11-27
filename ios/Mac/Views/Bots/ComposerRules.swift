import Foundation
import UniformTypeIdentifiers

/// What the gateway accepts as attachments of one prompt.
struct AttachmentLimits: Equatable {
    var maxCount: Int
    var maxFileBytes: Int
    var maxImageBytes: Int
    var maxEncodedBytes: Int

    /// Size once base64-encoded in the prompt.
    static func encodedSize(_ bytes: Int) -> Int { (bytes + 2) / 3 * 4 }
}

enum AttachmentRefusal: Equatable {
    case tooMany(max: Int)
    case directory(name: String)
    case unreadable(name: String)
    case tooLarge(name: String, maxBytes: Int)
    case overBudget(name: String, maxBytes: Int)

    var message: String {
        switch self {
        case let .tooMany(max): String(localized: "At most \(max) attachments per message.")
        case let .directory(name): String(localized: "“\(name)” is a folder: attach the files it contains.")
        case let .unreadable(name): String(localized: "“\(name)” can't be read.")
        case let .tooLarge(name, maxBytes): String(localized: "“\(name)” is over \(maxBytes / 1_000_000) MB.")
        case let .overBudget(name, maxBytes):
            String(localized: "“\(name)” would put the message over the \(maxBytes / 1_000_000) MB limit for attachments.")
        }
    }
}

/// A file about to be attached, as the file system describes it before reading it.
struct AttachmentCandidate: Equatable {
    let name: String
    let isDirectory: Bool
    let isReadable: Bool
    let byteCount: Int?
    let isImage: Bool

    init(name: String, isDirectory: Bool, isReadable: Bool, byteCount: Int?, isImage: Bool) {
        self.name = name
        self.isDirectory = isDirectory
        self.isReadable = isReadable
        self.byteCount = byteCount
        self.isImage = isImage
    }

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .fileSizeKey])
        self.init(
            name: url.lastPathComponent, isDirectory: values?.isDirectory == true, isReadable: values?.isReadable == true,
            byteCount: values?.fileSize, isImage: UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true)
    }
}

extension AttachmentLimits {
    /// Checked before reading the file, so a huge one is never loaded in memory.
    func refusal(for candidate: AttachmentCandidate, alreadyAttached: Int) -> AttachmentRefusal? {
        if alreadyAttached >= maxCount { return .tooMany(max: maxCount) }
        if candidate.isDirectory { return .directory(name: candidate.name) }
        if !candidate.isReadable { return .unreadable(name: candidate.name) }
        let limit = candidate.isImage ? maxImageBytes : maxFileBytes
        if let bytes = candidate.byteCount, bytes > limit { return .tooLarge(name: candidate.name, maxBytes: limit) }
        return nil
    }

    /// Checked once loaded (an image shrinks when re-encoded), against what the composer already holds.
    func refusal(adding bytes: Int, named name: String, toAttached attachedBytes: [Int]) -> AttachmentRefusal? {
        let total = attachedBytes.reduce(Self.encodedSize(bytes)) { $0 + Self.encodedSize($1) }
        return total > maxEncodedBytes ? .overBudget(name: name, maxBytes: maxEncodedBytes) : nil
    }
}

/// Composer state of the chats the user left, kept in memory and keyed by conversation (or `new-<botId>` before the
/// first message), so switching conversations does not lose a draft, its attachments or the queue.
struct ConversationStash<Entry> {
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    static func key(conversationId: String?, botId: String) -> String { conversationId ?? "new-\(botId)" }

    var count: Int { entries.count }

    mutating func put(_ entry: Entry, for key: String) {
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = entry
        // Attachments weigh up to tens of MB each: the oldest drafts go first.
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    mutating func take(_ key: String) -> Entry? {
        order.removeAll { $0 == key }
        return entries.removeValue(forKey: key)
    }

    mutating func remove(_ key: String) { _ = take(key) }
}
