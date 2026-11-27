import SwiftUI

/// Highlight state of the `#` palette, shared by the field (keyboard) and the palette view.
@MainActor
@Observable
final class ToolTagPalette {
    var highlight = 0
    @ObservationIgnored let store = MachineToolsStore.shared

    func matches(for text: String) -> [MachineTool] {
        guard let query = ToolTag.query(in: text) else { return [] }
        return store.matches(query)
    }

    func move(_ delta: Int, text: String) {
        let count = matches(for: text).count
        guard count > 0 else { return }
        highlight = (highlight + delta + count) % count
        Haptics.selection()
    }

    /// Returns the new text, or nil when nothing can be picked.
    func pickHighlighted(in text: String) -> String? {
        let list = matches(for: text)
        guard !list.isEmpty else { return nil }
        Haptics.selection()
        return ToolTag.insert(list[min(highlight, list.count - 1)], into: text)
    }
}

struct ToolTagPaletteView: View {
    let tools: [MachineTool]
    let query: String
    let highlighted: Int
    /// The bot that will receive the message; nil in the home dock before a bot is chosen.
    let config: BotConfig?
    let shellBots: [Bot]
    let loaded: Bool
    let onPick: (MachineTool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Machine tools")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.text3)
                Spacer()
                if !tools.isEmpty {
                    Text("\(tools.count) results")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.text3)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if tools.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: loaded ? "magnifyingglass" : "wrench.and.screwdriver")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.text2)
                        .frame(width: 38, height: 38)
                        .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loaded ? String(localized: "No tool #\(query)") : String(localized: "Loading tools…")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                        Text("The full list is in Settings › Machine Tools.").font(.caption).foregroundStyle(Color.text2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                            Button { onPick(tool) } label: {
                                row(tool, highlighted: index == highlighted)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityHint(tool.description)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: min(CGFloat(tools.count) * 58 + 8, 286))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: 24)
        .animation(.snappy(duration: 0.22), value: tools.map(\.id))
    }

    private func row(_ tool: MachineTool, highlighted: Bool) -> some View {
        let locked = config != nil && !tool.usable(by: config)
        return HStack(spacing: 12) {
            MachineToolGlyph(tool: tool, highlighted: highlighted && !locked)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    name(tool.id).font(.body.weight(.semibold)).fixedSize()
                    if tool.kind != "cli" {
                        Text(verbatim: tool.kind == "mcp" ? "MCP" : "skill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.text3)
                    }
                }
                if locked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.caption2.weight(.bold))
                        Text("Only \(machineToolBotNames(shellBots))")
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.text3)
                    .lineLimit(1)
                } else {
                    Text(tool.description).font(.footnote).foregroundStyle(Color.text2).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "return")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.text3)
                .opacity(highlighted ? 1 : 0)
        }
        .opacity(locked ? 0.55 : 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.card.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityLabel(locked ? String(localized: "#\(tool.id), only for \(machineToolBotNames(shellBots))") : "#\(tool.id)")
    }

    private func name(_ id: String) -> Text {
        let matched = query.isEmpty || !id.hasPrefix(query) ? "" : query
        let hash = Text(verbatim: "#").foregroundStyle(Color.text3)
        let head = Text(matched).foregroundStyle(Color.accent)
        let tail = Text(String(id.dropFirst(matched.count))).foregroundStyle(Color.ink)
        return Text("\(hash)\(head)\(tail)")
    }
}

/// User bubble text with its `#id` tags: leading tags as chips (like `/name`), inline ones highlighted.
struct ToolTagBubbleContent: View {
    let parsed: ToolTag.Parsed
    let known: Set<String>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(Array(parsed.leading.enumerated()), id: \.offset) { _, id in
                Text(verbatim: "#\(id)")
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize()
            }
            if !parsed.rest.isEmpty {
                Text(ToolTag.styled(parsed.rest, known: known))
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.leading, parsed.leading.isEmpty ? 0 : 2)
            }
        }
    }
}
