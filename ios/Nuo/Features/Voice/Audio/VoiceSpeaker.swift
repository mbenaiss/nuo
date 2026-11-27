@preconcurrency import AVFoundation
import Foundation

/// Speaks a queue of sentences without gaps: each sentence is synthesized to PCM while the
/// previous one plays, and played through the shared voice-processed engine.
@MainActor
final class VoiceSpeaker: NSObject {
    enum Kind: Sendable { case filler, answer, notice }

    struct Item: Identifiable, Equatable, Sendable {
        let id: Int
        let text: String
        let speech: String
        let kind: Kind
    }

    var onItemAudible: (Item) -> Void = { _ in }
    var onDrained: () -> Void = {}

    private let engine: VoiceAudioEngine
    private let synthesizer = AVSpeechSynthesizer()
    private let ledger = PlaybackLedger()
    private var voice: AVSpeechSynthesisVoice?
    private var pending: [Item] = []
    private var audible: [Item] = []
    private var rendering: Item?
    private var nextId = 0
    private var watchdog: Task<Void, Never>?

    init(engine: VoiceAudioEngine, voice: AVSpeechSynthesisVoice?) {
        self.engine = engine
        super.init()
        synthesizer.delegate = self
        setVoice(voice)
    }

    var isActive: Bool { rendering != nil || !pending.isEmpty || !audible.isEmpty }
    var hasAnswerQueued: Bool { (pending + audible + [rendering].compactMap { $0 }).contains { $0.kind == .answer } }
    var currentVoice: AVSpeechSynthesisVoice? { voice }

    func setVoice(_ voice: AVSpeechSynthesisVoice?) {
        self.voice = voice
        if let rate = VoiceCatalog.sampleRate(of: voice), !isActive {
            engine.preparePlayback(sampleRate: rate)
        }
    }

    func enqueue(_ text: String, speech: String? = nil, kind: Kind) {
        nextId += 1
        pending.append(Item(id: nextId, text: text, speech: speech ?? text, kind: kind))
        renderNext()
    }

    /// Cuts speech immediately (barge-in, close).
    func stop() {
        ledger.advanceGeneration()
        watchdog?.cancel()
        watchdog = nil
        pending.removeAll()
        audible.removeAll()
        rendering = nil
        synthesizer.stopSpeaking(at: .immediate)
        engine.flushPlayback()
    }

    /// After the engine graph was rebuilt, scheduled audio is gone: replay from the current sentence.
    func replayAfterEngineReset() {
        let remaining = audible + pending.filter { item in !audible.contains(item) }
        stop()
        if let rate = VoiceCatalog.sampleRate(of: voice) { engine.preparePlayback(sampleRate: rate) }
        for item in remaining { enqueue(item.text, speech: item.speech, kind: item.kind) }
    }

    private func renderNext() {
        guard rendering == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        rendering = item
        audible.append(item)
        if audible.first == item { onItemAudible(item) }

        let generation = ledger.begin(item.id)
        let utterance = AVSpeechUtterance(string: item.speech)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        let engine = engine
        let ledger = ledger
        synthesizer.write(utterance) { @Sendable [weak self] buffer in
            guard ledger.isCurrent(generation) else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                Task { @MainActor in self?.synthesisFinished(item, generation: generation) }
                return
            }
            ledger.scheduled(item.id)
            let ok = engine.schedule(pcm) {
                if ledger.played(item.id), ledger.isCurrent(generation) {
                    Task { @MainActor in self?.itemPlayed(item, generation: generation) }
                }
            }
            if !ok, ledger.played(item.id) {
                Task { @MainActor in self?.itemPlayed(item, generation: generation) }
            }
        }

        // A synthesis that never reports its end must not freeze the conversation.
        watchdog?.cancel()
        let budget = Double(item.text.count) * 0.12 + 4
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(budget))
            guard !Task.isCancelled else { return }
            self?.synthesisFinished(item, generation: generation)
        }
    }

    fileprivate func synthesisFinished(_ item: Item, generation: Int) {
        guard ledger.isCurrent(generation), rendering == item else { return }
        rendering = nil
        watchdog?.cancel()
        watchdog = nil
        if ledger.finishSynthesis(item.id) {
            itemPlayed(item, generation: generation)
        }
        renderNext()
    }

    private func itemPlayed(_ item: Item, generation: Int) {
        guard ledger.isCurrent(generation), let index = audible.firstIndex(of: item) else { return }
        audible.remove(at: index)
        if index == 0, let next = audible.first { onItemAudible(next) }
        if !isActive { onDrained() }
    }

    fileprivate func synthesisFinished(utteranceText: String) {
        guard let rendering, rendering.speech == utteranceText else { return }
        synthesisFinished(rendering, generation: ledger.generation)
    }
}

extension VoiceSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in self.synthesisFinished(utteranceText: text) }
    }
}

/// Counts scheduled vs played buffers per sentence, across the synthesizer and render threads.
final class PlaybackLedger: @unchecked Sendable {
    private struct Entry { var scheduled = 0, played = 0, synthesisDone = false, finished = false }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var currentGeneration = 0

    var generation: Int { lock.withLock { currentGeneration } }

    func isCurrent(_ generation: Int) -> Bool { lock.withLock { currentGeneration == generation } }

    func advanceGeneration() {
        lock.withLock {
            currentGeneration += 1
            entries.removeAll()
        }
    }

    func begin(_ id: Int) -> Int {
        lock.withLock {
            entries[id] = Entry()
            return currentGeneration
        }
    }

    func scheduled(_ id: Int) {
        lock.withLock { entries[id]?.scheduled += 1 }
    }

    /// Returns true exactly once, when the sentence has been fully synthesized and played.
    func played(_ id: Int) -> Bool {
        lock.withLock {
            entries[id]?.played += 1
            return complete(id)
        }
    }

    func finishSynthesis(_ id: Int) -> Bool {
        lock.withLock {
            entries[id]?.synthesisDone = true
            return complete(id)
        }
    }

    private func complete(_ id: Int) -> Bool {
        guard var entry = entries[id], !entry.finished, entry.synthesisDone, entry.played >= entry.scheduled else { return false }
        entry.finished = true
        entries[id] = entry
        return true
    }
}
