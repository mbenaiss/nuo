import AppKit
import SwiftUI

/// Finds the files of the shared folders that an answer names (`CV_Julie.pdf`, `Nouveau CV/lettre.pdf` or an absolute
/// path), so the chat links them: a click opens the file, the message's context menu shows it in the Finder.
@MainActor
final class LocalFileLinks {
    static let shared = LocalFileLinks()

    private struct Entry {
        let url: URL?
        let at: Date

        var ttl: TimeInterval { url == nil ? 600 : 30 }
    }

    /// A name looked up in vain stays unknown for minutes: a miss walks the shared folders on the main thread, and
    /// every render of a message asks again.
    private var cache: [String: Entry] = [:]
    private static let maxScanned = 3_000
    private static let fileName = /^[^\n`]{1,250}\.[A-Za-z0-9]{1,6}$/
    private static let codeSpan = /`([^`\n]+)`/

    func linker(preferred: String?) -> LocalFileLinker {
        LocalFileLinker(
            preferred: preferred,
            link: { [self] text in link(text, preferred: preferred) },
            files: { [self] text in files(in: text, preferred: preferred) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        )
    }

    func link(_ text: AttributedString, preferred: String?) -> AttributedString {
        var out = text
        for run in text.runs {
            let code = run.inlinePresentationIntent?.contains(.code) == true
            let fileLink = run.link?.isFileURL == true
            guard code || fileLink else { continue }
            let name = fileLink ? run.link!.path : String(text[run.range].characters)
            guard let url = resolve(name, preferred: preferred) else { continue }
            out[run.range].link = url
            out[run.range].foregroundColor = Color.accent
            out[run.range].underlineStyle = .single
        }
        return out
    }

    func files(in markdown: String, preferred: String?) -> [URL] {
        var seen: [URL] = []
        for match in markdown.matches(of: Self.codeSpan) {
            if let url = resolve(String(match.1), preferred: preferred), !seen.contains(url) { seen.append(url) }
        }
        return seen
    }

    func resolve(_ raw: String, preferred: String?) -> URL? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard name.wholeMatch(of: Self.fileName) != nil else { return nil }
        let key = "\(preferred ?? "")|\(name)"
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < hit.ttl { return hit.url }
        let url = lookUp(name, preferred: preferred)
        cache[key] = Entry(url: url, at: Date())
        return url
    }

    private func lookUp(_ name: String, preferred: String?) -> URL? {
        let roots = FolderAccess.shared.roots
        let ordered = roots.sorted { ($0.path == preferred ? 0 : 1) < ($1.path == preferred ? 0 : 1) }
        let fm = FileManager.default
        if name.hasPrefix("/") {
            let url = URL(fileURLWithPath: name).standardizedFileURL
            guard roots.contains(where: { LocalFolderTools.contains($0, url) }), fm.fileExists(atPath: url.path) else { return nil }
            return url
        }
        for root in ordered {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        guard !name.contains("/") else { return nil }
        for root in ordered {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var scanned = 0
            while let url = e.nextObject() as? URL, scanned < Self.maxScanned {
                scanned += 1
                if e.level > 3 { e.skipDescendants(); continue }
                if url.lastPathComponent == name { return url }
            }
        }
        return nil
    }
}
