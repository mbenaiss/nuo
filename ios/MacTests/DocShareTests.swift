import XCTest

final class DocShareTests: XCTestCase {
    private let certificate = Data("%PDF-1.7 PPS Athlé P4DB26F777D".utf8)

    func testTheSharedFileKeepsTheDocumentsNameAndBytes() async throws {
        let path = "Perso/Santé/Sport/PPS Athlé — P4DB26F777D (exp. 04-04-2027).pdf"
        let certificate = certificate
        let file = try await DocShare.file(path) { requested in
            XCTAssertEqual(requested, path)
            return certificate
        }
        XCTAssertEqual(file.lastPathComponent, "PPS Athlé — P4DB26F777D (exp. 04-04-2027).pdf")
        XCTAssertEqual(try Data(contentsOf: file), certificate)
    }

    func testSameNamesInTwoFoldersDoNotOverwriteEachOther() async throws {
        let minutes = try await DocShare.file("Pro/Lumen Studio/compte-rendu.md") { _ in Data("# AG Lumen Studio".utf8) }
        let copro = try await DocShare.file("Perso/Copro/compte-rendu.md") { _ in Data("# AG copropriété".utf8) }
        XCTAssertNotEqual(minutes, copro)
        XCTAssertEqual(try String(contentsOf: minutes, encoding: .utf8), "# AG Lumen Studio")
        XCTAssertEqual(try String(contentsOf: copro, encoding: .utf8), "# AG copropriété")
    }

    func testADownloadFailureIsReported() async {
        do {
            _ = try await DocShare.file("Perso/Santé/bilan-sanguin-2026.pdf") { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("a failed download must not produce a file to share")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testDropLifetimesAreTheOnesTheGatewayAccepts() {
        XCTAssertEqual(DropLifetime.allCases.map(\.rawValue), [60, 1440, 10080, 0])
        XCTAssertEqual(DropLifetime.allCases.map(\.label), ["1 hour", "24 hours", "7 days", "No expiration"])
    }
}
