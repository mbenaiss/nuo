import Foundation

/// `-demo -demoLongChat` (or the chat bench) adds a travel conversation of a few hundred messages, some of them long,
/// to check that the transcript still opens on its end and follows new answers.
enum DemoLongChat {
    static let conversationId = "c-voyages-long"
    static let botId = "voyages"
    static let messageCount = 400

    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo") else { return false }
        return arguments.contains("-demoLongChat") || ["chat", "longchat"].contains(UserDefaults.standard.string(forKey: "demoBench") ?? "")
    }

    static func conversation(now: Date = Date()) -> Conversation {
        Conversation(
            id: conversationId, botId: botId, title: String(localized: "Planning the Europe trip"), useDraft: false,
            context: ContextUsage(usedTokens: 182_000, maxTokens: 200_000, compactions: 3, updatedAt: now.addingTimeInterval(-60)),
            createdAt: now.addingTimeInterval(-86_400 * 20), updatedAt: now.addingTimeInterval(-60))
    }

    static func messages(now: Date = Date()) -> [Message] {
        let cities = [String(localized: "Lisbon"), "Porto", String(localized: "Seville"), String(localized: "Barcelona"), "Lyon", String(localized: "Geneva"), "Milan",
                      String(localized: "Venice"), String(localized: "Vienna"), "Prague", "Berlin", "Amsterdam"]
        return (0..<messageCount).map { index in
            let city = cities[(index / 2) % cities.count]
            let createdAt = now.addingTimeInterval(-Double(messageCount - index) * 600)
            if index.isMultiple(of: 2) {
                let text = index % 10 == 4
                    ? String(localized: "Here are my constraints for \(city): arriving by train around 2 pm, 180 € a night, two adults, no car. ") +
                        String(repeating: String(localized: "We like walking, museums in the morning and covered markets in the afternoon. "), count: 12)
                    : String(localized: "What do you suggest for the \(city) leg?")
                return Message(id: "l-\(index)", conversationId: conversationId, role: .user, text: text, createdAt: createdAt)
            }
            return Message(
                id: "l-\(index)", conversationId: conversationId, role: .assistant, text: answer(city: city, index: index),
                steps: index % 3 == 0 ? [
                    ToolStep(toolCallId: "l-\(index)-t0", title: "train_search \(city)", kind: "fetch", status: .completed, durationMs: 1300),
                    ToolStep(toolCallId: "l-\(index)-t1", title: "hotel_search \(city)", kind: "fetch", status: .completed, durationMs: 2100),
                ] : nil,
                durationMs: 9_000, stopReason: .endTurn, createdAt: createdAt.addingTimeInterval(30))
        }
    }

    private static func answer(city: String, index: Int) -> String {
        switch index % 6 {
        case 1:
            return String(localized: "For **\(city)**, two nights are enough: the historic center on day one, a quieter neighborhood on day two.")
        case 3:
            let days = (1...14).map { String(localized: "- **Day \(($0 - 1) / 5 + 1)**, stop \($0): a walk around neighborhood \($0), lunch at a local spot under 25 €, back at the hotel before 6 pm.") }
            return String(localized: "## \(city) in three days") + "\n\n" + days.joined(separator: "\n") + "\n\n"
                + String(localized: "demo.longChat.hotels", defaultValue: """
                | Hotel | Neighborhood | Price / night |
                | --- | --- | --- |
                | Casa do Rio | Center | 164 € |
                | Hotel Miradouro | Old town | 178 € |
                | Pension Estrela | Station | 121 € |
                """) + "\n\n"
                + String(repeating: String(localized: "Book early for \(city): prices climb fast on weekends and the best rooms go a month ahead. "), count: 10)
        default:
            return String(localized: "The train to **\(city)** leaves at 9:42 and arrives at 14:05.") + "\n\n```text\n"
                + String(localized: "Ticket ORD-2026-\(String(104_000 + index)) · car 12 · seats 64 and 65") + "\n```"
        }
    }
}
