#if os(iOS)
import SwiftUI
import UIKit
import WidgetKit

/// Nuo palette for extension views (the app's `Theme.swift` is not part of the widget target).
enum WPalette {
    static let canvas = adaptive(0xF6F4F0, 0x0C0C10)
    static let card = adaptive(0xFFFFFF, 0x1B1B21)
    static let ink = adaptive(0x16161A, 0xF4F2EE)
    static let text2 = adaptive(0x6E6C72, 0x9C9AA2)
    static let text3 = adaptive(0xA3A1A8, 0x6A6870)
    static let line = adaptive(0xE8E5DF, 0x2A2A31)
    static let chip = adaptive(0xEFECE6, 0x26262C)
    static let inkFill = adaptive(0x16161A, 0xF4F2EE)
    static let onInk = adaptive(0xFFFFFF, 0x16161A)
    static let accent = rgb(0xFF6A2B)
    static let accent2 = rgb(0xFFB36B)
    static let good = adaptive(0x1F9D57, 0x34C17A)
    static let bad = rgb(0xE5484D)

    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// Bot tile color; pastels are dimmed in dark mode so the tiles do not glow on a dark widget.
    static func tile(_ hexString: String) -> Color {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return chip }
        return Color(uiColor: UIColor { trait in
            let r = CGFloat((value >> 16) & 0xFF) / 255, g = CGFloat((value >> 8) & 0xFF) / 255, b = CGFloat(value & 0xFF) / 255
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: r * 0.32 + 0.06, green: g * 0.32 + 0.06, blue: b * 0.32 + 0.07, alpha: 1)
            }
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
    }
}

struct WidgetBotTile: View {
    let emoji: String
    let color: String
    var size: CGFloat = 40

    var body: some View {
        Text(emoji.isEmpty ? "✨" : emoji)
            .font(.system(size: size * 0.52))
            .frame(width: size, height: size)
            .background(WPalette.tile(color), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

/// Ink mic button, same glyph as the app's voice button (dot in a ring).
struct WidgetMicButton: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(WPalette.inkFill)
            Circle().strokeBorder(WPalette.onInk, lineWidth: size * 0.075).padding(size * 0.27)
            Circle().fill(WPalette.onInk).padding(size * 0.40)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Voice mode")
    }
}

/// The mascot in a widget: one still frame.
struct WidgetMascot: View {
    let state: MascotState
    var size: CGFloat = 40

    var body: some View {
        MascotView(state: state, size: size, animated: false)
    }
}

struct WidgetSignedOutView: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 8) {
                WidgetMascot(state: .sleep, size: compact ? 40 : 44)
                if !compact {
                    Text("Nuo").font(.headline).foregroundStyle(WPalette.ink)
                }
            }
            Spacer(minLength: 0)
            Text("Open Nuo to sign in")
                .font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(WPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !compact {
                Text("Pair the iPhone with your gateway to see your bots here.")
                    .font(.caption)
                    .foregroundStyle(WPalette.text2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "nuo://"))
    }
}

private struct WidgetHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(WPalette.text3)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption2.weight(.semibold)).foregroundStyle(WPalette.text3)
            }
        }
    }
}

// MARK: - Bots

struct WidgetBotsView: View {
    let snapshot: WidgetSnapshot
    let large: Bool

    var body: some View {
        if snapshot.status == .signedOut {
            WidgetSignedOutView()
        } else if large {
            largeBody
        } else {
            mediumBody
        }
    }

