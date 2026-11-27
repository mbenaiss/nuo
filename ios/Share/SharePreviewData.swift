#if DEBUG
import SwiftUI
import UIKit

/// Fake shares for SwiftUI previews and design screenshots.
enum SharePreviewData {
    enum Scenario: String { case photos, link, sent, files, notPaired }

    @MainActor
    static func model(_ scenario: Scenario) -> ShareModel {
        switch scenario {
        case .photos:
            return ShareModel(
                previewSlots: [.ready(.image(photo(.sunset))), .ready(.image(photo(.sea)))],
                bots: bots, selectedBotId: "cobot",
                message: "Can you find the name of this spot? We're going back this summer"
            )
        case .link:
            return ShareModel(
                previewSlots: [.ready(.link(SharedLink(
                    url: URL(string: "https://www.rail-journal.example/environment/2026/10/16/paris-berlin-night-train-returns")!,
                    title: "The Paris-Berlin night train returns in December, with renovated sleeper cars"
                )))],
                bots: bots, selectedBotId: "voyages",
                message: "Summarize it and tell me if it's worth it for Christmas"
            )
        case .sent:
            return ShareModel(
                previewSlots: [.ready(.image(photo(.sunset)))], bots: bots, selectedBotId: "cobot",
                phase: .sent(conversationId: "c-cobot-1", botId: "cobot")
            )
        case .files:
            return ShareModel(
                previewSlots: [
                    .ready(.file(SharedFile(fileURL: nil, name: "Invoice-October.pdf", mime: "application/pdf", byteCount: 248_000, kind: .pdf))),
                    .ready(.file(SharedFile(fileURL: nil, name: "Plumber contact.vcf", mime: "text/vcard", byteCount: 1_200, kind: .contact))),
                    .ready(.file(SharedFile(fileURL: nil, name: "Holiday-rushes.mov", mime: "video/quicktime", byteCount: 82_000_000, kind: .video))),
                    .ready(.text("Cottage wifi code: bluebell-2026, the router is in the hallway.")),
                    .loading(0.4),
                ],
                bots: bots, selectedBotId: "coach"
            )
        case .notPaired:
            return ShareModel(previewSlots: [], bots: [], selectedBotId: nil, paired: false)
        }
    }

    static let bots: [Bot] = [
        bot("cobot", "Cobot", "🦊", "#FFE8D9", "Personal assistant, full access to dev"),
        bot("voyages", "Travel", "✈️", "#E0EEFF", "Flights, statuses, activities"),
        bot("coach", "Coach", "🏃", "#E3F6E8", "Meals, workouts, WHOOP"),
    ]

    private static func bot(_ id: String, _ name: String, _ emoji: String, _ color: String, _ description: String) -> Bot {
        let config = BotConfig(
            name: name, emoji: emoji, color: color, description: description, agent: .claude,
            model: "claude-sonnet-5", instructions: "", toolServers: [], permissionPolicy: .ask
        )
        return Bot(id: id, published: BotVersion(version: 1, config: config, publishedAt: .now), createdAt: .now, updatedAt: .now)
    }

    private enum Picture { case sunset, sea }

    /// Simple painted landscapes, so previews need no bundled assets.
    private static func photo(_ picture: Picture) -> SharedImage {
        let size = picture == .sunset ? CGSize(width: 300, height: 400) : CGSize(width: 400, height: 300)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors: [UIColor] = picture == .sunset
                ? [UIColor(red: 0.98, green: 0.55, blue: 0.36, alpha: 1), UIColor(red: 0.99, green: 0.82, blue: 0.55, alpha: 1)]
                : [UIColor(red: 0.42, green: 0.70, blue: 0.93, alpha: 1), UIColor(red: 0.80, green: 0.91, blue: 0.98, alpha: 1)]
            let gradient = CGGradient(colorsSpace: nil, colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            let sun = picture == .sunset ? CGRect(x: size.width * 0.55, y: size.height * 0.28, width: 70, height: 70)
                : CGRect(x: size.width * 0.15, y: size.height * 0.14, width: 46, height: 46)
            UIColor(white: 1, alpha: 0.85).setFill()
            UIBezierPath(ovalIn: sun).fill()

            if picture == .sunset {
                fill(cg, UIColor(red: 0.55, green: 0.30, blue: 0.38, alpha: 1), [(0, 0.62), (0.25, 0.45), (0.45, 0.58), (0.7, 0.40), (1, 0.6)], size)
                fill(cg, UIColor(red: 0.30, green: 0.18, blue: 0.28, alpha: 1), [(0, 0.78), (0.35, 0.64), (0.6, 0.74), (1, 0.66)], size)
            } else {
                fill(cg, UIColor(red: 0.13, green: 0.45, blue: 0.68, alpha: 1), [(0, 0.6), (1, 0.6)], size)
                fill(cg, UIColor(red: 0.93, green: 0.84, blue: 0.66, alpha: 1), [(0, 0.86), (0.5, 0.8), (1, 0.84)], size)
            }
        }
        return SharedImage(fileURL: URL(fileURLWithPath: "/dev/null"), byteCount: 1_400_000, pixelSize: size, thumbnail: image)
    }

    private static func fill(_ cg: CGContext, _ color: UIColor, _ ridge: [(CGFloat, CGFloat)], _ size: CGSize) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (x, y) in ridge { path.addLine(to: CGPoint(x: x * size.width, y: y * size.height)) }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.close()
        color.setFill()
        path.fill()
    }
}

#Preview("Photos") { ShareRootView(model: SharePreviewData.model(.photos)) }
#Preview("Link") { ShareRootView(model: SharePreviewData.model(.link)) }
#Preview("Sent") { ShareRootView(model: SharePreviewData.model(.sent)) }
#Preview("Files") { ShareRootView(model: SharePreviewData.model(.files)) }
#Preview("Not connected") { ShareRootView(model: SharePreviewData.model(.notPaired)) }
#endif
