import Foundation

// Mirror of docs/data.md: collections, reminders, dashboards and docs.
// Kept out of Protocol.swift so the widget, watch and share targets do not compile them.

/// Accessors for row values, dashboard cells and partial PATCH bodies (where `null` clears a field).
extension JSONValue {
    var isNull: Bool { if case .null = self { true } else { false } }

    var string: String? {
        switch self {
        case let .string(value): value
        case let .number(value): value.rounded() == value ? String(Int64(value)) : String(value)
        case let .bool(value): value ? "true" : "false"
        default: nil
        }
    }

    var double: Double? {
        switch self {
        case let .number(value): value
        case let .string(value): Double(value.replacingOccurrences(of: ",", with: "."))
        case let .bool(value): value ? 1 : 0
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case let .bool(value): value
        case let .number(value): value != 0
        case let .string(value): ["1", "true", "oui"].contains(value.lowercased())
        default: nil
        }
    }

    /// Multiselect values arrive as a JSON array, or as the JSON text SQLite stores.
    var stringArray: [String] {
        switch self {
        case let .array(items): return items.compactMap(\.string)
        case let .string(text):
            if text.hasPrefix("["), let data = text.data(using: .utf8),
               let items = try? JSONDecoder().decode([String].self, from: data) { return items }
            return text.isEmpty ? [] : [text]
        default: return []
        }
    }
}

enum DataColumnType: String, Codable, Sendable, CaseIterable {
    case text, longtext, number, money, percent, date, datetime, bool, select, multiselect, ref, url, file
    /// Read-only back-references: an array of row ids, titles in `DataRow.refs`.
    case refs
    case unknown

    init(from decoder: any Decoder) throws {
        self = DataColumnType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// A select option (`{name, color?}` on the wire; plain strings are accepted too).
struct DataOption: Codable, Hashable, Sendable, Identifiable {
    var value: String
    var label: String?
    var color: String?
    var id: String { value }
    var display: String { label ?? value }

    init(value: String, label: String? = nil, color: String? = nil) {
        self.value = value
        self.label = label
        self.color = color
    }

    init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.init(value: text)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let value = try c.decodeIfPresent(String.self, forKey: .name) ?? c.decode(String.self, forKey: .value)
        self.init(value: value, label: try c.decodeIfPresent(String.self, forKey: .label), color: try c.decodeIfPresent(String.self, forKey: .color))
    }

    private enum Keys: String, CodingKey { case name, value, label, color }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(value, forKey: .name)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(color, forKey: .color)
    }
}

struct DataColumn: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var label: String
    var type: DataColumnType
    var options: [DataOption]?
    /// Target collection id of a `ref` column.
    var ref: String?
    var computed: Bool?
    var hidden: Bool?
    var order: Int?

    var id: String { name }
    var isComputed: Bool { (computed ?? false) || type == .refs }
    var isHidden: Bool { hidden ?? false }

    init(name: String, label: String, type: DataColumnType, options: [DataOption]? = nil, ref: String? = nil,
         computed: Bool? = nil, hidden: Bool? = nil, order: Int? = nil) {
        self.name = name
        self.label = label
        self.type = type
        self.options = options
        self.ref = ref
        self.computed = computed
        self.hidden = hidden
        self.order = order
    }
}

struct DataCollection: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var emoji: String?
    var count: Int
    var columns: [DataColumn]
    var titleColumn: String
    /// `column:asc|desc`.
    var defaultSort: String?

    var visibleColumns: [DataColumn] {
        columns.filter { !$0.isHidden }.sorted { ($0.order ?? .max, $0.name) < ($1.order ?? .max, $1.name) }
    }

    func column(_ name: String) -> DataColumn? { columns.first { $0.name == name } }
}

struct DataRow: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var values: [String: JSONValue]
    var title: String
    /// Title of the row each `ref` column points to.
    var refs: [String: String]?
    var updatedAt: Date
    var archivedAt: Date?

    subscript(column: String) -> JSONValue { values[column] ?? .null }
}

struct DataRowsPage: Codable, Sendable {
    var rows: [DataRow]
    var nextCursor: String?
    var total: Int?
}

