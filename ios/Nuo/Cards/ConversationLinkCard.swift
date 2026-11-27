import SwiftUI

/// A conversation another bot had with the user, named by the bot that sees them all: a tap opens it.
struct ConversationLinkCard: View {
    let payload: ConversationLinkPayload
    @Environment(BotsStore.self) private var bots: BotsStore?

    private var bot: Bot? { payload.botId.flatMap { id in bots?.bots.first { $0.id == id } } }

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.sm) {
                Text(bot?.config?.emoji ?? "💬")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Color(hexString: bot?.config?.color ?? "") ?? Color.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.title ?? String(localized: "Conversation")).font(.headline).foregroundStyle(Color.ink).lineLimit(2)
                    Text(bot?.config?.name ?? String(localized: "Open the conversation")).font(.subheadline).foregroundStyle(Color.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the conversation \(payload.title ?? "") with \(bot?.config?.name ?? String(localized: "the bot"))")
    }

    private func open() {
        let router = AppRouter.shared
        #if os(iOS)
        // Pushed over the chat that named it, so going back returns to that answer.
        if let botId = payload.botId, bots?.bots.contains(where: { $0.id == botId }) == true {
            router.openChat(botId: botId, conversationId: payload.id)
            return
        }
        #endif
        router.open(url: NuoLink.conversation(id: payload.id, botId: payload.botId).url)
    }
}
