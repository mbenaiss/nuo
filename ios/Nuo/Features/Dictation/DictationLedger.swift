import Foundation

enum DictationPhase: Equatable, Sendable { case idle, starting, listening, finishing }

/// Which dictation owns the mic and may write into a field. Every start and every cancel takes a new ticket; work that
/// resumes after an await checks its ticket first, so a late transcription never lands in a dictation that was
/// cancelled or replaced meanwhile.
struct DictationLedger: Equatable, Sendable {
    private(set) var phase: DictationPhase = .idle
    private(set) var key: String?
    private(set) var ticket = 0

    enum StartStep: Equatable {
        /// This field is already dictating.
        case already
        case start
        /// Another field is listening (or about to): end it first, its text goes into its own field.
        case stopOther
        /// Another field's recording is being transcribed: its text lands first, then this one starts.
        case waitForOther
    }

    func step(for key: String) -> StartStep {
        switch phase {
        case .idle: .start
        case _ where self.key == key: .already
        case .starting, .listening: .stopOther
        case .finishing: .waitForOther
        }
    }

    mutating func begin(_ key: String) -> Int {
        ticket += 1
        phase = .starting
        self.key = key
        return ticket
    }

    /// The mic is on; false when this start was cancelled or replaced meanwhile.
    mutating func listen(_ ticket: Int) -> Bool {
        guard owns(ticket, in: .starting) else { return false }
        phase = .listening
        return true
    }

    /// The ticket whose recording is now transcribed; nil when nothing was listening.
    mutating func finish() -> Int? {
        guard phase == .listening else { return nil }
        phase = .finishing
        return ticket
    }

    func owns(_ ticket: Int, in phase: DictationPhase) -> Bool { ticket == self.ticket && self.phase == phase }

    /// Drops whatever is under way: anything still holding the old ticket finds it stale.
    mutating func cancel() {
        ticket += 1
        phase = .idle
        key = nil
    }

    /// The transcription of `ticket` is done; false when it no longer owns the dictation, and must not write.
    mutating func end(_ ticket: Int) -> Bool {
        guard owns(ticket, in: .finishing) else { return false }
        phase = .idle
        key = nil
        return true
    }

    /// The text lands after what the field holds now, so what was typed while the voice was transcribed stays.
    static func compose(_ current: String, _ text: String) -> String {
        guard !text.isEmpty else { return current }
        guard let last = current.last else { return text }
        return last.isWhitespace ? current + text : current + " " + text
    }
}

/// The field a dictation writes into, read again when the text lands.
struct DictationField {
    let read: @MainActor () -> String
    let write: @MainActor (String) -> Void
}
