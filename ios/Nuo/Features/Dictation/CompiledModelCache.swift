import Foundation

/// CoreML keeps the Neural Engine build of every model it loads in Caches, keyed by the app build: each new
/// install compiles the dictation models again and the copies of earlier builds are never evicted.
enum CompiledModelCache {
    static let folderName = "com.apple.e5rt.e5bundlecache"
    static let buildKey = "nuo.dictation.compiledCacheBuild"

    /// Deletes the compiled copies once per build, before any model loads; the next load compiles again.
    @discardableResult
    static func purgeIfBuildChanged(
        caches: URL = defaultFolder,
        build: String = currentBuild,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.string(forKey: buildKey) != build else { return false }
        defaults.set(build, forKey: buildKey)
        let folder = caches.appending(path: folderName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        do {
            try FileManager.default.removeItem(at: folder)
            return true
        } catch {
            NSLog("Nuo dictation: compiled model cache not purged — %@", String(describing: error))
            return false
        }
    }

    static var defaultFolder: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "", directoryHint: .isDirectory)
    }

    /// Development installs keep the same CFBundleVersion, so the executable's date tells builds apart.
    static var currentBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let date = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return "\(version)-\(Int(date?.timeIntervalSince1970 ?? 0))"
    }
}
