import SwiftUI

/// Editing state of one document: autosave after a pause, conflict check through the sha the edits started from, and a
/// three-way merge when an agent or another device changed other lines meanwhile. One per path for the whole app
/// (`DocSessions`), shared by every view showing the document.
@MainActor @Observable
final class DocEditSession {
    enum Status: Equatable {
        case saved, edited, saving, conflict
        /// Could not reach the gateway: retried on its own.
        case failed(String)
        /// The gateway refused the save: not retried until the next edit or save.
        case refused(String)

        var label: String {
            switch self {
            case .saved: String(localized: "Saved")
            case .edited: String(localized: "Edited")
            case .saving: String(localized: "Saving…")
            case .conflict: String(localized: "Not saved: edited elsewhere")
            case .failed, .refused: String(localized: "Not saved")
            }
        }
    }

    let store: DocStore
    private(set) var text = ""
    /// Content the edits started from (last load or save): the common ancestor of a merge.
    private(set) var base: String?
    /// Sha of `base` on the gateway, sent with each save: a version written elsewhere since then is merged or
    /// surfaces as a conflict, never overwritten. Reloading the file does not move it while there are edits.
    @ObservationIgnored private(set) var baseSha: String?
    private(set) var status = Status.saved
    /// Presents the conflict alert.
    var conflict = false
    /// The conflict is with a document deleted or moved elsewhere: « Garder ma version » writes it again.
    private(set) var missing = false
    /// A save the gateway refused, for an alert.
    var error: String?
    /// « Continuer à modifier »: later autosaves try to merge again without asking every time.
    @ObservationIgnored private var quietConflicts = false
    /// Bumped when the content changed under the editors (reload, merge, another editor), so they show the new text.
    private(set) var externalRevision = 0
    @ObservationIgnored private var shownRevision: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Moves and deletions keep saves off the old path; one asked meanwhile runs on `resume`.
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var saveWhenResumed = false
    /// Reads each visual editor's Markdown; edits there only signal a change, the text is pulled when saving.
    @ObservationIgnored private var pulls: [ObjectIdentifier: () async -> String?] = [:]
    /// Visual editors changed since their text was last pulled, the latest last.
    @ObservationIgnored private var pendingEditors: [ObjectIdentifier] = []
    /// Called when nothing is left to save, so the registry can let the session go once no view shows it.
    @ObservationIgnored var onSettled: (() -> Void)?
    /// A visual editor changed since `text` was last pulled.
    private(set) var editorPending = false

    static let autosaveDelay = Duration.milliseconds(1000)
    static let conflictRetryDelay = Duration.seconds(5)
    static let failureRetryDelay = Duration.seconds(10)

    init(store: DocStore) {
        self.store = store
    }

    var path: String { store.path }

    var dirty: Bool { base != nil && (editorPending || text != base) }

    /// Nothing to save and no save running.
    var isSettled: Bool { !dirty && inFlight == nil }

    /// Unsaved edits the user should know about: a save that failed or a conflict.
    var needsAttention: Bool {
        switch status {
        case .conflict, .failed, .refused: dirty
        default: false
        }
    }

    /// The file as fetched. With unsaved edits, the content and the base sha stay: the next save sends that sha,
    /// so a newer version written elsewhere comes back as a conflict and goes through the merge.
    func loaded(_ file: DocFile) {
        guard base == nil || isSettled else { return }
        guard file.content != base || file.sha != baseSha else { return }
        let changed = file.content != base
        text = file.content
        base = file.content
        baseSha = file.sha
        if changed { bump(from: nil) }
    }

    // MARK: Editors

    func attachEditor(_ id: ObjectIdentifier, pull: @escaping () async -> String?) {
        pulls[id] = pull
    }

    /// After the editor's last edits were pulled (a save on leaving the document).
    func detachEditor(_ id: ObjectIdentifier) {
        pulls[id] = nil
        shownRevision[id] = nil
        pendingEditors.removeAll { $0 == id }
        if pendingEditors.isEmpty { editorPending = false }
    }

