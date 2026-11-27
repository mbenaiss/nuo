import Testing

struct TurnLabelsTests {
    @Test func statusShowsTheCommandDescriptionInsteadOfTheTerminal() {
        let label = TurnLabels.status(bot: "Homelab", phase: .working, tool: "Terminal", detail: "Wait 20 seconds in the background", steps: 3)
        #expect(label == "Homelab: Wait 20 seconds in the background (3 steps)")
    }

    @Test func statusOfAFirstDescribedStep() {
        let label = TurnLabels.status(bot: "Homelab", phase: .working, tool: "Terminal", detail: "Wait for the deploy workflow on main", steps: 1)
        #expect(label == "Homelab: Wait for the deploy workflow on main…")
    }

    @Test func statusKeepsTheProgramNameWithoutDescription() {
        #expect(TurnLabels.status(bot: "Homelab", phase: .working, tool: "Terminal", steps: 3) == "Homelab is using Terminal (3 steps)")
        #expect(TurnLabels.status(bot: "Agenda", phase: .working, tool: "gog calendar events --week", detail: "  \n", steps: 1) == "Agenda is using gog…")
        #expect(TurnLabels.status(bot: "Agenda", phase: .working, tool: nil, steps: 1) == "Agenda is using a tool…")
    }

    @Test func statusCutsALongDescriptionAtAWord() {
        let detail = "Poll the GitHub Actions run of the deploy workflow on main every 30 seconds until it finishes"
        let label = TurnLabels.status(bot: "Homelab", phase: .working, tool: "Terminal", detail: detail, steps: 4)
        #expect(label == "Homelab: Poll the GitHub Actions run of the deploy workflow on main… (4 steps)")
    }

    @Test func descriptionFitsOnOneLine() {
        #expect(TurnLabels.description("Restart the\nreverse proxy  container") == "Restart the reverse proxy container")
        #expect(TurnLabels.description("") == nil)
        #expect(TurnLabels.description("Back up the Postgres database and check the dump", limit: 30) == "Back up the Postgres database…")
    }

    @Test func shortLabelForConversationRows() {
        #expect(TurnLabels.short(phase: .working, tool: "Terminal", detail: "Wait 20 seconds in the background") == "Wait 20 seconds in the background…")
        #expect(TurnLabels.short(phase: .working, tool: "mcp__nuo__schedules_list") == "using schedules_list…")
        #expect(TurnLabels.short(phase: .thinking, tool: "Terminal", detail: "Wait 20 seconds in the background") == "thinking…")
    }

    @Test func genericStatusesWaitWhileSpecificOnesShowAtOnce() {
        #expect(TurnLabels.isGeneric(phase: .queued, tool: nil, detail: nil, steps: 0))
        #expect(TurnLabels.isGeneric(phase: .thinking, tool: nil, detail: nil, steps: 0))
        #expect(!TurnLabels.isGeneric(phase: .thinking, tool: nil, detail: nil, steps: 2))
        #expect(!TurnLabels.isGeneric(phase: .working, tool: "Terminal", detail: nil, steps: 1))
        #expect(!TurnLabels.isGeneric(phase: .working, tool: nil, detail: "Read the weather in Lyon", steps: 1))
        #expect(TurnLabels.isGeneric(phase: .working, tool: nil, detail: "  ", steps: 1))
        #expect(!TurnLabels.isGeneric(phase: .answering, tool: nil, detail: nil, steps: 0))
        #expect(!TurnLabels.isGeneric(phase: .waitingPermission, tool: nil, detail: nil, steps: 0))
    }
}
