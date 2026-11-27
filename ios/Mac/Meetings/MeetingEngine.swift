import Foundation

/// What transcribes the meeting. Whisper is the most accurate and spells the names it is given, but needs a 630 MB
/// model and about 500 MB of memory; Apple's recognizer ships with macOS and runs in a system service of about 110 MB,
/// in a language chosen beforehand.
enum MeetingEngine: String, CaseIterable, Identifiable, Sendable {
    case whisper, apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisper: String(localized: "Whisper · accurate")
        case .apple: String(localized: "Apple · light")
        }
    }

    var detail: String {
        switch self {
        case .whisper: String(localized: "The most accurate, spells participants' names correctly and detects the language. 630 MB model, about 500 MB of memory.")
        case .apple: String(localized: "Included in macOS, nothing to download, about 110 MB of memory. Slightly less accurate on proper names.")
        }
    }

    /// Apple's transcript can be redone with Whisper, so its recording is kept until the next meeting.
    var keepsAudio: Bool { self == .apple }

    var name: String {
        switch self {
        case .whisper: "Whisper"
        case .apple: "Apple"
        }
    }
}

/// How the cloud transcription tells the others apart, from the attendees of the event.
enum MeetingVoices {
    /// The attendee list may or may not hold the user: its size is a safe ceiling for the voices on the others' side.
    /// A single other attendee needs no diarization; an unknown list lets the service count.
    static func plan(participants: String) -> (diarize: Bool, max: Int?) {
        let count = participants.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        switch count {
        case 0: return (true, nil)
        case 1: return (false, nil)
        default: return (true, min(count, 32))
        }
    }

    /// The service answered: a stream with no line (the mic heard only typing) is taken as it is. Only when no stream
    /// gave a line although one of them sent several seconds of voice is its answer worth nothing, and the Mac does it all.
    static func allEmpty(_ streams: [(sentSeconds: Double, segments: Int)]) -> Bool {
        streams.allSatisfy { $0.segments == 0 } && streams.contains { $0.sentSeconds >= 8 }
    }

    /// Attendee names and the meeting's title, to spell right.
    static func terms(title: String, participants: String) -> [String] {
        let names = participants.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return ([title.trimmingCharacters(in: .whitespaces)] + names).filter { !$0.isEmpty }
    }
}

/// One stream's job failed on the gateway (the provider refused it): only that stream is sent again, under a new id.
struct MeetingStreamFailed: Error, Equatable {
    let speaker: MeetingSpeaker
    let status: Int
    let message: String
}

/// The gateway has no transcription service: asking it again is pointless.
struct MeetingNoTranscriptionService: Error {}

/// Which of the gateway's jobs an error from the cloud's side of a meeting costs. Only a job's own failure, or a
/// gateway without a service, stops jobs there; a cancel (« Réessayer »), a silence or a file the Mac could not read
/// leaves them, maybe already done, to be found again.
enum MeetingCloudLoss: Equatable {
    case none
    case stream(MeetingSpeaker)
    case all

    static func of(_ error: Error) -> MeetingCloudLoss {
        if let failed = error as? MeetingStreamFailed { return .stream(failed.speaker) }
        if error is MeetingNoTranscriptionService { return .all }
        return .none
    }
}

/// What the recording kept after a meeting allows, given where its transcript and note stand.
struct MeetingRecordingRules: Equatable {
    var kept: Bool
    var engine: MeetingEngine
    var transcribed: Bool
    var noteReady: Bool
    var retranscribing: Bool

    var canRetranscribe: Bool { kept && transcribed && engine == .apple && !retranscribing }
    /// Once the bot has written the note from the transcript, the recording is no longer needed.
    var canDelete: Bool { kept && noteReady && !retranscribing }
}

/// Language the meeting is transcribed in. « Auto » detects it on the first sentences with Whisper; choosing it avoids
/// a wrong guess on a short or noisy start.
enum MeetingLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto, french, english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: String(localized: "Auto language")
        case .french: String(localized: "French")
        case .english: String(localized: "English")
        }
    }

    var code: String? {
        switch self {
        case .auto: nil
        case .french: "fr"
        case .english: "en"
        }
    }

    /// Apple's recognizer cannot detect the language: « Auto » uses `fallback`, the dictation language.
    func appleLocale(fallback: String) -> Locale {
        switch code ?? fallback {
        case "en": Locale(identifier: "en-US")
        case "fr": Locale(identifier: "fr-FR")
        case let other: Locale(identifier: other)
        }
    }

    /// « French » for `fr`, in the language of the app.
    static func name(of code: String, locale: Locale = .current) -> String {
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
