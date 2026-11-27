import SwiftUI

struct RecentRow: View {
    let bot: Bot
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 8) {
            Text(bot.emoji).font(.body)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(conversation.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Bot {
    var displayName: String { config?.name ?? "Bot" }
    var emoji: String { config?.emoji ?? "🤖" }

    /// The gateway refuses the watch's token for these bots (docs/security.md): the iPhone sends their prompts.
    var needsPhone: Bool { config?.overview == true || config?.permissionPolicy == .auto }

    /// Slash commands that run on the gateway (tool or prompt), the only ones that make sense on the watch.
    var quickCommands: [BotCommand] {
        (config?.commands ?? []).filter { ["tool", "prompt"].contains($0.action.type) }
    }
}

extension BotCommand {
    /// True when the command cannot run without words after it (`<vol>` vs optional `[jj/mm]`).
    var needsArguments: Bool { args?.contains("<") ?? false }
}
