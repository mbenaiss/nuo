import UniformTypeIdentifiers

/// What a file of the docs repo is, for the screen that opens it. Only text goes through the Markdown reader and
/// the editor: a PDF read as UTF-8 shows a blank page, and saving it from the editor would destroy it.
enum DocFileKind: Equatable {
    /// Markdown, HTML, plain text, and any extension the system does not know (agents write `.env`, `.conf`…).
    case text
    case pdf
    /// Images, videos, archives, office files…: opened in Quick Look.
    case other

    static func of(_ path: String) -> DocFileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty { return .text }
        if ext == "pdf" { return .pdf }
        guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return .text }
        return type.conforms(to: .text) ? .text : .other
    }

    /// A page a bot wrote: shown rendered, its source only on demand.
    static func isWebPage(_ path: String) -> Bool {
        ["html", "htm"].contains((path as NSString).pathExtension.lowercased())
    }
}
