import SwiftUI

// Screens of the watch's one button, fed with plain values so they render the same live and in captures.

/// The one action of the home screen: a request said in under a minute, a meeting recorded past it.
struct HomeCapture: View {
    var isRecording: Bool
    /// A capture still under a minute, left for the home screen.
    var isListening = false
    var action: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            if isRecording {
                VoiceButton(size: 76, symbol: "waveform", colors: [Color(hex: 0xFF5A5F), Color(hex: 0xD62839)], action: action)
                    .accessibilityLabel("Back to the recording")
                Text(String(localized: "watch.recording.live", defaultValue: "Recording"))
                    .font(.system(size: 13, weight: .semibold))
            } else {
                VoiceButton(size: 76, action: action)
                    .accessibilityLabel(isListening ? String(localized: "Back to the request") : String(localized: "Talk to Nuo"))
                Text(isListening ? String(localized: "Listening") : String(localized: "Talk to Nuo"))
                    .font(.system(size: 13, weight: .semibold))
                Text("Over a minute: meeting recorded")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

/// Bars that follow the voice.
struct LevelMeter: View {
    var level: Float
    var tint: Color = .accent
    var bars = 13

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars, id: \.self) { index in
                let center = Double(bars - 1) / 2
                let falloff = 1 - abs(Double(index) - center) / (center + 1)
                let wobble = 0.55 + 0.45 * sin(Double(index) * 1.7 + Double(level) * 9)
                Capsule()
                    .fill(tint.opacity(0.35 + 0.65 * falloff))
                    .frame(width: 4, height: max(4, 34 * CGFloat(Double(level) * falloff * wobble)))
            }
        }
        .frame(height: 36)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// While the user speaks a request: level, time, and « Envoyer » on the double tap.
struct ListeningPanel: View {
    var targetName: String
    var level: Float
    var seconds: TimeInterval
    /// The minute is up: the microphone is off, the request waits for « Envoyer ».
    var capped = false
    /// The watch's button: past the minute the capture goes on as a recording instead of stopping.
    var becomesRecording = false
    var onSend: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("For \(targetName)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if capped {
                Text("One minute reached: the mic is off. Send what was said?")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else {
                LevelMeter(level: level)
            }
            Text(NoteFormat.clock(seconds))
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: onSend) {
                Label("Send", systemImage: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accent)
            .handGestureShortcut(.primaryAction)
            Button("Cancel", role: .cancel, action: onCancel)
                .font(.system(size: 13))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            if !capped {
                Text("Double pinch to send")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if becomesRecording {
                Label("Over a minute: meeting recorded", systemImage: "record.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// A request kept on the watch until the iPhone answers.
struct QueuedAskPanel: View {
    var reason: String?
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Waiting for iPhone")
                .font(.headline)
            Text(reason ?? String(localized: "Your request is kept on the watch and goes as soon as the iPhone answers. You'll get the reply as a notification."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("OK", action: onDone)
                .buttonStyle(.borderedProminent)
                .tint(.accent)
                .handGestureShortcut(.primaryAction)
        }
    }
}

/// A request that could not leave yet.
struct PendingAskRow: View {
    var label: String
    var detail: String
    var waiting: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: waiting ? "iphone.slash" : "arrow.up.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(waiting ? Color.orange : Color.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

// MARK: - Recorder

enum RecorderScreenState: Equatable {
    case recording
    /// A call or Siri took the microphone.
    case interrupted
}

/// The recording under way: time, level, markers, and « Repère » on the double tap.
struct RecorderScreen: View {
    var state: RecorderScreenState
    var elapsed: TimeInterval
    var level: Float
    var markers: Int
    var markerPulse: Int
    var warning: String? = nil
    var onMark: () -> Void
    var onResume: () -> Void
    var onStop: () -> Void

    @State private var blink = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state == .recording ? Color.red : Color.orange)
                    .frame(width: 9, height: 9)
                    .opacity(state == .recording && blink ? 0.25 : 1)
                Text(state == .recording ? String(localized: "RECORDING") : String(localized: "PAUSED"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(state == .recording ? Color.red : Color.orange)
            }
            Text(NoteFormat.clock(elapsed))
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if state == .recording {
                LevelMeter(level: level, tint: .red, bars: 15)
            } else {
                Text("A call or Siri took the microphone.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                if state == .recording {
                    Button(action: onMark) {
                        Label(markers == 0 ? String(localized: "Marker") : String(localized: "Marker · \(markers)"), systemImage: "bookmark.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accent)
                    .handGestureShortcut(.primaryAction)
                } else {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "record.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .handGestureShortcut(.primaryAction)
                }
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 30)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stop recording")
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else {
                Text(state == .recording ? String(localized: "Double pinch to mark a moment") : String(localized: "Double pinch to resume"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .overlay {
            MarkerFlash(pulse: markerPulse)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { blink = true }
        }
    }
}

/// A brief glow around the screen when a marker is set.
private struct MarkerFlash: View {
    var pulse: Int
    @State private var visible = false

    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Color.accent, lineWidth: 4)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .onChange(of: pulse) { _, _ in
                visible = true
                withAnimation(.easeOut(duration: 0.6)) { visible = false }
            }
    }
}

enum RecordingTransferState: Equatable {
    /// Pieces still on the watch, the iPhone in reach.
    case sending(left: Int)
    /// The iPhone does not answer: the pieces leave when it comes back.
    case waitingPhone(left: Int)
    case delivered
}

/// The recording just stopped: what it holds and where it is.
struct RecorderFinishedScreen: View {
    var duration: TimeInterval
    var markers: Int
    var transfer: RecordingTransferState
    var interrupted: Bool
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.good)
            Text("Saved")
                .font(.system(size: 18, weight: .semibold))
            HStack(spacing: 10) {
                Label(NoteFormat.clock(duration), systemImage: "timer")
                Label("\(markers)", systemImage: "bookmark.fill")
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            transferRow
            if interrupted {
                Text("Interrupted by a restart: the last few seconds may be missing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("OK", action: onDone)
                .buttonStyle(.borderedProminent)
                .tint(.accent)
                .handGestureShortcut(.primaryAction)
        }
    }

    @ViewBuilder private var transferRow: some View {
        switch transfer {
        case let .sending(left):
            Label(left == 0 ? String(localized: "Sending to iPhone…") : String(localized: "Sending to iPhone · \(left) chunks"), systemImage: "arrow.up.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accent)
                .multilineTextAlignment(.center)
        case let .waitingPhone(left):
            Label(String(localized: "Waiting for iPhone · \(left) chunks kept"), systemImage: "iphone.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .delivered:
            Label("On iPhone: summary being prepared", systemImage: "iphone")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.good)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Conversation additions

/// The agent waits for a yes before acting: one tap each way.
struct ConfirmationCard: View {
    var title: String
    /// Nil when the agent offers no « allow once »: the yes is given on the iPhone.
    var confirmLabel: String?
    /// Nil too when the request came on the watch's own connection: the iPhone shows it and takes the answer.
    var cancelLabel: String?
    var busy: Bool
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("CONFIRMATION", systemImage: "hand.raised.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let confirmLabel {
                Button(action: onConfirm) {
                    Text(confirmLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.good)
                .disabled(busy)
            } else {
                Label("Confirm on iPhone", systemImage: "iphone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let cancelLabel {
                Button(role: .cancel, action: onCancel) {
                    Text(cancelLabel)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
    }
}

struct LatencyRow: View {
    var seconds: TimeInterval

    var body: some View {
        Label(AskLatency.label(seconds), systemImage: "bolt.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

/// The big microphone of « Parler à Nuo »: Nuo records and transcribes, not the watch's dictation.
struct VoiceButton: View {
    var size: CGFloat = 86
    var symbol = "mic.fill"
    var colors: [Color] = [.accent2, .accent]
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: colors, center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: size * 0.7))
                    .shadow(color: (colors.last ?? .accent).opacity(0.45), radius: 10, y: 4)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }
}
