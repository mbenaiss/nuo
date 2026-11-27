import SwiftUI

/// A text binding SwiftUI does not compare. SwiftUI compares the stored properties of a view on every update and a
/// `Binding` keeps a copy of its value: comparing a pasted draft of 400 000 accented characters took most of a second
/// on each keystroke. A class instance is compared by identity.
@MainActor
final class TextAccess {
    private let binding: Binding<String>

    init(_ binding: Binding<String>) {
        self.binding = binding
    }

    var value: String {
        get { binding.wrappedValue }
        set { binding.wrappedValue = newValue }
    }
}

/// Mic button of a text field: tap to dictate, tap again to finish. The text lands in the field, never sent.
struct DictationButton: View {
    let key: String
    private let text: TextAccess
    var vocabulary: [String]
    var size: CGFloat
    /// Plain glyph (Mac fields, quick entries) instead of a chip.
    var compact: Bool
    /// Off when the host swaps this button for a `DictationFinishButton` and finishes the dictation itself.
    var finishesOnDisappear: Bool
    private var dictation: DictationController { DictationController.shared }

    init(key: String, text: Binding<String>, vocabulary: [String] = [], size: CGFloat = 34, compact: Bool = false,
         finishesOnDisappear: Bool = true) {
        self.key = key
        self.text = TextAccess(text)
        self.vocabulary = vocabulary
        self.size = size
        self.compact = compact
        self.finishesOnDisappear = finishesOnDisappear
    }

