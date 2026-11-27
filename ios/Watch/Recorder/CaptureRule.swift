import Foundation

/// The watch's one button: what is said in under a minute is a request to the general bot, past the minute the
/// capture goes on as a recorded meeting.
enum CaptureRule {
    /// Past this, the capture is a recording.
    static let requestLimit: TimeInterval = RecordingJournal.firstSegmentSeconds
    /// Shorter than this, a tap by mistake: nothing leaves.
    static let shortestRequest: TimeInterval = 0.6
    /// The first piece is encoded like a request (AAC at 32 kbit/s), so a short one fits in a live message.
    static let requestBitRate = 32_000

    enum Ending: Equatable {
        case discard
        case request
        case recording
    }

    /// What a stop (the button, a double tap, a call taking the microphone) makes of the capture.
    static func ending(seconds: TimeInterval, tentative: Bool) -> Ending {
        guard tentative else { return .recording }
        return seconds >= shortestRequest ? .request : .discard
    }

    static func becomesRecording(seconds: TimeInterval) -> Bool { seconds >= requestLimit }

    static func bitRate(ofSegment index: Int) -> Int { index == 0 ? requestBitRate : AACWriter.bitRate }
}
