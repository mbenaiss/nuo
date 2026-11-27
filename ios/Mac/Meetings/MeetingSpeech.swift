import Foundation

/// Prepares a chunk of a 16 kHz mono recording for Whisper: finds the voice, drops the silences in between and evens
/// out the level. Whisper invents sentences in long silences (the « Eux » stream is silent whenever the user talks)
/// and mishears a voice far below the level it was trained on.
enum MeetingSpeech {
    static let sampleRate = 16_000
    /// 100 ms.
    static let frame = 1_600

    /// RMS of each 100 ms frame.
    static func energy(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: frame).map { rms(samples[$0..<min(samples.count, $0 + frame)]) }
    }

    /// Above the noise floor of the chunk and above near-silence, but low enough to keep a quiet voice when the chunk
    /// is mostly speech.
    static func threshold(_ energy: [Float]) -> Float {
        let sorted = energy.sorted()
        let floor = sorted.isEmpty ? 0 : sorted[sorted.count / 10]
        return max(0.003, min(floor * 3, 0.015))
    }

    /// Frame ranges with voice: runs of at least `minimum` loud frames, joined across pauses shorter than `bridge` and
    /// widened by `padding` so the first and last syllables are kept.
    static func regions(_ energy: [Float], threshold: Float, minimum: Int = 2, bridge: Int = 8, padding: Int = 3) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var index = 0
        while index < energy.count {
            guard energy[index] > threshold else { index += 1; continue }
            let start = index
            while index < energy.count, energy[index] > threshold { index += 1 }
            if index - start >= minimum { runs.append(start..<index) }
        }
        var merged: [Range<Int>] = []
        for run in runs {
            let padded = max(0, run.lowerBound - padding)..<min(energy.count, run.upperBound + padding)
            if let last = merged.last, padded.lowerBound - last.upperBound < bridge {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, padded.upperBound)
            } else {
                merged.append(padded)
            }
        }
        return merged
    }

    /// The voiced parts of a chunk end to end, with a short pause between them, and where each came from.
    struct Compacted: Equatable {
        struct Piece: Equatable {
            /// Sample index in the compacted audio.
            var at: Int
            /// Sample index in the original chunk.
            var source: Int
            var count: Int
        }

        var samples: [Float]
        var pieces: [Piece]

        var seconds: Double { Double(samples.count) / Double(MeetingSpeech.sampleRate) }

        /// Seconds into the original chunk of a moment of the compacted audio.
        /// Kept within the audio that was sent: a time a service gives past its end (or absurdly large) maps to its last sample.
        func sourceTime(_ seconds: Double) -> Double {
            let sent = pieces.last.map { $0.at + $0.count } ?? samples.count
            let clamped = seconds.isFinite ? min(max(seconds, 0), Double(sent) / Double(MeetingSpeech.sampleRate)) : 0
            let sample = Int(clamped * Double(MeetingSpeech.sampleRate))
            // The last piece starting at or before `sample`, found by halving: a long meeting has thousands.
            var low = 0, high = pieces.count
            while low < high {
                let middle = (low + high) / 2
                if pieces[middle].at <= sample { low = middle + 1 } else { high = middle }
            }
            guard let piece = low > 0 ? pieces[low - 1] : pieces.first else { return clamped }
            let inside = min(max(sample - piece.at, 0), piece.count)
            return Double(piece.source + inside) / Double(MeetingSpeech.sampleRate)
        }
    }

    /// The voice of one block of a long stream, ready to follow what was kept of the blocks before it: the samples to
    /// append and their pieces, in samples of the whole stream. A region running on from the previous block follows it
    /// without a pause, so no word is cut in two.
    static func voiced(_ block: [Float], blockStart: Int, keptSoFar: Int, previous: Compacted.Piece?, gap: Int = 4_800) -> Compacted {
        let energy = energy(block)
        let regions = regions(energy, threshold: threshold(energy))
        var output: [Float] = []
        var pieces: [Compacted.Piece] = []
        var last = previous
        for region in regions {
            let start = min(region.lowerBound * frame, block.count)
            let end = min(region.upperBound * frame, block.count)
            guard end > start else { continue }
            let source = blockStart + start
            let continues = last.map { $0.source + $0.count == source } ?? false
            if !continues, keptSoFar + output.count > 0 { output.append(contentsOf: repeatElement(0, count: gap)) }
            let piece = Compacted.Piece(at: keptSoFar + output.count, source: source, count: end - start)
            pieces.append(piece)
            output.append(contentsOf: normalized(Array(block[start..<end])))
            last = piece
        }
        return Compacted(samples: output, pieces: pieces)
    }

    /// Seconds into the sent audio where it jumps over a removed silence. A piece that only carries on from the previous
    /// block is no jump.
    static func breaks(_ map: Compacted) -> [Double] {
        zip(map.pieces, map.pieces.dropFirst()).compactMap { previous, piece in
            piece.at > previous.at + previous.count ? (Double(piece.at) / Double(sampleRate) * 100).rounded() / 100 : nil
        }
    }

    static func compact(_ samples: [Float], regions: [Range<Int>], gap: Int = 4_800) -> Compacted {
        var output: [Float] = []
        var pieces: [Compacted.Piece] = []
        for region in regions {
            let start = min(region.lowerBound * frame, samples.count)
            let end = min(region.upperBound * frame, samples.count)
            guard end > start else { continue }
            if !output.isEmpty { output.append(contentsOf: repeatElement(0, count: gap)) }
            pieces.append(.init(at: output.count, source: start, count: end - start))
            output.append(contentsOf: samples[start..<end])
        }
        return Compacted(samples: output, pieces: pieces)
    }

    /// Brings the voice to about -22 dBFS without clipping: the system audio follows the Mac's volume and a mic far
    /// from the mouth is faint.
    static func normalized(_ samples: [Float], target: Float = 0.08) -> [Float] {
        let level = rms(samples[...])
        guard level > 0 else { return samples }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let gain = min(max(min(target / level, 0.95 / peak), 0.25), 8)
        guard abs(gain - 1) > 0.05 else { return samples }
        return samples.map { $0 * gain }
    }

    /// Frame where a chunk should end: the middle of the last pause of at least `pause` frames that starts after
    /// `minimum`, so no word is cut in two. Nil while the speaker has not paused yet.
    static func cut(_ energy: [Float], threshold: Float, after minimum: Int, pause: Int = 6) -> Int? {
        var best: Int?
        var index = minimum
        while index < energy.count {
            guard energy[index] <= threshold else { index += 1; continue }
            let start = index
            while index < energy.count, energy[index] <= threshold { index += 1 }
            // A pause that runs to the end may be cut short by the next word: it does not count yet.
            if index - start >= pause, index < energy.count { best = start + (index - start) / 2 }
        }
        return best
    }

    /// The quietest frame of `range`, where to end a chunk when nobody pauses.
    static func quietest(_ energy: [Float], in range: Range<Int>) -> Int {
        let range = max(0, range.lowerBound)..<min(energy.count, range.upperBound)
        return range.min { energy[$0] < energy[$1] } ?? range.upperBound
    }

    static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for value in slice { sum += value * value }
        return sqrt(sum / Float(slice.count))
    }
}
