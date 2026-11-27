import SwiftUI

/// The user message of a wake-up: the mail or the webhook call that woke the bot, where the chat would show the prompt
/// the gateway wrote for it.
struct WakeCard: View {
    let wake: MessageWake
    @State private var expanded = false

    private static let mailLines = 6
    private static let bodyLines = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            switch wake {
            case let .mail(mail): mailContent(mail)
            case let .hook(hook): hookContent(hook)
            case .unknown: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: CardMetrics.compactPadding + 2)
        .contextMenu {
            Button { PlatformPasteboard.copy(wake.copyText) } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Mail

    @ViewBuilder
    private func mailContent(_ mail: MessageWake.Mail) -> some View {
        header(symbol: "envelope.fill", title: wake.title) {
            if !mail.verified { badge(String(localized: "Unverified"), tint: .accentInk) }
        }
        if !mail.verified, mail.fromName != nil {
            Text(mail.from)
                .font(.caption).foregroundStyle(Color.text2)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        Text(mail.subject.isEmpty ? String(localized: "(no subject)") : mail.subject)
            .font(.headline).foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if !mail.text.isEmpty {
            Divider().overlay(Color.line)
            Text(mail.text)
                .font(.subheadline).foregroundStyle(Color.ink)
                .lineSpacing(TextMetrics.lineSpacing)
                .lineLimit(expanded ? nil : Self.mailLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if Self.isLong(mail.text, lines: Self.mailLines) { toggle }
        }
        if let attachments = mail.attachments, !attachments.isEmpty {
            Label(attachments.joined(separator: ", "), systemImage: "paperclip")
                .font(.caption).foregroundStyle(Color.text2)
                .lineLimit(2)
        }
    }

    // MARK: - Webhook

    @ViewBuilder
    private func hookContent(_ hook: MessageWake.Hook) -> some View {
        header(symbol: "bolt.fill", title: wake.title) {
            if let event = hook.event, !event.isEmpty { badge(event, tint: .text2) }
        }
        if !hook.body.isEmpty {
            Text(hook.body)
                .font(.caption.monospaced()).foregroundStyle(Color.ink)
                .lineLimit(expanded ? nil : Self.bodyLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.sm)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
            if Self.isLong(hook.body, lines: Self.bodyLines) { toggle }
        }
    }

    // MARK: - Parts

    private func header(symbol: String, title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accent)
            Text(title)
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Spacing.xs)
            trailing()
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold)).foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, Spacing.xs).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var toggle: some View {
        Button(expanded ? String(localized: "Show less") : String(localized: "Show all")) {
            withAnimation(.smooth) { expanded.toggle() }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentInk)
    }

    private static func isLong(_ text: String, lines: Int) -> Bool {
        text.count > lines * 60 || text.filter { $0 == "\n" }.count >= lines
    }
}
