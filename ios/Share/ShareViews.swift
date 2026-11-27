import SwiftUI

struct ShareRootView: View {
    @Bindable var model: ShareModel

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            if !model.isPaired {
                NotPairedView(model: model)
            } else if case let .sent(_, botId) = model.phase {
                SentView(model: model, bot: model.bots.first { $0.id == botId })
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                ComposerView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: model.phase)
    }
}

// MARK: Composer

private struct ComposerView: View {
    @Bindable var model: ShareModel
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SharePreviews(slots: model.slots)
                    recipients
                    messageField
                    ConversationModePicker(continueLast: $model.continueLast, bot: model.selectedBot)
                        .disabled(model.isBusy)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
    }

    private var header: some View {
        HStack {
            Button(action: model.cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 36, height: 36)
                    .background(Palette.chip, in: Circle())
            }
            .accessibilityLabel("Cancel")
            Spacer()
            VStack(spacing: 1) {
                Text("Nuo").font(.headline).foregroundStyle(Palette.ink)
                Text(subtitle).font(.caption).foregroundStyle(Palette.text2).contentTransition(.numericText())
            }
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        if model.isLoadingItems { return String(localized: "Preparing… \(Int(model.loadingFraction * 100))%") }
        let summary = ShareFormat.summary(of: model.contents)
        return summary.isEmpty ? String(localized: "Share") : summary
    }

    private var recipients: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(String(localized: "Send to"))
            switch model.botsState {
            case .loading where model.bots.isEmpty:
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(Palette.chip).frame(width: 104, height: 40)
                    }
                }
                .redacted(reason: .placeholder)
            case let .failed(message) where model.bots.isEmpty:
                HStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(Palette.bad)
                    Text(message).font(.footnote).foregroundStyle(Palette.text2)
                    Spacer(minLength: 0)
                    Button("Try again", action: model.refreshBots)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.accentInk)
                }
                .padding(12)
                .shareCard(radius: 16)
            default:
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.bots) { bot in
                            BotChip(bot: bot, selected: bot.id == model.selectedBotId) { model.select(bot) }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .padding(.horizontal, -20)
            }
        }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Add a message…", text: $model.message, axis: .vertical)
                .lineLimit(1...6)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.sentences)
                .focused($messageFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .shareCard(radius: 20)
                .disabled(model.isBusy)
            Text("/commands and #tools work like in the app.")
                .font(.caption)
                .foregroundStyle(Palette.text3)
                .padding(.leading, 6)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.bad)
                    Text(error).font(.footnote).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Palette.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            SendButton(model: model)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Palette.canvas)
        .animation(.smooth, value: model.errorMessage)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(Palette.text2)
    }
}

// MARK: Bots

private struct BotChip: View {
    let bot: Bot
    let selected: Bool
    let action: () -> Void

    private var color: Color { Palette.hex(bot.config?.color) ?? Palette.chip }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(bot.config?.emoji ?? "✨")
                    .font(.system(size: 17))
                    .frame(width: 30, height: 30)
                    .background(selected ? Color.white.opacity(0.55) : color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(bot.config?.name ?? "Bot")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Palette.onBot : Palette.ink)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.onBot.opacity(0.7))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 14)
            .frame(height: 40)
            .background(selected ? color : Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.black.opacity(0.1) : Palette.line, lineWidth: 1))
            .animation(.snappy(duration: 0.2), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ConversationModePicker: View {
    @Binding var continueLast: Bool
    let bot: Bot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                option(String(localized: "New conversation"), symbol: "plus.bubble", active: !continueLast) { continueLast = false }
                option(String(localized: "Continue the last one"), symbol: "arrow.turn.down.right", active: continueLast) { continueLast = true }
            }
            .padding(4)
            .background(Palette.chip, in: Capsule())
            Text(caption)
                .font(.caption)
                .foregroundStyle(Palette.text2)
                .padding(.leading, 6)
                .contentTransition(.opacity)
        }
        .animation(.snappy(duration: 0.22), value: continueLast)
    }

    private var caption: String {
        let name = bot.flatMap { b in b.config.map { "\($0.emoji) \($0.name)" } } ?? String(localized: "this bot")
        return continueLast ? String(localized: "Added to the last conversation with \(name)") : String(localized: "A new conversation with \(name)")
    }

    private func option(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(active ? Palette.ink : Palette.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                if active {
                    Capsule().fill(Palette.card).shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: Send

private struct SendButton: View {
    let model: ShareModel

    var body: some View {
        Button(action: model.send) {
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.inkFill)
                if case let .sending(fraction) = model.phase {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Palette.accent)
                            .frame(width: max(54, proxy.size.width * fraction))
                            .animation(.smooth, value: fraction)
                    }
                }
                HStack(spacing: 8) {
                    Text(label).font(.body.weight(.semibold)).lineLimit(1)
                    if case .sending = model.phase {
                        ProgressView().tint(Palette.onInk).controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(Palette.onInk)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 54)
            .clipShape(Capsule())
            .opacity(model.canSend || model.isBusy ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
    }

    private var label: String {
        if case let .sending(fraction) = model.phase { return String(localized: "Sending… \(Int(fraction * 100))%") }
        if model.isLoadingItems { return String(localized: "Preparing…") }
        guard let config = model.selectedBot?.config else { return String(localized: "Pick a bot") }
        if !model.hasSendableContent { return String(localized: "Nothing to send") }
        if case .failed = model.phase { return String(localized: "Try again") }
        return String(localized: "Send to \(config.emoji) \(config.name)")
    }
}

// MARK: Sent and not paired

private struct SentView: View {
    let model: ShareModel
    let bot: Bot?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Palette.good.opacity(0.14)).frame(width: 112, height: 112)
                Circle().fill(Palette.good).frame(width: 76, height: 76)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: appeared)
            }
            .scaleEffect(appeared ? 1 : 0.6)
            VStack(spacing: 6) {
                Text("Sent to \(bot?.config.map { "\($0.emoji) \($0.name)" } ?? String(localized: "your bot"))")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Palette.ink)
                Text("You'll get the reply as a notification")
                    .font(.subheadline)
                    .foregroundStyle(Palette.text2)
            }
            .multilineTextAlignment(.center)
            Button(action: model.openConversation) {
                HStack(spacing: 6) {
                    Text("Open the conversation")
                    Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(Palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { appeared = true }
        }
    }
}

private struct NotPairedView: View {
    let model: ShareModel

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button(action: model.cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 36, height: 36)
                        .background(Palette.chip, in: Circle())
                }
                .accessibilityLabel("Close")
            }
            Spacer()
            Image(systemName: "link.badge.plus")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Palette.accentInk)
                .frame(width: 88, height: 88)
                .background(Palette.accentSoft, in: Circle())
            VStack(spacing: 8) {
                Text("Open Nuo to sign in")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.ink)
                Text("Sharing uses the connection to your gateway. Pair the app once, then come back here.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.text2)
            }
            .multilineTextAlignment(.center)
            Button(action: model.openApp) {
                Text("Open Nuo")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.onInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Palette.inkFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .padding(20)
    }
}