struct DataChange: Codable, Hashable, Sendable, Identifiable {
    enum Op: String, Codable, Sendable {
        case insert, update, archive, unarchive, delete, revert
        case unknown
        init(from decoder: any Decoder) throws {
            self = Op(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    var id: String
    var at: Date
    var collection: String
    var rowId: String
    var op: Op
    /// `column: [old, new]`.
    var changes: [String: [JSONValue]]
    var source: String
}

struct DataRowDetail: Codable, Sendable {
    var row: DataRow
    var history: [DataChange]
}

/// Item of a `file` value; `path` is served by `GET /api/data/files?path=`.
struct DataFileRef: Codable, Hashable, Sendable {
    var name: String
    var path: String?
    var url: String?

    var downloadPath: String? {
        if let path { return "/api/data/files?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? path)" }
        return url
    }
}

struct DataSearchHit: Codable, Hashable, Sendable {
    var collection: String
    var row: DataRow
}

/// Filter of `GET …/rows`: `filter=col:op:value`.
struct DataFilter: Hashable, Sendable, Identifiable {
    enum Op: String, Sendable { case eq, ne, lt, lte, gt, gte, contains, `in`, empty, notempty }
    var column: String
    var op: Op
    var value: String
    var id: String { "\(column):\(op.rawValue):\(value)" }
}

/// One group of `GET …/groups`: `key` is the column value (`"2026"` for a year), `label` the title of a `ref` key.
struct DataGroup: Codable, Hashable, Sendable, Identifiable {
    var key: JSONValue
    var label: String?
    var count: Int
    /// Sum of every money column of the group.
    var sums: [String: Double]
    var id: String { key.string ?? "" }
}

struct DataGroups: Codable, Hashable, Sendable {
    struct Total: Codable, Hashable, Sendable {
        var count: Int
        var sums: [String: Double]
    }
    var by: String
    var groups: [DataGroup]
    var total: Total
}

struct DataQuery: Hashable, Sendable {
    var search = ""
    var sort: String?
    var filters: [DataFilter] = []

    var cacheKey: String { "\(search)|\(sort ?? "")|\(filters.map(\.id).sorted().joined(separator: ","))" }
}

// MARK: - Reminders

struct Reminder: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var notes: String?
    var dueAt: Date?
    /// 5-field cron (Europe/Paris) or `daily|weekly|monthly|yearly`.
    var `repeat`: String?
    var list: String
    var priority: Int
    var doneAt: Date?
    var snoozedUntil: Date?
    var createdAt: Date
    var updatedAt: Date
    var place: ReminderPlace?
    /// `arrive` | `leave`, set with `place`.
    var placeTrigger: String?
    var projectId: String? = nil
    var project: ReminderRef? = nil
    /// Its own area, or its project's.
    var areaId: String? = nil
    var area: ReminderRef? = nil
    var headingId: String? = nil
    var someday: Bool? = nil
    var position: Double? = nil
    var checklist: [ChecklistItem]? = nil

    var isDone: Bool { doneAt != nil }
    var isSomeday: Bool { someday == true }
    /// Neither in a project nor in an area: waiting to be filed.
    var isUnfiled: Bool { projectId == nil && areaId == nil }
    var leavesPlace: Bool { placeTrigger == "leave" }

    /// When it rings next: a snooze pushes the due date back.
    var effectiveDate: Date? {
        if let snoozedUntil, snoozedUntil > (dueAt ?? .distantPast) { return snoozedUntil }
        return dueAt
    }
}

enum ReminderScope: String, Sendable { case today, upcoming, overdue, done, all, inbox, anytime, someday }

/// The project or area embedded in a `Reminder`.
struct ReminderRef: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var emoji: String?
}

struct ChecklistItem: Codable, Hashable, Sendable {
    var title: String
    var done: Bool
}

/// Things-like « domaine » (Pro, Perso…) holding projects and reminders.
struct ReminderArea: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var emoji: String?
    var position: Double
}

struct ReminderProject: Codable, Hashable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable { case open, done, cancelled }

    var id: String
    var title: String
    var notes: String?
    var emoji: String?
    var color: String?
    var areaId: String?
    /// `YYYY-MM-DD`.
    var deadline: String?
    var someday: Bool
    var status: Status
    var doneAt: Date?
    var position: Double
    var openCount: Int
    var doneCount: Int
    /// 0...1.
    var progress: Double

    var isOpen: Bool { status == .open }

    var deadlineDate: Date? {
        deadline.flatMap { try? Date($0 + "T12:00:00Z", strategy: .iso8601) }
    }
}

struct ProjectHeading: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var projectId: String
    var title: String
    var position: Double
}

