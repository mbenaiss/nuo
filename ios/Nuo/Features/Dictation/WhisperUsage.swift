import Foundation

/// Whether the loaded Whisper model may be dropped, for another model or under memory pressure.
enum WhisperUsage {
    /// A pass running on it, or a long job (a meeting, a dictation) holding it, other than the caller itself.
    static func inUse(busy: Int, holders: Int, callerHolds: Bool) -> Bool {
        busy > 0 || holders - (callerHolds ? 1 : 0) > 0
    }
}
