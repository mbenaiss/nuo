import Foundation

enum CalloutStyle: String {
    case info, success, warning, tip, error

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .tip: "lightbulb.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .info: String(localized: "Info")
        case .success: String(localized: "Success")
        case .warning: String(localized: "Warning")
        case .tip: String(localized: "Tip")
        case .error: String(localized: "Error")
        }
    }
}

struct FactItem: Hashable {
    var key: String
    var value: String
}

struct CalloutPayload: Hashable {
    var style: CalloutStyle
    var title: String?
    var text: String
}

struct FactsPayload: Hashable {
    var title: String?
    var items: [FactItem]
}

struct EventPayload: Hashable {
    var title: String
    var date: String?
    var endDate: String?
    var location: String?
    var notes: String?
    var joinURL: String?
    var allDay: Bool = false
}

struct PlacePayload: Hashable {
    var name: String
    var address: String?
    var query: String?
    var category: String?
    var rating: String?
    var openStatus: String?
    var distance: String?
    var phone: String?
    var url: String?
    var latitude: Double?
    var longitude: Double?
}

struct ContactPayload: Hashable {
    var name: String
    var phone: String?
    var email: String?
    var organization: String?
}

struct WeatherHourPayload: Hashable {
    var time: String
    var temperature: String
    var symbol: String?
}

struct WeatherDayPayload: Hashable {
    var day: String
    var symbol: String?
    var low: Double?
    var high: Double?
    var rain: String?
}

struct WeatherPayload: Hashable {
    var location: String
    var temperature: String
    var condition: String
    var detail: String?
    var symbol: String?
    var high: String?
    var low: String?
    var hours: [WeatherHourPayload] = []
    var days: [WeatherDayPayload] = []
    var period: String?
}

struct StockPayload: Hashable {
    var symbol: String
    var name: String?
    var price: String?
    var change: String?
    var positive: Bool
    var source: String?
}

struct RoutePayload: Hashable {
    var from: String
    var to: String
    var duration: String?
    var distance: String?
    var transport: String?

    var mapsURL: URL? {
        var url = URLComponents(string: "https://maps.apple.com/")
        var items = [URLQueryItem(name: "saddr", value: from), URLQueryItem(name: "daddr", value: to)]
        switch transport {
        case "walking": items.append(URLQueryItem(name: "dirflg", value: "w"))
        case "transit": items.append(URLQueryItem(name: "dirflg", value: "r"))
        case "driving": items.append(URLQueryItem(name: "dirflg", value: "d"))
        default: break
        }
        url?.queryItems = items
        return url?.url
    }
}

struct MediaPayload: Hashable {
    var title: String
    var subtitle: String?
    var url: String?
    var symbol: String?
}

struct MetricItem: Hashable {
    var label: String
    var value: String
}

struct MetricsPayload: Hashable {
    var title: String?
    var symbol: String?
    var items: [MetricItem]
}

struct ChartPointPayload: Hashable {
    var label: String
    var value: Double
}

struct ChartPayload: Hashable {
    var title: String?
    var symbol: String?
    var unit: String?
    /// "bar" (default) or "line".
    var style: String?
    var points: [ChartPointPayload]
    var average: Double?
}

struct NowPlayingPayload: Hashable {
    var title: String
    var artist: String?
    var album: String?
    var artwork: String?
    var isPlaying: Bool
    var url: String?
}

struct PhotosPayload: Hashable {
    var title: String?
    var subtitle: String?
    var urls: [String]
}

struct ImagePayload: Hashable {
    var url: String
    var caption: String?
    var aspect: Double?
}

struct FlightPayload: Hashable {
    var number: String?
    var airline: String?
    var date: String?
    var fromCode: String
    var fromCity: String?
    var toCode: String
    var toCity: String?
    var departure: String?
    var arrival: String?
    var departureTerminal: String?
    var arrivalTerminal: String?
    var gate: String?
    var seats: String?
    var status: String?
    var statusKind: String?
    var actions: [CardAction] = []
}

struct CardAction: Hashable {
    var label: String
    var url: String?
    /// Sent back to the bot as a prompt when there is no URL.
    var prompt: String?
}

struct ProductPayload: Hashable {
    var barcode: String
    var portion: Double?
}