struct ProjectDetail: Codable, Sendable {
    var project: ReminderProject
    var headings: [ProjectHeading]
    var reminders: [Reminder]
}

struct ProjectDraft: Codable, Sendable {
    var title: String
    var notes: String?
    var emoji: String?
    var areaId: String?
    var deadline: String?
    var someday: Bool?
}

struct ReminderDraft: Codable, Sendable {
    var title: String
    var notes: String?
    var dueAt: Date?
    var `repeat`: String?
    var list: String?
    var priority: Int?
    var placeId: String?
    var placeTrigger: String?
    var projectId: String? = nil
    var areaId: String? = nil
    var headingId: String? = nil
    var someday: Bool? = nil
    var checklist: [ChecklistItem]? = nil
}

/// The place embedded in a `Reminder`.
struct ReminderPlace: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var lat: Double
    var lon: Double
    var radiusM: Double
}

/// A saved place (`GET /api/places`).
struct Place: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var address: String?
    var lat: Double
    var lon: Double
    var radiusM: Double
    var createdAt: Date?
    var updatedAt: Date?

    var asReminderPlace: ReminderPlace { ReminderPlace(id: id, name: name, lat: lat, lon: lon, radiusM: radiusM) }
}

struct PlaceDraft: Codable, Sendable {
    var name: String
    var address: String?
    var lat: Double
    var lon: Double
    var radiusM: Double?
}

// MARK: - Dashboards

struct DashboardSummary: Codable, Hashable, Sendable, Identifiable {
    var slug: String
    var title: String
    var emoji: String?
    var description: String?
    var id: String { slug }
}

struct Dashboard: Codable, Hashable, Sendable, Identifiable {
    var slug: String
    var title: String
    var emoji: String?
    var description: String?
    var blocks: [DashboardBlock]
    var id: String { slug }
}

/// A block with its computed result: `value` for `number`, `series` for charts (one per distinct `s`),
/// `columns` + `rows` for `table`, `items` for `list`.
struct DashboardBlock: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case number, line, bar, donut, table, list
        case unknown
        init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    struct Point: Codable, Hashable, Sendable {
        var x: JSONValue
        var y: Double?
    }

    struct Series: Codable, Hashable, Sendable {
        var name: String
        var points: [Point]
    }

    struct Item: Codable, Hashable, Sendable {
        var title: String
        var subtitle: String?
        var value: JSONValue?
        var id: String?
    }

    var type: Kind
    var title: String
    /// `money`, `number`, `percent`, `date`… (same names as column types).
    var format: String?
    var collection: String?
    var value: JSONValue?
    var series: [Series]?
    var columns: [String]?
    var rows: [[JSONValue]]?
    var items: [Item]?
    var truncated: Bool?
    var error: String?
}

// MARK: - Docs

struct DocNode: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case dir, file }
    var path: String
    var name: String
    var kind: Kind
    var updatedAt: Date?
    var size: Int?
        var id: String { path }
}

struct DocFile: Codable, Hashable, Sendable {
    var path: String
    var content: String
    var sha: String
    var updatedAt: Date?
}

struct DocSaveResult: Codable, Hashable, Sendable {
    var path: String
    var sha: String
    var updatedAt: Date?
}

struct DocUploadResult: Codable, Hashable, Sendable {
    var path: String
    var size: Int
}

/// A public link to a document on drop; `expiresAt` is nil for a permanent one.
struct DocDropLink: Codable, Hashable, Sendable {
    var url: URL
    var expiresAt: Date?
}

struct DocMoveResult: Codable, Hashable, Sendable {
    var path: String
    var kind: DocNode.Kind
}

struct DocPins: Codable, Hashable, Sendable {
    var paths: [String]
}

struct DocSearchHit: Codable, Hashable, Sendable, Identifiable {
    var path: String
    var line: Int
    var snippet: String
    var id: String { "\(path):\(line)" }
}

