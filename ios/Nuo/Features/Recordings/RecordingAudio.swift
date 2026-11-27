@preconcurrency import AVFoundation
import Foundation

/// Where the iPhone keeps what the watch sends, until it is transcribed. Usable from WatchConnectivity's queue: the
/// received file has to be moved before its callback returns.
enum RecordingInbox {
    static var root: URL { folder("Recordings") }
    static var asksFolder: URL { folder("WatchAsks") }

    static func folder(recording id: String) -> URL {
        let url = root.appending(path: id, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum Stored: Equatable {
        case stored(String)
        /// A copy of a piece already here, or of a recording already put together: dropped, never written over a
        /// file that may be being read.
        case duplicate
        case rejected
    }

    static let assembledMark = "assembled"

    /// Moves a received segment in place.
    static func store(segment: URL, recordingId: String, index: Int) -> Stored {
        guard UUID(uuidString: recordingId) != nil, index >= 0 else { return .rejected }
        let folder = folder(recording: recordingId)
        let name = RecordingJournal.fileName(index: index)
        let target = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: target.path) || FileManager.default.fileExists(atPath: folder.appending(path: assembledMark).path) {
            return .duplicate
        }
        do {
            try FileManager.default.moveItem(at: segment, to: target)
            return .stored(name)
        } catch {
            return FileManager.default.fileExists(atPath: target.path) ? .duplicate : .rejected
        }
    }

    private static func folder(_ name: String) -> URL {
        let url = URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The watch's 30 s pieces joined into the one file the gateway transcribes. They are decoded and encoded again rather
/// than joined as they are: each AAC file starts with its encoder's priming, and joining them raw would shift every
/// later marker by a fraction of a second per piece, a dozen seconds over an hour.
enum RecordingAudio {
    static let fileName = "audio.m4a"

    /// A place in the recording: the piece if it is here, and how long it lasts on the watch's clock.
    struct Slot: Sendable {
        var index: Int
        var url: URL?
        var seconds: TimeInterval
    }

    struct Report: Equatable, Sendable {
        var seconds: TimeInterval
        /// Pieces that never came, replaced by silence so that later markers stay in place.
        var missing: [Int] = []
        /// Pieces that came but could not be read, replaced by silence too.
        var unreadable: [Int] = []
        /// Where those silences are on the recording's clock.
        var gaps: [ClosedRange<TimeInterval>] = []
    }

    /// Written to a temporary file, then moved in place in one step: `url` is either absent or complete.
    static func assembleAtomically(_ slots: [Slot], into url: URL) throws -> Report {
        let partial = url.deletingLastPathComponent().appending(path: "audio.partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        let report = try assemble(slots, into: partial)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: url)
        }
        return report
    }

    static func assembleAtomically(_ segments: [URL], into url: URL) throws -> TimeInterval {
        try assembleAtomically(segments.enumerated().map { Slot(index: $0.offset, url: $0.element, seconds: RecordingJournal.segmentSeconds) }, into: url).seconds
    }

    /// Reads a piece at a time, so an hour never sits in memory. A piece that is missing or unreadable becomes silence
    /// of its length: the recording keeps its clock, and the markers their place.
    static func assemble(_ slots: [Slot], into url: URL) throws -> Report {
        let writer = try AACWriter(url: url)
        var report = Report(seconds: 0)
        for slot in slots {
            let start = Double(writer.samplesWritten) / Double(AACWriter.sampleRate)
            guard let segment = slot.url else {
                try writeSilence(slot.seconds, to: writer)
                report.missing.append(slot.index)
                report.gaps.append(start...(start + slot.seconds))
                continue
            }
            let before = writer.samplesWritten
            do {
                try copy(segment, to: writer)
            } catch {
                // What a damaged piece let through is kept; the rest of its length is silence.
                let written = Double(writer.samplesWritten - before) / Double(AACWriter.sampleRate)
                try writeSilence(max(0, slot.seconds - written), to: writer)
                report.unreadable.append(slot.index)
                report.gaps.append(start...max(start, Double(writer.samplesWritten) / Double(AACWriter.sampleRate)))
            }
        }
        writer.close()
        report.seconds = Double(writer.samplesWritten) / Double(AACWriter.sampleRate)
        return report
    }

    private static func copy(_ segment: URL, to writer: AACWriter) throws {
        let file = try AVAudioFile(forReading: segment)
        let format = file.processingFormat
        guard format.sampleRate == Double(AACWriter.sampleRate), format.channelCount == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let block: AVAudioFrameCount = 160_000
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { break }
            try file.read(into: buffer, frameCount: block)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            try writer.append(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
    }

    private static func writeSilence(_ seconds: TimeInterval, to writer: AACWriter) throws {
        var left = Int(seconds * Double(AACWriter.sampleRate))
        let chunk = [Float](repeating: 0, count: 160_000)
        while left > 0 {
            let count = min(left, chunk.count)
            try writer.append(Array(chunk.prefix(count)))
            left -= count
        }
    }

    /// The files to upload: the assembled audio itself when it fits one job as it is, otherwise one
    /// `audio-part-N.m4a` per part at the plan's rate, cut on the decoded samples so each starts exactly at its offset.
    static func uploads(_ audio: URL, plan: RecordingParts.Plan, folder: URL) throws -> [URL] {
        guard !plan.isDirect else { return [audio] }
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        let rate = format.sampleRate
        return try plan.parts.map { part in
            let url = folder.appending(path: "audio-part-\(part.index).m4a")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let partial = folder.appending(path: "audio-part-\(part.index).partial.m4a")
            try? FileManager.default.removeItem(at: partial)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AACWriter.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: plan.bitRate,
            ]
            let output = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            file.framePosition = AVAudioFramePosition(part.start * rate)
            var left = AVAudioFrameCount(part.duration * rate)
            while left > 0, file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(160_000, left)) else { break }
                try file.read(into: buffer, frameCount: min(160_000, left))
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                left -= buffer.frameLength
            }
            output.close()
            try FileManager.default.moveItem(at: partial, to: url)
            return url
        }
    }

    /// Leftovers of an earlier pass: part files and the saved transcript.
    static func removePasses(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("audio-part-") || name == "transcript.json" {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
