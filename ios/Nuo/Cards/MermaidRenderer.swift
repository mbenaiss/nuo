import Foundation
import JavaScriptCore

struct MermaidDiagram: Hashable, Sendable {
    var svg: String
    var width: Double
    var height: Double
}

enum MermaidError: Error, Hashable, Sendable {
    case unavailable
    case invalid(String)

    var label: String {
        switch self {
        case .unavailable: String(localized: "Diagram unavailable")
        case let .invalid(reason): String(localized: "Unreadable diagram: \(reason)")
        }
    }
}

/// ```mermaid blocks drawn to SVG by Pele (bundled `pele.js`), in JavaScriptCore: synchronous, offline, no web view
/// to lay the diagram out. One context, on its own queue, since a JSContext is not thread-safe.
final class MermaidRenderer: @unchecked Sendable {
    static let shared = MermaidRenderer()

    private let script: URL?
    private let queue = DispatchQueue(label: AppIdentity.scoped("mermaid"))
    private var pele: JSValue?
    private var loaded = false
    private var cache: [String: Result<MermaidDiagram, MermaidError>] = [:]

    init(script: URL? = Bundle.main.url(forResource: "pele", withExtension: "js")) {
        self.script = script
    }

    /// With `maxWidth`, Pele lays a diagram too wide for it out again top to bottom (a left-to-right flowchart on iPhone).
    func render(_ source: String, maxWidth: Double? = nil) -> Result<MermaidDiagram, MermaidError> {
        queue.sync {
            let key = "\(maxWidth.map { Int($0) } ?? 0)\n\(source)"
            if let hit = cache[key] { return hit }
            let result = draw(source, maxWidth: maxWidth)
            if cache.count > 64 { cache.removeAll() }
            cache[key] = result
            return result
        }
    }

    private func draw(_ source: String, maxWidth: Double?) -> Result<MermaidDiagram, MermaidError> {
        guard let pele = load(), let context = pele.context else { return .failure(.unavailable) }
        var thrown: String?
        context.exceptionHandler = { _, error in
            thrown = error?.objectForKeyedSubscript("message")?.toString() ?? error?.toString()
        }
        var options: [String: Any] = ["fontFamily": "-apple-system, sans-serif"]
        if let maxWidth { options["maxWidth"] = maxWidth }
        let out = pele.invokeMethod("render", withArguments: [source, options])
        if let thrown {
            // Pele's parse errors go on with the grammar's expectations over several lines; the first one says where.
            let first = thrown.split(separator: "\n").first.map(String.init) ?? thrown
            return .failure(.invalid(first.trimmingCharacters(in: CharacterSet(charactersIn: ": "))))
        }
        guard let out, let svg = out.objectForKeyedSubscript("svg")?.toString(), svg.hasPrefix("<svg") else {
            return .failure(.invalid(String(localized: "no drawing produced")))
        }
        let width = out.objectForKeyedSubscript("width")?.toDouble() ?? 0
        let height = out.objectForKeyedSubscript("height")?.toDouble() ?? 0
        guard width > 0, height > 0 else { return .failure(.invalid(String(localized: "empty drawing"))) }
        return .success(MermaidDiagram(svg: svg, width: width, height: height))
    }

    private func load() -> JSValue? {
        if loaded { return pele }
        loaded = true
        guard let script, let source = try? String(contentsOf: script, encoding: .utf8), let context = JSContext() else { return nil }
        context.evaluateScript(source)
        pele = context.objectForKeyedSubscript("pele").flatMap { $0.isObject ? $0 : nil }
        return pele
    }
}
