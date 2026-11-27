import CoreGraphics
import Foundation

/// In-memory data, reminders, dashboards and docs for `-demo`. Values are invented; nothing is real.
actor DemoWorkspace {
    static let shared = DemoWorkspace()

    private var collectionList: [DataCollection]
    private var rowsByCollection: [String: [DataRow]]
    private var history: [DataChange] = []
    private var reminderList: [Reminder]
    private var docs: [String: (content: String, sha: String, updatedAt: Date)]
    private var docDirs: Set<String>
    private var docFiles: [String: Data] = [:]
    private var dataFiles: [String: Data] = [:]
    private var docPinList: [String] = []
    private var placeList: [Place]
    private var areaList = DemoProjectsSeed.areas
    private var projectList = DemoProjectsSeed.projects
    private var headingList = DemoProjectsSeed.headings

    private init() {
        let seed = DemoWorkspaceSeed.make(now: Date())
        var collections = seed.collections
        var rows = seed.rows
        #if DEBUG
        if let count = DemoBulkRows.count {
            DemoBulkRows.add(count, to: &rows, collections: seed.collections, now: Date())
            collections.append(DemoBulkRows.transactions)
        }
        #endif
        collectionList = collections
        rowsByCollection = rows
        history = seed.history
        reminderList = DemoProjectsSeed.file(seed.reminders)
        docs = seed.docs
        docDirs = seed.dirs
        placeList = seed.places
    }

    /// Fills `refs` like the gateway: the title of the row each `ref` column points to.
    private func withRefs(_ row: DataRow, _ collectionId: String) -> DataRow {
        guard let collection = collectionList.first(where: { $0.id == collectionId }) else { return row }
        var row = row
        var refs: [String: String] = [:]
        for column in collection.columns where column.type == .ref {
            guard let target = column.ref, let id = row[column.name].string else { continue }
            if let title = rowsByCollection[target]?.first(where: { $0.id == id })?.title { refs[column.name] = title }
        }
        row.refs = refs.isEmpty ? nil : refs
        return row
    }

    private func pause() async { try? await Task.sleep(for: .milliseconds(140)) }

    // MARK: Data

    func collections() async -> [DataCollection] {
        await pause()
        return collectionList.map { collection in
            var copy = collection
            copy.count = rowsByCollection[collection.id, default: []].filter { $0.archivedAt == nil }.count
            return copy
        }
    }

    func rows(collection id: String, query: DataQuery, limit: Int, cursor: String?) async throws -> DataRowsPage {
        await pause()
        guard let collection = collectionList.first(where: { $0.id == id }) else { throw NuoError.notFound }
        var rows = matching(collection, query)
        let sort = query.sort ?? collection.defaultSort ?? "\(collection.titleColumn):asc"
        let parts = sort.split(separator: ":").map(String.init)
        let column = parts.first ?? collection.titleColumn
        let descending = parts.count > 1 && parts[1] == "desc"
        rows.sort { lhs, rhs in
            let ordered = Self.less(lhs[column], rhs[column])
            let reversed = Self.less(rhs[column], lhs[column])
            if !ordered && !reversed { return lhs.id < rhs.id }
            return descending ? reversed : ordered
        }
        let offset = Int(cursor ?? "") ?? 0
        let page = Array(rows.dropFirst(offset).prefix(limit))
        let next = offset + page.count < rows.count ? String(offset + page.count) : nil
        return DataRowsPage(rows: page.map { withRefs($0, id) }, nextCursor: next, total: rows.count)
    }

    func groups(collection id: String, by: String, query: DataQuery) async throws -> DataGroups {
        await pause()
        guard let collection = collectionList.first(where: { $0.id == id }) else { throw NuoError.notFound }
        let parts = by.split(separator: ":").map(String.init)
        guard let name = parts.first, let column = collection.column(name) else { throw NuoError.server(status: 400, message: "cannot group by \(by)") }
        let width = parts.count > 1 ? ["year": 4, "month": 7, "day": 10][parts[1]] : (column.type == .date || column.type == .datetime ? 4 : nil)
        let money = collection.columns.filter { $0.type == .money }
        var buckets: [JSONValue: [DataRow]] = [:]
        for row in matching(collection, query) {
            var key = row[name]
            if let width, let text = key.string { key = .string(String(text.prefix(width))) }
            if key.string == "" { key = .null }
            buckets[key, default: []].append(row)
        }
        let refs = column.ref.map { target in Dictionary(rowsByCollection[target, default: []].map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }) }
        let sums = { (rows: [DataRow]) in Dictionary(uniqueKeysWithValues: money.map { c in (c.name, rows.reduce(0) { $0 + ($1[c.name].double ?? 0) }) }) }
        let groups = buckets.map { key, rows in
            DataGroup(key: key, label: key.string.flatMap { refs?[$0] }, count: rows.count, sums: sums(rows))
        }.sorted { lhs, rhs in
            if lhs.key.isNull != rhs.key.isNull { return rhs.key.isNull }
            if refs != nil { return (lhs.label ?? "").localizedStandardCompare(rhs.label ?? "") == .orderedAscending }
            return width != nil ? Self.less(rhs.key, lhs.key) : Self.less(lhs.key, rhs.key)
        }
        let all = buckets.values.flatMap { $0 }
        return DataGroups(by: by, groups: groups, total: .init(count: all.count, sums: sums(all)))
    }

    private func matching(_ collection: DataCollection, _ query: DataQuery) -> [DataRow] {
        var rows = rowsByCollection[collection.id, default: []].filter { $0.archivedAt == nil }
        let search = query.search.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if !search.isEmpty {
            rows = rows.filter { row in
                let text = ([row.title] + collection.columns.filter { [.text, .longtext, .select].contains($0.type) }.compactMap { row[$0.name].string })
                    .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                return text.contains(search)
            }
        }
        for filter in query.filters {
            rows = rows.filter { Self.matches($0[filter.column], filter) }
        }
        return rows
    }

    private static func matches(_ value: JSONValue, _ filter: DataFilter) -> Bool {
        switch filter.op {
        case .empty: return value.isNull || value.string == ""
        case .notempty: return !(value.isNull || value.string == "")
        case .eq: return value.string == filter.value || value.stringArray.contains(filter.value)
        case .ne: return value.string != filter.value
        case .contains: return (value.string ?? "").localizedCaseInsensitiveContains(filter.value)
        case .in: return filter.value.split(separator: ",").map(String.init).contains(value.string ?? "")
        case .lt, .lte, .gt, .gte:
            let lhs = value.double.map { String(format: "%020.4f", $0) } ?? value.string ?? ""
            let rhs = Double(filter.value).map { String(format: "%020.4f", $0) } ?? filter.value
            switch filter.op {
            case .lt: return lhs < rhs
            case .lte: return lhs <= rhs
            case .gt: return lhs > rhs
            default: return lhs >= rhs
            }
        }
    }

    private static func less(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        if let a = lhs.double, let b = rhs.double, case .number = lhs { return a < b }
        return (lhs.string ?? "").localizedStandardCompare(rhs.string ?? "") == .orderedAscending
    }

    func row(collection: String, id: String) async throws -> DataRowDetail {
        await pause()
        guard let row = rowsByCollection[collection]?.first(where: { $0.id == id }) else { throw NuoError.notFound }
        let changes = history.filter { $0.collection == collection && $0.rowId == id }.sorted { $0.at > $1.at }
        return DataRowDetail(row: withRefs(row, collection), history: Array(changes.prefix(50)))
    }

    func createRow(collection id: String, values: [String: JSONValue]) async throws -> DataRow {
        guard let collection = collectionList.first(where: { $0.id == id }) else { throw NuoError.notFound }
        let rowId = "\(id.prefix(3))-\(UUID().uuidString.prefix(6).lowercased())"
        var row = DataRow(id: rowId, values: values, title: "", updatedAt: Date())
        row = DemoWorkspaceSeed.recompute(row, in: collection)
        rowsByCollection[id, default: []].append(row)
        record(collection: id, rowId: rowId, op: .insert, old: [:], new: values, source: "app")
        return row
    }

    func updateRow(collection id: String, rowId: String, values: [String: JSONValue], source: String = "app", op: DataChange.Op = .update) async throws -> DataRow {
        guard let collection = collectionList.first(where: { $0.id == id }),
              let index = rowsByCollection[id]?.firstIndex(where: { $0.id == rowId }) else { throw NuoError.notFound }
        var row = rowsByCollection[id]![index]
        let old = values.keys.reduce(into: [String: JSONValue]()) { $0[$1] = row[$1] }
        for (key, value) in values { row.values[key] = value }
        row.updatedAt = Date()
        row = DemoWorkspaceSeed.recompute(row, in: collection)
        rowsByCollection[id]![index] = row
        record(collection: id, rowId: rowId, op: op, old: old, new: values, source: source)
        return withRefs(row, id)
    }

    func attachFile(collection id: String, rowId: String, column: String, name: String, data: Data) async throws -> DataRow {
        guard let row = rowsByCollection[id]?.first(where: { $0.id == rowId }) else { throw NuoError.notFound }
        let files = ValueFormat.files(row[column])
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var stored = name
        var n = 2
        while files.contains(where: { $0.name == stored }) {
            stored = "\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        }
        let path = "\(id)/\(rowId)/\(stored)"
        dataFiles[path] = data
        let list = (files + [DataFileRef(name: stored, path: path)]).map { file -> JSONValue in
            var item: [String: JSONValue] = ["name": .string(file.name)]
            if let path = file.path { item["path"] = .string(path) }
            if let url = file.url { item["url"] = .string(url) }
            return .object(item)
        }
        return try await updateRow(collection: id, rowId: rowId, values: [column: .array(list)])
    }

    /// Seeded invoices have no stored bytes: they get a blank one-page PDF.
    func dataFile(_ path: String) -> Data? {
        if let data = dataFiles[path] { return data }
        guard path.lowercased().hasSuffix(".pdf") else { return nil }
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: pdf), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(CGRect(x: 48, y: 720, width: 300, height: 60))
        context.endPDFPage()
        context.closePDF()
        return pdf as Data
    }

    func archiveRow(collection id: String, rowId: String, archived: Bool) async throws -> DataRow {
        guard let index = rowsByCollection[id]?.firstIndex(where: { $0.id == rowId }) else { throw NuoError.notFound }
        rowsByCollection[id]![index].archivedAt = archived ? Date() : nil
        rowsByCollection[id]![index].updatedAt = Date()
        record(collection: id, rowId: rowId, op: archived ? .archive : .unarchive, old: [:], new: [:], source: "app")
        return rowsByCollection[id]![index]
    }

    func revert(changeId: String) async throws -> DataChange {
        guard let change = history.first(where: { $0.id == changeId }) else { throw NuoError.notFound }
        let restored = change.changes.reduce(into: [String: JSONValue]()) { $0[$1.key] = $1.value.first ?? .null }
        _ = try await updateRow(collection: change.collection, rowId: change.rowId, values: restored, op: .revert)
        return history.last!
    }

    private func record(collection: String, rowId: String, op: DataChange.Op, old: [String: JSONValue], new: [String: JSONValue], source: String) {
        let keys = Set(old.keys).union(new.keys)
        let changes = keys.reduce(into: [String: [JSONValue]]()) { $0[$1] = [old[$1] ?? .null, new[$1] ?? .null] }
        history.append(DataChange(id: "chg-\(UUID().uuidString.prefix(8).lowercased())", at: Date(), collection: collection, rowId: rowId, op: op, changes: changes, source: source))
    }

    func search(_ text: String) async -> [DataSearchHit] {
        await pause()
        let needle = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return [] }
        var hits: [DataSearchHit] = []
        for collection in collectionList {
            for row in rowsByCollection[collection.id, default: []] where row.archivedAt == nil {
                if row.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle) {
                    hits.append(DataSearchHit(collection: collection.id, row: withRefs(row, collection.id)))
                }
            }
        }
        return Array(hits.prefix(30))
    }

    // MARK: Reminders

    func reminders(scope: ReminderScope, list: String?) async -> [Reminder] {
        await pause()
        let now = Date()
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return reminderList.filter { reminder in
            if let list, reminder.list != list { return false }
            switch scope {
            case .all: return !reminder.isDone
            case .inbox: return !reminder.isDone && reminder.isUnfiled && !reminder.isSomeday && reminder.dueAt == nil && reminder.place == nil
            case .anytime: return !reminder.isDone && !reminder.isSomeday
            case .someday: return !reminder.isDone && reminder.isSomeday
            case .done: return reminder.isDone
            case .today: return !reminder.isDone && (reminder.effectiveDate.map { $0 < endOfToday } ?? false)
            case .overdue: return !reminder.isDone && (reminder.effectiveDate.map { $0 < now } ?? false)
            case .upcoming: return !reminder.isDone && (reminder.effectiveDate.map { $0 >= endOfToday } ?? true)
            }
        }
    }

    func createReminder(_ draft: ReminderDraft) async -> Reminder {
        let place = draft.placeId.flatMap { id in placeList.first { $0.id == id } }
        let reminder = Reminder(
            id: "rem-\(UUID().uuidString.prefix(6).lowercased())", title: draft.title, notes: draft.notes, dueAt: draft.dueAt,
            repeat: draft.repeat, list: draft.list ?? "inbox", priority: draft.priority ?? 0, doneAt: nil, snoozedUntil: nil,
            createdAt: Date(), updatedAt: Date(), place: place?.asReminderPlace, placeTrigger: place == nil ? nil : draft.placeTrigger ?? "arrive",
            someday: draft.someday, position: Double(reminderList.count + 1), checklist: draft.checklist)
        reminderList.append(reminder)
        var patch: [String: JSONValue] = [:]
        if let id = draft.headingId { patch["headingId"] = .string(id) } else if let id = draft.projectId { patch["projectId"] = .string(id) }
        if let id = draft.areaId { patch["areaId"] = .string(id) }
        return patch.isEmpty ? reminder : (try? await updateReminder(id: reminder.id, patch: patch)) ?? reminder
    }

    func updateReminder(id: String, patch: [String: JSONValue]) async throws -> Reminder {
        try mutateReminder(id) { reminder in
            for (key, value) in patch {
                switch key {
                case "title": reminder.title = value.string ?? reminder.title
                case "notes": reminder.notes = value.string
                case "dueAt": reminder.dueAt = value.string.flatMap(NuoJSON.parseDate); reminder.snoozedUntil = nil
                case "repeat": reminder.repeat = value.string
                case "list": reminder.list = value.string ?? reminder.list
                case "priority": reminder.priority = Int(value.double ?? 0)
                case "placeId":
                    reminder.place = value.string.flatMap { id in placeList.first { $0.id == id } }?.asReminderPlace
                    if reminder.place == nil { reminder.placeTrigger = nil } else if reminder.placeTrigger == nil { reminder.placeTrigger = "arrive" }
                case "placeTrigger": reminder.placeTrigger = reminder.place == nil ? nil : value.string
                case "projectId":
                    reminder.projectId = value.string
                    reminder.headingId = nil
                    if value.string != nil { reminder.areaId = nil }
                case "areaId":
                    reminder.areaId = value.string
                    if value.string != nil { reminder.projectId = nil; reminder.headingId = nil }
                case "headingId":
                    reminder.headingId = value.string
                    if let heading = headingList.first(where: { $0.id == value.string }) { reminder.projectId = heading.projectId; reminder.areaId = nil }
                case "someday": if case let .bool(flag) = value { reminder.someday = flag }
                case "position": reminder.position = value.double
                case "checklist":
                    if case let .array(items) = value {
                        reminder.checklist = items.compactMap { item in
                            guard case let .object(fields) = item, let title = fields["title"]?.string else { return nil }
                            if case let .bool(done) = fields["done"] { return ChecklistItem(title: title, done: done) }
                            return ChecklistItem(title: title, done: false)
                        }
                    } else {
                        reminder.checklist = nil
                    }
                default: break
                }
            }
        }
    }

    func setDone(id: String, done: Bool) async throws -> Reminder {
        try mutateReminder(id) { reminder in
            if done, let rule = reminder.repeat, let next = DemoWorkspace.nextOccurrence(rule, after: max(reminder.dueAt ?? Date(), Date())) {
                reminder.dueAt = next
                reminder.snoozedUntil = nil
            } else {
                reminder.doneAt = done ? Date() : nil
            }
        }
    }

    func snooze(id: String, until: Date) async throws -> Reminder {
        try mutateReminder(id) { $0.snoozedUntil = until }
    }

    func deleteReminder(id: String) async {
        reminderList.removeAll { $0.id == id }
    }

    private func mutateReminder(_ id: String, _ change: (inout Reminder) -> Void) throws -> Reminder {
        guard let index = reminderList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        change(&reminderList[index])
        reminderList[index].updatedAt = Date()
        reminderList[index] = resolved(reminderList[index])
        return reminderList[index]
    }

    static func nextOccurrence(_ rule: String, after date: Date) -> Date? {
        let calendar = Calendar.current
        switch rule {
        case "daily": return calendar.date(byAdding: .day, value: 1, to: date)
        case "weekly": return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case "monthly": return calendar.date(byAdding: .month, value: 1, to: date)
        case "yearly": return calendar.date(byAdding: .year, value: 1, to: date)
        default: return CronSpec(rule)?.next(after: date, timeZone: TimeZone(identifier: "Europe/Paris") ?? .current)
        }
    }

    // MARK: Places

    func places() async -> [Place] {
        await pause()
        return placeList
    }

    func createPlace(_ draft: PlaceDraft) async -> Place {
        let place = Place(id: "plc-\(UUID().uuidString.prefix(6).lowercased())", name: draft.name, address: draft.address, lat: draft.lat,
                          lon: draft.lon, radiusM: draft.radiusM ?? 150, createdAt: Date(), updatedAt: Date())
        placeList.append(place)
        return place
    }

    func updatePlace(id: String, patch: [String: JSONValue]) async throws -> Place {
        guard let index = placeList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        var place = placeList[index]
        if let name = patch["name"]?.string { place.name = name }
        if let address = patch["address"] { place.address = address.string }
        if let lat = patch["lat"]?.double { place.lat = lat }
        if let lon = patch["lon"]?.double { place.lon = lon }
        if let radius = patch["radiusM"]?.double { place.radiusM = radius }
        place.updatedAt = Date()
        placeList[index] = place
        for reminderIndex in reminderList.indices where reminderList[reminderIndex].place?.id == id {
            reminderList[reminderIndex].place = place.asReminderPlace
        }
        return place
    }

    func deletePlace(id: String) async {
        placeList.removeAll { $0.id == id }
    }

    // MARK: Dashboards

    func dashboards() async -> [DashboardSummary] {
        await pause()
        return [
            DashboardSummary(slug: "lumen", title: "Lumen Studio 2026", emoji: "💼", description: DemoDashboards.lumenDescription),
            DashboardSummary(slug: "patrimoine", title: DemoDashboards.networthTitle, emoji: "📈", description: DemoDashboards.networthDescription),
        ]
    }

    func dashboard(slug: String) async throws -> Dashboard {
        try? await Task.sleep(for: .milliseconds(380))
        let rows = rowsByCollection
        switch slug {
        case "lumen": return DemoDashboards.lumen(rows: rows)
        case "patrimoine": return DemoDashboards.patrimoine(rows: rows)
        default: throw NuoError.notFound
        }
    }

    // MARK: Docs

    func tree() async -> [DocNode] {
        await pause()
        let dirs = allDocDirs().map { DocNode(path: $0, name: ($0 as NSString).lastPathComponent, kind: .dir, updatedAt: nil, size: nil) }
        let files = docs.map { path, file in
            DocNode(path: path, name: (path as NSString).lastPathComponent, kind: .file, updatedAt: file.updatedAt, size: file.content.utf8.count)
        }
        let attachments = docFiles.map { path, data in
            DocNode(path: path, name: (path as NSString).lastPathComponent, kind: .file, updatedAt: nil, size: data.count)
        }
        return (dirs + files + attachments).sorted { $0.path < $1.path }
    }

    func uploadDocFile(path: String, data: Data) async -> DocUploadResult {
        await pause()
        let ext = (path as NSString).pathExtension
        let stem = ext.isEmpty ? path : String(path.dropLast(ext.count + 1))
        var candidate = path
        var n = 2
        while docFiles[candidate] != nil || docs[candidate] != nil {
            candidate = "\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        }
        docFiles[candidate] = data
        return DocUploadResult(path: candidate, size: data.count)
    }

    func docFile(_ path: String) -> Data? { docFiles[path] }

    func doc(path: String) async throws -> DocFile {
        await pause()
        guard let file = docs[path] else { throw NuoError.notFound }
        return DocFile(path: path, content: file.content, sha: file.sha, updatedAt: file.updatedAt)
    }

    func saveDoc(path: String, content: String, baseSha: String?) async throws -> DocSaveResult {
        try? await Task.sleep(for: .milliseconds(250))
        if let baseSha, let current = docs[path], current.sha != baseSha {
            throw NuoError.server(status: 409, message: String(localized: "The document was changed in the meantime."))
        }
        let sha = String(UUID().uuidString.prefix(10).lowercased())
        docs[path] = (content, sha, Date())
        return DocSaveResult(path: path, sha: sha, updatedAt: Date())
    }

    func createDoc(path: String, content: String) async throws -> DocSaveResult {
        guard docs[path] == nil else { throw NuoError.server(status: 409, message: String(localized: "A document already exists at this location.")) }
        return try await saveDoc(path: path, content: content, baseSha: nil)
    }

    func deleteDoc(path: String) async {
        keepParent(of: path)
        docs[path] = nil
        updatePins { $0 == path ? nil : $0 }
    }

    /// Folders listed by the gateway: the created ones and every parent of a document.
    private func allDocDirs() -> Set<String> {
        var dirs = docDirs
        for path in docs.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                dirs.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return dirs
    }

    /// The gateway keeps a folder emptied by a move or a deletion.
    private func keepParent(of path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty { docDirs.insert(parent) }
    }

    func moveDoc(from: String, to: String) async throws -> DocMoveResult {
        await pause()
        let dirs = allDocDirs()
        let isDir = dirs.contains(from)
        guard isDir || docs[from] != nil else { throw NuoError.notFound }
        if from == to { return DocMoveResult(path: to, kind: isDir ? .dir : .file) }
        if isDir && to.hasPrefix(from + "/") { throw NuoError.server(status: 400, message: "cannot move a folder into itself") }
        if docs[to] != nil || dirs.contains(to) { throw NuoError.server(status: 409, message: "an item already exists at this path") }
        if docs[(to as NSString).deletingLastPathComponent] != nil { throw NuoError.server(status: 400, message: "the destination folder is a file") }
        keepParent(of: from)
        if isDir {
            let prefix = from + "/"
            for (path, file) in docs where path.hasPrefix(prefix) {
                docs[path] = nil
                docs[to + "/" + path.dropFirst(prefix.count)] = file
            }
            docDirs = Set(docDirs.compactMap { dir in
                if dir == from { return to }
                return dir.hasPrefix(prefix) ? to + "/" + dir.dropFirst(prefix.count) : dir
            })
        } else {
            docs[to] = docs.removeValue(forKey: from)
        }
        updatePins { $0 == from ? to : $0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0 }
        return DocMoveResult(path: to, kind: isDir ? .dir : .file)
    }

    func docPins() async -> [String] {
        await pause()
        let dirs = allDocDirs()
        return docPinList.filter { docs[$0] != nil || dirs.contains($0) }
    }

    func setDocPins(_ paths: [String]) async -> [String] {
        var seen = Set<String>()
        docPinList = paths.filter { seen.insert($0).inserted }
        return await docPins()
    }

    private func updatePins(_ map: (String) -> String?) {
        var seen = Set<String>()
        docPinList = docPinList.compactMap(map).filter { seen.insert($0).inserted }
    }

    func createDocFolder(path: String) async throws {
        await pause()
        guard docs[path] == nil, !allDocDirs().contains(path) else {
            throw NuoError.server(status: 409, message: "an item already exists at this path")
        }
        docDirs.insert(path)
    }

    func deleteDocFolder(path: String) async throws {
        await pause()
        guard allDocDirs().contains(path) else { throw NuoError.notFound }
        keepParent(of: path)
        let prefix = path + "/"
        docs = docs.filter { !$0.key.hasPrefix(prefix) }
        docDirs = docDirs.filter { $0 != path && !$0.hasPrefix(prefix) }
        updatePins { $0 == path || $0.hasPrefix(prefix) ? nil : $0 }
    }

    func searchDocs(_ text: String) async -> [DocSearchHit] {
        await pause()
        var hits: [DocSearchHit] = []
        for (path, file) in docs.sorted(by: { $0.key < $1.key }) {
            for (index, line) in file.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.localizedCaseInsensitiveContains(text) {
                hits.append(DocSearchHit(path: path, line: index + 1, snippet: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return Array(hits.prefix(50))
    }
}

// MARK: - Areas and projects

extension DemoWorkspace {
    /// Embeds the project and area like the gateway does.
    private func resolved(_ reminder: Reminder) -> Reminder {
        var reminder = reminder
        let project = projectList.first { $0.id == reminder.projectId }
        reminder.project = project.map { ReminderRef(id: $0.id, title: $0.title, emoji: $0.emoji) }
        let areaId = reminder.projectId == nil ? reminder.areaId : project?.areaId
        reminder.areaId = areaId
        reminder.area = areaList.first { $0.id == areaId }.map { ReminderRef(id: $0.id, title: $0.title, emoji: $0.emoji) }
        return reminder
    }

    private func counted(_ project: ReminderProject) -> ReminderProject {
        var project = project
        let items = reminderList.filter { $0.projectId == project.id }
        project.openCount = items.filter { !$0.isDone }.count
        project.doneCount = items.filter(\.isDone).count
        project.progress = items.isEmpty ? (project.status == .done ? 1 : 0) : Double(project.doneCount) / Double(items.count)
        return project
    }

    func resolveAll() {
        reminderList = reminderList.map(resolved)
    }

    func areas() async -> [ReminderArea] { areaList.sorted { $0.position < $1.position } }

    func createArea(title: String, emoji: String?) async -> ReminderArea {
        let area = ReminderArea(id: "area-\(UUID().uuidString.prefix(6).lowercased())", title: title, emoji: emoji, position: Double(areaList.count + 1))
        areaList.append(area)
        return area
    }

    func updateArea(id: String, patch: [String: JSONValue]) async throws -> ReminderArea {
        guard let index = areaList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        if let title = patch["title"]?.string { areaList[index].title = title }
        if let emoji = patch["emoji"] { areaList[index].emoji = emoji.string }
        if let position = patch["position"]?.double { areaList[index].position = position }
        resolveAll()
        return areaList[index]
    }

    func deleteArea(id: String) async {
        areaList.removeAll { $0.id == id }
        for index in projectList.indices where projectList[index].areaId == id { projectList[index].areaId = nil }
        for index in reminderList.indices where reminderList[index].areaId == id { reminderList[index].areaId = nil }
        resolveAll()
    }

    func projects(status: String) async -> [ReminderProject] {
        projectList.filter { status == "all" || $0.status.rawValue == status }.map(counted).sorted { ($0.someday ? 1 : 0, $0.position) < ($1.someday ? 1 : 0, $1.position) }
    }

    func project(id: String) async throws -> ProjectDetail {
        guard let project = projectList.first(where: { $0.id == id }) else { throw NuoError.notFound }
        let items = reminderList.filter { $0.projectId == id }
        return ProjectDetail(project: counted(project), headings: headingList.filter { $0.projectId == id }.sorted { $0.position < $1.position },
                             reminders: items.filter { !$0.isDone }.sorted { ($0.position ?? 0) < ($1.position ?? 0) } + items.filter(\.isDone))
    }

    func createProject(_ draft: ProjectDraft) async -> ReminderProject {
        let project = ReminderProject(id: "prj-\(UUID().uuidString.prefix(6).lowercased())", title: draft.title, notes: draft.notes, emoji: draft.emoji,
                                      areaId: draft.areaId, deadline: draft.deadline, someday: draft.someday ?? false, status: .open,
                                      position: Double(projectList.count + 1), openCount: 0, doneCount: 0, progress: 0)
        projectList.append(project)
        return project
    }

    func updateProject(id: String, patch: [String: JSONValue]) async throws -> ReminderProject {
        guard let index = projectList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        for (key, value) in patch {
            switch key {
            case "title": projectList[index].title = value.string ?? projectList[index].title
            case "notes": projectList[index].notes = value.string
            case "emoji": projectList[index].emoji = value.string
            case "color": projectList[index].color = value.string
            case "areaId": projectList[index].areaId = value.string
            case "deadline": projectList[index].deadline = value.string
            case "someday": if case let .bool(flag) = value { projectList[index].someday = flag }
            case "position": projectList[index].position = value.double ?? projectList[index].position
            default: break
            }
        }
        resolveAll()
        return counted(projectList[index])
    }

    func finishProject(id: String, cancel: Bool, keepOpenReminders: Bool) async throws -> ReminderProject {
        guard let index = projectList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        if !keepOpenReminders {
            for i in reminderList.indices where reminderList[i].projectId == id && !reminderList[i].isDone { reminderList[i].doneAt = Date() }
        }
        projectList[index].status = cancel ? .cancelled : .done
        projectList[index].doneAt = Date()
        return counted(projectList[index])
    }

    func reopenProject(id: String) async throws -> ReminderProject {
        guard let index = projectList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        projectList[index].status = .open
        projectList[index].doneAt = nil
        return counted(projectList[index])
    }

    func deleteProject(id: String) async {
        projectList.removeAll { $0.id == id }
        headingList.removeAll { $0.projectId == id }
        reminderList.removeAll { $0.projectId == id }
    }

    func createHeading(projectId: String, title: String) async -> ProjectHeading {
        let heading = ProjectHeading(id: "hd-\(UUID().uuidString.prefix(6).lowercased())", projectId: projectId, title: title,
                                     position: Double(headingList.filter { $0.projectId == projectId }.count + 1))
        headingList.append(heading)
        return heading
    }

    func updateHeading(id: String, patch: [String: JSONValue]) async throws -> ProjectHeading {
        guard let index = headingList.firstIndex(where: { $0.id == id }) else { throw NuoError.notFound }
        if let title = patch["title"]?.string { headingList[index].title = title }
        if let position = patch["position"]?.double { headingList[index].position = position }
        return headingList[index]
    }

    func deleteHeading(id: String) async {
        headingList.removeAll { $0.id == id }
        for index in reminderList.indices where reminderList[index].headingId == id { reminderList[index].headingId = nil }
    }
}

extension DemoBackend {
    private var workspace: DemoWorkspace { DemoWorkspace.shared }

    func reminderAreas() async throws -> [ReminderArea] { await workspace.areas() }
    func createArea(title: String, emoji: String?) async throws -> ReminderArea { await workspace.createArea(title: title, emoji: emoji) }
    func updateArea(id: String, patch: [String: JSONValue]) async throws -> ReminderArea { try await workspace.updateArea(id: id, patch: patch) }
    func deleteArea(id: String) async throws { await workspace.deleteArea(id: id) }
    func reminderProjects(status: String) async throws -> [ReminderProject] { await workspace.projects(status: status) }
    func project(id: String) async throws -> ProjectDetail { try await workspace.project(id: id) }
    func createProject(_ draft: ProjectDraft) async throws -> ReminderProject { await workspace.createProject(draft) }
    func updateProject(id: String, patch: [String: JSONValue]) async throws -> ReminderProject { try await workspace.updateProject(id: id, patch: patch) }
    func finishProject(id: String, cancel: Bool, keepOpenReminders: Bool) async throws -> ReminderProject {
        try await workspace.finishProject(id: id, cancel: cancel, keepOpenReminders: keepOpenReminders)
    }
    func reopenProject(id: String) async throws -> ReminderProject { try await workspace.reopenProject(id: id) }
    func deleteProject(id: String) async throws { await workspace.deleteProject(id: id) }
    func createHeading(projectId: String, title: String) async throws -> ProjectHeading { await workspace.createHeading(projectId: projectId, title: title) }
    func updateHeading(id: String, patch: [String: JSONValue]) async throws -> ProjectHeading { try await workspace.updateHeading(id: id, patch: patch) }
    func deleteHeading(id: String) async throws { await workspace.deleteHeading(id: id) }

    func collections() async throws -> [DataCollection] { await workspace.collections() }
    func rows(collection: String, query: DataQuery, limit: Int, cursor: String?) async throws -> DataRowsPage {
        try await workspace.rows(collection: collection, query: query, limit: limit, cursor: cursor)
    }
    func groups(collection: String, by: String, query: DataQuery) async throws -> DataGroups {
        try await workspace.groups(collection: collection, by: by, query: query)
    }
    func row(collection: String, id: String) async throws -> DataRowDetail { try await workspace.row(collection: collection, id: id) }
    func createRow(collection: String, values: [String: JSONValue]) async throws -> DataRow {
        try await workspace.createRow(collection: collection, values: values)
    }
    func updateRow(collection: String, id: String, values: [String: JSONValue]) async throws -> DataRow {
        try await workspace.updateRow(collection: collection, rowId: id, values: values)
    }
    func archiveRow(collection: String, id: String, archived: Bool) async throws -> DataRow {
        try await workspace.archiveRow(collection: collection, rowId: id, archived: archived)
    }
    func attachFile(collection: String, id: String, column: String, name: String, data: Data, contentType: String) async throws -> DataRow {
        try await workspace.attachFile(collection: collection, rowId: id, column: column, name: name, data: data)
    }
    func revertChange(id: String) async throws -> DataChange { try await workspace.revert(changeId: id) }
    func searchData(_ query: String) async throws -> [DataSearchHit] { await workspace.search(query) }

    func reminders(scope: ReminderScope, list: String?) async throws -> [Reminder] { await workspace.reminders(scope: scope, list: list) }
    func createReminder(_ draft: ReminderDraft) async throws -> Reminder { await workspace.createReminder(draft) }
    func updateReminder(id: String, patch: [String: JSONValue]) async throws -> Reminder { try await workspace.updateReminder(id: id, patch: patch) }
    func setReminderDone(id: String, done: Bool) async throws -> Reminder { try await workspace.setDone(id: id, done: done) }
    func snoozeReminder(id: String, until: Date) async throws -> Reminder { try await workspace.snooze(id: id, until: until) }
    func deleteReminder(id: String) async throws { await workspace.deleteReminder(id: id) }

    func places() async throws -> [Place] { await workspace.places() }
    func createPlace(_ draft: PlaceDraft) async throws -> Place { await workspace.createPlace(draft) }
    func updatePlace(id: String, patch: [String: JSONValue]) async throws -> Place { try await workspace.updatePlace(id: id, patch: patch) }
    func deletePlace(id: String) async throws { await workspace.deletePlace(id: id) }

    func dashboards() async throws -> [DashboardSummary] { await workspace.dashboards() }
    func dashboard(slug: String) async throws -> Dashboard { try await workspace.dashboard(slug: slug) }

    func docsTree() async throws -> [DocNode] { await workspace.tree() }
    func doc(path: String) async throws -> DocFile { try await workspace.doc(path: path) }
    func saveDoc(path: String, content: String, baseSha: String?) async throws -> DocSaveResult {
        try await workspace.saveDoc(path: path, content: content, baseSha: baseSha)
    }
    func createDoc(path: String, content: String) async throws -> DocSaveResult { try await workspace.createDoc(path: path, content: content) }
    func uploadDocFile(path: String, data: Data, contentType: String) async throws -> DocUploadResult { await workspace.uploadDocFile(path: path, data: data) }
    func dropDoc(path: String, ttlMinutes: Int) async throws -> DocDropLink {
        DocDropLink(url: URL(string: "https://drop.example.com/s/drop-5c2e81a4d7f0/")!, expiresAt: ttlMinutes == 0 ? nil : Date().addingTimeInterval(Double(ttlMinutes) * 60))
    }
    func deleteDoc(path: String) async throws { await workspace.deleteDoc(path: path) }
    func moveDoc(from: String, to: String) async throws -> DocMoveResult { try await workspace.moveDoc(from: from, to: to) }
    func createDocFolder(path: String) async throws { try await workspace.createDocFolder(path: path) }
    func deleteDocFolder(path: String) async throws { try await workspace.deleteDocFolder(path: path) }
    func docPins() async throws -> [String] { await workspace.docPins() }
    func setDocPins(_ paths: [String]) async throws -> [String] { await workspace.setDocPins(paths) }
    func searchDocs(_ query: String) async throws -> [DocSearchHit] { await workspace.searchDocs(query) }
}
