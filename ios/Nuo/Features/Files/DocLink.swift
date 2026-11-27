import Foundation

enum DocLink {
    /// Docs path of a Markdown link clicked in a document of `folder`, nil when it is not a link to another document.
    /// The link is percent-encoded (`Fast%20Line/Rep%C3%A8res.md`) while the docs API wants the real name.
    static func target(_ url: URL, from folder: String) -> String? {
        guard url.scheme == nil || url.scheme == "file" else { return nil }
        let raw = url.path(percentEncoded: false)
        guard raw.lowercased().hasSuffix(".md") else { return nil }
        let joined = raw.hasPrefix("/") || folder.isEmpty ? raw : folder + "/" + raw
        var parts: [Substring] = []
        for part in joined.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if parts.popLast() == nil { return nil } } else { parts.append(part) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}
