import Foundation
import Testing

struct ToolStepTests {
    @Test func readsAStoredStepWithItsDescription() throws {
        let json = #"{"toolCallId":"toolu_01","title":"Terminal","kind":"execute","detail":"Wait for the deploy workflow on main","status":"completed","durationMs":61000}"#
        let step = try JSONDecoder().decode(ToolStep.self, from: Data(json.utf8))
        #expect(step.detail == "Wait for the deploy workflow on main")
        #expect(step.label == "Wait for the deploy workflow on main")
    }

    @Test func fallsBackToTheTitleWithoutDescription() throws {
        let json = #"{"toolCallId":"toolu_02","title":"mcp__nuo__notify_user","status":"running"}"#
        let step = try JSONDecoder().decode(ToolStep.self, from: Data(json.utf8))
        #expect(step.detail == nil)
        #expect(step.label == "mcp__nuo__notify_user")
        #expect(ToolStep(toolCallId: "toolu_03", title: "Terminal", status: .running, detail: "").label == "Terminal")
    }
}
