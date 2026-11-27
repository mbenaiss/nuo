#if DEBUG
import AppKit
import Foundation
@preconcurrency import WhisperKit

/// `-meetingBenchmark`: transcribes meetings built from the bundled French dictation samples (a quiet far voice, long
/// silences, a noise floor) the way the Mac does when the gateway cannot, in one pass once the recording is over, and
/// prints the WER and time of each, then quits. Runs Whisper (the « Précis » model, downloaded first if missing), then
/// Apple's recognizer.
enum MeetingBenchmark {
    private static let rate = WhisperEngine.sampleRate

    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-meetingBenchmark") else { return }
        Task {
            await run()
            NSApp.terminate(nil)
        }
    }

    private static func log(_ line: String) {
        print("BENCH \(line)")
        fflush(stdout)
    }

    @MainActor private static func run() async {
        guard let first = sample("dictation-bench-60s"), let second = sample("dictation-bench-10s"),
              let reference60 = DictationBenchmark.references["dictation-bench-60s"],
              let reference10 = DictationBenchmark.references["dictation-bench-10s"] else {
            log("samples missing")
            return
        }
        let model = WhisperModel.turbo
        var folder = DictationModelStore.folder(model)
        if !FileManager.default.fileExists(atPath: folder.path) {
            do {
                try FileManager.default.createDirectory(at: DictationModelStore.root, withIntermediateDirectories: true)
                folder = try await WhisperKit.download(variant: model.variant, downloadBase: DictationModelStore.root)
            } catch {
                log("download failed: \(error)")
                return
            }
        }
        do {
            try await WhisperEngine.shared.load(model, folder: folder)
        } catch {
            log("load failed: \(error)")
            return
        }
        await WhisperEngine.shared.hold()
        let reference = reference60 + " " + reference10
        var noise = SystemRandomNumberGenerator()
        let scenarios: [(String, [Float])] = [
            ("clean", first + silence(2) + second),
            ("quiet-pauses", silence(12) + first.map { $0 * 0.15 } + silence(25) + second.map { $0 * 0.15 } + silence(40)),
            ("noise-floor", (first + silence(6) + second).map { $0 + Float.random(in: -0.01...0.01, using: &noise) }),
            // The « Eux » stream: short turns, each followed by the silence of the user answering.
            ("turn-taking", turns(first) + turns(second)),
            ("muffled-turns", lowPass(turns(first) + turns(second)).map { $0 * 0.3 }),
        ]
        for (name, samples) in scenarios {
            for vocabulary in ["", "Alex, Coach."] {
                let clock = ContinuousClock.now
                do {
                    let text = try await transcribe(samples, vocabulary: vocabulary)
                    report(name, vocabulary.isEmpty ? "no prompt" : "prompt", clock, reference, text)
                } catch {
                    log("\(name) failed: \(error)")
                }
            }
        }
        await WhisperEngine.shared.release()
        await WhisperEngine.shared.unload(ifUsing: model)
        do {
            let locale = try await AppleFileTranscriber.prepare(Locale(identifier: "fr-FR"))
            for (name, samples) in scenarios {
                let clock = ContinuousClock.now
                let text = try await transcribe(samples, vocabulary: "", engine: .apple(locale))
                report(name, "apple", clock, reference, text)
            }
        } catch {
            log("apple failed: \(error)")
        }
        log("DONE")
    }

    /// Writes the whole meeting, then transcribes it.
    private static func transcribe(_ samples: [Float], vocabulary: String, engine: MeetingTranscriber.Engine = .whisper) async throws -> String {
        let url = URL.temporaryDirectory.appending(path: "meeting-bench-\(UUID().uuidString).f32")
        let writer = try MeetingStreamWriter(url: url, startedAt: Date())
        writer.close()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try samples.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        try handle.close()
        let transcriber = MeetingTranscriber(streams: [.init(speaker: .them, writer: writer)], engine: engine, language: nil,
                                             fallbackLanguage: "fr", vocabulary: vocabulary)
        var lines: [MeetingTranscriber.Line] = []
        while let chunk = try await transcriber.next() { lines += chunk.lines }
        return lines.map(\.text).joined(separator: " ")
    }

    private static func report(_ name: String, _ variant: String, _ clock: ContinuousClock.Instant, _ reference: String, _ text: String) {
        let elapsed = ContinuousClock.now - clock
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let wer = DictationBenchmark.errorRate(reference, text) * 100
        log(String(format: "%@ (%@): WER %.1f %% in %.1f s — %@", name, variant, wer, seconds, text))
    }

    private static func sample(_ name: String) -> [Float]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        return try? AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    }

    /// Cuts a recording into pieces of 2 to 9 s at its quietest moments and puts 4 to 9 s of silence after each.
    private static func turns(_ samples: [Float]) -> [Float] {
        let lengths = [4.0, 7, 2.5, 9, 3, 5.5, 2, 6]
        let gaps = [6, 4, 9, 5, 7, 4, 8, 5]
        let energy = MeetingSpeech.energy(samples)
        var output: [Float] = []
        var frame = 0
        var index = 0
        while frame < energy.count {
            let target = frame + Int(lengths[index % lengths.count] * 10)
            let end = target >= energy.count - 10 ? energy.count : MeetingSpeech.quietest(energy, in: target - 10..<target + 10)
            output += samples[frame * MeetingSpeech.frame..<min(samples.count, end * MeetingSpeech.frame)]
            output += silence(gaps[index % gaps.count])
            frame = end
            index += 1
        }
        return output
    }

    /// About 3 kHz of bandwidth, like a compressed call.
    private static func lowPass(_ samples: [Float]) -> [Float] {
        samples.indices.map { index in
            let window = samples[max(0, index - 4)...index]
            return window.reduce(0, +) / Float(window.count)
        }
    }

    private static func silence(_ seconds: Int) -> [Float] {
        Array(repeating: 0, count: seconds * rate)
    }
}
#endif