struct CosmeticFlag: Hashable {
    var name: String
    var risk: IngredientRisk
}

struct CosmeticPayload: Hashable {
    var barcode: String
    var name: String
    var brand: String?
    var image: String?
    var score: Int?
    var flagged: [CosmeticFlag]
}

struct ParcelEventPayload: Hashable {
    var label: String
    var at: Date?
    var location: String?
}

struct ParcelPayload: Hashable {
    var id: String?
    var number: String
    var label: String?
    var carrier: String?
    var status: String
    var statusLabel: String
    var lastEvent: String?
    var lastEventAt: Date?
    /// YYYY-MM-DD.
    var eta: String?
    var url: String?
    var events: [ParcelEventPayload]
}

/// System line persisted in history, e.g. a context compaction.
struct NoticePayload: Hashable {
    var kind: String
    var text: String
    var beforeTokens: Int?
    var afterTokens: Int?
}

/// `::artifact`: a file a bot wrote (HTML page, PDF, spreadsheet…), published by the gateway under `/api/media/…`.
struct ArtifactPayload: Hashable {
    var title: String
    var name: String
    var mime: String?
    var size: Int?
    /// Nil while the turn runs: the gateway publishes the file when the answer ends.
    var url: String?
    var error: String?

    private var ext: String { (name as NSString).pathExtension.lowercased() }

    /// Shown in Nuo's own web view; the rest goes to Quick Look.
    var isWebPage: Bool { ["html", "htm", "svg"].contains(ext) || mime == "text/html" }

    var symbol: String {
        switch ext {
        case "html", "htm": "safari"
        case "pdf": "doc.richtext"
        case "csv", "xlsx", "xls", "numbers": "tablecells"
        case "pptx", "key": "rectangle.on.rectangle"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": "photo"
        case "md", "txt", "docx": "doc.text"
        case "zip": "doc.zipper"
        default: "doc"
        }
    }

    var detail: String {
        var parts = [name]
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

/// `::question`: a choice the bot asks the user to make, answered from the card.
struct QuestionPayload: Hashable {
    var question: String
    var options: [String]
    var multiple = false
}

struct TablePayload: Hashable {
    var header: [String]
    var rows: [[String]]
}

/// `::conversation`: a conversation of any bot, opened on tap.
struct ConversationLinkPayload: Hashable {
    var id: String
    var botId: String?
    var title: String?
}

/// `::email`: a Gmail draft a bot prepared, which the user reads, edits and sends from the card. Also the body of the
/// gateway's `GET|PUT /api/google/drafts/:id`.
struct EmailDraftPayload: Hashable, Codable, Sendable {
    var account: String
    var draftId: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String

    /// `"Martin, Julie" <julie.martin@lumen.example>, compta@lumen.example` → two recipients: a comma between
    /// quotes belongs to a name.
    static func addresses(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if (character == "," || character == ";") && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

indirect enum ResponseBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedSteps([String])
    case quote(String)
    case code(language: String?, body: String)
    case table(TablePayload)
    case divider
    case callout(CalloutPayload)
    case facts(FactsPayload)
    case event(EventPayload)
    case carousel([ResponseBlock])
    case place(PlacePayload)
    case contact(ContactPayload)
    case weather(WeatherPayload)
    case stock(StockPayload)
    case route(RoutePayload)
    case media(MediaPayload)
    case metrics(MetricsPayload)
    case chart(ChartPayload)
    case nowPlaying(NowPlayingPayload)
    case photos(PhotosPayload)
    case image(ImagePayload)
    case flight(FlightPayload)
    case product(ProductPayload)
    case cosmetic(CosmeticPayload)
    case parcel(ParcelPayload)
    case notice(NoticePayload)
    case artifact(ArtifactPayload)
    case conversation(ConversationLinkPayload)
    case email(EmailDraftPayload)
    case workout(WorkoutPayload)
    case meal(MealPayload)
    case home(HomePayload)
    /// Consecutive `::question` markers, asked one after the other in a single card.
    case questions([QuestionPayload])

    var isText: Bool {
        switch self {
        case .heading, .paragraph, .bulletList, .numberedSteps, .quote, .code, .table, .divider: true
        default: false
        }
    }
}

enum ChartFormat {
    static func value(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...(abs(value) < 10 ? 1 : 0))).locale(.current))
    }
}
