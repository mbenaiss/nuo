import Foundation
import Network
import Observation
@preconcurrency import WhisperKit

/// Whisper variants offered for dictation, both supported by WhisperKit on A17 Pro and later and on every Apple silicon Mac.
enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case small, turbo

    var id: String { rawValue }

    /// Folder name in argmaxinc/whisperkit-coreml.
    var variant: String {
        switch self {
        case .small: "openai_whisper-small"
        // large-v3-turbo (OpenAI's v20240930 release), palettized by Argmax to 626 MB.
        case .turbo: "openai_whisper-large-v3-v20240930_626MB"
        }
    }

    var title: String {
        switch self {
        case .small: String(localized: "Fast")
        case .turbo: String(localized: "Accurate")
        }
    }

    var detail: String {
        switch self {
        case .small: "Whisper Small"
        case .turbo: "Whisper Large v3 Turbo"
        }
    }

    var downloadBytes: Int64 {
        switch self {
        case .small: 486_000_000
        case .turbo: 627_000_000
        }
    }
}

enum DictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto, french, english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: String(localized: "Auto (French first)")
        case .french: String(localized: "French")
        case .english: String(localized: "English")
        }
    }

    var whisperCode: String? {
        switch self {
        case .auto: nil
        case .french: "fr"
        case .english: "en"
        }
    }

    var appleLocale: Locale { Locale(identifier: self == .english ? "en-US" : "fr-FR") }
}

/// Downloads, prepares and deletes the Whisper models (Application Support, never bundled nor backed up).
@MainActor
@Observable
final class DictationModelStore {
    static let shared = DictationModelStore()

    enum State: Equatable {
        case absent
        case downloading(Double)
        /// First load: fetches the tokenizer and compiles the model for the Neural Engine.
        case preparing
        case ready
        case failed(String)
    }

    var selected: WhisperModel {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: Keys.model) }
    }
    var language: DictationLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Keys.language) }
    }
    /// The gateway's transcription service first when it has one; off, the voice never leaves the device.
    var useCloud: Bool {
        didSet { UserDefaults.standard.set(useCloud, forKey: Keys.cloud) }
    }
    private(set) var states: [WhisperModel: State] = [:]
    private(set) var bytesOnDisk: [WhisperModel: Int64] = [:]
    /// Models plus tokenizers.
    private(set) var totalBytes: Int64 = 0
    private(set) var isExpensiveNetwork = false

    let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
    @ObservationIgnored private var tasks: [WhisperModel: Task<Void, Never>] = [:]
    @ObservationIgnored private let monitor = NWPathMonitor()

    private enum Keys {
        static let model = AppIdentity.local(.dictationModel)
        static let language = AppIdentity.local(.dictationLanguage)
        static let cloud = AppIdentity.local(.dictationCloud)
        static let ready = AppIdentity.local(.dictationReady)
    }

    nonisolated static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Dictation", directoryHint: .isDirectory)
    }

    private init() {
        let defaults = UserDefaults.standard
        selected = WhisperModel(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .turbo
        language = DictationLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .auto
        useCloud = defaults.object(forKey: Keys.cloud) as? Bool ?? true
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.isExpensiveNetwork = expensive }
        }
        monitor.start(queue: DispatchQueue(label: AppIdentity.local(.dictationNetworkQueue)))
        refresh()
    }

    func state(_ model: WhisperModel) -> State { states[model] ?? .absent }


    /// Folder of a model ready to load, nil while it is missing or still downloading.
    func readyFolder(_ model: WhisperModel) -> URL? {
        guard state(model) == .ready else { return nil }
        let folder = Self.folder(model)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    func refresh() {
        if isDemo {
            states = [.turbo: .ready, .small: .absent]
            bytesOnDisk = [.turbo: 632_000_000]
            totalBytes = 634_000_000
            return
        }
        let ready = Set(UserDefaults.standard.stringArray(forKey: Keys.ready) ?? [])
        for model in WhisperModel.allCases {
            let folder = Self.folder(model)
            let exists = FileManager.default.fileExists(atPath: folder.path)
            bytesOnDisk[model] = exists ? Self.size(of: folder) : 0
            if tasks[model] != nil { continue }
            states[model] = exists && ready.contains(model.rawValue) ? .ready : .absent
        }
        totalBytes = FileManager.default.fileExists(atPath: Self.root.path) ? Self.size(of: Self.root) : 0
    }

    /// Starts a download unless one is running; `quiet` skips it on cellular or low storage (first-use path).
    @discardableResult
    func download(_ model: WhisperModel, quiet: Bool = false) -> Bool {
        guard !isDemo, tasks[model] == nil, state(model) != .ready else { return false }
        if let problem = storageProblem(for: model) {
            if !quiet { states[model] = .failed(problem) }
            return false
        }
        if quiet, isExpensiveNetwork { return false }
        states[model] = .downloading(0)
        tasks[model] = Task { [weak self] in
            await self?.run(model)
        }
        return true
    }

    /// The selected model, in the background, while none is on the device yet.
    func downloadIfMissing() {
        guard WhisperModel.allCases.allSatisfy({ readyFolder($0) == nil }) else { return }
        download(selected, quiet: true)
    }

    func cancel(_ model: WhisperModel) {
        tasks[model]?.cancel()
    }

    func delete(_ model: WhisperModel) {
        cancel(model)
        Task {
            await WhisperEngine.shared.unload(ifUsing: model)
            try? FileManager.default.removeItem(at: Self.folder(model))
            markReady(model, false)
            refresh()
        }
    }

    private func run(_ model: WhisperModel) async {
        defer { tasks[model] = nil }
        do {
            let base = Self.root
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var root = base
            try? root.setResourceValues(values)

            let folder = try await WhisperKit.download(variant: model.variant, downloadBase: base) { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state(model) else { return }
                    self.states[model] = .downloading(fraction)
                }
            }
            try Task.checkCancellation()
            states[model] = .preparing
            try await WhisperEngine.shared.load(model, folder: folder, tokenizerBase: base)
            markReady(model, true)
            states[model] = .ready
        } catch is CancellationError {
            states[model] = .absent
        } catch {
            dictationLog.error("model \(model.variant, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            states[model] = .failed(Self.describe(error))
        }
        refresh()
    }

    func markReady(_ model: WhisperModel, _ ready: Bool) {
        var set = Set(UserDefaults.standard.stringArray(forKey: Keys.ready) ?? [])
        if ready { set.insert(model.rawValue) } else { set.remove(model.rawValue) }
        UserDefaults.standard.set(Array(set), forKey: Keys.ready)
    }

    private func storageProblem(for model: WhisperModel) -> String? {
        let values = try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        // Room for the download plus the compiled copy CoreML keeps, and some margin for the system.
        let needed = model.downloadBytes * 2 + 500_000_000
        guard available < needed else { return nil }
        let formatter = ByteCountFormatter()
        return String(localized: "Not enough space: \(formatter.string(fromByteCount: needed)) free is needed.")
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .notConnectedToInternet ? String(localized: "No Internet connection.") : String(localized: "Download interrupted. Try again.")
        }
        return String(localized: "The model could not be prepared. Try again.")
    }

    nonisolated static func folder(_ model: WhisperModel) -> URL {
        root.appending(path: "models/argmaxinc/whisperkit-coreml/\(model.variant)", directoryHint: .isDirectory)
    }

    nonisolated private static func size(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

extension DictationModelStore.State {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return self == .preparing
    }
}
