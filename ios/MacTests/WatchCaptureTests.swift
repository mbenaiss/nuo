import AppKit
import SwiftUI
import Testing

/// Renders the watch screens of its one button (a request under a minute, a recorded meeting past it) to PNG, at the size of an Apple Watch Series 12
/// (46 mm, 416 × 496 px), when `NUO_CAPTURE_DIR` names a folder (`TEST_RUNNER_NUO_CAPTURE_DIR` with xcodebuild).
/// The same views run on the watch; only the system chrome (clock, title) is drawn here.
@MainActor
struct WatchCaptureTests {
    private static let size = CGSize(width: 208, height: 248)
    private static var folder: URL? {
        ProcessInfo.processInfo.environment["NUO_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func bot(_ id: String, _ name: String, _ emoji: String, _ color: String, preview: String, overview: Bool = false) throws -> Bot {
        let json = ##"{"name":"\##(name)","emoji":"\##(emoji)","color":"\##(color)","description":"","agent":"claude","model":"claude-opus-5-5","instructions":"","toolServers":[],"permissionPolicy":"ask""## + (overview ? #","overview":true}"# : "}")
        let config = try JSONDecoder().decode(BotConfig.self, from: Data(json.utf8))
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        return Bot(id: id, published: BotVersion(version: 1, config: config, publishedAt: created), createdAt: created, updatedAt: created,
                   lastMessagePreview: preview)
    }

    @Test func renderWatchScreens() throws {
        guard let folder = Self.folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let friday = Date(timeIntervalSince1970: 1_794_650_400)

        let general = try bot("general", "Général", "🧭", "#EDE7FF", preview: "C'est noté : 2 rappels ajoutés.", overview: true)
        let now = Date()
        let recents = [
            Conversation(id: "c-rappels", botId: general.id, title: "Rappel : appeler Julie Martin", useDraft: false,
                         createdAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(-600)),
            Conversation(id: "c-dentiste", botId: general.id, title: "Dentiste mardi à 14 h", useDraft: false,
                         createdAt: now.addingTimeInterval(-3 * 3600), updatedAt: now.addingTimeInterval(-3 * 3600)),
        ]
        try render("montre-1-accueil", title: "Nuo") {
            VStack(alignment: .leading, spacing: 6) {
                HomeCapture(isRecording: false) {}
                Text("Recent").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 6)
                ForEach(recents) { conversation in
                    RecentRow(bot: general, conversation: conversation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }

        try render("montre-1b-accueil-enregistrement", title: "Nuo") {
            HomeCapture(isRecording: true) {}
        }

        try render("montre-2-ecoute", title: "Nuo") {
            ListeningPanel(targetName: "General", level: 0.62, seconds: 4.2, becomesRecording: true, onSend: {}, onCancel: {})
        }

        let reminders = AskDemoScript.reply(to: AskDemoScript.reminders, now: friday)
        try render("montre-3-reponse-rappels", title: "🧭 Général") {
            answer(prompt: AskDemoScript.reminders, reply: reminders.text, latency: AskDemoScript.latency(for: AskDemoScript.reminders))
        }

        let event = AskDemoScript.reply(to: AskDemoScript.event, now: friday)
        try render("montre-4-reponse-evenement", title: "🧭 Général") {
            answer(prompt: AskDemoScript.event, reply: event.text, latency: AskDemoScript.latency(for: AskDemoScript.event))
        }

        let email = AskDemoScript.reply(to: AskDemoScript.email, now: friday)
        try render("montre-5-confirmation", title: "🧭 Général") {
            VStack(alignment: .leading, spacing: 8) {
                bubble(AskDemoScript.email)
                ConfirmationCard(title: email.confirmation ?? "", confirmLabel: "Send", cancelLabel: "Cancel", busy: false,
                                 onConfirm: {}, onCancel: {})
            }
        }

        // Just past the minute: the same capture, now a meeting.
        try render("montre-6-bascule", title: "Record") {
            RecorderScreen(state: .recording, elapsed: 61, level: 0.58, markers: 0, markerPulse: 0, onMark: {}, onResume: {}, onStop: {})
        }

        try render("montre-7-enregistrement", title: "Record") {
            RecorderScreen(state: .recording, elapsed: 754, level: 0.58, markers: 2, markerPulse: 0, onMark: {}, onResume: {}, onStop: {})
        }

        try render("montre-8-fin", title: "Record") {
            RecorderFinishedScreen(duration: 1862, markers: 3, transfer: .sending(left: 2), interrupted: false, onDone: {})
        }

        try render("montre-9-en-attente", title: "Nuo") {
            QueuedAskPanel(reason: nil, onDone: {})
        }

        try render("montre-10-reponse-agenda", title: "🧭 Général", height: 1.3 * Self.size.height) {
            answer(prompt: "Qu'est-ce que j'ai aujourd'hui ?", reply: WatchMessageContentTests.agenda, latency: 2.4)
        }

        try render("montre-11-reponse-mixte", title: "🧭 Général", height: 1.65 * Self.size.height) {
            answer(prompt: "Où en est le salon de Lyon ?", reply: WatchMessageContentTests.mixed, latency: 3.1)
        }
    }

    private func bubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 24)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.userBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func answer(prompt: String, reply: String, latency: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            bubble(prompt)
            AssistantContent(text: reply)
            LatencyRow(seconds: latency)
        }
    }

    /// A `height` past the screen's shows the whole answer as it scrolls by.
    private func render<Content: View>(_ name: String, title: String, height: CGFloat = Self.size.height, @ViewBuilder content: () -> Content) throws {
        let screen = VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accent).lineLimit(1)
                Spacer()
                Text("9:41").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            content()
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: height, alignment: .top)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "fr_FR"))
        .foregroundStyle(.white)
        let renderer = ImageRenderer(content: screen)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try data?.write(to: Self.folder!.appending(path: "\(name).png"))
    }
}