    var body: some View {
        let active = dictation.isActive(key)
        Button {
            let text = self.text
            dictation.toggle(key: key, vocabulary: vocabulary, field: DictationField(read: { text.value }, write: { text.value = $0 }))
        } label: {
            ZStack {
                if active {
                    Circle().fill(Color.inkFill)
                    DictationLevelRing(level: dictation.level).padding(-3)
                    if dictation.phase == .listening {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.4, weight: .bold))
                            .foregroundStyle(Color.onInk)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        ProgressView().controlSize(.small).tint(Color.onInk)
                    }
                } else {
                    if !compact { Circle().fill(Color.chip) }
                    Image(systemName: "mic")
                        .font(compact ? .body.weight(.medium) : .system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(compact ? Color.text2 : Color.ink)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .animation(.snappy(duration: 0.2), value: active)
            .animation(.snappy(duration: 0.2), value: dictation.phase)
        }
        .buttonStyle(PressableStyle())
        .disabled(active && dictation.phase != .listening)
        .accessibilityLabel(active ? String(localized: "Finish dictation") : String(localized: "Dictate"))
        .help(active ? String(localized: "Finish dictation") : String(localized: "Dictate (on device)"))
        .onDisappear {
            if finishesOnDisappear { dictation.leave(key) }
        }
        // Small fields (a row of a list) have no room for a line of their own: the message comes in a popover, which
        // takes the touch wherever the row is.
        .popover(isPresented: Binding(
            get: { finishesOnDisappear && dictation.notice?.key == key },
            // Only this button's notice: another field's may have taken its place meanwhile.
            set: { if !$0, dictation.notice?.key == key { dictation.dismissNotice() } }
        ), arrowEdge: .bottom) {
            if let notice = dictation.notice {
                VStack(alignment: .leading, spacing: 8) {
                    Label(notice.text, systemImage: "waveform.slash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ink)
                    if notice.canRetry {
                        Button("Try again on device", systemImage: "arrow.clockwise") { dictation.retryOnDevice() }
                            .font(.subheadline.weight(.semibold))
                            .tint(Color.accent)
                    }
                }
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        }
        .task {
            if DictationDemo.inSmallField, finishesOnDisappear, dictation.phase == .idle {
                let text = self.text
                await dictation.start(key: key, vocabulary: [], field: DictationField(read: { text.value }, write: { text.value = $0 }))
            }
        }
        .alert(dictation.alert ?? "", isPresented: Binding(
            get: { dictation.alert != nil && dictation.alertKey == key },
            set: { if !$0 { dictation.alert = nil } }
        )) {
            #if os(iOS)
            if dictation.alert?.contains(String(localized: "Settings")) == true {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            #endif
            Button("OK", role: .cancel) {}
        }
    }
}

/// « Aucune parole reconnue » under the field whose dictation gave no text, for a few seconds, without a dialog.
struct DictationNoticeLabel: View {
    let key: String
    private var dictation: DictationController { DictationController.shared }

    @State private var choosing = false

    var body: some View {
        if let notice = dictation.notice, notice.key == key {
            Group {
                if notice.canRetry {
                    Button { choosing = true } label: { label(notice, more: true) }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .confirmationDialog(notice.text, isPresented: $choosing, titleVisibility: .visible) {
                            Button("Try again on device") { dictation.retryOnDevice() }
                            Button("Cancel", role: .cancel) {}
                        }
                        // The notice stays while the choice is open: the take must still be there.
                        .onChange(of: choosing) { _, open in dictation.holdNotice(open) }
                        // Gone with the screen while the choice was open: the notice's time runs again.
                        .onDisappear { dictation.holdNotice(false) }
                } else {
                    label(notice, more: false).accessibilityAddTraits(.isStaticText)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func label(_ notice: DictationController.Notice, more: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform.slash")
            Text(notice.text)
            if more { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color.text2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.chip, in: Capsule())
    }
}


/// Ring around the mic button of a small field that follows the voice.
struct DictationLevelRing: View {
    let level: Float

    var body: some View {
        Circle()
            .stroke(Color.accent.opacity(0.35 + Double(level) * 0.65), lineWidth: 2 + CGFloat(level) * 3)
            .scaleEffect(1 + CGFloat(level) * 0.12)
            .animation(.linear(duration: 0.08), value: level)
    }
}

/// The controls of a composer while it dictates, in place of its usual buttons: discard, the voice as a line of dots,
/// the time, « stop » (the text lands in the field) and « send » (it lands and goes). Nothing is written while the user
/// speaks; once stopped the dots ripple until the transcription arrives.
struct DictationBar: View {
    var compact = false
    var canSend = true
    /// Nil hides the send button.
    var onSend: (@MainActor () -> Void)?
    private var dictation: DictationController { DictationController.shared }

    var body: some View {
        let finishing = dictation.phase == .finishing
        let size: CGFloat = compact ? 28 : 36
        HStack(spacing: compact ? 8 : 10) {
            Button { dictation.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: size, height: size)
                    .background(Color.chip, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Cancel dictation")
            .help("Cancel dictation, the recording is deleted")

            DictationWave(level: dictation.level, finishing: finishing, height: compact ? 18 : 24)
                .frame(maxWidth: .infinity)

            Group {
                if finishing {
                    Text("Transcribing…")
                } else if let startedAt = dictation.startedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            }
            .font(compact ? .caption : .footnote)
            .foregroundStyle(Color.text2)
            .fixedSize()
            .contentTransition(.opacity)

            Button { dictation.finish() } label: {
                ZStack {
                    Circle().fill(Color.chip)
                    if finishing {
                        ProgressView().controlSize(.small).tint(Color.ink)
                    } else {
                        RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                            .fill(Color.ink)
                            .frame(width: size * 0.3, height: size * 0.3)
                    }
                }
                .frame(width: size, height: size)
            }
            .buttonStyle(PressableStyle())
            .disabled(finishing)
            .accessibilityLabel("Stop and insert the text")
            .help("Stop: the text is inserted into the field (↩)")

            if let onSend {
                Button { dictation.finish(then: onSend) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size, height: size)
                        .background(Color.accent, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .disabled(finishing || !canSend)
                .opacity(canSend ? 1 : 0.35)
                .accessibilityLabel("Stop and send")
                .help("Stop, transcribe and send")
            }
        }
        .animation(.snappy(duration: 0.2), value: finishing)
        .accessibilityElement(children: .contain)
    }
}

/// A line of dots that rise with the voice, newest on the right; while transcribing, a ripple runs along it.
struct DictationWave: View {
    let level: Float
    var finishing = false
    var height: CGFloat = 24
    private let dot: CGFloat = 3.5
    private let gap: CGFloat = 3.5
    @State private var history: [Float] = []

    var body: some View {
        GeometryReader { geometry in
            let count = max(8, Int((geometry.size.width + gap) / (dot + gap)))
            Group {
                if finishing {
                    TimelineView(.animation) { context in
                        let time = context.date.timeIntervalSinceReferenceDate
                        HStack(spacing: gap) {
                            ForEach(0..<count, id: \.self) { index in
                                let pulse = 0.5 + 0.5 * sin((time * 1.4 - Double(index) / 14) * 2 * .pi)
                                Circle()
                                    .fill(Color.ink.opacity(0.2 + 0.6 * pulse))
                                    .frame(width: dot, height: dot)
                                    .scaleEffect(0.8 + 0.5 * pulse)
                            }
                        }
                    }
                } else {
                    HStack(spacing: gap) {
                        ForEach(0..<count, id: \.self) { index in
                            let position = history.count - count + index
                            let value = position >= 0 ? CGFloat(history[position]) : 0
                            Capsule()
                                .fill(Color.ink.opacity(0.35 + 0.55 * Double(value)))
                                .frame(width: dot, height: max(dot, value * height))
                        }
                    }
                    .animation(.linear(duration: 0.08), value: history.count)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: height)
        .onChange(of: level) { _, value in
            history.append(value)
            if history.count > 160 { history.removeFirst(history.count - 160) }
        }
        .accessibilityHidden(true)
    }
}
