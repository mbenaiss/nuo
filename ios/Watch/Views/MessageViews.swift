import SwiftUI

struct MessageView: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 24)
                Text(message.text)
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.userBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if let summary = WorkSummary.label(durationMs: message.durationMs, steps: message.steps?.count ?? 0) {
                    WorkRow(label: summary)
                }
                AssistantContent(text: message.text)
                if message.stopReason == .cancelled {
                    Text("Interrupted").font(.caption2).foregroundStyle(.secondary)
                } else if message.stopReason == .error {
                    Text("Error while replying").font(.caption2).foregroundStyle(Color.accent)
                }
            }
        }
    }
}

struct WorkRow: View {
    let label: String

    var body: some View {
        Label(label, systemImage: "gearshape.fill")
            .font(.system(size: 12))
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.surface, in: Capsule())
    }
}

struct AssistantContent: View {
    let text: String
    var streaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MessageContent.blocks(text, streaming: streaming).enumerated()), id: \.offset) { _, block in
                BlockRow(block: block)
            }
        }
    }
}

private struct BlockRow: View {
    let block: MessageBlock

    var body: some View {
        switch block {
        case let .heading(value):
            Text(WatchMarkdown.inline(value))
                .font(.footnote.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
        case let .paragraph(value):
            Text(WatchMarkdown.inline(value))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        case let .bullets(items):
            ListRows(items: items) { _ in "•" }
        case let .steps(items):
            ListRows(items: items) { "\($0 + 1)." }
        case let .quote(value):
            HStack(spacing: 6) {
                Capsule().fill(Color.accent.opacity(0.6)).frame(width: 2)
                Text(WatchMarkdown.inline(value))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .code(value):
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
        case .divider:
            Rectangle().fill(Color.surface2).frame(height: 1)
        case let .table(table):
            TableCards(table: table)
        case let .card(card):
            CardRow(card: card)
        }
    }
}

private struct ListRows: View {
    let items: [String]
    let marker: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(marker(index))
                        .foregroundStyle(Color.accent)
                        .monospacedDigit()
                    Text(WatchMarkdown.inline(item))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote)
            }
        }
    }
}
