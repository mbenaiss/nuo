import Foundation

/// Line-based three-way merge: both sides' changes apply when they touch different lines of the base.
enum DocMerge {
    private struct Hunk {
        var start: Int
        var end: Int
        var lines: [Substring]
    }

    static func merge(base: String, mine: String, theirs: String) -> String? {
        if mine == base { return theirs }
        if theirs == base || theirs == mine { return mine }
        let b = base.split(separator: "\n", omittingEmptySubsequences: false)
        let m = hunks(b, mine.split(separator: "\n", omittingEmptySubsequences: false))
        let t = hunks(b, theirs.split(separator: "\n", omittingEmptySubsequences: false))
        for x in m {
            for y in t where overlaps(x, y) && !(x.start == y.start && x.end == y.end && x.lines == y.lines) {
                return nil
            }
        }
        var all = m
        for y in t where !m.contains(where: { $0.start == y.start && $0.end == y.end && $0.lines == y.lines }) { all.append(y) }
        all.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var out: [Substring] = []
        var index = 0
        for hunk in all {
            out += b[index..<hunk.start]
            out += hunk.lines
            index = hunk.end
        }
        out += b[index...]
        return out.joined(separator: "\n")
    }

    private static func overlaps(_ a: Hunk, _ b: Hunk) -> Bool {
        if a.start == a.end || b.start == b.end { return a.start <= b.end && b.start <= a.end }
        return a.start < b.end && b.start < a.end
    }

    private static func hunks(_ base: [Substring], _ other: [Substring]) -> [Hunk] {
        let diff = other.difference(from: base)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Hunk] = []
        var i = 0, j = 0
        while i < base.count || j < other.count {
            if i < base.count, j < other.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
                continue
            }
            var hunk = Hunk(start: i, end: i, lines: [])
            while (i < base.count && removed.contains(i)) || (j < other.count && inserted.contains(j)) {
                if i < base.count, removed.contains(i) { i += 1 }
                if j < other.count, inserted.contains(j) {
                    hunk.lines.append(other[j])
                    j += 1
                }
            }
            hunk.end = i
            if hunk.start == hunk.end && hunk.lines.isEmpty { break }
            result.append(hunk)
        }
        return result
    }
}
