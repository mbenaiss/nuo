import SwiftUI

enum CommandKind: String, CaseIterable, Identifiable {
    case tool, prompt, open, app

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tool: String(localized: "Tool")
        case .prompt: String(localized: "Prompt")
        case .open: String(localized: "Link")
        case .app: String(localized: "App action")
        }
    }

    var shortLabel: String {
        switch self {
        case .tool: String(localized: "Tool")
        case .prompt: String(localized: "Prompt")
        case .open: String(localized: "Link")
        case .app: String(localized: "App")
        }
    }

    var symbol: String {
        switch self {
        case .tool: "wrench.and.screwdriver"
        case .prompt: "text.bubble"
        case .open: "safari"
        case .app: "app.badge"
        }
    }

    var hint: String {
        switch self {
        case .tool: String(localized: "Calls an MCP tool directly, without going through the agent.")
        case .prompt: String(localized: "Replaces the command with a prompt and starts the agent.")
        case .open: String(localized: "Opens a web page in the app.")
        case .app: String(localized: "Triggers a Nuo action on the iPhone.")
        }
    }
}

enum AppCommandAction: String, CaseIterable, Identifiable {
    case newConversation = "new_conversation"
    case voice
    case barcode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newConversation: String(localized: "New conversation")
        case .voice: String(localized: "Voice mode")
        case .barcode: String(localized: "Scan a barcode")
        }
    }

    var symbol: String {
        switch self {
        case .newConversation: "square.and.pencil"
        case .voice: "waveform"
        case .barcode: "barcode.viewfinder"
        }
    }
}

extension BotCommand {
    static func isValidName(_ name: String) -> Bool { name.wholeMatch(of: /[a-z0-9_]{1,24}/) != nil }

    var kind: CommandKind { CommandKind(rawValue: action.type) ?? .prompt }
    var appAction: AppCommandAction? { action.action.flatMap(AppCommandAction.init(rawValue:)) }
    var takesArgs: Bool { !(args ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    var symbol: String {
        switch kind {
        case .app: appAction?.symbol ?? kind.symbol
        default: name == Self.compactName ? "arrow.down.right.and.arrow.up.left" : kind.symbol
        }
    }
}

/// A composer line of the form `/name args…`.
struct SlashLine: Equatable {
    let name: String
    let args: String

    static func parse(_ text: String) -> SlashLine? {
        guard let match = text.wholeMatch(of: /\/([a-z0-9_]{1,24})(?:\s+([\s\S]*))?/) else { return nil }
        return SlashLine(name: String(match.1), args: String(match.2 ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum LocalCommand: Equatable {
    case open(URL)
    case newConversation
    case voice
    case barcode
}

struct CommandPalette: View {
    let commands: [BotCommand]
    let query: String
    let hasCommands: Bool
    let highlighted: Int
    let onPick: (BotCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Commands")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.text3)
                Spacer()
                if hasCommands {
                    Text("\(commands.count) results")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.text3)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if !hasCommands {
                empty(symbol: "command", title: "No commands", text: "Add commands to this bot in Edit › Commands.")
            } else if commands.isEmpty {
                empty(symbol: "magnifyingglass", title: "No command /\(query)", text: "Send the message as is, or clear it to see all commands.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(commands.enumerated()), id: \.element.name) { index, command in
                            Button { onPick(command) } label: {
                                CommandPaletteRow(command: command, query: query, highlighted: index == highlighted)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityHint(command.description)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: min(CGFloat(commands.count) * 58 + 8, 286))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: 24)
        .animation(.snappy(duration: 0.22), value: commands.map(\.name))
    }

    private func empty(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.text2)
                .frame(width: 38, height: 38)
                .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                Text(text).font(.caption).foregroundStyle(Color.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }
}

private struct CommandPaletteRow: View {
    let command: BotCommand
    let query: String
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(highlighted ? Color.accentInk : Color.ink)
                .frame(width: 36, height: 36)
                .background(highlighted ? Color.accentSoft : Color.chip, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    nameText.font(.body.weight(.semibold)).fixedSize()
                    if let args = command.args, !args.isEmpty {
                        Text(args)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.text3)
                            .lineLimit(1)
                    }
                }
                Text(command.description)
                    .font(.footnote)
                    .foregroundStyle(Color.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !command.takesArgs {
                Image(systemName: "return")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.text3)
                    .opacity(highlighted ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.card.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }

    private var nameText: Text {
        let name = command.name
        let matched = query.isEmpty || !name.hasPrefix(query) ? "" : query
        let rest = String(name.dropFirst(matched.count))
        let slash = Text("/").foregroundStyle(Color.text3)
        let head = Text(matched).foregroundStyle(Color.accent)
        let tail = Text(rest).foregroundStyle(Color.ink)
        return Text("\(slash)\(head)\(tail)")
    }
}

/// Shown above the composer once a known command is followed by a space: reminds the arguments.
struct CommandArgsHint: View {
    let command: BotCommand

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol).font(.caption.weight(.bold)).foregroundStyle(Color.accentInk)
            Text("/\(command.name)").font(.footnote.monospaced().weight(.semibold)).foregroundStyle(Color.ink)
            if let args = command.args, !args.isEmpty {
                Text(args).font(.footnote.monospaced()).foregroundStyle(Color.text2)
            }
            Text("· \(command.description)").font(.footnote).foregroundStyle(Color.text3).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular.tint(Color.card.opacity(0.55)), in: .capsule)
    }
}

/// `/name args` inside a user bubble: the command as a monospace chip followed by its arguments.
struct CommandBubbleContent: View {
    let line: SlashLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("/\(line.name)")
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] }
            if !line.args.isEmpty {
                Text(line.args).font(.body).foregroundStyle(.white)
            }
        }
    }
}
