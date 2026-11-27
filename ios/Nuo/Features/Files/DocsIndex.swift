import Foundation

/// The docs tree indexed once per fetch: the outline asks for the children and the file count of every folder it
/// draws, and filtering the whole tree for each of them made large trees quadratic on every render.
struct DocsIndex: Equatable {
    private(set) var children: [String: [DocNode]] = [:]
    private(set) var fileCounts: [String: Int] = [:]
    private(set) var nodes: [String: DocNode] = [:]
    /// Files, most recently updated first.
    private(set) var recent: [DocNode] = []

    init() {}

    init(_ docs: [DocNode]) {
        for node in docs {
            nodes[node.path] = nodes[node.path] ?? node
            if !node.name.hasPrefix(".") { children[Self.parent(of: node.path), default: []].append(node) }
            guard node.kind == .file else { continue }
            var folder = Self.parent(of: node.path)
            while !folder.isEmpty {
                fileCounts[folder, default: 0] += 1
                folder = Self.parent(of: folder)
            }
        }
        for (folder, nodes) in children {
            children[folder] = nodes.sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .dir }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        recent = docs.filter { $0.kind == .file && !$0.path.hasPrefix(".") }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
