import SwiftUI
import UIKit

/// Full-screen voice conversation with a bot. Owned by the voice work; the chat screen presents it.
struct VoiceModeView: View {
    let bot: Bot
    let conversationId: String
    let transport: any ChatTransport
    var onClose: () -> Void = {}

    @State private var session: VoiceSession
    @State private var showVoicePicker = false
    @Environment(\.scenePhase) private var scenePhase

    init(bot: Bot, conversationId: String, transport: any ChatTransport, onClose: @escaping () -> Void = {}) {
        self.init(bot: bot, conversationId: conversationId, transport: transport, demoUtterance: nil, onClose: onClose)
    }

    /// `demoUtterance` simulates the user saying it once the session is ready (previews, screenshots).
    init(bot: Bot, conversationId: String, transport: any ChatTransport, demoUtterance: String?, onClose: @escaping () -> Void = {}) {
        self.bot = bot
        self.conversationId = conversationId
        self.transport = transport
        self.onClose = onClose
        _session = State(initialValue: VoiceSession(bot: bot, conversationId: conversationId, transport: transport, demoUtterance: demoUtterance))
    }

    var body: some View {
        ZStack {
            VoiceTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                Spacer(minLength: 12)

                VoiceOrb(mood: mood, meter: session.meter)
                    .frame(width: 400, height: 400)
                    .padding(.vertical, -30)
                    .contentShape(Circle().inset(by: 70))
                    .onTapGesture { session.tapOrb() }
                    .accessibilityElement()
                    .accessibilityLabel(stateLine)
                    .accessibilityAddTraits(.isButton)

                VStack(spacing: 14) {
                    Text(stateLine)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(VoiceTheme.secondaryText)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: stateLine)

                    captionView
                        .frame(minHeight: 132, alignment: .top)

                    toolChip
                        .frame(height: 34)
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)

                Spacer(minLength: 12)

                controls
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .task { await session.start() }
        .onDisappear {
            session.close()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, newPhase in
            UIApplication.shared.isIdleTimerDisabled = newPhase == .active
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .sensoryFeedback(trigger: session.stateChanges) { _, _ in feedback }
        .sheet(isPresented: $showVoicePicker) {
            VoicePickerSheet(currentVoiceId: session.voiceId) { option in
                session.previewVoice(option)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if let emoji = bot.config?.emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 15))
                }
                Text(session.botName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(VoiceTheme.secondaryText)
            }
            Spacer()
            Button {
                showVoicePicker = true
            } label: {
                Image(systemName: "person.wave.2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(VoiceTheme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(VoiceTheme.button, in: Circle())
            }
            .accessibilityLabel("Choose the voice")
            TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                Text(Self.format(context.date.timeIntervalSince(session.startedAt)))
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(VoiceTheme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var captionView: some View {
        let caption = currentCaption
        VStack(spacing: 10) {
            if showsUserEcho {
                Text(session.userCaption)
                    .font(.system(size: 15))
                    .foregroundStyle(VoiceTheme.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            Text(caption.text)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(caption.dimmed ? VoiceTheme.tertiaryText : VoiceTheme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .minimumScaleFactor(0.7)
                .id(caption.text)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
        .animation(.easeOut(duration: 0.25), value: caption.text)
    }

    @ViewBuilder
    private var toolChip: some View {
        if !session.tools.isEmpty, session.phase == .thinking || session.phase == .speaking {
            let running = session.tools.contains { $0.status == .running }
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.rotate, isActive: running)
                Text(session.tools.suffix(3).map(\.title).joined(separator: " · "))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(VoiceTheme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(VoiceTheme.chip, in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else if let notice = session.notice {
            Text(notice)
                .font(.system(size: 13))
                .foregroundStyle(VoiceTheme.tertiaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if case .failed(let failure) = session.phase, failure.needsSettings {
            Button("Open the Settings app") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .tint(VoiceTheme.button)
            .padding(.bottom, 16)
        }
        HStack(spacing: 28) {
            ControlButton(
                systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill",
                background: session.isMuted ? VoiceTheme.primaryText : VoiceTheme.button,
                foreground: session.isMuted ? VoiceTheme.background : VoiceTheme.primaryText,
                label: session.isMuted ? String(localized: "Unmute the microphone") : String(localized: "Mute the microphone")
            ) {
                session.toggleMute()
            }
            ControlButton(systemImage: "keyboard", background: VoiceTheme.button, foreground: VoiceTheme.primaryText, label: String(localized: "Switch to keyboard")) {
                close()
            }
            ControlButton(systemImage: "xmark", background: VoiceTheme.end, foreground: .white, label: String(localized: "End")) {
                close()
            }
        }
    }

    private func close() {
        session.close()
        UIApplication.shared.isIdleTimerDisabled = false
        onClose()
    }

    // MARK: - Derived state

    private var mood: VoiceOrb.Mood {
        if session.isMuted, session.phase == .listening { return .muted }
        switch session.phase {
        case .starting, .paused: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .failed: return .failed
        }
    }

    private var stateLine: String {
        let name = session.botName
        switch session.phase {
        case .starting: return String(localized: "Getting ready…")
        case .listening:
            if session.isMuted { return String(localized: "Microphone muted · tap to unmute") }
            return session.userCaption.isEmpty ? String(localized: "I'm listening") : String(localized: "I'm listening · tap to send")
        case .thinking: return String(localized: "\(name) is thinking · tap to interrupt")
        case .speaking: return String(localized: "\(name) is speaking · tap to interrupt")
        case .paused: return String(localized: "Paused · tap to resume")
        case .failed: return String(localized: "Voice mode unavailable · tap to retry")
        }
    }

    private var showsUserEcho: Bool {
        (session.phase == .thinking || session.phase == .speaking) && !session.userCaption.isEmpty && !session.botCaption.isEmpty
    }

    private var currentCaption: (text: String, dimmed: Bool) {
        switch session.phase {
        case .starting:
            return ("", true)
        case .listening:
            if session.isMuted { return ("", true) }
            return session.userCaption.isEmpty ? (String(localized: "Speak, I'm listening."), true) : (session.userCaption, false)
        case .thinking:
            if !session.botCaption.isEmpty { return (session.botCaption, true) }
            return (session.userCaption, true)
        case .speaking:
            return (session.botCaption, false)
        case .paused:
            return (String(localized: "A call or another app took over the audio."), true)
        case .failed(let failure):
            return (failure.message, false)
        }
    }

    private var feedback: SensoryFeedback? {
        switch session.phase {
        case .listening: .impact(weight: .light)
        case .thinking: .impact(flexibility: .soft, intensity: 0.6)
        case .speaking: .impact(flexibility: .soft, intensity: 0.4)
        case .failed: .error
        default: nil
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ControlButton: View {
    var systemImage: String
    var background: Color
    var foreground: Color
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 68, height: 68)
                .background(background, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

enum VoiceTheme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let button = Color(white: 0.17)
    static let chip = Color(white: 0.15)
    static let end = Color(red: 0.91, green: 0.27, blue: 0.27)
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.62)
    static let tertiaryText = Color(white: 0.45)
}

@MainActor
enum VoiceHaptics {
    static func ready() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func interrupt() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

#if DEBUG
#Preview("Voice mode") {
    VoiceModeView(
        bot: PreviewVoiceTransport.sampleBot,
        conversationId: "preview",
        transport: PreviewVoiceTransport(),
        demoUtterance: "What are we doing for today's workout?"
    )
}
#endif
