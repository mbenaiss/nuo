import SwiftUI

struct BotView: View {
    let bot: Bot
    @Binding var path: [WatchRoute]
    @Environment(WatchSession.self) private var session
    @State private var conversations: [Conversation] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if AskCenter.shared.phoneReachable || bot.needsPhone || session.isDemo {
                    HStack(alignment: .bottom, spacing: 6) {
                        // The watch's button speaks to the general bot only: another bot answers by voice in its conversation.
                        VoiceButton(size: 86) { path.append(.conversation(botId: bot.id, conversationId: nil, prompt: nil)) }
                            .accessibilityLabel("Talk to \(bot.displayName)")
                        MicButton(prompt: String(localized: "Write to \(bot.displayName)"), size: 30, symbol: "keyboard") { text in
                            start(text)
                        }
                    }
                } else {
                    // iPhone out of reach: the watch's own dictation, straight to the gateway, as before.
                    MicButton(prompt: String(localized: "Ask \(bot.displayName)"), size: 86) { text in
                        start(text)
                    }
                }
                Text("Tap to talk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !bot.quickCommands.isEmpty {
                    commandChips
                }

                if !conversations.isEmpty {
                    recents
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle {
            HStack(spacing: 4) {
                Text(bot.emoji)
                Text(bot.displayName).foregroundStyle(Color.accent)
            }
        }
        .task { conversations = await session.conversations(botId: bot.id) }
    }

    private var commandChips: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(bot.quickCommands) { command in
                if command.needsArguments {
                    TextFieldLink(prompt: Text(command.args ?? command.description)) {
                        CommandChip(name: command.name, needsInput: true)
                    } onSubmit: { text in
                        start("/\(command.name) \(text)")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        start("/\(command.name)")
                    } label: {
                        CommandChip(name: command.name, needsInput: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 4)
            ForEach(conversations.prefix(4)) { conversation in
                Button {
                    path.append(.conversation(botId: bot.id, conversationId: conversation.id, prompt: nil))
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func start(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        path.append(.conversation(botId: bot.id, conversationId: nil, prompt: prompt))
    }
}

struct CommandChip: View {
    let name: String
    let needsInput: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text("/\(name)")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if needsInput {
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color.surface2, in: Capsule())
    }
}

/// The system text input (dictation first, then Scribble/keyboard) behind a big mic, as on Siri.
struct MicButton: View {
    let prompt: String
    var size: CGFloat = 86
    var symbol = "mic.fill"
    let onSubmit: (String) -> Void

    var body: some View {
        TextFieldLink(prompt: Text(prompt)) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.accent2, .accent], center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: size * 0.7))
                    .shadow(color: .accent.opacity(0.45), radius: 10, y: 4)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        } onSubmit: { text in
            onSubmit(text)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(prompt)
    }
}
