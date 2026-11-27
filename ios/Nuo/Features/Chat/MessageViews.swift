import SwiftUI

/// A long pasted text shows its start until the user asks for all of it, then in pieces: one text of hundreds of
/// thousands of characters takes seconds to lay out.
struct UserBubble: View {
    let message: Message
    /// The part of the text a chat row shows, which the chat chose; without it the bubble shortens itself.
    var slice: UserSlice?
    @Environment(\.expandTranscriptPart) private var expand
    @State private var pieces: [Substring]?

    static let previewCharacters = 3_000
    static let previewLines = 40
    static let pieceCharacters = 4_000

    var body: some View {
        if let slice {
            sliced(slice)
        } else {
            whole
        }
    }

    @ViewBuilder
    private var attachments: some View {
        let images = message.attachments?.filter { $0.kind != "file" } ?? []
        if !images.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, attachment in
                    AttachmentThumb(attachment: attachment)
                        .frame(width: images.count == 1 ? 200 : 110, height: images.count == 1 ? 200 : 110)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        ForEach(Array((message.attachments?.filter { $0.kind == "file" } ?? []).enumerated()), id: \.offset) { _, file in
            FileChip(name: file.name ?? String(localized: "File"), size: file.size)
        }
    }

    /// One row of the bubble: its top on the first slice, its bottom on the last, one surface across them.
    private func sliced(_ slice: UserSlice) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if slice.isFirst { attachments }
            if !message.text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if slice.isFirst { content(String(slice.text)) } else { plain(slice.text) }
                    if let count = slice.expandableCount {
                        Button {
                            expand?.expand(TranscriptRows.textKey(messageId: message.id))
                        } label: {
                            showAllLabel(count)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // A bubble cut into rows spans the width so that its slices line up.
                .frame(maxWidth: slice.isFirst && slice.isLast ? nil : .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                // Slices meet at a line break of the text, which they keep as the gap between them.
                .padding(.top, slice.isFirst ? 10 : 0)
                .padding(.bottom, slice.isLast ? 10 : 0)
                .background(Color.userBubble, in: UnevenRoundedRectangle(
                    topLeadingRadius: slice.isFirst ? 20 : 0, bottomLeadingRadius: slice.isLast ? 20 : 0,
                    bottomTrailingRadius: slice.isLast ? 6 : 0, topTrailingRadius: slice.isFirst ? 20 : 0, style: .continuous))
                .contextMenu {
                    Button { PlatformPasteboard.copy(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private func showAllLabel(_ count: Int) -> some View {
        Label("Show all (\(count.formatted()) characters)", systemImage: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
    }

    private var whole: some View {
        VStack(alignment: .trailing, spacing: 6) {
            attachments
            if !message.text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let pieces {
                        ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                            if index == 0 { content(String(piece)) } else { plain(piece) }
                        }
                    } else if let preview = TextExcerpt.preview(message.text, maxCharacters: Self.previewCharacters, maxLines: Self.previewLines) {
                        content(String(preview))
                        Button {
                            pieces = TextExcerpt.chunks(message.text, maxCharacters: Self.pieceCharacters)
                        } label: {
                            showAllLabel(message.text.count)
                        }
                        .buttonStyle(.plain)
                    } else {
                        content(message.text)
                    }
                }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Color.userBubble, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                    .contextMenu {
                        Button { PlatformPasteboard.copy(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    /// Only ever given a bounded text: the command and tag parsers read all of it.
    @ViewBuilder
    private func content(_ text: String) -> some View {
        if let line = SlashLine.parse(text) {
            CommandBubbleContent(line: line)
        } else if let parsed = ToolTag.parse(text, known: MachineToolsStore.shared.ids) {
            ToolTagBubbleContent(parsed: parsed, known: MachineToolsStore.shared.ids)
        } else {
            plain(text[...])
        }
    }

    private func plain(_ text: Substring) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.white)
            .textSelection(.enabled)
    }
}

struct FileChip: View {
    let name: String
    var size: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.body).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AttachmentThumb: View {
    let attachment: Attachment
    @State private var local: PlatformImage?

    var body: some View {
        Group {
            if let url = attachment.url {
                RemoteImage(url: url)
            } else if let local {
                Image(platformImage: local).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.chip)
            }
        }
        .task(id: attachment.dataBase64?.count) {
            guard local == nil, let base64 = attachment.dataBase64 else { return }
            local = await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: base64).flatMap { PlatformImage.decoded($0, maxPixel: 600) }
            }.value
        }
    }
}

private enum AssistantGroup {
    case text([TranscriptPiece])
    case card(ResponseBlock)
}

struct AssistantMessageView: View {
    let message: Message
    @Environment(\.localFileLinker) private var linker
    /// Files the answer names, for its context menu: the menu is built with the view and resolving a name can walk the
    /// shared folders, so they are looked up once the answer is done.
    @State private var files: [URL] = []
    let isLive: Bool
    var startedAt: Date?
    /// « Codex · GPT-5.6 Sol » when this answer came from another agent or model than the one before.
    var answeredBy: String?
    /// The user's message that followed this answer, if any.
    var reply: String?
    var canAnswer = true
    /// The blocks a chat row shows, which the chat chose; without it the view shows the whole answer.
    var part: AssistantPart?

    var body: some View {
        let groups = self.groups
        let isFirst = part?.isFirst ?? true
        let isLast = part?.isLast ?? true
        VStack(alignment: .leading, spacing: 10) {
            if isFirst && showsWorkRow {
                WorkRow(steps: message.steps ?? [], thoughts: message.thoughts, durationMs: message.durationMs, isLive: isLive, startedAt: startedAt ?? message.createdAt)
            }
            if isFirst, let subagents = message.subagents, !subagents.isEmpty {
                SubagentsChip(subagents: subagents)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                switch group {
                case let .text(pieces):
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                            // Code and tables are cards: they stay flush with the other cards, only prose is inset.
                            PieceView(piece: piece)
                                .padding(.horizontal, Self.isProse(piece) ? CardMetrics.textInset : 0)
                                .environment(\.isStreaming, isLive && isLast && groupIndex == groups.count - 1 && index == pieces.count - 1)
                        }
                    }
                    .foregroundStyle(Color.ink)
                    .contextMenu {
                        Button { PlatformPasteboard.copy(ResponseBlockParser.plainText(message.text)) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if let linker, !isLive {
                            ForEach(files, id: \.self) { file in
                                Button { linker.reveal(file) } label: { Label("Show “\(file.lastPathComponent)” in Finder", systemImage: "folder") }
                            }
                        }
                    }
                case let .card(block):
                    BlockView(block: block)
                        .environment(\.questionContext, QuestionContext(reply: reply, canAnswer: canAnswer && !isLive))
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.98)), removal: .opacity))
                }
            }
            if isLast, let answeredBy, !isLive {
                Label(answeredBy, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(Color.text3)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Answered by \(answeredBy)")
            }
            if isLast, message.stopReason == .cancelled {
                Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(Color.text3).padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: groups.count)
        .task(id: isLive ? nil : FileScan(messageId: message.id, length: message.text.utf8.count, linker: linker)) {
            files = isLive ? [] : linker?.files(message.text) ?? []
        }
    }

    private struct FileScan: Equatable {
        let messageId: String
        let length: Int
        let linker: LocalFileLinker?
    }

    private static func isProse(_ piece: TranscriptPiece) -> Bool {
        switch piece {
        case .block(.code), .block(.table), .code, .table, .diagram: false
        default: true
        }
    }

    private var showsWorkRow: Bool {
        isLive || !(message.steps ?? []).isEmpty || (message.thoughts?.isEmpty == false)
    }

    private var groups: [AssistantGroup] {
        var result: [AssistantGroup] = []
        var run: [TranscriptPiece] = []
        let pieces = part?.pieces ?? ResponseBlockParser.parse(message.text, streaming: isLive).map(TranscriptPiece.block)
        for piece in pieces {
            if piece.isText {
                run.append(piece)
            } else if case let .block(block) = piece {
                if !run.isEmpty { result.append(.text(run)); run = [] }
                result.append(.card(block))
            }
        }
        if !run.isEmpty { result.append(.text(run)) }
        return result
    }
}

private struct PieceView: View {
    let piece: TranscriptPiece

    var body: some View {
        switch piece {
        case let .block(block): BlockView(block: block)
        case let .steps(items, start): StepsView(items: items, start: start)
        case let .code(slice): CodeCard(language: slice.language, code: slice.code, slice: slice)
        case let .table(slice): TableSliceCard(slice: slice)
        case let .quote(slice): QuoteSliceView(slice: slice)
        case let .diagram(slice): MermaidCard(code: slice.code, slice: slice)
        }
    }
}

/// "A travaillé 8 s · 2 étapes" chip that expands to the tool steps (and the agent's thoughts).
struct WorkRow: View {
    let steps: [ToolStep]
    let thoughts: String?
    let durationMs: Int?
    let isLive: Bool
    let startedAt: Date
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.selection()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if isLive {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "gearshape").font(.caption.weight(.semibold))
                    }
                    if isLive {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(liveLabel(now: context.date)).monospacedDigit().contentTransition(.numericText())
                        }
                    } else {
                        Text(doneLabel)
                    }
                    if !steps.isEmpty || thoughts?.isEmpty == false {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.text3)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(.footnote)
                .foregroundStyle(Color.text2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(steps.isEmpty && thoughts?.isEmpty != false)

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    if let thoughts, !thoughts.isEmpty {
                        Text(thoughts)
                            .font(.footnote)
                            .italic()
                            .foregroundStyle(Color.text2)
                            .lineLimit(8)
                    }
                    ForEach(steps) { step in
                        HStack(spacing: 9) {
                            stepIcon(step)
                            if step.detail?.isEmpty == false {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(step.label).font(.footnote).foregroundStyle(Color.ink).lineLimit(2)
                                    Text(step.title).font(.caption2.monospaced()).foregroundStyle(Color.text3).lineLimit(1)
                                }
                            } else {
                                Text(step.title).font(.footnote.monospaced()).foregroundStyle(Color.ink).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let ms = step.durationMs {
                                Text(durationLabel(ms)).font(.caption).foregroundStyle(Color.text3).monospacedDigit()
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ step: ToolStep) -> some View {
        switch step.status {
        case .running: ProgressView().controlSize(.mini).frame(width: 16)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.good).frame(width: 16)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.bad).frame(width: 16)
        }
    }

    private var stepsLabel: String? {
        steps.isEmpty ? nil : String(localized: "\(steps.count) steps")
    }

    private func liveLabel(now: Date) -> String {
        let running = steps.last { $0.status == .running }
        let head = running.map { $0.label } ?? (steps.isEmpty ? String(localized: "Thinking") : String(localized: "Working"))
        return [head + " · " + TurnLabels.elapsed(since: startedAt, now: now), stepsLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private var doneLabel: String {
        let time = durationMs.map { String(localized: "Worked for \(durationLabel($0))") } ?? String(localized: "Worked")
        return [time, stepsLabel].compactMap { $0 }.joined(separator: " · ")
    }
}