enum DocsPaths {
    /// Raw bytes of a file of the docs repository (images in Markdown).
    static func raw(_ path: String) -> String {
        "/api/docs/raw?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? path)"
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}

/// Data, reminders, dashboards and docs routes of docs/data.md.
protocol NuoDataAPI: Sendable {
    func collections() async throws -> [DataCollection]
    func rows(collection: String, query: DataQuery, limit: Int, cursor: String?) async throws -> DataRowsPage
    /// Rows matching `query` grouped `by` a column (`column:year|month` for a date), with money sums per group.
    func groups(collection: String, by: String, query: DataQuery) async throws -> DataGroups
    func row(collection: String, id: String) async throws -> DataRowDetail
    func createRow(collection: String, values: [String: JSONValue]) async throws -> DataRow
    func updateRow(collection: String, id: String, values: [String: JSONValue]) async throws -> DataRow
    func archiveRow(collection: String, id: String, archived: Bool) async throws -> DataRow
    /// Stores the file next to the row and appends it to the `file` column; a taken name gets a free one (`devis-2.pdf`).
    func attachFile(collection: String, id: String, column: String, name: String, data: Data, contentType: String) async throws -> DataRow
    func revertChange(id: String) async throws -> DataChange
    func searchData(_ query: String) async throws -> [DataSearchHit]

    func reminders(scope: ReminderScope, list: String?) async throws -> [Reminder]
    func createReminder(_ draft: ReminderDraft) async throws -> Reminder
    /// Partial update; `.null` clears a field.
    func updateReminder(id: String, patch: [String: JSONValue]) async throws -> Reminder
    func setReminderDone(id: String, done: Bool) async throws -> Reminder
    func snoozeReminder(id: String, until: Date) async throws -> Reminder
    func deleteReminder(id: String) async throws

    func reminderAreas() async throws -> [ReminderArea]
    func createArea(title: String, emoji: String?) async throws -> ReminderArea
    /// Partial update (`title`, `emoji`, `position`).
    func updateArea(id: String, patch: [String: JSONValue]) async throws -> ReminderArea
    /// Archives the area; its projects and reminders lose it.
    func deleteArea(id: String) async throws
    /// `status`: open, done, cancelled or all.
    func reminderProjects(status: String) async throws -> [ReminderProject]
    func project(id: String) async throws -> ProjectDetail
    func createProject(_ draft: ProjectDraft) async throws -> ReminderProject
    /// Partial update (`title`, `notes`, `emoji`, `color`, `areaId`, `deadline`, `someday`, `position`).
    func updateProject(id: String, patch: [String: JSONValue]) async throws -> ReminderProject
    /// Completes (or cancels) the project and, unless `keepOpenReminders`, its open reminders.
    func finishProject(id: String, cancel: Bool, keepOpenReminders: Bool) async throws -> ReminderProject
    func reopenProject(id: String) async throws -> ReminderProject
    /// Archives the project with its headings and reminders.
    func deleteProject(id: String) async throws
    func createHeading(projectId: String, title: String) async throws -> ProjectHeading
    /// Partial update (`title`, `position`).
    func updateHeading(id: String, patch: [String: JSONValue]) async throws -> ProjectHeading
    /// Archives the heading; its reminders stay in the project.
    func deleteHeading(id: String) async throws

    func places() async throws -> [Place]
    func createPlace(_ draft: PlaceDraft) async throws -> Place
    /// Partial update (`name`, `address`, `lat`, `lon`, `radiusM`).
    func updatePlace(id: String, patch: [String: JSONValue]) async throws -> Place
    /// Archives the place; reminders keep working until changed.
    func deletePlace(id: String) async throws

    func dashboards() async throws -> [DashboardSummary]
    func dashboard(slug: String) async throws -> Dashboard

    func docsTree() async throws -> [DocNode]
    func doc(path: String) async throws -> DocFile
    func saveDoc(path: String, content: String, baseSha: String?) async throws -> DocSaveResult
    func createDoc(path: String, content: String) async throws -> DocSaveResult
    /// Stores an image, a PDF or any file in the docs repo; a taken path gets a free name (`photo-2.png`).
    func uploadDocFile(path: String, data: Data, contentType: String) async throws -> DocUploadResult
    func dropDoc(path: String, ttlMinutes: Int) async throws -> DocDropLink
    func deleteDoc(path: String) async throws
    /// Moves or renames a file or a folder; never overwrites (409).
    func moveDoc(from: String, to: String) async throws -> DocMoveResult
    func createDocFolder(path: String) async throws
    /// Moves the folder and everything in it to the docs trash.
    func deleteDocFolder(path: String) async throws
    /// Pinned files and folders of the profile, in order.
    func docPins() async throws -> [String]
    func setDocPins(_ paths: [String]) async throws -> [String]
    func searchDocs(_ query: String) async throws -> [DocSearchHit]
}

extension NuoError {
    var isConflict: Bool { if case .server(409, _) = self { true } else { false } }
}
