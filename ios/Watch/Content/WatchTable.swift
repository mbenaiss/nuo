import Foundation

/// A markdown table as the watch shows it: one card per row, read without scrolling sideways. Each row leads with its
/// time when a column holds one, then its title cell, then the other cells as labelled lines.
struct WatchTable: Hashable {
    struct Row: Hashable {
        var time: String?
        var title: String
        var lines: [Line]
    }

    struct Line: Hashable {
        var label: String
        var value: String
    }

    static let shownRows = 6

    var rows: [Row]
    /// Rows past `shownRows`, left to the iPhone.
    var hidden: Int

    init(_ table: TablePayload, limit: Int = WatchTable.shownRows) {
        let header = table.header.map(WatchMarkdown.plain)
        let columns = max(header.count, table.rows.map(\.count).max() ?? 0)
        let body = table.rows.map { row in (0..<columns).map { $0 < row.count ? row[$0] : "" } }
        let time = columns > 1 ? Self.timeColumn(header: header, rows: body, columns: columns) : nil
        let title = Self.titleColumn(header: header, rows: body, columns: columns, skipping: time)
        rows = body.prefix(limit).map { cells in
            var lines = (0..<columns).filter { $0 != time && $0 != title && !cells[$0].isEmpty }
                .map { Line(label: $0 < header.count ? header[$0] : "", value: cells[$0]) }
            var heading = cells[title]
            if heading.isEmpty, !lines.isEmpty { heading = lines.removeFirst().value }
            return Row(time: time.flatMap { cells[$0].nilIfEmpty }, title: heading, lines: lines)
        }
        hidden = max(0, body.count - limit)
    }

    var spokenText: String {
        var sentences = rows.map { row in
            ([row.time, row.title].compactMap { $0 } + row.lines.map(\.value)).map(WatchMarkdown.plain).joined(separator: ", ")
        }
        if hidden > 0 { sentences.append(String(localized: "And \(hidden) more rows on the iPhone.")) }
        return sentences.joined(separator: "\n")
    }

    private static let timeHeaders = ["heure", "horaire", "creneau", "quand", "date", "jour", "debut", "time", "when", "start"]
    private static let titleHeaders = ["rendez-vous", "rdv", "titre", "nom", "sujet", "objet", "evenement", "reunion", "tache",
                                       "intitule", "activite", "produit", "article", "title", "name", "event", "task"]

    private static func timeColumn(header: [String], rows: [[String]], columns: Int) -> Int? {
        if let named = (0..<min(columns, header.count)).first(where: { matches(header[$0], timeHeaders) }) { return named }
        return (0..<columns).first { column in
            let cells = rows.map { $0[column] }.filter { !$0.isEmpty }
            return !cells.isEmpty && cells.allSatisfy(looksLikeTime)
        }
    }

    private static func titleColumn(header: [String], rows: [[String]], columns: Int, skipping time: Int?) -> Int {
        let candidates = (0..<columns).filter { $0 != time }
        guard let first = candidates.first else { return 0 }
        if let named = candidates.first(where: { $0 < header.count && matches(header[$0], titleHeaders) }) { return named }
        return candidates.first { column in
            let cells = rows.map { $0[column] }.filter { !$0.isEmpty }
            return cells.filter { $0.contains(where: \.isLetter) }.count * 2 > cells.count
        } ?? first
    }

    private static func matches(_ header: String, _ words: [String]) -> Bool {
        let folded = header.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        return words.contains { folded == $0 || folded.hasPrefix($0 + " ") }
    }

    private static func looksLikeTime(_ cell: String) -> Bool {
        cell.contains(#/\b\d{1,2}[:h]\d{2}\b/#) || cell.contains(#/\b\d{4}-\d{2}-\d{2}\b/#) || cell.contains(#/^\d{1,2}/\d{1,2}/#)
    }
}
