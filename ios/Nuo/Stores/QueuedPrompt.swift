import Foundation

struct QueuedPrompt: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let attachments: [Attachment]
}