    private var mediumBody: some View {
        HStack(spacing: 8) {
            ForEach(snapshot.bots.prefix(4)) { bot in
                VStack(spacing: 6) {
                    Link(destination: bot.newLink) {
                        VStack(spacing: 7) {
                            WidgetBotTile(emoji: bot.emoji, color: bot.color, size: 50)
                            Text(bot.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WPalette.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    Link(destination: bot.voiceLink) { WidgetMicButton(size: 30) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if snapshot.bots.isEmpty { emptyLabel }
        }
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: String(localized: "Your bots"), trailing: offlineLabel)
            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(snapshot.bots.prefix(6)) { bot in
                    largeTile(bot)
                }
            }
            if snapshot.bots.isEmpty { emptyLabel }
            Spacer(minLength: 0)
        }
    }

    private func largeTile(_ bot: WidgetBotItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Link(destination: bot.newLink) {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetBotTile(emoji: bot.emoji, color: bot.color, size: 38)
                    Spacer(minLength: 0)
                    Text(bot.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WPalette.ink)
                        .lineLimit(1)
                    Text(bot.preview ?? String(localized: "New conversation"))
                        .font(.caption2)
                        .foregroundStyle(WPalette.text2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            Link(destination: bot.voiceLink) { WidgetMicButton(size: 28) }
                .padding(8)
        }
        .frame(height: 98)
        .background(WPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var offlineLabel: String? { snapshot.status == .offline ? String(localized: "Offline") : nil }

    private var emptyLabel: some View {
        Text("No published bots yet.")
            .font(.footnote)
            .foregroundStyle(WPalette.text2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Recents

struct WidgetRecentsView: View {
    let snapshot: WidgetSnapshot
    let large: Bool

    var body: some View {
        if snapshot.status == .signedOut {
            WidgetSignedOutView()
        } else {
            VStack(alignment: .leading, spacing: large ? 12 : 8) {
                WidgetHeader(title: String(localized: "Recent"), trailing: snapshot.status == .offline ? String(localized: "Offline") : nil)
                let items = Array(snapshot.recents.prefix(large ? 4 : 3))
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Link(destination: item.link) { row(item) }
                    if large, index < items.count - 1 { Divider().overlay(WPalette.line) }
                }
                if items.isEmpty {
                    Text("No recent conversations.")
                        .font(.footnote)
                        .foregroundStyle(WPalette.text2)
                }
                Spacer(minLength: 0)
                if large, let bot = snapshot.latestBot {
                    Link(destination: bot.newLink) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("New conversation with \(bot.name)")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(WPalette.onInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(WPalette.inkFill, in: Capsule())
                    }
                }
            }
        }
    }

    private func row(_ item: WidgetConversationItem) -> some View {
        HStack(alignment: large ? .top : .center, spacing: 10) {
            WidgetBotTile(emoji: item.emoji, color: item.color, size: large ? 40 : 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.botName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(WPalette.ink)
                    Spacer(minLength: 4)
                    Text(WidgetDate.relative(item.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(WPalette.text3)
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(WPalette.text2)
                    .lineLimit(large ? 2 : 1)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum WidgetDate {
    static func relative(_ date: Date, now: Date = .now) -> String {
        let interval = now.timeIntervalSince(date)
        let locale = Locale.current
        if interval < 60 { return String(localized: "just now") }
        if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute().locale(locale)) }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "yesterday") }
        if interval < 7 * 86400 { return date.formatted(.dateTime.weekday(.wide).locale(locale)) }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }
}

// MARK: - Single bot

struct WidgetBotSmallView: View {
    let snapshot: WidgetSnapshot
    let bot: WidgetBotItem?

    var body: some View {
        if snapshot.status == .signedOut {
            WidgetSignedOutView(compact: true)
        } else if let bot {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    WidgetBotTile(emoji: bot.emoji, color: bot.color, size: 44)
                    Spacer()
                    Link(destination: bot.voiceLink) { WidgetMicButton(size: 30) }
                }
                Spacer(minLength: 6)
                Text(bot.name)
                    .font(.headline)
                    .foregroundStyle(WPalette.ink)
                    .lineLimit(1)
                Text(bot.preview ?? String(localized: "Ask your first question."))
                    .font(.caption)
                    .foregroundStyle(WPalette.text2)
                    .lineLimit(2)
                    .padding(.top, 1)
                if let lastAt = bot.lastAt {
                    Text(WidgetDate.relative(lastAt))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(WPalette.text3)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(bot.openLink)
        } else {
            Text("No bots")
                .font(.footnote)
                .foregroundStyle(WPalette.text2)
        }
    }
}

// MARK: - Lock screen

struct WidgetVoiceCircleView: View {
    let bot: WidgetBotItem?

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Text(bot?.emoji ?? "🎙️").font(.system(size: 22))
                Image(systemName: "waveform").font(.system(size: 10, weight: .bold))
            }
        }
        .widgetURL(bot?.voiceLink ?? URL(string: "nuo://"))
        .accessibilityLabel(bot.map { String(localized: "Talk to \($0.name)") } ?? "Nuo")
    }
}

struct WidgetLastReplyView: View {
    let snapshot: WidgetSnapshot
    let bot: WidgetBotItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if snapshot.status == .signedOut {
                Text("Nuo").font(.headline)
                Text("Open Nuo to sign in").font(.caption).lineLimit(2)
            } else if let bot {
                HStack(spacing: 4) {
                    Text("\(bot.emoji) \(bot.name)").font(.headline).widgetAccentable()
                    if let lastAt = bot.lastAt {
                        Text("· \(WidgetDate.relative(lastAt))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Text(bot.preview ?? String(localized: "No reply yet."))
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(bot?.openLink ?? URL(string: "nuo://"))
    }
}
#endif
