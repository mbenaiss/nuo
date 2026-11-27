import XCTest

final class DocMergeTests: XCTestCase {
    private let base = """
    # Assemblée générale du 14 mars
    - Ravalement : devis à comparer
    - Budget 2026 : à voter
    """

    func testEditsOnDifferentLinesAreBothKept() {
        let mine = base.replacingOccurrences(of: "devis à comparer", with: "devis Bâti-Est retenu")
        let theirs = base.replacingOccurrences(of: "à voter", with: "adopté à 812 tantièmes")
        XCTAssertEqual(DocMerge.merge(base: base, mine: mine, theirs: theirs), """
        # Assemblée générale du 14 mars
        - Ravalement : devis Bâti-Est retenu
        - Budget 2026 : adopté à 812 tantièmes
        """)
    }

    func testEditsOfTheSameLineConflict() {
        let mine = base.replacingOccurrences(of: "à voter", with: "reporté")
        let theirs = base.replacingOccurrences(of: "à voter", with: "adopté")
        XCTAssertNil(DocMerge.merge(base: base, mine: mine, theirs: theirs))
    }

    func testUnchangedSideTakesTheOther() {
        let theirs = base + "\n- Questions diverses"
        XCTAssertEqual(DocMerge.merge(base: base, mine: base, theirs: theirs), theirs)
        XCTAssertEqual(DocMerge.merge(base: base, mine: theirs, theirs: base), theirs)
    }
}
