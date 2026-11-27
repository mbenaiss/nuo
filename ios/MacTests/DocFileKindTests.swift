import XCTest

final class DocFileKindTests: XCTestCase {
    func testAPDFOpensInThePDFViewer() {
        XCTAssertEqual(DocFileKind.of("Perso/Santé/Sport/PPS Athlé — P4DB26F777D (exp. 04-04-2027).pdf"), .pdf)
        XCTAssertEqual(DocFileKind.of("Pro/Lumen Studio/_fichiers/Facture-2026-031.PDF"), .pdf)
    }

    func testWrittenDocumentsStayText() {
        XCTAssertEqual(DocFileKind.of("Perso/Santé/PPS — Pass Prévention Santé.md"), .text)
        XCTAssertEqual(DocFileKind.of("Pro/Idées apps/forma-spec.html"), .text)
        XCTAssertEqual(DocFileKind.of("Perso/Voyages/Lisbonne 2026/checklist.txt"), .text)
        XCTAssertEqual(DocFileKind.of("Perso/Finances/budget-mensuel.csv"), .text)
        XCTAssertEqual(DocFileKind.of("Homelab/README"), .text)
    }

    func testBotPagesOpenRendered() {
        XCTAssertTrue(DocFileKind.isWebPage("Perso/Finances/Suivi patrimoine.html"))
        XCTAssertTrue(DocFileKind.isWebPage("Pro/Lumen Studio/rapport-2026.HTM"))
        XCTAssertFalse(DocFileKind.isWebPage("Pro/Helio Labs/Atlas/index.md"))
        XCTAssertFalse(DocFileKind.isWebPage("Homelab/caddy/nuo.conf"))
        XCTAssertFalse(DocFileKind.isWebPage("Pro/Lumen Studio/_fichiers/Facture-2026-031.pdf"))
    }

    func testUnknownExtensionsStayText() {
        XCTAssertEqual(DocFileKind.of("Homelab/caddy/nuo.conf"), .text)
        XCTAssertEqual(DocFileKind.of("Homelab/backup/restic.env"), .text)
    }

    func testMediaAndArchivesOpenInQuickLook() {
        XCTAssertEqual(DocFileKind.of("Perso/Voyages/Lisbonne 2026/_fichiers/tram-28.jpg"), .other)
        XCTAssertEqual(DocFileKind.of("Perso/Santé/_fichiers/echographie-genou.png"), .other)
        XCTAssertEqual(DocFileKind.of("Pro/Lumen Studio/_fichiers/demo-forma.mov"), .other)
        XCTAssertEqual(DocFileKind.of("Pro/Lumen Studio/_fichiers/export-banque-2026.zip"), .other)
    }
}