    /// Whether the editor still has to show `text` (it is behind `externalRevision`).
    func needsSync(_ id: ObjectIdentifier) -> Bool { shownRevision[id] != externalRevision }

    func synced(_ id: ObjectIdentifier) { shownRevision[id] = externalRevision }

    private func bump(from editor: ObjectIdentifier?) {
        externalRevision += 1
        // The editor the text came from already shows it, unless it was behind.
        if let editor, shownRevision[editor] == externalRevision - 1 { shownRevision[editor] = externalRevision }
    }

    func editorChanged(_ id: ObjectIdentifier) {
        guard base != nil else { return }
        editorPending = true
        pendingEditors.removeAll { $0 == id }
        pendingEditors.append(id)
        if status != .conflict { status = .edited }
        scheduleAutosave()
    }

    /// Brings `text` up to date with the visual editors that changed.
    func pullEditor() async {
        guard editorPending else { return }
        editorPending = false
        let ids = pendingEditors
        pendingEditors = []
        let start = text
        var pulled: [(id: ObjectIdentifier, markdown: String)] = []
        for id in ids {
            if let pull = pulls[id], let markdown = await pull() { pulled.append((id, markdown)) }
        }
        guard let first = pulled.first else { return }
        guard pulled.count > 1 else { return apply(first.markdown, from: first.id) }
        // Two windows of this document were both edited: each keeps the other's edits; on the same lines the
        // editor changed last wins.
        let combined = pulled.dropFirst().reduce(first.markdown) { result, next in
            DocMerge.merge(base: start, mine: result, theirs: next.markdown) ?? next.markdown
        }
        apply(combined, from: nil)
    }

    /// Edits from the raw Markdown editor or a checkbox ticked in the reader.
    func edited(_ markdown: String) {
        apply(markdown, from: nil)
    }

    private func apply(_ markdown: String, from editor: ObjectIdentifier?) {
        guard base != nil else { return }
        let changed = markdown != text
        text = markdown
        if changed { bump(from: editor) }
        guard dirty else {
            if status == .edited { status = .saved }
            return
        }
        if status != .conflict { status = .edited }
        scheduleAutosave()
    }

    // MARK: Saving

