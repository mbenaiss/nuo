@preconcurrency import AVFoundation
import SwiftUI

/// The recordings made on the watch: where each one is, then its note, its transcript and its moments.
struct RecordingsView: View {
    @State private var store = RecordingsStore.shared
    @State private var pendingDelete: PhoneRecording?
    @State private var opened: String? = RecordingsDemo.opensScreen && RecordingsDemo.tab != "list" ? RecordingsDemo.clientId : nil

    var body: some View {
        List {
            if store.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No recordings", systemImage: "applewatch.radiowaves.left.and.right")
                } description: {
                    Text("On your watch, tap “Record” or the Nuo complication. Double pinch to mark a key moment: it will show up in the summary.")
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.recordings) { recording in
                Button {
                    opened = recording.id
                } label: {
                    RecordingRow(recording: recording)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.card)
                .swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = recording }
                }
            }
            Section {
                Toggle("Keep the audio after transcription", isOn: $store.keepsAudio)
                Picker("Default template", selection: $store.template) {
                    ForEach(MeetingTemplate.allCases) { template in
                        Label(template.title, systemImage: template.symbol).tag(template)
                    }
                }
                Picker("Bot that writes the summaries", selection: Binding(get: { store.noteBot?.id ?? "" },
                                                                               set: { store.noteBotId = $0.isEmpty ? nil : $0 })) {
                    if store.noteBot == nil { Text("None").tag("") }
                    ForEach(store.noteBotCandidates) { bot in
                        Text("\(bot.config?.emoji ?? "🤖") \(bot.config?.name ?? "Bot")").tag(bot.id)
                    }
                }
            } footer: {
                Text("The audio leaves the watch once it is on the iPhone, then the iPhone and your gateway once transcribed, unless you keep it. Nothing goes anywhere but to your gateway. The bot that writes reads other people's speech: the General bot and those with full access are not offered.")
            }
            .listRowBackground(Color.card)
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .toolbarVisibility(.hidden, for: .tabBar)
        .navigationTitle("Recordings")
        .navigationDestination(item: $opened) { id in
            RecordingDetailView(id: id)
        }
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id { store.delete(id) }
            }
        } message: {
            Text("The audio, transcript and summary are deleted from the iPhone. The document already saved in Docs › reunions stays.")
        }
    }
}

