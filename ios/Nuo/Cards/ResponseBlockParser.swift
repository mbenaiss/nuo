import Foundation

/// Splits assistant text into card markers (`::kind {json}`, possibly spanning lines) and plain lines.
enum CardMarkup {
    struct Segment {
        let text: String
        let name: String?
    }

    /// Lines a JSON marker may span: past this, its brace is taken as never closing.
    static let maxMarkerLines = 200

    /// While `streaming`, a JSON marker still open at the end of the text takes the remaining lines (its JSON is still
    /// coming); otherwise an unclosed marker is only its own line, so the rest of the answer stays readable.
    static func segments(in text: String, streaming: Bool = false) -> [Segment] {
        let lines = text.components(separatedBy: "\n")
        var result: [Segment] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                let start = index
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    index += 1
                }
                let fence = Segment(text: lines[start..<min(index + 1, lines.count)].joined(separator: "\n"), name: nil)
                // Models sometimes wrap card markers in a code fence; unwrap when the fence holds only cards.
                guard index < lines.count, lines[(start + 1)..<index].contains(where: { $0.contains("::") }) else {
                    result.append(fence)
                    index += 1
                    continue
                }
                let inner = segments(in: lines[(start + 1)..<index].joined(separator: "\n"))
                if inner.contains(where: { $0.name != nil }),
                   inner.allSatisfy({ $0.name != nil || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    result.append(contentsOf: inner)
                } else {
                    result.append(fence)
                }
                index += 1
                continue
            }
            guard line.hasPrefix("::") else {
                result.append(Segment(text: lines[index], name: nil))
                index += 1
                continue
            }
            let name = String(line.dropFirst(2).prefix { !$0.isWhitespace && $0 != "{" && $0 != ":" }).lowercased()
            var marker = line
            var next = index + 1
            while next < lines.count, next - index < maxMarkerLines {
                let following = lines[next].trimmingCharacters(in: .whitespaces)
                guard (opensJSON(marker) && jsonDepth(marker) > 0) || (marker.lowercased() == "::" + name && following.hasPrefix("{")) else { break }
                marker += "\n" + following
                next += 1
            }
            if opensJSON(marker), jsonDepth(marker) > 0, !streaming || next < lines.count {
                marker = line
                next = index + 1
            }
            result.append(Segment(text: marker, name: name))
            index = next
        }
        return result
    }

    /// `::name {` (or `::name` then `{` on the next line): the marker carries JSON, not a one-line shorthand.
    private static func opensJSON(_ marker: String) -> Bool {
        marker.dropFirst(2).drop { !$0.isWhitespace && $0 != "{" && $0 != ":" }
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    static func jsonDepth(_ text: String) -> Int {
        var depth = 0
        var quoted = false
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if quoted, character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            guard !quoted else { continue }
            if character == "{" || character == "[" { depth += 1 }
            if character == "}" || character == "]" { depth -= 1 }
        }
        return depth
    }
}

private final class ParsedBlocksBox {
    let blocks: [ResponseBlock]
    init(_ blocks: [ResponseBlock]) { self.blocks = blocks }
}

enum ResponseBlockParser {
    // NSCache is thread-safe; message text is immutable, so memoising by content is sound.
    nonisolated(unsafe) private static let cache: NSCache<NSString, ParsedBlocksBox> = {
        let cache = NSCache<NSString, ParsedBlocksBox>()
        cache.countLimit = 256
        return cache
    }()

    /// A `streaming` text is the answer still arriving: each delta is a new string, so it is not cached, and its last
    /// card marker may be incomplete, so it is hidden rather than shown as text.
    static func parse(_ text: String, streaming: Bool = false) -> [ResponseBlock] {
        guard !streaming else { return computeBlocks(text, streaming: true) }
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let blocks = computeBlocks(text, streaming: false)
        cache.setObject(ParsedBlocksBox(blocks), forKey: key)
        return blocks
    }

