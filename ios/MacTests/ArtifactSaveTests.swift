import Foundation
import Testing

struct ArtifactSaveTests {
    private let request = Data("Demande de pièces justificatives 2023-2025 — Gecina, bail n° 4417-B".utf8)

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theProposedNameIsTheAttachmentsOwnName() {
        #expect(ArtifactSave.fileName("Demande Gecina - pièces justificatives 2023-2025.docx") == "Demande Gecina - pièces justificatives 2023-2025.docx")
        #expect(ArtifactSave.fileName("Demande Gecina - pièces justificatives 2023-2025.pdf") == "Demande Gecina - pièces justificatives 2023-2025.pdf")
        #expect(ArtifactSave.fileName(" bilan-patrimoine-2026.html\n") == "bilan-patrimoine-2026.html")
    }

    @Test func aNameWithFoldersKeepsOnlyTheFile() {
        #expect(ArtifactSave.fileName("exports/2026/relevé-charges-T3.xlsx") == "relevé-charges-T3.xlsx")
    }

    @Test func aMissingNameStillGivesAFileToSave() {
        #expect(ArtifactSave.fileName("") == "file")
        #expect(ArtifactSave.fileName("  ") == "file")
        #expect(ArtifactSave.fileName("/") == "file")
    }

    @Test func theSavePanelStartsInDownloads() throws {
        let downloads = try #require(ArtifactSave.defaultFolder)
        #expect(downloads.lastPathComponent == "Downloads")
    }

    @Test func savingCopiesTheBytesAndKeepsTheDownloadedFile() throws {
        let folder = try folder()
        let downloaded = folder.appendingPathComponent("Demande Gecina - pièces justificatives 2023-2025.docx")
        try request.write(to: downloaded)
        let destination = folder.appendingPathComponent("Documents bail").appendingPathExtension("docx")
        try ArtifactSave.copy(downloaded, to: destination)
        #expect(try Data(contentsOf: destination) == request)
        #expect(FileManager.default.fileExists(atPath: downloaded.path))
    }

    @Test func savingOverAnExistingFileReplacesIt() throws {
        let folder = try folder()
        let downloaded = folder.appendingPathComponent("quittance-octobre-2026.pdf")
        try request.write(to: downloaded)
        let previous = folder.appendingPathComponent("saved", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        let destination = previous.appendingPathComponent("quittance-octobre-2026.pdf")
        try Data("%PDF-1.7 quittance septembre 2026".utf8).write(to: destination)
        try ArtifactSave.copy(downloaded, to: destination)
        #expect(try Data(contentsOf: destination) == request)
    }
}