struct RecordingRow: View {
    let recording: PhoneRecording

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recording.template.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentInk)
                .frame(width: 38, height: 38)
                .background(Color.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(recording.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(.current)))
                    Text("·")
                    Text(NoteFormat.clock(recording.duration))
                    if !recording.markers.isEmpty {
                        Label("\(recording.markers.count)", systemImage: "bookmark.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.text2)
                StageChip(recording: recording)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.text3)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct StageChip: View {
    let recording: PhoneRecording

    var body: some View {
        HStack(spacing: 5) {
            switch recording.stage {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
            case .recording:
                Image(systemName: "record.circle")
            default:
                ProgressView().controlSize(.mini)
            }
            Text(recording.status).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var tint: Color {
        switch recording.stage {
        case .ready: .good
        case .failed: .red
        case .recording: .red
        default: Color.accentInk
        }
    }
}

struct RecordingDetailView: View {
    let id: String
    @State private var store = RecordingsStore.shared
    @State private var tab: Tab = RecordingsDemo.tab == "transcript" ? .transcript : .note
    @State private var player = RecordingPlayer()
    @State private var asksBot = false
    @State private var renaming: String?
    @State private var newName = ""
    @State private var riskyBot: Bot?
    @Environment(BotsStore.self) private var bots
    @Environment(AppRouter.self) private var router

    enum Tab: Hashable { case note, transcript }

    var body: some View {
        if let recording = store.recording(id: id) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    header(recording)
                    if recording.hasAudio { audioRow(recording) }
                    if recording.stage == .failed {
                        Label(recording.status, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        if store.canRetry(id) {
                            Button("Try again") { store.retry(id) }.buttonStyle(.bordered)
                        }
                    }
                    ForEach([recording.warning, recording.saveError].compactMap { $0 }, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if recording.canTranscribePartially(now: context.date) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(recording.arrival.received.count) of \(recording.arrival.expected.map(String.init) ?? "?") chunks arrived from the watch, nothing new for a few minutes. Missing chunks will become silence.")
                                    .font(.footnote)
                                    .foregroundStyle(Color.text2)
                                Button("Transcribe what arrived") { store.transcribePartially(id) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    if recording.canTranscribeFully {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("The missing chunks have arrived from the watch.").font(.footnote).foregroundStyle(Color.text2)
                            Button("Transcribe the whole recording") { store.transcribeFully(id) }.buttonStyle(.bordered)
                        }
                    }
                    Picker("View", selection: $tab) {
                        Text("Summary").tag(Tab.note)
                        Text("Transcript").tag(Tab.transcript)
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case .note: noteTab(recording)
                    case .transcript: transcriptTab(recording)
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.bottom, 24)
            }
            .contentMargins(.bottom, 96, for: .scrollContent)
            .background(Color.canvas)
            .toolbarVisibility(.hidden, for: .tabBar)
            .navigationTitle(recording.template.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if recording.lines?.isEmpty == false {
                    Menu {
                        ForEach(MeetingTemplate.allCases) { template in
                            Button {
                                store.regenerate(id, template: template)
                            } label: {
                                Label(template.title, systemImage: template.symbol)
                            }
                        }
                    } label: {
                        Label("Template", systemImage: "wand.and.stars")
                    }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    asksBot = true
                } label: {
                    Label("Ask a bot", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .padding(.horizontal, Spacing.gutter)
                .padding(.bottom, 8)
                .disabled(recording.lines?.isEmpty != false)
            }
            .confirmationDialog("Ask which bot?", isPresented: $asksBot, titleVisibility: .visible) {
                ForEach(bots.bots) { bot in
                    Button("\(bot.config?.emoji ?? "🤖") \(bot.config?.name ?? "Bot")") {
                        // A bot that can act on the machine or reach every bot: asked first, whoever spoke.
                        if !NoteBotChoice.isEligible(bot) { riskyBot = bot } else { ask(bot, about: recording) }
                    }
                }
            } message: {
                Text("The summary and transcript go with your first question.")
            }
            .alert("Send to \(riskyBot?.config?.name ?? String(localized: "this bot"))?", isPresented: Binding(get: { riskyBot != nil }, set: { if !$0 { riskyBot = nil } })) {
                Button("Send anyway", role: .destructive) {
                    if let bot = riskyBot { ask(bot, about: recording) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This bot can act on your machine or hand over to all your bots: it will read what the other participants said.")
            }
            .alert("Voice name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Julie Martin", text: $newName)
                Button("Save") {
                    if let voice = renaming { store.rename(id, voice: voice, to: newName) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onDisappear { player.stop() }
        } else {
            ContentUnavailableView("Recording deleted", systemImage: "waveform.slash")
        }
    }

    private func header(_ recording: PhoneRecording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.title)
                .font(.title2.bold())
                .foregroundStyle(Color.ink)
            HStack(spacing: 8) {
                Label(NoteFormat.clock(recording.duration), systemImage: "timer")
                if recording.voiceCount > 0 { Label("\(recording.voiceCount) voices", systemImage: "person.2") }
                Label("\(recording.markers.count) markers", systemImage: "bookmark.fill")
            }
            .font(.footnote)
            .foregroundStyle(Color.text2)
            HStack(spacing: 8) {
                StageChip(recording: recording)
                if let path = recording.savedPath {
                    Label(path, systemImage: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.top, 8)
    }

    private func audioRow(_ recording: PhoneRecording) -> some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(store.audioURL(id))
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording audio").font(.subheadline.weight(.semibold))
                Text(store.keepsAudio ? String(localized: "Kept on the iPhone") : String(localized: "Deleted once transcribed")).font(.caption).foregroundStyle(Color.text2)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func noteTab(_ recording: PhoneRecording) -> some View {
        if !recording.quotes.isEmpty, recording.lines != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Key moments").font(.headline).foregroundStyle(Color.ink)
                ForEach(recording.quotes) { quote in
                    MarkerQuoteCard(quote: quote, names: recording.speakerNames) {
                        if recording.hasAudio { player.play(store.audioURL(id), at: quote.marker.offset) }
                    }
                }
            }
        }
        if let note = recording.note {
            MarkdownView(document: MarkdownDocument(Self.withoutMoments(note)), basePath: "reunions")
                .padding(14)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text(recording.lines == nil ? String(localized: "The summary will be written once the transcription is done.") : String(localized: "Writing the summary…"))
                    .font(.subheadline)
                    .foregroundStyle(Color.text2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    @ViewBuilder
    private func transcriptTab(_ recording: PhoneRecording) -> some View {
        if let lines = recording.lines {
            let markers = recording.quotes
            VStack(alignment: .leading, spacing: 14) {
                ForEach(RecordingTurn.group(lines)) { turn in
                    let line = RecordingLine(start: turn.start, end: turn.end, text: turn.text, speaker: turn.speaker)
                    let flagged = markers.filter { quote in quote.line.map { $0.start >= turn.start && $0.start <= turn.end } ?? false }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Button {
                                renaming = turn.speaker
                                newName = recording.speakerNames[turn.speaker ?? ""] ?? ""
                            } label: {
                                Text(line.displayLabel(names: recording.speakerNames))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Self.voiceColor(turn.speaker))
                            }
                            .buttonStyle(.plain)
                            .disabled(turn.speaker == nil)
                            Text(NoteFormat.clock(turn.start)).font(.caption.monospacedDigit()).foregroundStyle(Color.text3)
                            if !flagged.isEmpty {
                                Label("Marker", systemImage: "bookmark.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.accentInk)
                            }
                        }
                        Text(Self.highlighted(turn, lines: lines, flagged: Set(flagged.compactMap { $0.line?.start })))
                            .font(.body)
                            .foregroundStyle(Color.ink)
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text(recording.stage == .transferring || recording.stage == .recording
                     ? String(localized: "The audio is arriving from the watch.") : String(localized: "Your gateway is transcribing, with the speakers."))
                    .font(.subheadline)
                    .foregroundStyle(Color.text2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private func ask(_ bot: Bot, about recording: PhoneRecording) {
        let context = RecordingNotePrompt.askContext(title: recording.title, startedAt: recording.startedAt, note: recording.note,
                                                     lines: recording.lines ?? [], names: recording.speakerNames)
        router.path = [.chat(ChatTarget(botId: bot.id, initialPrompt: context))]
    }

    /// The moments are shown above with the words said, and the title heads the screen: the note's own would repeat them.
    static func withoutMoments(_ note: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in note.components(separatedBy: "\n") {
            if line.hasPrefix("# ") { continue }
            if line.hasPrefix("## ") { skipping = line.lowercased().hasPrefix("## moments clés") }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The paragraph of a voice, with the sentence said at a marker picked out.
    static func highlighted(_ turn: RecordingTurn, lines: [RecordingLine], flagged: Set<TimeInterval>) -> AttributedString {
        let own = lines.filter { $0.speaker == turn.speaker && $0.start >= turn.start && $0.start <= turn.end }
        var text = AttributedString()
        for (index, line) in own.enumerated() {
            var part = AttributedString((index == 0 ? "" : " ") + line.text)
            if flagged.contains(line.start) {
                part.backgroundColor = Color.accent.opacity(0.22)
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            text += part
        }
        return text
    }

    static func voiceColor(_ voice: String?) -> Color {
        switch voice {
        case "1": Color.accentInk
        case "2": Color(hex: 0x2F7DD1)
        case "3": Color(hex: 0x2E9E6B)
        case "4": Color(hex: 0x9B59B6)
        default: Color.text2
        }
    }
}

/// A moment flagged on the watch, with the words said then.
struct MarkerQuoteCard: View {
    let quote: MarkerQuote
    let names: [String: String]
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 2) {
                    Image(systemName: "bookmark.fill").font(.subheadline)
                    Text(NoteFormat.clock(quote.marker.offset)).font(.caption2.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(Color.accentInk)
                .frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    if let line = quote.line {
                        Text("“\(line.text)”")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(line.displayLabel(names: names)).font(.caption).foregroundStyle(Color.text2)
                    } else {
                        Text("Silence at that moment").font(.subheadline).foregroundStyle(Color.text2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accent.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }
}

/// Plays the recording's audio while it is on the iPhone, from a marker if asked.
@MainActor
@Observable
final class RecordingPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }

    func toggle(_ url: URL) {
        if isPlaying { stop() } else { play(url, at: player?.currentTime ?? 0) }
    }

    func play(_ url: URL, at offset: TimeInterval) {
        if player?.url != url {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.currentTime = max(0, offset - 3)
        player.play()
        isPlaying = true
    }

    func stop() {
        player?.pause()
        isPlaying = false
    }
}