    private func scheduleAutosave() {
        autosave?.cancel()
        guard status != .conflict || quietConflicts else { return }
        let delay = status == .conflict ? Self.conflictRetryDelay : Self.autosaveDelay
        autosave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.save(explicit: false)
        }
    }

    /// Saves now, or right after the save already running. `explicit` saves show the conflict alert again.
    func save(force: Bool = false, explicit: Bool = true) async {
        autosave?.cancel()
        await pullEditor()
        while let running = inFlight { await running.value }
        // Checked after the wait: a move may have started meanwhile.
        if holds > 0 {
            saveWhenResumed = true
            return
        }
        guard dirty || force else { return }
        let task = Task { await self.perform(force: force, explicit: explicit) }
        inFlight = task
        await task.value
    }

    private func perform(force: Bool, explicit: Bool) async {
        defer {
            inFlight = nil
            if isSettled { onSettled?() }
        }
        var force = force
        for _ in 0..<3 {
            guard dirty || force else {
                status = .saved
                return
            }
            let snapshot = text
            status = .saving
            switch await store.save(snapshot, baseSha: force ? nil : baseSha) {
            case let .saved(file):
                base = snapshot
                baseSha = file.sha
                conflict = false
                missing = false
                quietConflicts = false
                status = dirty ? .edited : .saved
                if dirty { scheduleAutosave() }
                return
            case .conflict:
                force = false
                switch await merge() {
                case .merged: continue
                case .conflicting: break
                case .missing: missing = true
                case let .failed(message, retryable):
                    fail(String(localized: "Could not fetch the version saved elsewhere: \(message)"), retryable: retryable)
                    return
                }
            case let .failed(message, retryable):
                fail(message, retryable: retryable)
                return
            }
            break
        }
        status = .conflict
        if explicit || !quietConflicts { conflict = true }
    }

    private func fail(_ message: String, retryable: Bool) {
        autosave?.cancel()
        guard retryable else {
            status = .refused(message)
            error = message
            return
        }
        status = .failed(message)
        autosave = Task { [weak self] in
            try? await Task.sleep(for: Self.failureRetryDelay)
            guard !Task.isCancelled else { return }
            await self?.save(explicit: false)
        }
    }

    private enum MergeResult { case merged, conflicting, missing, failed(String, retryable: Bool) }

    private func merge() async -> MergeResult {
        await pullEditor()
        let snapshot = text
        let latest: DocFile
        switch await store.fetchLatest() {
        case let .file(file): latest = file
        case .missing: return .missing
        case let .failed(message, retryable): return .failed(message, retryable: retryable)
        }
        // Edits typed during the save and the fetch go on top of the merge instead of being replaced by it.
        await pullEditor()
        guard let base, var merged = DocMerge.merge(base: base, mine: snapshot, theirs: latest.content) else { return .conflicting }
        if text != snapshot {
            guard let withLatest = DocMerge.merge(base: snapshot, mine: text, theirs: merged) else { return .conflicting }
            merged = withLatest
        }
        store.adopt(latest)
        self.base = latest.content
        baseSha = latest.sha
        if merged != text {
            text = merged
            bump(from: nil)
        }
        return .merged
    }

    /// « Reprendre la sienne »: drop the local edits. False when the other version could not be fetched.
    @discardableResult
    func keepTheirs() async -> Bool {
        autosave?.cancel()
        while let running = inFlight { await running.value }
        guard case let .file(latest) = await store.fetchLatest() else { return false }
        autosave?.cancel()
        store.adopt(latest)
        conflict = false
        missing = false
        quietConflicts = false
        editorPending = false
        pendingEditors = []
        text = latest.content
        base = latest.content
        baseSha = latest.sha
        status = .saved
        bump(from: nil)
        onSettled?()
        return true
    }

    func overwrite() async {
        conflict = false
        quietConflicts = false
        status = .edited
        await save(force: true)
    }

    func continueEditing() {
        guard conflict else { return }
        conflict = false
        quietConflicts = true
        scheduleAutosave()
    }

    /// Shows the conflict alert again (« Résoudre… »).
    func reviewConflict() {
        guard status == .conflict else { return }
        conflict = true
    }

    // MARK: Moves

    func hold() { holds += 1 }

    /// Returns once no save is running.
    func idle() async {
        while let running = inFlight { await running.value }
    }

    func resume() {
        holds = max(0, holds - 1)
        guard holds == 0, saveWhenResumed || (dirty && status != .conflict) else { return }
        saveWhenResumed = false
        Task { await save(explicit: false) }
    }

    /// The document is gone (deleted): nothing is saved any more.
    func discard() {
        autosave?.cancel()
        autosave = nil
        holds = max(holds, 1)
        saveWhenResumed = false
    }

    /// Edits from the raw Markdown editor.
    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.edited($0) })
    }
}

/// Quiet « Enregistré » / « Enregistrement… » / « Non enregistré » with a dot, like Notion's sync indicator; it fades out
/// a few seconds after everything is saved.
struct SaveStatusLabel: View {
    let status: DocEditSession.Status
    let dirty: Bool
    @State private var visible = false
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            Text(status.label)
        }
        .font(.callout)
        .foregroundStyle(Color.text2)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: visible)
        .help(helpText)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .task(id: status) {
            defer { appeared = true }
            if !appeared, status == .saved { return }
            visible = true
            guard status == .saved else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { visible = false }
        }
    }

    private var dotColor: Color {
        switch status {
        case .saved: Color.good
        case .edited, .saving: Color.text3
        case .conflict, .failed, .refused: Color(hex: 0xE58A00)
        }
    }

    private var helpText: String {
        if case let .failed(message) = status { return String(localized: "\(message). Trying again in a few seconds.") }
        if case let .refused(message) = status { return String(localized: "\(message). Edit the document or save it to try again.") }
        return dirty ? String(localized: "Autosaving in a moment") : String(localized: "All changes are saved")
    }
}
