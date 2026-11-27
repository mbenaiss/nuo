import AppKit
import SwiftUI

/// Small dot and elapsed time of the meeting being recorded, discreet enough for a shared screen.
struct MeetingRecordingBadge: View {
    @State private var recorder = MeetingRecorder.shared
    var font: Font = .caption.monospacedDigit()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
                Circle().fill(Color.text3).frame(width: 5, height: 5)
                Text(MeetingFormat.clock(recorder.elapsed(at: context.date))).font(font)
            }
            .foregroundStyle(Color.text2)
        }
        .accessibilityLabel("Recording in progress")
    }
}

struct MeetingConsentLine: View {
    var body: some View {
        Label("Tell the participants that you are transcribing.", systemImage: "hand.raised")
            .font(.caption)
            .foregroundStyle(Color.text2)
    }
}

/// The meeting window: the user's notes beside the live transcript, then the generated note. Left out of screen
/// sharing: it shows what the others say.
struct MeetingWindow: View {
    @State private var recorder = MeetingRecorder.shared
    @State private var pane: Pane = .notes

    enum Pane: Hashable { case note, notes }

    var body: some View {
        VStack(spacing: 0) {
            if recorder.phase != .idle {
                MeetingHeader()
                Divider()
            }
            if let issue = recorder.issue { MeetingIssueBanner(issue: issue) }
            if recorder.phase == .idle {
                MeetingIdleView()
            } else {
                HSplitView {
                    leftPane
                        .frame(minWidth: 380, idealWidth: 600, maxHeight: .infinity)
                    MeetingTranscriptPane()
                        .frame(minWidth: 320, idealWidth: 460, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color.canvas)
        .hiddenFromScreenSharing()
        .onAppear {
            if recorder.isRecording { recorder.opensWindowOnStart = true }
            if recorder.phase == .stopped { pane = .note }
        }
        .onDisappear { if recorder.isRecording { recorder.opensWindowOnStart = false } }
        .onChange(of: recorder.phase) { _, phase in pane = phase == .stopped ? .note : .notes }
        .confirmationDialog("Start a new meeting?", isPresented: $recorder.confirmsStart) {
            Button("Erase and Start", role: .destructive) { recorder.confirmStart() }
        } message: {
            Text(recorder.isFinalizing
                ? String(localized: "This meeting's transcript isn't finished: it will be lost, along with your notes.")
                : String(localized: "This meeting's transcript and your notes weren't saved."))
        }
    }

    @ViewBuilder
    private var leftPane: some View {
        VStack(spacing: 0) {
            if recorder.phase == .stopped {
                MeetingNoteToolbar(pane: $pane)
                Divider()
            }
            if recorder.phase == .stopped, pane == .note {
                MeetingNoteView()
            } else {
                MeetingNotepad()
            }
        }
        .background(Color.card)
    }
}

// MARK: - Header

private struct MeetingHeader: View {
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        @Bindable var recorder = recorder
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.sm) {
                    MeetingStatusPill()
                    TextField("Meeting title", text: $recorder.title)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                }
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "person.2").font(.caption)
                    TextField("Participants", text: $recorder.participants)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .foregroundStyle(Color.text2)
            }
            Spacer(minLength: Spacing.md)
            if recorder.phase == .recording {
                HStack(spacing: Spacing.xs) {
                    MeetingSource(label: String(localized: "Me"), symbol: "mic.fill", level: recorder.micLevel)
                    if recorder.hasSystemAudio {
                        MeetingSource(label: String(localized: "Them"), symbol: "speaker.wave.2.fill", level: recorder.systemLevel)
                    }
                }
            }
            primaryButton
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if recorder.isRecording {
            Button { Task { await recorder.stop() } } label: {
                Label("Stop", systemImage: "stop.fill").padding(.horizontal, Spacing.xxs)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.bad)
            .controlSize(.large)
            .disabled(recorder.phase == .starting)
            .help("Stop recording (⇧⌘R)")
        } else {
            Button {
                recorder.requestStart(event: nil)
            } label: {
                Label("New Meeting", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// « ● 12:34 » while recording, « Terminée · 42:10 » after.
private struct MeetingStatusPill: View {
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        Group {
            switch recorder.phase {
            case .starting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Starting")
                }
                .foregroundStyle(Color.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.chip, in: Capsule())
            case .recording:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Circle().fill(Color.bad).frame(width: 8, height: 8)
                            .opacity(Int(context.date.timeIntervalSince1970) % 2 == 0 ? 1 : 0.35)
                            .animation(.easeInOut(duration: 0.5), value: Int(context.date.timeIntervalSince1970))
                        Text(MeetingFormat.clock(recorder.elapsed(at: context.date)))
                    }
                }
                .foregroundStyle(Color.bad)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.bad.opacity(0.12), in: Capsule())
            case .stopped:
                Text("Finished · \(MeetingFormat.clock(recorder.elapsed))")
                    .foregroundStyle(Color.text2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.chip, in: Capsule())
            case .idle:
                EmptyView()
            }
        }
        .font(.callout.monospacedDigit().weight(.semibold))
        .fixedSize()
    }
}

