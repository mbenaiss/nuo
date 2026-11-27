import XCTest

final class DocLinkTargetTests: XCTestCase {
    private func target(_ link: String, from folder: String) -> String? {
        DocLink.target(URL(string: link)!, from: folder)
    }

    func testAccentsAndSpacesAreDecoded() {
        XCTAssertEqual(
            target("Rep%C3%A8res%20du%20domaine.md", from: "Pro/Helio Labs/Atlas"),
            "Pro/Helio Labs/Atlas/Repères du domaine.md"
        )
        XCTAssertEqual(
            target("%C3%89quipes/atelier%20%C2%B7%20planning%20des%20livraisons.md", from: "Pro/Helio Labs/Atlas"),
            "Pro/Helio Labs/Atlas/Équipes/atelier · planning des livraisons.md"
        )
        XCTAssertEqual(
            target("Points%20d%27attention.md", from: "Pro/Helio Labs/Atlas"),
            "Pro/Helio Labs/Atlas/Points d'attention.md"
        )
    }

    func testParentFolderLinks() {
        XCTAssertEqual(target("../index.md", from: "Pro/Helio Labs/Atlas/Équipes"), "Pro/Helio Labs/Atlas/index.md")
        XCTAssertEqual(target("../lumen/plan-2026.md", from: "Pro/Dev"), "Pro/lumen/plan-2026.md")
        XCTAssertNil(target("../../plan-2026.md", from: "Pro"))
    }

    func testRootAndTopLevelLinks() {
        XCTAssertEqual(target("/Perso/Sant%C3%A9/index.md", from: "Pro/Helio Labs"), "Perso/Santé/index.md")
        XCTAssertEqual(target("Freelances.md", from: ""), "Freelances.md")
        XCTAssertEqual(target("./Transporteurs.md", from: "Pro/Helio Labs"), "Pro/Helio Labs/Transporteurs.md")
    }

    func testOtherLinksAreLeftToTheSystem() {
        XCTAssertNil(target("https://docs.example.com/index.md", from: "Pro/Helio Labs"))
        XCTAssertNil(target("_fichiers/rapport.pdf", from: "Pro/Lumen Studio"))
        XCTAssertNil(target("nuo://docs/Pro/index.md", from: "Pro"))
    }
}
