import Foundation

/// A card on the watch, mapped from the blocks the iPhone parses: the kinds that read well on a small screen keep a card
/// of their own, the others a compact one, and those that need a bigger screen only point to the iPhone.
enum WatchCard: Hashable {
    case flight(FlightPayload)
    case facts(FactsPayload)
    case callout(CalloutPayload)
    case weather(WeatherPayload)
    case product(title: String, detail: String?)
    case questions([QuestionPayload])
    case event(title: String, when: String?, location: String?)
    case compact(Compact)
    case phoneOnly(kind: String, symbol: String, title: String?)

    struct Compact: Hashable {
        var kind: String
        var symbol: String
        var tint: Tint
        var title: String
        var detail: String?
    }

    enum Tint: Hashable {
        case accent, good, bad
    }
}

enum MessageBlock: Hashable {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    case steps([String])
    case quote(String)
    case code(String)
    case divider
    case table(WatchTable)
    case card(WatchCard)
}

enum MessageContent {
    static func blocks(_ text: String, streaming: Bool = false) -> [MessageBlock] {
        ResponseBlockParser.parse(text, streaming: streaming).flatMap(blocks(for:))
    }

    /// Plain sentences for speech and previews: no code, table syntax, card JSON or markdown marks.
    static func spokenText(_ text: String) -> String {
        blocks(text).compactMap(spoken).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func spoken(_ block: MessageBlock) -> String? {
        switch block {
        case let .heading(text), let .paragraph(text), let .quote(text):
            WatchMarkdown.plain(text)
        case let .bullets(items), let .steps(items):
            items.map(WatchMarkdown.plain).joined(separator: "\n")
        case let .table(table):
            table.spokenText
        case let .card(.callout(callout)):
            [callout.title, callout.text].compactMap { $0 }.map(WatchMarkdown.plain).joined(separator: ". ")
        case let .card(.questions(questions)):
            questions.map { $0.question + " " + $0.options.joined(separator: ", ") }.joined(separator: "\n")
        case let .card(.event(title, when, _)):
            [title, when].compactMap { $0 }.joined(separator: ", ")
        case .code, .divider, .card:
            nil
        }
    }

    private static func blocks(for block: ResponseBlock) -> [MessageBlock] {
        switch block {
        case let .heading(_, text):
            return [.heading(text)]
        case let .paragraph(text):
            return readable(text).map { [.paragraph($0)] } ?? []
        case let .bulletList(items):
            return [.bullets(items)]
        case let .numberedSteps(items):
            return [.steps(items)]
        case let .quote(text):
            return [.quote(text)]
        case let .code(language, body):
            if language?.lowercased() == "mermaid" {
                return [.card(.phoneOnly(kind: String(localized: "Diagram"), symbol: "point.3.connected.trianglepath.dotted", title: nil))]
            }
            return [.code(body)]
        case let .table(table):
            return [.table(WatchTable(table))]
        case .divider:
            return [.divider]
        case let .carousel(items):
            return items.flatMap(blocks(for:))
        case let .flight(flight):
            return [.card(.flight(flight))]
        case let .facts(facts):
            return [.card(.facts(facts))]
        case let .metrics(metrics):
            return [.card(.facts(FactsPayload(title: metrics.title, items: metrics.items.map { FactItem(key: $0.label, value: $0.value) })))]
        case let .callout(callout):
            return [.card(.callout(callout))]
        case let .notice(notice):
            return [.card(.callout(CalloutPayload(style: .info, title: nil, text: notice.text.isEmpty ? String(localized: "Conversation compacted") : notice.text)))]
        case let .weather(weather):
            return [.card(.weather(weather))]
        case let .product(product):
            return [.card(.product(title: String(localized: "Product \(product.barcode)"), detail: product.portion.map { String(localized: "Portion \(ChartFormat.value($0)) g") }))]
        case let .cosmetic(cosmetic):
            let detail = [cosmetic.brand, cosmetic.score.map { "\($0)/100" }].compactMap { $0 }.joined(separator: " · ")
            return [.card(.product(title: cosmetic.name, detail: detail.nilIfEmpty))]
        case let .questions(questions):
            return [.card(.questions(questions))]
        case let .event(event):
            return [.card(.event(title: event.title, when: when(event), location: event.location))]
        case let .place(place):
            return [compact(String(localized: "PLACE"), "mappin.and.ellipse", .accent, place.name, place.category, place.distance, place.openStatus, place.address)]
        case let .contact(contact):
            return [compact("CONTACT", "person.crop.circle.fill", .accent, contact.name, contact.organization, contact.phone ?? contact.email)]
        case let .stock(stock):
            return [compact(String(localized: "STOCKS"), stock.positive ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                            stock.positive ? .good : .bad, stock.name ?? stock.symbol,
                            stock.name == nil ? nil : stock.symbol, stock.price, stock.change)]
        case let .route(route):
            return [compact(String(localized: "ROUTE"), "arrow.triangle.turn.up.right.diamond.fill", .accent, "\(route.from) → \(route.to)", route.duration, route.distance)]
        case let .nowPlaying(track):
            return [compact(String(localized: "MUSIC"), "music.note", .accent, track.title, track.artist, track.album)]
        case let .parcel(parcel):
            return [compact(String(localized: "PARCEL"), "shippingbox.fill", .accent, parcel.label ?? String(localized: "Parcel \(parcel.number)"), parcel.statusLabel, parcel.lastEvent)]
        case let .media(media):
            return [.card(.phoneOnly(kind: String(localized: "Link"), symbol: "play.rectangle.fill", title: media.title))]
        case let .chart(chart):
            return [.card(.phoneOnly(kind: String(localized: "Chart"), symbol: "chart.bar.fill", title: chart.title))]
        case let .photos(photos):
            return [.card(.phoneOnly(kind: String(localized: "Photos"), symbol: "photo.on.rectangle", title: photos.title))]
        case let .image(image):
            return [.card(.phoneOnly(kind: String(localized: "Image"), symbol: "photo", title: image.caption))]
        case let .artifact(artifact):
            return [.card(.phoneOnly(kind: String(localized: "File"), symbol: artifact.symbol, title: artifact.title))]
        case let .conversation(conversation):
            return [.card(.phoneOnly(kind: String(localized: "Conversation"), symbol: "bubble.left.and.bubble.right.fill", title: conversation.title))]
        case let .email(email):
            return [.card(.phoneOnly(kind: String(localized: "Email draft"), symbol: "envelope.fill", title: email.subject.nilIfEmpty ?? String(localized: "(no subject)")))]
        }
    }

    /// The iPhone shows an unknown or broken card marker as text; its JSON means nothing on a wrist.
    private static func readable(_ paragraph: String) -> String? {
        paragraph.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("::") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func compact(_ kind: String, _ symbol: String, _ tint: WatchCard.Tint, _ title: String, _ details: String?...) -> MessageBlock {
        let detail = details.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
        return .card(.compact(.init(kind: kind, symbol: symbol, tint: tint, title: title, detail: detail.nilIfEmpty)))
    }

    private static func when(_ event: EventPayload) -> String? {
        if event.allDay { return shortDate(event.date) }
        guard let start = shortDateTime(event.date) else { return nil }
        guard let end = event.endDate, end.count >= 16 else { return start }
        return start + "–" + end.dropFirst(11).prefix(5)
    }

    // MARK: - Dates

    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    private static func shortDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let date = dayParser.date(from: String(value.prefix(10))) else { return value }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.current))
    }

    private static let stampParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return parser
    }()

    /// "Thu, Nov 19 · 14:00", "tomorrow · 09:00".
    private static func shortDateTime(_ value: String?, now: Date = Date()) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let date = stampParser.date(from: String(value.prefix(16))) else { return shortDate(value) }
        let calendar = Calendar.current
        let hour = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(.current))
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = String(localized: "today")
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            day = String(localized: "tomorrow")
        } else {
            day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.current))
        }
        return "\(day) · \(hour)"
    }
}

enum WatchMarkdown {
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func plain(_ text: String) -> String {
        String(inline(text).characters)
    }
}
