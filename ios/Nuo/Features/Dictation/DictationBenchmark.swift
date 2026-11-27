#if DEBUG || DICTATION_BENCHMARK
import AVFoundation
import Foundation
@preconcurrency import Speech
@preconcurrency import WhisperKit
#if canImport(UIKit)
import UIKit
#endif

/// `-dictationBenchmark`: times load and transcription of the bundled French samples with every engine and prints
/// text, WER and memory, for runs on a device with `devicectl process launch --console`. Debug builds, or a test
/// build with the DICTATION_BENCHMARK flag; the samples are left out of Release builds.
enum DictationBenchmark {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-dictationBenchmark") }
    @MainActor private static var started = false

    static let references = [
        "dictation-bench-10s": "Bonjour Coach, peux-tu me préparer une séance de course à pied pour jeudi matin ? Rappelle aussi à Alex d'envoyer le devis au client de Lyon avant vendredi dix-huit heures.",
        "dictation-bench-60s": "Bonjour Coach, j'aimerais organiser ma semaine d'entraînement avant le semi-marathon de Lyon. Lundi je fais une sortie facile d'une heure, mardi du fractionné sur piste avec des répétitions de quatre cents mètres. Mercredi c'est repos, mais je voudrais quand même faire des étirements et un peu de gainage le soir. Jeudi matin, rappelle-moi d'appeler Alex pour le devis du client de Marseille, c'est important. Vendredi je travaille depuis la maison, donc je peux courir à midi le long du canal. Le week-end, je pars chez mes parents en Bretagne, alors prévois une sortie longue samedi matin avant le départ du train. Enfin, ajoute à ma liste de courses des pâtes complètes, des bananes, du fromage blanc et des amandes. Merci, et envoie-moi un résumé clair que je pourrai relire ce soir.",
    ]

    @MainActor static func runOnce() {
        guard isOn, !started else { return }
        started = true
        #if canImport(UIKit)
        // Auto-lock suspends the app mid-run and the timings become meaningless.
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        Task.detached(priority: .userInitiated) { await run() }
    }

    private static func log(_ line: String) {
        print("BENCH \(line)")
        fflush(stdout)
    }

    private static func run() async {
        #if DEBUG
        log("build Debug")
        #else
        log("build Release")
        #endif
        let files = ["dictation-bench-10s", "dictation-bench-60s"].compactMap { name -> (String, URL, [Float])? in
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let samples = try? AudioProcessor.loadAudioAsFloatArray(fromPath: url.path) else {
                log("missing \(name)")
                return nil
            }
            return (name, url, samples)
        }
        let prompt = "Alex, Coach, Voyages."
        log("device \(WhisperKit.deviceName()) footprint \(footprintMB()) MB")
        let root = DictationModelStore.root

        await benchApple(files)

        for model in [WhisperModel.small, .turbo] {
            let folder = DictationModelStore.folder(model)
            if !FileManager.default.fileExists(atPath: folder.path) {
                let clock = ContinuousClock.now
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    _ = try await WhisperKit.download(variant: model.variant, downloadBase: root)
                } catch {
                    log("\(model.rawValue) download failed: \(error)")
                    continue
                }
                log("\(model.rawValue) downloaded in \(seconds(since: clock)) s")
            }
            await WhisperEngine.shared.unload(ifUsing: .small)
            await WhisperEngine.shared.unload(ifUsing: .turbo)
            let before = footprintMB()
            let loadClock = ContinuousClock.now
            do {
                try await WhisperEngine.shared.load(model, folder: folder)
            } catch {
                log("\(model.rawValue) load failed: \(error)")
                continue
            }
            log("\(model.rawValue) load \(seconds(since: loadClock)) s, +\(footprintMB() - before) MB, \(await WhisperEngine.shared.computeDescription)")
            await MainActor.run { DictationModelStore.shared.markReady(model, true) }
            for (name, _, samples) in files {
                for run in 1...2 {
                    let clock = ContinuousClock.now
                    let text = (try? await WhisperEngine.shared.transcribe(samples, language: "fr", prompt: prompt).text) ?? "<failed>"
                    report(model.rawValue, name, samples, run, seconds(since: clock), text)
                }
            }
            log("\(model.rawValue) peak footprint \(footprintMB()) MB")
        }
        await WhisperEngine.shared.unload(ifUsing: .turbo)
        log("DONE")
    }

    /// Apple's SpeechTranscriber over the file, as fast as it can read it.
    private static func benchApple(_ files: [(String, URL, [Float])]) async {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
            log("apple: French unsupported")
            return
        }
        for (name, url, samples) in files {
            for run in 1...2 {
                do {
                    let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        try await request.downloadAndInstall()
                    }
                    let clock = ContinuousClock.now
                    let analyzer = SpeechAnalyzer(modules: [module])
                    let results = module.results
                    let collector = Task {
                        var text = ""
                        for try await result in results { text += String(result.text.characters) }
                        return text
                    }
                    let file = try AVAudioFile(forReading: url)
                    if let last = try await analyzer.analyzeSequence(from: file) {
                        try await analyzer.finalizeAndFinish(through: last)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                    let text = try await collector.value
                    report("apple", name, samples, run, seconds(since: clock), text)
                } catch {
                    log("apple \(name) failed: \(error)")
                }
            }
        }
    }

    private static func report(_ engine: String, _ name: String, _ samples: [Float], _ run: Int, _ time: String, _ text: String) {
        let duration = String(format: "%.1f", Double(samples.count) / Double(WhisperEngine.sampleRate))
        let wer = references[name].map { String(format: "%.1f", errorRate($0, text) * 100) } ?? "?"
        log("\(engine) \(name) (\(duration) s) run \(run): \(time) s WER \(wer) % — \(text)")
    }

    private static func words(_ text: String) -> [String] {
        let mapped = text.lowercased().replacingOccurrences(of: "’", with: "'").map { ($0.isLetter || $0.isNumber) ? $0 : " " }
        return String(mapped).split(separator: " ").map(String.init)
    }

    static func errorRate(_ reference: String, _ hypothesis: String) -> Double {
        let ref = words(reference), hyp = words(hypothesis)
        guard !ref.isEmpty else { return 0 }
        var previous = Array(0...hyp.count)
        for i in 1...ref.count {
            var current = [i] + Array(repeating: 0, count: hyp.count)
            for j in stride(from: 1, through: hyp.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        return String(format: "%.2f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}
#endif
