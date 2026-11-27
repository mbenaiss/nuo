import Charts
import SwiftUI

/// "Bot Speed": how long each bot makes you wait for its first word and its whole answer, day by day.
struct BotLatencyView: View {
    @Environment(SessionStore.self) private var session
    @State private var days = 7
    @State private var scheduled = false
    @State private var report: LatencyReport?
    @State private var loadError: String?

    private static let periods = [7, 30, 90]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                controls
                content
                Text("First word: from sending your message to the first word shown. Median: half the answers arrive faster; p90: nine out of ten. Full durations only count answers that finished.")
                    .font(.footnote)
                    .foregroundStyle(Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.xxs)
            }
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.md)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
        .navigationTitle("Bot Speed")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: "\(days)-\(scheduled)") { await load() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Picker("Period", selection: $days) {
                ForEach(Self.periods, id: \.self) { Text("\($0) days").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Toggle("Include scheduled tasks", isOn: $scheduled)
                .font(.subheadline)
                .tint(Color.accent)
        }
        .card(padding: CardMetrics.compactPadding)
    }

    @ViewBuilder private var content: some View {
        if let report, !report.bots.isEmpty {
            ForEach(report.bots) { BotLatencyCard(bot: $0, days: report.days) }
        } else if let loadError, report == nil {
            ContentUnavailableView {
                Label("Measurements Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
            .card()
        } else if report != nil {
            ContentUnavailableView(
                "No Measurements Yet",
                systemImage: "gauge.with.dots.needle.33percent",
                description: Text("Every bot answer is timed. Write to one of them, then come back here.")
            )
            .card()
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, Spacing.xxl)
        }
    }

    private func load() async {
        do {
            report = try await session.api.latency(days: days, scheduled: scheduled)
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct BotLatencyCard: View {
    let bot: BotLatency
    let days: Int

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.headerGap) {
            HStack(spacing: Spacing.sm) {
                BotAvatar(emoji: bot.emoji, color: bot.color ?? "#EFECE6", size: 36)
                Text(bot.name).font(.body.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                Spacer(minLength: 0)
                Text(LatencyFormat.responses(bot.responses)).font(.caption.weight(.medium)).foregroundStyle(Color.text2)
            }
            HStack(spacing: Spacing.xs) {
                LatencyTile(title: "First word", value: LatencyFormat.duration(bot.firstTextMedianMs), detail: "p90 \(LatencyFormat.duration(bot.firstTextP90Ms))")
                LatencyTile(title: "Answer", value: LatencyFormat.duration(bot.durationMedianMs), detail: String(localized: "tools \(LatencyFormat.duration(bot.toolMedianMs))"))
                LatencyTile(title: "Steps", value: LatencyFormat.decimal(bot.avgSteps), detail: String(localized: "on average"))
            }
            if bot.daily.contains(where: { $0.firstTextMedianMs != nil }) {
                Kicker(text: String(localized: "First word per day"), symbol: "chart.xyaxis.line")
                    .padding(.top, Spacing.xxs)
                DailyFirstWordChart(bot: bot, days: days)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct LatencyTile: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(Color.text3).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

private struct DailyFirstWordChart: View {
    let bot: BotLatency
    let days: Int

    private struct Point: Identifiable {
        let date: Date
        let seconds: Double
        var id: Date { date }
    }

    private var points: [Point] {
        bot.daily.compactMap { day in
            guard let ms = day.firstTextMedianMs, let date = LatencyFormat.date(day: day.day) else { return nil }
            return Point(date: date, seconds: Double(ms) / 1000)
        }
    }

    /// The whole period, so days without answers keep their place; it ends tomorrow so today's label is not cut.
    private var period: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return start...(calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Day", point.date, unit: .day), y: .value("First word", point.seconds))
                    .foregroundStyle(Color.accent)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Day", point.date, unit: .day), y: .value("First word", point.seconds))
                    .foregroundStyle(Color.accent)
                    .symbolSize(days > 30 ? 10 : 24)
            }
            if let median = bot.firstTextMedianMs {
                RuleMark(y: .value("Median", Double(median) / 1000))
                    .foregroundStyle(Color.text3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXScale(domain: period)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2).foregroundStyle(Color.text2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(Color.line)
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(verbatim: "\(LatencyFormat.decimal(seconds)) s") }
                }
                .font(.caption2)
                .foregroundStyle(Color.text3)
            }
        }
        .frame(height: 120)
    }
}
