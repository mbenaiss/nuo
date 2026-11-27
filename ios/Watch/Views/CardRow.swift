import SwiftUI

struct CardRow: View {
    let card: WatchCard

    var body: some View {
        content.watchCard()
    }

    @ViewBuilder private var content: some View {
        switch card {
        case let .flight(flight): FlightRow(flight: flight)
        case let .facts(facts): FactsRow(title: facts.title, items: facts.items)
        case let .callout(callout): CalloutRow(callout: callout)
        case let .weather(weather): WeatherRow(weather: weather)
        case let .questions(questions): QuestionRow(questions: questions)
        case let .event(title, when, location):
            CompactRow(kind: String(localized: "ON CALENDAR"), symbol: "calendar", tint: Color(hex: 0x5AA9FF), title: title,
                       detail: [when, location].compactMap { $0 }.joined(separator: " · "))
        case let .compact(compact):
            CompactRow(kind: compact.kind, symbol: compact.symbol, tint: compact.tint.color, title: compact.title, detail: compact.detail ?? "")
        case let .phoneOnly(kind, symbol, title):
            CompactRow(kind: kind.uppercased(), symbol: symbol, tint: .secondary, title: title ?? String(localized: "See on iPhone"),
                       detail: title == nil ? "" : String(localized: "See on iPhone"))
        case let .product(title, detail):
            HStack(spacing: 8) {
                Text("🛒").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.footnote.weight(.semibold)).lineLimit(2)
                    if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

extension View {
    func watchCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension WatchCard.Tint {
    var color: Color {
        switch self {
        case .accent: .accent
        case .good: .good
        case .bad: .red
        }
    }
}

/// A table, one card per row: its time, its title, then the other cells as small labelled lines.
struct TableCards: View {
    let table: WatchTable

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    if let time = row.time {
                        Text(WatchMarkdown.inline(time))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.accent)
                            .monospacedDigit()
                    }
                    Text(WatchMarkdown.inline(row.title))
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if !line.label.isEmpty {
                                Text(line.label)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            Text(WatchMarkdown.inline(line.value))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .font(.caption2)
                    }
                }
                .watchCard()
            }
            if table.hidden > 0 {
                Label(String(localized: "+ \(table.hidden) rows on the iPhone"), systemImage: "iphone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}

private struct FlightRow: View {
    let flight: FlightPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([String(localized: "Flight"), flight.number, flight.date].compactMap { $0 }.joined(separator: " · ").uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline) {
                endpoint(flight.fromCode, flight.departure, alignment: .leading)
                Spacer(minLength: 4)
                Image(systemName: "airplane")
                    .font(.footnote)
                    .foregroundStyle(Color.accent)
                Spacer(minLength: 4)
                endpoint(flight.toCode, flight.arrival, alignment: .trailing)
            }
            HStack(spacing: 6) {
                if let gate = flight.gate { pill(String(localized: "Gate"), gate) }
                if let status = flight.status { pill(String(localized: "Status"), status, tint: statusTint(status)) }
            }
            if let seats = flight.seats {
                Text("Seats \(seats)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func endpoint(_ code: String, _ time: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(code).font(.system(size: 22, weight: .bold, design: .rounded))
            if let time { Text(time).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func pill(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.bold)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func statusTint(_ status: String) -> Color {
        let text = status.lowercased()
        if text.contains("retard") || text.contains("delay") { return .orange }
        if text.contains("annul") || text.contains("cancel") { return .red }
        return .good
    }
}

private struct FactsRow: View {
    let title: String?
    let items: [FactItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accent)
            }
            ForEach(items.prefix(6), id: \.self) { item in
                HStack {
                    Text(item.key).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(item.value).font(.caption.weight(.semibold)).lineLimit(1)
                }
            }
        }
    }
}

private struct CalloutRow: View {
    let callout: CalloutPayload

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: callout.style.symbol)
                .font(.footnote)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                if let title = callout.title { Text(WatchMarkdown.inline(title)).font(.footnote.weight(.semibold)) }
                Text(WatchMarkdown.inline(callout.text)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        switch callout.style {
        case .success: .good
        case .warning: .orange
        case .tip: .yellow
        case .error: .red
        case .info: .blue
        }
    }
}

private struct WeatherRow: View {
    let weather: WeatherPayload

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: weather.symbol ?? WeatherSymbols.symbol(for: weather.condition))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 28))
            VStack(alignment: .leading, spacing: 0) {
                Text(weather.location).font(.caption2).foregroundStyle(.secondary)
                Text(weather.temperature).font(.system(size: 24, weight: .semibold, design: .rounded))
                Text([weather.condition, range].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private var range: String? {
        guard let high = weather.high, let low = weather.low else { return nil }
        return "↑\(high) ↓\(low)"
    }
}

/// A thing the bot created or pointed at, in two lines: what, then when or where.
private struct CompactRow: View {
    let kind: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct QuestionRow: View {
    let questions: [QuestionPayload]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("QUESTION", systemImage: "questionmark.bubble.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accent)
            ForEach(questions, id: \.self) { question in
                Text(question.question).font(.footnote.weight(.semibold))
                ForEach(question.options, id: \.self) { option in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: question.multiple ? "square" : "circle").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(option).font(.caption2)
                    }
                }
            }
        }
    }
}
