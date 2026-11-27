import Foundation
import Testing

struct MermaidRendererTests {
    private final class Anchor {}
    private let renderer = MermaidRenderer(script: Bundle(for: Anchor.self).url(forResource: "pele", withExtension: "js"))

    @Test func aFlowchartIsDrawnToSVGWithItsSize() throws {
        let source = """
        flowchart LR
          A[Relevés bancaires] --> B{Charges récupérables ?}
          B -->|oui| C[Contrôle Gecina 2023-2025]
          B -->|non| D[Archive]
        """
        let diagram = try renderer.render(source).get()
        #expect(diagram.svg.hasPrefix("<svg"))
        #expect(diagram.svg.contains("pele-flowchart"))
        #expect(diagram.svg.contains("Contrôle Gecina 2023-2025"))
        #expect(diagram.width > 0 && diagram.height > 0)
    }

    @Test func aLeftToRightFlowTooWideForAnIPhoneIsLaidOutTopToBottom() throws {
        let source = """
        flowchart LR
          A[Convocation J-21] --> B[Contrôle des charges]
          B --> C{Écart > 10 % ?}
          C -->|oui| D[Question au syndic]
          C -->|non| E[Ordre du jour]
          D --> E
          E --> F[Vote du budget]
        """
        let wide = try renderer.render(source).get()
        #expect(wide.width > 360)
        let narrow = try renderer.render(source, maxWidth: 360).get()
        #expect(narrow.width <= 360)
        #expect(narrow.height > narrow.width)
    }

    @Test func otherDiagramTypesAreDrawnToo() throws {
        let sequence = try renderer.render("sequenceDiagram\n  Julie->>Syndic: Demande des justificatifs\n  Syndic-->>Julie: Relevé des charges 2025").get()
        #expect(sequence.svg.contains("Syndic"))
        let gantt = try renderer.render("gantt\n  dateFormat YYYY-MM-DD\n  section Assemblée générale\n  Convocation :2026-11-02, 15d\n  Vote du budget :2026-11-20, 1d").get()
        #expect(gantt.svg.contains("Vote du budget"))
    }

    @Test func aBrokenDiagramSaysWhereItIsWrong() {
        guard case let .failure(.invalid(reason)) = renderer.render("flowchart LR\n  A[Relevés] -->") else {
            Issue.record("expected a syntax error")
            return
        }
        #expect(reason.contains("line"))
        #expect(!reason.contains("\n"))
    }

    @Test func withoutPeleNothingIsDrawn() {
        let missing = MermaidRenderer(script: URL(fileURLWithPath: "/nonexistent/pele.js"))
        #expect(missing.render("flowchart LR\n  A --> B") == .failure(.unavailable))
    }
}
