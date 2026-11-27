import AppKit
import Foundation
import PDFKit

/// The bots' file tools on the folders the user picked on this Mac (docs/protocol.md, "Device tools"). Every path is
/// checked against those folders: the sandbox would refuse the rest anyway, but the bot reads why.
struct LocalFolderTools: Sendable {
    static let tools = ["mac_folders", "mac_files_list", "mac_files_search", "mac_file_read", "mac_file_write"]

    /// Folders the user granted, already reachable (security scope started).
    let roots: [URL]

    private static let skippedDirectories: Set<String> = ["node_modules", ".git", "Pods", "DerivedData", ".build", "build", ".venv", "__pycache__"]
    private static let richText: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"]
    private static let maxReadChars = 100_000
    private static let maxScanned = 20_000
    private static let maxSearchedBytes = 1_000_000

    init(roots: [URL]) {
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    func run(_ tool: String, _ args: DeviceToolArgs) throws -> JSONValue {
        switch tool {
        case "mac_folders": return folders()
        case "mac_files_list": return try list(args)
        case "mac_files_search": return try search(args)
        case "mac_file_read": return try read(args)
        case "mac_file_write": return try write(args)
        default: throw DeviceToolError("Outil inconnu \(tool) sur ce Mac.")
        }
    }

    // MARK: Paths

    /// Absolute, `~/…`, or relative to the first folder; always inside one of the granted folders.
    func resolve(_ text: String?) throws -> URL {
        guard let first = roots.first else {
            throw DeviceToolError("Aucun dossier partagé sur ce Mac : demande à l'utilisateur d'en choisir un dans Nuo (bouton dossier sous le champ de message).")
        }
        guard let text, !text.isEmpty else { return first }
        let url: URL
        if text.hasPrefix("/") {
            url = URL(fileURLWithPath: text)
        } else if text == "~" || text.hasPrefix("~/") {
            url = URL(fileURLWithPath: Self.realHome + text.dropFirst())
        } else {
            url = first.appendingPathComponent(text)
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard roots.contains(where: { Self.contains($0, resolved) }) else {
            let list = roots.map(\.path).joined(separator: ", ")
            throw DeviceToolError("« \(text) » est hors des dossiers que l'utilisateur a partagés (\(list)). Demande-lui d'ajouter ce dossier dans Nuo s'il le faut.")
        }
        return resolved
    }

    static func contains(_ root: URL, _ url: URL) -> Bool {
        let r = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        return url.path == r || url.path.hasPrefix(r + "/") || r.isEmpty
    }

    /// The sandbox points `NSHomeDirectory()` at the app's container; bots mean the user's own home.
    private static var realHome: String {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    // MARK: Tools

    private func folders() -> JSONValue {
        .object(["folders": .array(roots.map { .object(["name": .string($0.lastPathComponent), "path": .string($0.path)]) })])
    }

    private func list(_ args: DeviceToolArgs) throws -> JSONValue {
        let dir = try resolve(args.string("path"))
        guard isDirectory(dir) else { throw DeviceToolError("\(dir.path) n'est pas un dossier : lis-le avec mac_file_read.") }
        let depth = args.int("depth", default: 1, range: 1...4)
        let max = args.int("max", default: 300, range: 1...2000)
        let hidden = args.bool("hidden") ?? false
        var entries: [JSONValue] = []
        var truncated = false
        try walk(dir, hidden: hidden) { url, level, values in
            guard level <= depth else { return .skipChildren }
            guard entries.count < max else { truncated = true; return .stop }
            entries.append(entry(url, values))
            return level < depth ? .descend : .skipChildren
        }
        return .fields(["path": .string(dir.path), "entries": .array(entries), "truncated": truncated ? .bool(true) : nil])
    }

    private func search(_ args: DeviceToolArgs) throws -> JSONValue {
        guard let query = args.string("query") else { throw DeviceToolError("Il manque `query`, le texte à chercher.") }
        let dir = try resolve(args.string("path"))
        let inContent = args.bool("content") ?? false
        let max = args.int("max", default: 50, range: 1...200)
        var matches: [JSONValue] = []
        var truncated = false
        try walk(dir, hidden: false) { url, _, values in
            guard matches.count < max else { truncated = true; return .stop }
            if url.lastPathComponent.localizedCaseInsensitiveContains(query) {
                matches.append(entry(url, values))
            } else if inContent, values.isRegularFile == true, (values.fileSize ?? 0) <= Self.maxSearchedBytes,
                      let lines = matchingLines(url, query), !lines.isEmpty {
                var found = entry(url, values)
                if case var .object(o) = found { o["lines"] = .array(lines.map { .string($0) }); found = .object(o) }
                matches.append(found)
            }
            return .descend
        }
        return .fields(["query": .string(query), "matches": .array(matches), "truncated": truncated ? .bool(true) : nil])
    }

    private func read(_ args: DeviceToolArgs) throws -> JSONValue {
        let file = try resolve(args.string("path"))
        guard FileManager.default.fileExists(atPath: file.path) else { throw DeviceToolError("\(file.path) n'existe pas.") }
        guard !isDirectory(file) else { throw DeviceToolError("\(file.path) est un dossier : liste-le avec mac_files_list.") }
        let text = try Self.text(of: file)
        let lines = text.components(separatedBy: .newlines)
        let start = args.int("offset", default: 1, range: 1...Swift.max(lines.count, 1))
        let count = args.int("limit", default: 2000, range: 1...10_000)
        var slice = lines[(start - 1)..<Swift.min(lines.count, start - 1 + count)].joined(separator: "\n")
        var cut = start - 1 + count < lines.count
        if slice.count > Self.maxReadChars {
            slice = String(slice.prefix(Self.maxReadChars))
            cut = true
        }
        return .fields([
            "path": .string(file.path),
            "content": .string(slice),
            "lines": .number(Double(lines.count)),
            "from_line": .number(Double(start)),
            "truncated": cut ? .string("Suite tronquée : relis avec offset pour continuer.") : nil,
        ])
    }

    private func write(_ args: DeviceToolArgs) throws -> JSONValue {
        guard args.has("path") else { throw DeviceToolError("Il manque `path`, le fichier à écrire.") }
        let file = try resolve(args.string("path"))
        let data: Data
        if case let .string(encoded)? = args.raw["content_base64"] {
            guard let bytes = Data(base64Encoded: encoded) else { throw DeviceToolError("Le fichier reçu est illisible (base64 invalide).") }
            data = bytes
        } else if case let .string(content)? = args.raw["content"] {
            data = Data(content.utf8)
        } else {
            throw DeviceToolError("Il manque `content` (du texte) ou `from` (un fichier de ton espace de travail).")
        }
        let mode = args.string("mode") ?? "create"
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: file.path)
        if isDirectory(file) { throw DeviceToolError("\(file.path) est un dossier.") }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch mode {
            case "create":
                if exists { throw DeviceToolError("\(file.path) existe déjà : demande à l'utilisateur s'il faut le remplacer, puis rappelle avec mode « overwrite ».") }
                try data.write(to: file, options: .withoutOverwriting)
            case "overwrite":
                try data.write(to: file, options: .atomic)
            case "append":
                if !exists { try data.write(to: file) } else {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            default:
                throw DeviceToolError("mode « \(mode) » inconnu : create, overwrite ou append.")
            }
        } catch let error as DeviceToolError {
            throw error
        } catch {
            throw DeviceToolError("Écriture impossible dans \(file.path) : \(error.localizedDescription)")
        }
        return .fields(["path": .string(file.path), "bytes": .number(Double(data.count)), "created": .bool(!exists)])
    }

    // MARK: Helpers

    private enum Step { case descend, skipChildren, stop }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

    private func walk(_ dir: URL, hidden: Bool, _ visit: (URL, Int, URLResourceValues) -> Step) throws {
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: Self.keys, options: hidden ? [] : [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw DeviceToolError("Impossible de lire \(dir.path).") }
        var scanned = 0
        while let url = e.nextObject() as? URL {
            scanned += 1
            if scanned > Self.maxScanned { return }
            let values = (try? url.resourceValues(forKeys: Set(Self.keys))) ?? URLResourceValues()
            if values.isDirectory == true, Self.skippedDirectories.contains(url.lastPathComponent) {
                e.skipDescendants()
                continue
            }
            switch visit(url, e.level, values) {
            case .descend: break
            case .skipChildren: e.skipDescendants()
            case .stop: return
            }
        }
    }

    private func entry(_ url: URL, _ values: URLResourceValues) -> JSONValue {
        let dir = values.isDirectory == true
        return .fields([
            "path": .string(url.standardizedFileURL.resolvingSymlinksInPath().path),
            "type": .string(dir ? "dir" : "file"),
            "size": dir ? nil : .num(values.fileSize.map(Double.init)),
            "modified": .str(values.contentModificationDate.map { DeviceToolDate.format($0) }),
        ])
    }

    private func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    private func matchingLines(_ url: URL, _ query: String) -> [String]? {
        guard let data = try? Data(contentsOf: url), let text = Self.plainText(data) else { return nil }
        return text.components(separatedBy: .newlines).enumerated()
            .filter { $0.element.localizedCaseInsensitiveContains(query) }
            .prefix(5)
            .map { "\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces).prefix(200))" }
    }

    /// Plain text, PDF text, or the text of a rich document (Word, RTF, HTML).
    static func text(of file: URL) throws -> String {
        let ext = file.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: file) else { throw DeviceToolError("PDF illisible : \(file.path).") }
            return doc.string ?? ""
        }
        if richText.contains(ext) {
            do { return try NSAttributedString(url: file, options: [:], documentAttributes: nil).string }
            catch { throw DeviceToolError("Document illisible : \(file.path) (\(error.localizedDescription)).") }
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 20_000_000 else { throw DeviceToolError("\(file.path) fait \(size / 1_000_000) Mo : trop gros pour être lu en entier.") }
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw DeviceToolError("Lecture impossible : \(file.path) (\(error.localizedDescription)).") }
        guard let text = plainText(data) else {
            throw DeviceToolError("\(file.path) n'est pas un fichier texte (\(ext.isEmpty ? "binaire" : ext)) : il ne peut pas être lu comme du texte.")
        }
        return text
    }

    /// Nil for binary data: a NUL byte in the first 8 KB.
    static func plainText(_ data: Data) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
