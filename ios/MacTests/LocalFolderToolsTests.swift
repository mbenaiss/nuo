import Foundation
import Testing

struct LocalFolderToolsTests {
    private let root: URL
    private let tools: LocalFolderTools

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Devis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try "# Devis cuisine\nPlan de travail chêne\nTotal : 8 450 €".write(to: root.appendingPathComponent("2026/devis-cuisine.md"), atomically: true, encoding: .utf8)
        try "Salle de bain\nTotal : 5 900 €".write(to: root.appendingPathComponent("devis-sdb.txt"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: root.appendingPathComponent("plan.png"))
        tools = LocalFolderTools(roots: [root])
    }

    private var rootPath: String { root.standardizedFileURL.resolvingSymlinksInPath().path }

    private func object(_ value: JSONValue) -> [String: JSONValue] {
        if case let .object(o) = value { return o }
        return [:]
    }

    @Test func pathsOutsideTheSharedFoldersAreRefused() throws {
        #expect(throws: DeviceToolError.self) { try tools.resolve("/etc/hosts") }
        #expect(throws: DeviceToolError.self) { try tools.resolve(root.path + "/../escape.txt") }
        #expect(throws: DeviceToolError.self) { try tools.resolve(root.path + "-voisin/devis.txt") }
        #expect(try tools.resolve("2026/devis-cuisine.md").path == rootPath + "/2026/devis-cuisine.md")
        #expect(try tools.resolve(nil).path == rootPath)
        #expect(throws: DeviceToolError.self) { try LocalFolderTools(roots: []).resolve("devis.txt") }
    }

    @Test func listsOneLevelByDefault() throws {
        let result = object(try tools.run("mac_files_list", DeviceToolArgs([:])))
        guard case let .array(entries)? = result["entries"] else { Issue.record("no entries"); return }
        let paths = entries.compactMap { if case let .string(p)? = object($0)["path"] { p } else { nil } }.sorted()
        #expect(paths == [rootPath + "/2026", rootPath + "/devis-sdb.txt", rootPath + "/plan.png"])
    }

    @Test func searchesNamesAndContent() throws {
        let byName = object(try tools.run("mac_files_search", DeviceToolArgs(["query": .string("cuisine")])))
        guard case let .array(named)? = byName["matches"] else { Issue.record("no matches"); return }
        #expect(named.count == 1)
        let byContent = object(try tools.run("mac_files_search", DeviceToolArgs(["query": .string("total"), "content": .bool(true)])))
        guard case let .array(found)? = byContent["matches"] else { Issue.record("no matches"); return }
        #expect(found.count == 2)
    }

    @Test func readsTextBySlicesAndRefusesBinaries() throws {
        let read = object(try tools.run("mac_file_read", DeviceToolArgs(["path": .string(root.path + "/2026/devis-cuisine.md"), "offset": .number(2), "limit": .number(1)])))
        #expect(read["content"] == .string("Plan de travail chêne"))
        #expect(read["lines"] == .number(3))
        #expect(read["truncated"] != nil)
        #expect(throws: DeviceToolError.self) { try tools.run("mac_file_read", DeviceToolArgs(["path": .string("plan.png")])) }
    }

    @Test func writesAnyFileSentAsBytes() throws {
        let pdf = Data("%PDF-1.7\n%\u{E2}\u{E3}\nCV Julie Martin".utf8) + Data([0x00, 0xFF, 0x10])
        let path = JSONValue.string(root.path + "/Nouveau CV/CV_Julie_Martin_2026.pdf")
        _ = try tools.run("mac_file_write", DeviceToolArgs(["path": path, "content_base64": .string(pdf.base64EncodedString())]))
        #expect(try Data(contentsOf: root.appendingPathComponent("Nouveau CV/CV_Julie_Martin_2026.pdf")) == pdf)
        #expect(throws: DeviceToolError.self) { try tools.run("mac_file_write", DeviceToolArgs(["path": .string(root.path + "/cv.pdf"), "content_base64": .string("pas du base64 !")])) }
        #expect(throws: DeviceToolError.self) { try tools.run("mac_file_write", DeviceToolArgs(["path": .string(root.path + "/vide.txt")])) }
    }

    @Test func writesWithoutOverwritingUnlessAsked() throws {
        let path = JSONValue.string(root.path + "/synthese/comparatif.md")
        _ = try tools.run("mac_file_write", DeviceToolArgs(["path": path, "content": .string("Cuisine 8 450 € / SdB 5 900 €")]))
        #expect(throws: DeviceToolError.self) { try tools.run("mac_file_write", DeviceToolArgs(["path": path, "content": .string("Autre")])) }
        _ = try tools.run("mac_file_write", DeviceToolArgs(["path": path, "content": .string("\nTotal 14 350 €"), "mode": .string("append")]))
        let text = try String(contentsOf: root.appendingPathComponent("synthese/comparatif.md"), encoding: .utf8)
        #expect(text == "Cuisine 8 450 € / SdB 5 900 €\nTotal 14 350 €")
        #expect(throws: DeviceToolError.self) { try tools.run("mac_file_write", DeviceToolArgs(["path": .string("/tmp/hors.txt"), "content": .string("x")])) }
    }
}