    /// Text without card markers, for the clipboard and previews.
    static func plainText(_ text: String) -> String {
        CardMarkup.segments(in: text).filter { $0.name == nil }.map(\.text)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func computeBlocks(_ text: String, streaming: Bool) -> [ResponseBlock] {
        let lines = CardMarkup.segments(in: text, streaming: streaming).flatMap { segment in
            segment.name == nil ? segment.text.components(separatedBy: "\n") : [segment.text.replacingOccurrences(of: "\n", with: " ")]
        }
        var blocks: [ResponseBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
        }

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("::") {
                flushParagraph()
                let marker = parseMarker(trimmed)
                if case let .questions(asked)? = marker, case let .questions(previous)? = blocks.last {
                    blocks[blocks.count - 1] = .questions(previous + asked)
                } else if let marker {
                    blocks.append(marker)
                } else if streaming, lines[(index + 1)...].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
                          !trimmed.contains("{") || CardMarkup.jsonDepth(trimmed) > 0 {
                    // Incomplete marker while streaming: hide it until the JSON closes.
                } else {
                    paragraph.append(trimmed)
                }
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, body: code.joined(separator: "\n")))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix("|") {
                flushParagraph()
                var rows: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                if let table = table(rows) {
                    blocks.append(.table(table))
                } else {
                    blocks.append(.paragraph(rows.joined(separator: "\n")))
                }
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if bulletText(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    if let item = bulletText(line) {
                        items.append(item)
                    } else if !line.isEmpty, lines[index].hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += " " + line
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if numberedText(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, let item = numberedText(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.numberedSteps(items))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        for (level, prefix) in [(3, "### "), (2, "## "), (1, "# "), (4, "#### ")] where line.hasPrefix(prefix) {
            return (level, String(line.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func bulletText(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedText(_ line: String) -> String? {
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let head = line[line.startIndex..<dot]
        guard !head.isEmpty, head.count <= 3, head.allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...]
        guard rest.first == " " else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private static func table(_ rows: [String]) -> TablePayload? {
        func cells(_ row: String) -> [String] {
            var inner = row
            if inner.hasPrefix("|") { inner.removeFirst() }
            if inner.hasSuffix("|") { inner.removeLast() }
            return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard rows.count >= 2 else { return nil }
        let separator = cells(rows[1])
        guard separator.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) else { return nil }
        let header = cells(rows[0])
        let body = rows.dropFirst(2).map(cells)
        return TablePayload(header: header, rows: Array(body))
    }

    // MARK: - Card markers

    private static func parseMarker(_ line: String) -> ResponseBlock? {
        let body = line.dropFirst(2)
        let name: String
        let jsonPart: String
        if let split = body.firstIndex(where: { $0 == " " || $0 == "{" }) {
            name = String(body[body.startIndex..<split]).lowercased().trimmingCharacters(in: .whitespaces)
            jsonPart = String(body[split...]).trimmingCharacters(in: .whitespaces)
        } else {
            name = String(body).lowercased().trimmingCharacters(in: .whitespaces)
            jsonPart = ""
        }
        guard !jsonPart.isEmpty,
              let data = jsonPart.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return shorthandCallout(String(body))
        }
        return makeBlock(name: name, json: json)
    }

    private static func shorthandCallout(_ body: String) -> ResponseBlock? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let name = body[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
        let text = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let style: CalloutStyle
        switch name {
        case "info": style = .info
        case "warning", "warn": style = .warning
        case "success", "ok": style = .success
        case "tip": style = .tip
        default: return nil
        }
        return .callout(CalloutPayload(style: style, title: nil, text: text))
    }

    struct Fields {
        let json: [String: Any]

        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = json[key] as? String, !value.isEmpty { return value }
                if let number = json[key] as? NSNumber { return number.stringValue }
            }
            return nil
        }

        func double(_ keys: String...) -> Double? {
            for key in keys {
                if let value = json[key] as? NSNumber { return value.doubleValue }
                if let value = json[key] as? String, let double = Double(value.replacingOccurrences(of: ",", with: ".")) { return double }
            }
            return nil
        }

        func int(_ keys: String...) -> Int? {
            for key in keys {
                if let value = json[key] as? NSNumber { return value.intValue }
                if let value = json[key] as? String, let int = Int(value) { return int }
            }
            return nil
        }

        func bool(_ keys: String...) -> Bool? {
            for key in keys {
                if let value = json[key] as? Bool { return value }
                if let value = json[key] as? NSNumber { return value.boolValue }
            }
            return nil
        }

        func strings(_ keys: String...) -> [String] {
            for key in keys {
                if let array = json[key] as? [String] { return array }
                if let array = json[key] as? [Any] { return array.map { "\($0)" } }
                if let text = json[key] as? String, !text.isEmpty { return [text] }
            }
            return []
        }

        func object(_ key: String) -> Fields? {
            (json[key] as? [String: Any]).map(Fields.init)
        }
    }

    private static func pairs(_ value: Any?) -> [(String, String)] {
        if let pairs = value as? [[Any]] {
            return pairs.filter { $0.count >= 2 }.map { ("\($0[0])", "\($0[1])") }
        }
        if let objects = value as? [[String: Any]] {
            return objects.compactMap { object in
                guard let key = (object["key"] as? String) ?? (object["label"] as? String) else { return nil }
                if let value = object["value"] as? String { return (key, value) }
                if let value = object["value"] as? NSNumber { return (key, value.stringValue) }
                return nil
            }
        }
        if let dict = value as? [String: Any] {
            return dict.keys.sorted().map { ($0, "\(dict[$0] ?? "")") }
        }
        return []
    }

    private static func degrees(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.contains("°") { return value }
        if let number = Double(value) { return "\(Int(number.rounded()))°" }
        return value
    }

    private static func terminal(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.allSatisfy(\.isNumber) || value.count <= 2 ? "T\(value)" : value
    }

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func flightDate(_ value: String?) -> String? {
        guard let value else { return nil }
        guard let date = dayParser.date(from: String(value.prefix(10))) else { return value }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(.current))
    }

    private static func question(_ json: [String: Any]) -> QuestionPayload? {
        let f = Fields(json: json)
        guard let question = f.string("question", "title", "text", "prompt") else { return nil }
        let raw = (json["options"] ?? json["choices"] ?? json["answers"]) as? [Any] ?? []
        var options: [String] = []
        for item in raw {
            let label: String? = if let object = item as? [String: Any] {
                Fields(json: object).string("label", "text", "title", "value")
            } else {
                "\(item)"
            }
            guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty, !options.contains(label) else { continue }
            options.append(label)
        }
        guard !options.isEmpty else { return nil }
        let multiple = f.bool("multiple", "multi", "multiSelect", "allowMultiple")
            ?? ["true", "yes", "oui"].contains(f.string("multiple")?.lowercased() ?? "")
        return QuestionPayload(question: question, options: options, multiple: multiple)
    }

    private static func makeBlock(name: String, json: [String: Any]) -> ResponseBlock? {
        let f = Fields(json: json)
        switch name {
        case "callout", "info", "warning", "warn", "success", "ok", "tip", "error":
            guard let text = f.string("text", "body", "message") else { return nil }
            let fallback: CalloutStyle = switch name {
            case "warning", "warn": .warning
            case "success", "ok": .success
            case "tip": .tip
            case "error": .error
            default: .info
            }
            let style = CalloutStyle(rawValue: (f.string("style") ?? "").lowercased()) ?? fallback
            return .callout(CalloutPayload(style: style, title: f.string("title"), text: text))

        case "artifact", "file":
            guard let name = f.string("name") ?? f.string("path").map({ ($0 as NSString).lastPathComponent }) ?? f.string("title") else { return nil }
            return .artifact(ArtifactPayload(
                title: f.string("title") ?? name, name: name, mime: f.string("mime"), size: (json["size"] as? NSNumber)?.intValue,
                url: f.string("url"), error: f.string("error")))

        case "facts", "keyvalue":
            let items = pairs(json["items"]).map { FactItem(key: $0.0, value: $0.1) }
            guard !items.isEmpty else { return nil }
            return .facts(FactsPayload(title: f.string("title"), items: items))

        case "table":
            if let header = json["header"] as? [Any], let rows = json["rows"] as? [[Any]] {
                return .table(TablePayload(header: header.map { "\($0)" }, rows: rows.map { $0.map { "\($0)" } }))
            }
            let items = pairs(json["items"]).map { FactItem(key: $0.0, value: $0.1) }
            guard !items.isEmpty else { return nil }
            return .facts(FactsPayload(title: f.string("title"), items: items))

        case "event":
            guard let title = f.string("title", "name") else { return nil }
            return .event(EventPayload(
                title: title, date: f.string("date", "start"), endDate: f.string("end", "endDate"),
                location: f.string("location", "place"), notes: f.string("notes"),
                joinURL: f.string("join", "joinURL", "url"), allDay: f.bool("allDay") ?? false))

        case "carousel", "cards", "list":
            let groupKind = (f.string("kind", "type") ?? "").lowercased()
            let rawItems = (json["items"] as? [[String: Any]]) ?? []
            let blocks: [ResponseBlock] = rawItems.compactMap { item in
                let kind = groupKind.isEmpty ? ((item["type"] as? String) ?? (item["kind"] as? String) ?? "").lowercased() : groupKind
                guard !kind.isEmpty, !["carousel", "cards", "list"].contains(kind) else { return nil }
                return makeBlock(name: kind, json: item)
            }
            guard !blocks.isEmpty else { return nil }
            return .carousel(blocks)

        case "place", "location", "map":
            guard let name = f.string("name", "title") else { return nil }
            return .place(PlacePayload(
                name: name, address: f.string("address"), query: f.string("query", "address", "name"),
                category: f.string("category"), rating: f.string("rating"), openStatus: f.string("open", "openStatus", "hours"),
                distance: f.string("distance"), phone: f.string("phone", "tel"), url: f.string("url"),
                latitude: f.double("latitude", "lat"), longitude: f.double("longitude", "lon", "lng")))

        case "contact":
            guard let name = f.string("name") else { return nil }
            return .contact(ContactPayload(name: name, phone: f.string("phone", "tel"), email: f.string("email"), organization: f.string("organization", "org", "company")))

        case "weather":
            guard let location = f.string("location", "city") else { return nil }
            let hours = ((json["hours"] as? [[String: Any]]) ?? []).compactMap { entry -> WeatherHourPayload? in
                let e = Fields(json: entry)
                guard let time = e.string("t", "time"), let temp = e.string("temp", "temperature") else { return nil }
                return WeatherHourPayload(time: time, temperature: degrees(temp) ?? temp, symbol: WeatherSymbols.sfSymbol(e.string("symbol", "icon")))
            }
            let rawDays = (json["forecast"] as? [[String: Any]]) ?? (json["days"] as? [[String: Any]]) ?? []
            let days = rawDays.compactMap { entry -> WeatherDayPayload? in
                let e = Fields(json: entry)
                guard let day = e.string("day", "d", "date") else { return nil }
                return WeatherDayPayload(
                    day: day, symbol: WeatherSymbols.sfSymbol(e.string("symbol", "icon")),
                    low: e.double("low", "lo", "min"), high: e.double("high", "hi", "max"), rain: e.string("rain", "precip"))
            }
            return .weather(WeatherPayload(
                location: location, temperature: degrees(f.string("temperature", "temp")) ?? "", condition: f.string("condition", "summary") ?? "",
                detail: f.string("detail", "feelsLike"), symbol: WeatherSymbols.sfSymbol(f.string("symbol", "icon")),
                high: degrees(f.string("high", "hi", "max")), low: degrees(f.string("low", "lo", "min")),
                hours: hours, days: days, period: f.string("period", "date")))

        case "stock":
            guard let symbol = f.string("symbol", "ticker") else { return nil }
            let change = f.string("change")
            let positive = f.bool("positive") ?? !(change?.trimmingCharacters(in: .whitespaces).hasPrefix("-") ?? false)
            return .stock(StockPayload(symbol: symbol, name: f.string("name"), price: f.string("price"), change: change, positive: positive, source: f.string("source")))

        case "route", "directions":
            guard let from = f.string("from", "origin"), let to = f.string("to", "destination") else { return nil }
            return .route(RoutePayload(from: from, to: to, duration: f.string("duration", "eta"), distance: f.string("distance"), transport: f.string("transport", "mode")))

        case "media", "video", "link":
            guard let title = f.string("title") else { return nil }
            return .media(MediaPayload(title: title, subtitle: f.string("subtitle", "description"), url: f.string("url"), symbol: f.string("symbol")))

        case "metrics":
            let items = pairs(json["items"]).map { MetricItem(label: $0.0, value: $0.1) }
            guard !items.isEmpty else { return nil }
            return .metrics(MetricsPayload(title: f.string("title"), symbol: f.string("symbol", "icon"), items: items))

        case "chart", "graph", "trend":
            var points: [ChartPointPayload] = []
            let series = (json["series"] as? [[String: Any]])?.first
            if let raw = (series?["points"] ?? json["points"]) as? [[String: Any]] {
                points = raw.compactMap { entry in
                    let e = Fields(json: entry)
                    guard let label = e.string("label", "l", "x"), let value = e.double("value", "v", "y"), value.isFinite else { return nil }
                    return ChartPointPayload(label: label, value: value)
                }
            } else if let raw = (series?["points"] ?? json["points"]) as? [[Any]] {
                points = raw.compactMap { pair in
                    guard pair.count >= 2 else { return nil }
                    let value = (pair[1] as? NSNumber)?.doubleValue ?? Double("\(pair[1])")
                    guard let value, value.isFinite else { return nil }
                    return ChartPointPayload(label: "\(pair[0])", value: value)
                }
            }
            guard points.count >= 2 else { return nil }
            return .chart(ChartPayload(title: f.string("title"), symbol: f.string("symbol", "icon"), unit: f.string("unit"), style: f.string("type", "style"), points: points, average: f.double("average", "avg")))

        case "nowplaying", "music", "track":
            guard let title = f.string("title", "track", "name") else { return nil }
            return .nowPlaying(NowPlayingPayload(title: title, artist: f.string("artist"), album: f.string("album"), artwork: f.string("artwork", "image"), isPlaying: f.bool("playing", "isPlaying") ?? false, url: f.string("url")))

        case "photos", "gallery":
            let urls = f.strings("urls", "images", "photos")
            guard !urls.isEmpty else { return nil }
            return .photos(PhotosPayload(title: f.string("title"), subtitle: f.string("subtitle"), urls: urls))

        case "image", "img":
            guard let url = f.string("url", "src") else { return nil }
            return .image(ImagePayload(url: url, caption: f.string("caption", "title"), aspect: f.double("aspect")))

        case "flight":
            let from = f.object("from")
            let to = f.object("to")
            guard let fromCode = from?.string("code", "iata") ?? f.string("fromCode", "from", "origin"),
                  let toCode = to?.string("code", "iata") ?? f.string("toCode", "to", "destination")
            else { return nil }
            let actions = ((json["actions"] as? [Any]) ?? []).compactMap { raw -> CardAction? in
                if let label = raw as? String { return CardAction(label: label, url: nil, prompt: label) }
                guard let object = raw as? [String: Any] else { return nil }
                let a = Fields(json: object)
                guard let label = a.string("label", "title") else { return nil }
                return CardAction(label: label, url: a.string("url"), prompt: a.string("prompt"))
            }
            return .flight(FlightPayload(
                number: f.string("flight", "number", "flightNumber"), airline: f.string("airline"), date: flightDate(f.string("date")),
                fromCode: fromCode, fromCity: from?.string("city", "name") ?? f.string("fromCity"),
                toCode: toCode, toCity: to?.string("city", "name") ?? f.string("toCity"),
                departure: from?.string("time", "departure") ?? f.string("departure", "departureTime"),
                arrival: to?.string("time", "arrival") ?? f.string("arrival", "arrivalTime"),
                departureTerminal: terminal(from?.string("terminal") ?? f.string("departureTerminal", "terminal")),
                arrivalTerminal: terminal(to?.string("terminal") ?? f.string("arrivalTerminal")),
                gate: from?.string("gate") ?? f.string("gate"),
                seats: f.strings("seats", "seat").joined(separator: " ").nilIfEmpty,
                status: f.string("status"), statusKind: f.string("statusKind", "state"),
                actions: actions))

        case "product", "food":
            guard let barcode = f.string("barcode", "code", "ean")?.filter(\.isNumber), !barcode.isEmpty else { return nil }
            return .product(ProductPayload(barcode: barcode, portion: f.double("portion_g", "portion", "grams")))

        case "cosmetic", "beauty":
            guard let barcode = f.string("barcode", "code", "ean")?.filter(\.isNumber), !barcode.isEmpty,
                  let name = f.string("name", "title") else { return nil }
            let flagged = ((json["flagged"] as? [[String: Any]]) ?? []).compactMap { entry -> CosmeticFlag? in
                let e = Fields(json: entry)
                guard let name = e.string("name"), let risk = IngredientRisk(rawValue: e.string("risk") ?? "") else { return nil }
                return CosmeticFlag(name: name, risk: risk)
            }
            return .cosmetic(CosmeticPayload(
                barcode: barcode, name: name, brand: f.string("brand"), image: f.string("image", "imageUrl"),
                score: f.int("score"), flagged: flagged))

        case "parcel", "package", "shipment":
            guard let number = f.string("number", "tracking", "trackingNumber") else { return nil }
            let events = ((json["events"] as? [[String: Any]]) ?? []).compactMap { entry -> ParcelEventPayload? in
                let e = Fields(json: entry)
                guard let label = e.string("label", "description") else { return nil }
                return ParcelEventPayload(label: label, at: e.string("at").flatMap(ISO8601Wire.parse), location: e.string("location"))
            }
            let status = f.string("status") ?? "unknown"
            return .parcel(ParcelPayload(
                id: f.string("id"), number: number, label: f.string("label", "title"), carrier: f.string("carrier", "carrierName"),
                status: status, statusLabel: f.string("statusLabel") ?? String(localized: "Tracking"), lastEvent: f.string("lastEvent"),
                lastEventAt: f.string("lastEventAt").flatMap(ISO8601Wire.parse), eta: f.string("eta"), url: f.string("url"),
                events: events))

        case "question", "questions", "choice", "choices":
            let asked = ((json["questions"] as? [[String: Any]]) ?? [json]).compactMap(question)
            return asked.isEmpty ? nil : .questions(asked)

        case "conversation", "chat":
            guard let id = f.string("id", "conversationId") else { return nil }
            return .conversation(ConversationLinkPayload(id: id, botId: f.string("botId", "bot"), title: f.string("title")))

        case "email", "email_draft":
            guard let draftId = f.string("draftId", "draft_id") else { return nil }
            func recipients(_ key: String) -> [String] {
                if let text = json[key] as? String { return EmailDraftPayload.addresses(text) }
                return f.strings(key).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            return .email(EmailDraftPayload(
                account: f.string("account", "from") ?? "", draftId: draftId, to: recipients("to"), cc: recipients("cc"),
                bcc: recipients("bcc"), subject: f.string("subject") ?? "", body: (json["body"] as? String) ?? ""))

        case "workout", "session", "training":
            return workout(json).map(ResponseBlock.workout)

        case "meal", "nutrition":
            return meal(json).map(ResponseBlock.meal)

        case "home", "house":
            return home(json).map(ResponseBlock.home)

        case "notice":
            return .notice(NoticePayload(
                kind: f.string("kind") ?? "info", text: f.string("text") ?? "",
                beforeTokens: f.int("beforeTokens"), afterTokens: f.int("afterTokens")))

        default:
            return nil
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