/// One audio source and its live level: a flat line says at a glance that nothing is heard.
private struct MeetingSource: View {
    let label: String
    let symbol: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption).foregroundStyle(Color.text2)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Color.text2)
            MeetingLevelBars(level: level, tint: Color.good)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.chip, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
    }
}

struct MeetingLevelBars: View {
    let level: Float
    var tint: Color = Color.good
    private static let weights: [CGFloat] = [0.5, 0.85, 1, 0.75, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(level > 0.02 ? tint : Color.text3)
                    .frame(width: 3, height: 3 + 13 * CGFloat(min(max(level, 0), 1)) * Self.weights[index])
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

private struct MeetingIssueBanner: View {
    let issue: MeetingRecorder.Issue

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xE58A00))
            Text(issue.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let url = issue.settingsURL {
                Button("Open System Settings") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(Color(hex: 0xE58A00, opacity: 0.12))
    }
}

// MARK: - Before the meeting

/// The window opened with no meeting: what is about to happen, and how to start.
private struct MeetingIdleView: View {
    @State private var recorder = MeetingRecorder.shared
    @State private var models = DictationModelStore.shared

    var body: some View {
        @Bindable var recorder = recorder
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.xl)
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.accentInk)
                .frame(width: 64, height: 64)
                .background(Color.accentSoft, in: Circle())
            VStack(spacing: Spacing.xs) {
                Text("Transcribe a Meeting").font(.title2.weight(.semibold))
                Text("Nuo records your voice and the other participants', transcribes the whole meeting at once when it ends, then writes the summary.")
                    .font(.callout)
                    .foregroundStyle(Color.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if let event = recorder.proposedEvent ?? MeetingRecorder.currentEvent() {
                HStack(spacing: Spacing.xs) {
                    RoundedRectangle(cornerRadius: 1.5).fill(event.tint).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(event.start > Date() ? String(localized: "Upcoming · \(AgendaText.range(event))") : String(localized: "In progress · \(AgendaText.range(event))")).font(.caption).foregroundStyle(Color.text2)
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.line))
            }
            VStack(spacing: Spacing.xs) {
                Toggle("Online transcription, with speakers", isOn: $recorder.useCloud)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                HStack(spacing: Spacing.xs) {
                    Text(recorder.useCloud ? String(localized: "Without network:") : String(localized: "On the Mac:")).font(.caption).foregroundStyle(Color.text2)
                    Picker("Transcription engine", selection: $recorder.engine) {
                        ForEach(MeetingEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(recorder.engine.detail)
                    .font(.caption)
                    .foregroundStyle(Color.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.sm) {
                MeetingTemplateMenu()
                Picker("Language", selection: $recorder.language) {
                    ForEach(MeetingLanguage.allCases) { language in
                        Text(language == .auto && recorder.engine == .apple ? String(localized: "Auto language (French)") : language.title).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            VStack(spacing: Spacing.xs) {
                Button { Task { await recorder.start(event: nil) } } label: {
                    Label("Start", systemImage: "record.circle").frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                Text("or ⇧⌘R from anywhere in Nuo").font(.caption).foregroundStyle(Color.text3)
            }
            VStack(spacing: Spacing.xxs) {
                MeetingConsentLine()
                if recorder.engine == .whisper, models.readyFolder(.turbo) == nil, models.readyFolder(.small) == nil {
                    Label("The transcription model (630 MB) will be downloaded on the first recording.", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(Color.text2)
                }
                Label(recorder.useCloud
                      ? String(localized: "After the meeting, only the voice is sent to your gateway, which has it transcribed, then the audio is deleted.")
                      : recorder.engine.keepsAudio
                      ? String(localized: "Everything stays on this Mac; the audio is kept until the next meeting so it can be transcribed again with Whisper.")
                      : String(localized: "Everything stays on this Mac; the audio is deleted once transcribed."), systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(Color.text2)
            }
            Spacer(minLength: Spacing.xl)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingTemplateMenu: View {
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        @Bindable var recorder = recorder
        Picker("Meeting type", selection: $recorder.template) {
            ForEach(MeetingTemplate.allCases) { template in
                Label(template.title, systemImage: template.symbol).tag(template)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("The meeting type shapes the summary")
    }
}

// MARK: - Notes

private struct MeetingNotepad: View {
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        @Bindable var recorder = recorder
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("My Notes").font(.headline)
                Spacer()
                if recorder.phase != .stopped { MeetingTemplateMenu().controlSize(.small) }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xs)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $recorder.notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Spacing.md)
                if recorder.notes.isEmpty {
                    Text("A word, an idea, a decision… in any order.\nYour notes stay as they are in the summary; the transcript fills in the rest.")
                        .foregroundStyle(Color.text3)
                        .padding(.horizontal, Spacing.md + 5)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Transcript

/// The transcript as it is written, with where the transcription stands.
struct MeetingTranscriptPane: View {
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Text("Transcript").font(.headline)
                Spacer()
                status
                if recorder.canRetranscribe {
                    Button { recorder.retranscribeWithWhisper() } label: {
                        Label("Transcribe Again with Whisper", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .help("More accurate, spells participants' names correctly. The recording is deleted afterwards.")
                }
                if recorder.transcription == .done, !recorder.transcript.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recorder.transcript.displayText(meName: String(localized: "Me")), forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy transcript")
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xs)
            if recorder.transcript.isEmpty {
                placeholder
            } else {
                lines
            }
        }
        .background(Color.canvas)
    }

    @ViewBuilder
    private var status: some View {
        switch recorder.transcription {
        case let .finishing(progress, remaining):
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 60)
                let label = recorder.isRetranscribing ? String(localized: "Transcribing again with Whisper") : String(localized: "Transcript")
                Text(remaining.map { String(localized: "\(label) · \(MeetingFormat.remaining($0)) left") } ?? label)
                // A resumed meeting shows its lines so far, not the placeholder that holds this button.
                if recorder.isWaitingForCloud, !recorder.transcript.isEmpty {
                    Button("Transcribe on the Mac Now") { recorder.transcribeOnMacNow() }
                        .controlSize(.small)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.text2)
        case .done:
            let voices = recorder.transcript.voiceCount
            let parts = [String(localized: "\(recorder.transcript.wordCount) words")]
                + [recorder.detectedLanguage.map { MeetingLanguage.name(of: $0) }].compactMap { $0 }
                + (voices > 1 ? [String(localized: "\(voices) voices")] : [])
                + [recorder.transcribedInCloud ? String(localized: "online") : recorder.activeEngine.name]
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Color.text2)
        case let .downloading(fraction):
            Text("Model · \(fraction.formatted(.percent.precision(.fractionLength(0))))").font(.caption.monospacedDigit()).foregroundStyle(Color.text2)
        case .preparing:
            Text("Preparing…").font(.caption).foregroundStyle(Color.text2)
        case .failed:
            Text("Interrupted").font(.caption.weight(.medium)).foregroundStyle(Color.bad)
        case .none:
            EmptyView()
        }
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(recorder.transcript.turns) { turn in
                        MeetingTurnRow(turn: turn, voices: recorder.transcript.voiceCount).id(turn.id)
                    }
                    footer.id("footer")
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onChange(of: recorder.transcript.segments.count) { _, _ in
                guard recorder.phase == .recording else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("footer", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch recorder.transcription {
        case let .failed(message):
            failure(message)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: Spacing.sm) {
            switch recorder.transcription {
            case let .downloading(fraction):
                ProgressView(value: fraction).frame(maxWidth: 240)
                Text("Downloading the transcription model… \(fraction.formatted(.percent.precision(.fractionLength(0))))").font(.callout)
                Text("One time only, about 630 MB. Recording continues: nothing is lost.")
                    .font(.caption)
                    .foregroundStyle(Color.text2)
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Preparing the model…").font(.callout)
                Text(recorder.activeEngine == .apple
                    ? String(localized: "The first time, macOS downloads the language model. Recording continues.")
                    : String(localized: "The first time, it is optimized for this Mac: a few minutes. Recording continues."))
                    .font(.caption)
                    .foregroundStyle(Color.text2)
            case let .failed(message):
                failure(message)
            case .done:
                Text("Nothing was transcribed.").font(.callout).foregroundStyle(Color.text2)
            case let .finishing(progress, _):
                ProgressView(value: progress).frame(maxWidth: 240)
                Text("Transcribing the meeting…").font(.callout)
                Text("All at once, with speakers and without filler words.")
                    .font(.caption)
                    .foregroundStyle(Color.text2)
                if recorder.isWaitingForCloud {
                    Button("Transcribe on the Mac Now") { recorder.transcribeOnMacNow() }
                        .controlSize(.small)
                        .help("The gateway keeps going on its side: if it answers before the Mac, its transcript is kept.")
                }
            default:
                Image(systemName: recorder.phase == .recording ? "waveform" : "text.bubble").font(.title2).foregroundStyle(Color.text3)
                Text("The transcript arrives at the end of the meeting, all at once. Take your notes alongside in the meantime.")
                    .font(.callout)
                    .foregroundStyle(Color.text2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.bad)
            if recorder.phase == .stopped {
                Button("Retry") { recorder.retryTranscription() }
            }
        }
    }
}

private struct MeetingTurnRow: View {
    let turn: MeetingTurn
    let voices: Int

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: turn.speaker == .me ? "person.fill" : "person.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(turn.speaker == .me ? Color.accentInk : Color.text2)
                .frame(width: 26, height: 26)
                .background(turn.speaker == .me ? Color.accentSoft : Color.chip, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(turn.displayLabel(meName: String(localized: "Me"), voices: voices)).font(.callout.weight(.semibold))
                    Text(MeetingFormat.clock(turn.start)).font(.caption.monospacedDigit()).foregroundStyle(Color.text3)
                }
                Text(turn.text)
                    .font(.body)
                    .foregroundStyle(Color.ink)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Generated note

private struct MeetingNoteToolbar: View {
    @State private var riskyBot: Bot?
    @Binding var pane: MeetingWindow.Pane
    @Environment(BotsStore.self) private var bots
    @State private var recorder = MeetingRecorder.shared

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Picker("", selection: $pane) {
                Text("Summary").tag(MeetingWindow.Pane.note)
                Text("My Notes").tag(MeetingWindow.Pane.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if pane == .note {
                MeetingTemplateMenu()
                botMenu
                if recorder.noteState != .none, recorder.noteState != .generating {
                    Button { recorder.generate() } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .disabled(!recorder.canGenerate)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    private var botMenu: some View {
        let bot = recorder.defaultBot(in: bots.bots)
        return Menu {
            ForEach(bots.bots) { candidate in
                // A bot with full access or that reaches every bot would read the others' words: chosen knowingly.
                Button("\(candidate.config?.emoji ?? "✨") \(candidate.config?.name ?? String(localized: "Bot"))\(NoteBotChoice.isEligible(candidate) ? "" : " ⚠︎")") {
                    if NoteBotChoice.isEligible(candidate) { recorder.botId = candidate.id } else { riskyBot = candidate }
                }
            }
        } label: {
            Text("\(bot?.config?.emoji ?? "✨") \(bot?.config?.name ?? String(localized: "Choose the bot that writes the summaries"))")
        }
        .fixedSize()
        .help("The bot that writes the summary")
        .confirmationDialog("Give the summary to \(riskyBot?.config?.name ?? String(localized: "this bot"))?",
                            isPresented: Binding(get: { riskyBot != nil }, set: { if !$0 { riskyBot = nil } }), titleVisibility: .visible) {
            Button("Choose Anyway", role: .destructive) { if let riskyBot { recorder.botId = riskyBot.id } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This bot can act on your machine or hand over to all your bots: it will read what the other participants say.")
        }
    }
}

/// The generated note, where it was saved, and its action items as reminders.
struct MeetingNoteView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(BotsStore.self) private var bots
    @State private var recorder = MeetingRecorder.shared
    @State private var creating = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                saveStatus
                content
                if recorder.noteState == .ready { actionsSection }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch recorder.noteState {
        case let .failed(message):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.bad)
                Button("Retry") { recorder.generate() }.disabled(!recorder.canGenerate)
            }
        case .generating where recorder.note.isEmpty:
            waiting(String(localized: "\(botName) is writing the summary…"))
        case .generating, .ready:
            MarkdownView(document: MarkdownDocument(recorder.note), basePath: "reunions")
        case .none:
            pending
        }
    }

    /// Before the note: why it is not there yet.
    @ViewBuilder
    private var pending: some View {
        switch recorder.transcription {
        case .done:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(blockReason ?? String(localized: "The summary hasn't been written yet.")).foregroundStyle(Color.text2)
                Button { recorder.generate() } label: {
                    Label("Write the Summary", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .disabled(!recorder.canGenerate || recorder.defaultBot(in: bots.bots) == nil)
            }
        case .failed:
            Text("The summary will be written once the transcript is finished.").foregroundStyle(Color.text2)
        default:
            waiting(String(localized: "\(botName) will write the summary as soon as the transcript is finished."))
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(Color.text2)
        }
        .padding(.top, Spacing.xs)
    }

    private var botName: String { recorder.defaultBot(in: bots.bots)?.config?.name ?? String(localized: "The bot") }

    private var blockReason: String? {
        if recorder.elapsed < MeetingRecorder.minimumDuration { return String(localized: "At least 1 min of meeting is needed for a summary.") }
        if recorder.transcript.isEmpty { return String(localized: "The transcript is empty.") }
        if bots.bots.isEmpty { return String(localized: "No bot available to write the summary.") }
        return nil
    }

    @ViewBuilder
    private var saveStatus: some View {
        if recorder.noteState == .ready {
            HStack(spacing: Spacing.xs) {
                if let path = recorder.savedPath {
                    Label("Saved in \(path)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.good)
                    Spacer()
                    Button("Open") { openWindow(id: MacWindow.doc, value: path) }
                } else if let error = recorder.saveError {
                    Label("Not saved: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.bad)
                    Spacer()
                    Button("Retry") { Task { await recorder.save() } }
                } else {
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recorder.note, forType: .string)
                }
                if recorder.canDeleteRecording {
                    Button("Delete Audio", role: .destructive) { confirmDelete = true }
                        .help("The meeting recording is still on this Mac.")
                }
            }
            .controlSize(.small)
            .confirmationDialog("Delete the meeting recording?", isPresented: $confirmDelete) {
                Button("Delete Audio", role: .destructive) { recorder.deleteRecording() }
            } message: {
                Text("The transcript and the summary are kept. You won't be able to transcribe again with Whisper.")
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        @Bindable var recorder = recorder
        if !recorder.actions.isEmpty || recorder.remindersCreated > 0 {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader(title: "Actions")
                ForEach($recorder.actions) { $action in
                    Toggle(isOn: $action.selected) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.title)
                            let detail = [action.owner, action.due.map { AgendaText.dayTitle($0) }].compactMap { $0 }
                            if !detail.isEmpty {
                                Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(Color.text2)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    if recorder.remindersCreated > 0 {
                        Label("\(recorder.remindersCreated) reminders created",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.good)
                    }
                    Spacer()
                    if !recorder.actions.isEmpty {
                        Button("Create Reminders") {
                            creating = true
                            Task {
                                await recorder.createReminders()
                                creating = false
                            }
                        }
                        .disabled(creating || !recorder.actions.contains(where: \.selected))
                    }
                }
            }
            .card(padding: Spacing.sm, radius: Radius.sm)
        }
    }
}

// MARK: - Sidebar section

/// Content column of « Réunions »: the meeting under way (or a button to start one), then the saved notes.
struct MeetingsList: View {
    @Environment(SessionStore.self) private var session
    @Environment(MacNavigator.self) private var navigator
    @State private var recorder = MeetingRecorder.shared
    @State private var notes: [DocNode] = []
    @State private var loaded = false

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.doc) {
            Section {
                MeetingStartCard()
                    .listRowSeparator(.hidden)
            }
            Section("Summaries") {
                if loaded && notes.isEmpty {
                    Text("Summaries are saved in Docs › reunions.")
                        .font(.callout)
                        .foregroundStyle(Color.text2)
                }
                ForEach(notes) { node in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(node)).lineLimit(1)
                            if let date = node.updatedAt {
                                Text(AgendaText.dayTitle(date)).font(.caption).foregroundStyle(Color.text2)
                            }
                        }
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                    .tag(node.path)
                }
            }
        }
        .task(id: "\(navigator.refreshTick)-\(recorder.savedPath ?? "")") { await load() }
    }

    private func load() async {
        guard let tree = try? await session.api.docsTree() else { loaded = true; return }
        notes = tree.filter { $0.kind == .file && $0.path.hasPrefix("reunions/") && $0.path.hasSuffix(".md") }
            .sorted { $0.path > $1.path }
        loaded = true
    }

    /// `2026-10-20-point-hebdo.md` → « Point hebdo ».
    static func title(_ node: DocNode) -> String {
        var name = node.name.hasSuffix(".md") ? String(node.name.dropLast(3)) : node.name
        if name.count > 11, name.prefix(10).allSatisfy({ $0.isNumber || $0 == "-" }) { name = String(name.dropFirst(11)) }
        let words = name.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// Start, follow or reopen the meeting; shared by the « Réunions » list and the menu bar panel. Stays neutral in color:
/// the main window may be on a shared screen.
struct MeetingStartCard: View {
    @Environment(\.openWindow) private var openWindow
    @State private var recorder = MeetingRecorder.shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            switch recorder.phase {
            case .recording, .starting: recording
            case .stopped: finished
            case .idle: idle
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                MeetingLevelBars(level: max(recorder.micLevel, recorder.systemLevel), tint: Color.text2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recorder.title.isEmpty ? String(localized: "Meeting in progress") : recorder.title).font(.callout.weight(.semibold)).lineLimit(1)
                    HStack(spacing: Spacing.xxs) {
                        Text("Transcript")
                        MeetingRecordingBadge()
                    }
                    .font(.caption)
                    .foregroundStyle(Color.text2)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Button("Open") { open() }
                Button("Stop") { Task { await recorder.stop() } }
                    .disabled(recorder.phase == .starting)
            }
            .controlSize(compact ? .small : .regular)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button { open() } label: {
                HStack(spacing: Spacing.sm) {
                    statusIcon.frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(recorder.title.isEmpty ? String(localized: "Last meeting") : recorder.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(statusText).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("New Meeting") { recorder.requestStart(event: nil) }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch (recorder.transcription, recorder.noteState) {
        case (_, .ready): Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.good)
        case (.failed, _), (_, .failed): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.bad)
        default: ProgressView().controlSize(.small)
        }
    }

    private var statusText: String {
        switch (recorder.transcription, recorder.noteState) {
        case (_, .ready): recorder.savedPath == nil ? String(localized: "Summary ready") : String(localized: "Summary saved")
        case (_, .generating): String(localized: "Writing the summary…")
        case (_, .failed): String(localized: "Summary not written")
        case let (.finishing(progress, _), _): String(localized: "Finishing the transcript · \(progress.formatted(.percent.precision(.fractionLength(0))))")
        case (.downloading, _), (.preparing, _): String(localized: "Preparing the model…")
        case (.failed, _): String(localized: "Transcript interrupted")
        case (.done, _): String(localized: "Transcript finished")
        default: String(localized: "Transcribing…")
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let event = MeetingRecorder.currentEvent() {
                Text("In progress: \(event.displayTitle)").font(.caption).foregroundStyle(Color.text2).lineLimit(1)
            }
            Button { Task { await recorder.start(event: nil) } } label: {
                Label("Transcribe a Meeting", systemImage: "waveform")
                    .frame(maxWidth: compact ? nil : .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
            .controlSize(compact ? .regular : .large)
            .help("Start transcribing (⇧⌘R)")
            if !compact { MeetingConsentLine() }
        }
    }

    private func open() {
        openWindow(id: MacWindow.meeting)
        NSApp.activate()
    }
}

extension View {
    /// Asks the window server to leave the window out of screenshots and screen sharing. Since macOS 15,
    /// ScreenCaptureKit (what Zoom, Meet in Chrome, Teams… now use) may still capture it: it only stops older capture paths.
    func hiddenFromScreenSharing(_ hidden: Bool = true) -> some View {
        background(WindowSharingHider(hidden: hidden))
    }
}

private struct WindowSharingHider: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> NSView { HiderView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? HiderView)?.excluded = hidden
    }

    private final class HiderView: NSView {
        var excluded = true {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.sharingType = excluded ? .none : .readOnly
        }
    }
}
