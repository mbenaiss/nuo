import Foundation
import Testing

struct LatencyFormatTests {
    private let french = Locale(identifier: "fr_FR")

    @Test func shortWaitsKeepATenthOfASecond() {
        #expect(LatencyFormat.duration(840, locale: french) == "0,8 s")
        #expect(LatencyFormat.duration(4_230, locale: french) == "4,2 s")
        #expect(LatencyFormat.duration(840, locale: Locale(identifier: "en_US")) == "0.8 s")
    }

    @Test func aWaitRoundingUpToTenSecondsLosesItsDecimal() {
        #expect(LatencyFormat.duration(9_960) == "10 s")
        #expect(LatencyFormat.duration(42_400) == "42 s")
    }

    @Test func longAnswersReadInMinutes() {
        #expect(LatencyFormat.duration(65_000) == "1 min 05")
        #expect(LatencyFormat.duration(754_000) == "12 min 34")
    }

    @Test func anUnknownFigureShowsADash() {
        #expect(LatencyFormat.duration(nil) == "—")
    }

    @Test func averageStepsDropAWholeDecimal() {
        #expect(LatencyFormat.decimal(3, locale: french) == "3")
        #expect(LatencyFormat.decimal(2.46, locale: french) == "2,5")
        #expect(LatencyFormat.decimal(2.46, locale: Locale(identifier: "en_US")) == "2.5")
    }

    @Test func responsesAgreeInNumber() {
        #expect(LatencyFormat.responses(1) == "1 response")
        #expect(LatencyFormat.responses(14) == "14 responses")
    }

    @Test func theGatewayDayIsMidnightHere() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let date = try #require(LatencyFormat.date(day: "2026-10-28", calendar: calendar))
        #expect(calendar.dateComponents([.year, .month, .day, .hour], from: date) == DateComponents(year: 2026, month: 10, day: 28, hour: 0))
        #expect(LatencyFormat.date(day: "28/10/2026", calendar: calendar) == nil)
    }

    @Test func aReportDecodesWithoutTheFiguresNoAnswerHad() throws {
        let json = """
        {"days":7,"since":"2026-10-22T22:00:00.000Z","scheduled":false,"bots":[{"botId":"b-homelab","name":"Homelab","emoji":"🖥️","color":"#DDE8F0",
        "responses":3,"firstTextMedianMs":4000,"firstTextP90Ms":5600,"firstEventMedianMs":1200,"toolMedianMs":3000,"avgSteps":3,
        "daily":[{"day":"2026-10-28","responses":3,"firstTextMedianMs":4000,"avgSteps":3}]}]}
        """
        let report = try JSONDecoder().decode(LatencyReport.self, from: Data(json.utf8))
        let homelab = try #require(report.bots.first)
        #expect(homelab.name == "Homelab")
        #expect(homelab.durationMedianMs == nil)
        #expect(homelab.daily.map(\.id) == ["2026-10-28"])
    }
}
