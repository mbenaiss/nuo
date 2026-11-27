import Foundation
import Testing

struct CompiledModelCacheTests {
    private let caches: URL
    private let defaults: UserDefaults

    init() throws {
        caches = FileManager.default.temporaryDirectory.appending(path: "compiled-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defaults = try #require(UserDefaults(suiteName: "CompiledModelCacheTests-\(UUID().uuidString)"))
    }

    private var folder: URL { caches.appending(path: CompiledModelCache.folderName, directoryHint: .isDirectory) }

    /// Mirrors what CoreML leaves after compiling Whisper Large v3 Turbo for the Neural Engine.
    private func seedCompiledTurboEncoder() throws {
        let entry = folder.appending(path: "24B5110a/7AC3B835C15AD82A6939E8029F8FAEBCD101CE2078694829FB4E46FADC7087CF", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 4096).write(to: entry.appending(path: "AudioEncoder.bundle"))
    }

    @Test func aNewBuildDeletesTheCopiesCompiledByEarlierBuilds() throws {
        defaults.set("214-1792166400", forKey: CompiledModelCache.buildKey)
        try seedCompiledTurboEncoder()

        #expect(CompiledModelCache.purgeIfBuildChanged(caches: caches, build: "215-1792771200", defaults: defaults))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(defaults.string(forKey: CompiledModelCache.buildKey) == "215-1792771200")
    }

    @Test func theSameBuildKeepsItsCompiledCopy() throws {
        defaults.set("215-1792771200", forKey: CompiledModelCache.buildKey)
        try seedCompiledTurboEncoder()

        #expect(!CompiledModelCache.purgeIfBuildChanged(caches: caches, build: "215-1792771200", defaults: defaults))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aFirstLaunchWithoutCacheOnlyRecordsTheBuild() {
        #expect(!CompiledModelCache.purgeIfBuildChanged(caches: caches, build: "215-1792771200", defaults: defaults))
        #expect(defaults.string(forKey: CompiledModelCache.buildKey) == "215-1792771200")
    }
}
