import SwiftUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

/// Settings › Secrets: the env files of the gateway's machine (`~/.secrets`), grouped by file. The list
/// only has names; each reveal, copy, addition, change or deletion asks Face ID and goes to the security log.
struct SecretsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: SecretsState?
    @State private var error: String?
    @State private var notice: String?
    @State private var query = ""
    @State private var revealed: [SecretRef: String] = [:]
    @State private var busy: SecretRef?
    @State private var editor: SecretEditor?
    @State private var deleting: SecretRef?
    @State private var hideTask: Task<Void, Never>?

    private var api: (any NuoSecretsAPI)? { session.api as? any NuoSecretsAPI }

    private var sources: [SecretSource] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return state?.sources ?? [] }
        return (state?.sources ?? []).compactMap { source in
            if source.id.localizedCaseInsensitiveContains(q) || (source.usedBy?.localizedCaseInsensitiveContains(q) ?? false) { return source }
            var filtered = source
            filtered.entries = source.entries.filter { $0.key.localizedCaseInsensitiveContains(q) }
            return filtered.entries.isEmpty ? nil : filtered
        }
    }

    var body: some View {
        GroupedList {
            if let error {
                Section { Text(error).foregroundStyle(Color.bad) }.cardRows()
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Color.ink) }.cardRows()
            }
            #if os(macOS)
            Section {
                TextField("Search for a secret or a file", text: $query)
            }
            #endif
            if let state, !state.configured {
                Section {
                    Label("The folder \(state.root) doesn't exist on the gateway.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.text2)
                }
                .cardRows()
            }
            ForEach(sources) { source in
                Section {
                    if source.entries.isEmpty {
                        Text("No variables").foregroundStyle(Color.text3)
                    }
                    ForEach(source.entries, id: \.key) { entry in
                        let ref = SecretRef(source: source.id, key: entry.key)
                        SecretRow(
                            entry: entry,
                            value: revealed[ref],
                            busy: busy == ref,
                            onToggle: { Task { await toggle(ref) } },
                            onCopy: { Task { await copy(ref) } },
                            onEdit: { editor = SecretEditor(source: source.id, key: entry.key, value: revealed[ref] ?? "") },
                            onDelete: { deleting = ref }
                        )
                    }
                } header: {
                    SourceHeader(source: source)
                } footer: {
                    SourceFooter(source: source)
                }
                .cardRows()
            }
            if state?.configured == true {
                Section {
                    Button {
                        editor = SecretEditor(source: sources.first?.id ?? state?.sources.first?.id ?? "", key: nil, value: "")
                    } label: {
                        Label("Add a Secret", systemImage: "plus.circle.fill").foregroundStyle(Color.accent)
                    }
                } footer: {
                    Text("Every display, copy or change asks for Face ID and shows up in “Security Activity”. Services reread their files the next time they start.")
                }
                .cardRows()
            }
        }
        .overlay {
            if state == nil && error == nil {
                ProgressView()
            } else if let state, state.configured, sources.isEmpty {
                ContentUnavailableView(query.isEmpty ? String(localized: "No Secret Files") : String(localized: "No Results"), systemImage: "key", description: Text(query.isEmpty ? String(localized: "Add a secret to create the first file.") : String(localized: "No name or file contains “\(query)”.")))
            }
        }
        #if os(iOS)
        .searchable(text: $query, prompt: "Search for a secret or a file")
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Secrets")
        .task { await load() }
        .refreshable { await load() }
        .onDisappear { hideAll() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { hideAll() } }
        .sheet(item: $editor) { draft in
            SecretEditorSheet(draft: draft, sources: state?.sources ?? []) { saved in
                editor = nil
                Task { await save(saved) }
            }
        }
        .confirmationDialog(
            deleting.map { String(localized: "Delete \($0.key)?") } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let ref = deleting else { return }
                Task { await delete(ref) }
            }
        } message: {
            if let ref = deleting {
                Text("The \(ref.key) line is removed from \(ref.source) on the gateway. Services that read it won't find it the next time they start. This can't be undone.")
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let api else { return }
        do {
            state = try await api.secrets()
            error = nil
            if SecretsDemo.revealsOne, let source = state?.sources.dropFirst().first, let entry = source.entries.last {
                revealed[SecretRef(source: source.id, key: entry.key)] = try? await api.revealSecret(source: source.id, key: entry.key)
            }
        } catch NuoError.notFound {
            error = String(localized: "Secrets are only available on the main profile of an up-to-date gateway.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reveal(_ ref: SecretRef) async -> String? {
        if let value = revealed[ref] { return value }
        guard let api else { return nil }
        busy = ref
        defer { busy = nil }
        do {
            let value = try await api.revealSecret(source: ref.source, key: ref.key)
            error = nil
            return value
        } catch NuoError.stepUpCancelled {
            return nil
        } catch {
            Haptics.error()
            self.error = message(for: error)
            return nil
        }
    }

    private func toggle(_ ref: SecretRef) async {
        if revealed[ref] != nil {
            revealed[ref] = nil
            return
        }
        guard let value = await reveal(ref) else { return }
        revealed[ref] = value
        scheduleHide()
    }

    private func copy(_ ref: SecretRef) async {
        guard let value = await reveal(ref) else { return }
        SecretPasteboard.copy(value)
        Haptics.success()
        notice = String(localized: "\(ref.key) copied. The clipboard clears in 90 seconds.")
    }

    private func save(_ draft: SecretEditor.Saved) async {
        guard let api else { return }
        do {
            let source: SecretSource
            if draft.isNew {
                source = try await api.createSecret(source: draft.source, key: draft.key, value: draft.value, createSource: draft.newFile)
                notice = String(localized: "\(draft.key) added to \(draft.source).")
            } else {
                source = try await api.updateSecret(source: draft.source, key: draft.key, value: draft.value)
                notice = String(localized: "\(draft.key) changed in \(draft.source).")
            }
            revealed[SecretRef(source: draft.source, key: draft.key)] = nil
            replace(source)
            Haptics.success()
            error = nil
        } catch NuoError.stepUpCancelled {
            return
        } catch {
            Haptics.error()
            self.error = message(for: error)
        }
    }

    private func delete(_ ref: SecretRef) async {
        guard let api else { return }
        do {
            replace(try await api.deleteSecret(source: ref.source, key: ref.key))
            revealed[ref] = nil
            Haptics.success()
            notice = String(localized: "\(ref.key) deleted from \(ref.source).")
            error = nil
        } catch NuoError.stepUpCancelled {
            return
        } catch {
            Haptics.error()
            self.error = message(for: error)
        }
    }

    private func replace(_ source: SecretSource) {
        guard var current = state else { return }
        if let index = current.sources.firstIndex(where: { $0.id == source.id }) {
            current.sources[index] = source
        } else {
            current.sources.append(source)
        }
        state = current
    }

    /// Revealed values stay on screen 30 seconds at most.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            revealed = [:]
        }
    }

    private func hideAll() {
        hideTask?.cancel()
        revealed = [:]
    }

    private func message(for error: Error) -> String {
        switch error {
        case NuoError.notFound: String(localized: "Not found on the gateway: the list changed. Refresh.")
        case let NuoError.server(status, _) where status == 409: String(localized: "This name already exists in this file: edit the existing line.")
        case let NuoError.server(status, message) where status == 400: String(localized: "Refused by the gateway: \(message)")
        case NuoError.unauthorized: String(localized: "The gateway refused the confirmation. Try again.")
        case let NuoError.server(status, message) where status == 403 && message.contains("home or the VPN"):
            String(localized: "Secrets can only be shown and changed from the gateway's network.")
        case let NuoError.server(status, _) where status == 429: String(localized: "Too many operations on secrets: try again in a few minutes.")
        default: error.localizedDescription
        }
    }
}

struct SecretRef: Hashable {
    let source: String
    let key: String
}

private struct SecretRow: View {
    let entry: SecretSource.Entry
    let value: String?
    let busy: Bool
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.key)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if let value {
                        // No text selection: the system Copy would skip the local-only, expiring pasteboard of the copy button.
                        Text(value.isEmpty ? String(localized: "(empty)") : value)
                            .foregroundStyle(value.isEmpty ? Color.text3 : Color.text2)
                            .lineLimit(3)
                    } else {
                        Text(verbatim: "••••••••••••").foregroundStyle(Color.text3)
                    }
                }
                .font(.system(.footnote, design: .monospaced))
            }
            Spacer(minLength: Spacing.xs)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: onToggle) {
                    Image(systemName: value == nil ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.text2)
                .accessibilityLabel(value == nil ? String(localized: "Show \(entry.key)") : String(localized: "Hide \(entry.key)"))
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.text2)
                .accessibilityLabel("Copy \(entry.key)")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(value == nil ? String(localized: "Show") : String(localized: "Hide"), systemImage: value == nil ? "eye" : "eye.slash", action: onToggle)
            Button("Copy Value", systemImage: "doc.on.doc", action: onCopy)
            Button("Copy Name", systemImage: "textformat") { SecretPasteboard.copyName(entry.key) }
            Button("Edit…", systemImage: "pencil", action: onEdit)
            Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
        }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            Button("Edit", systemImage: "pencil", action: onEdit).tint(Color.text2)
        }
        #endif
    }
}

private struct SourceHeader: View {
    let source: SecretSource

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
            Text(source.id).textCase(nil)
            Spacer()
            Text(verbatim: "\(source.entries.count)").monospacedDigit()
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(Color.text3)
    }
}

private struct SourceFooter: View {
    let source: SecretSource

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let usedBy = source.usedBy { Text("Read by \(usedBy)") }
            Text(verbatim: [source.path, source.link.map { String(localized: "link \($0)") }, String(localized: "modified \(source.modifiedAt.formatted(.relative(presentation: .named)))")].compactMap { $0 }.joined(separator: " · "))
            if source.insecure {
                Label("Permissions \(source.mode): readable by other users of the machine (chmod 600 recommended).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.bad)
            }
        }
    }
}

// MARK: - Editor

struct SecretEditor: Identifiable {
    var source: String
    /// Nil for a new secret.
    var key: String?
    var value: String
    let id = UUID()

    struct Saved {
        let source: String
        let key: String
        let value: String
        let isNew: Bool
        let newFile: Bool
    }
}

private struct SecretEditorSheet: View {
    let draft: SecretEditor
    let sources: [SecretSource]
    let onSave: (SecretEditor.Saved) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var newFile = ""
    @State private var key = ""
    @State private var value = ""
    @State private var showsValue = false

    private static let newFileTag = "\u{0}new"
    private var isNew: Bool { draft.key == nil }
    private var creatingFile: Bool { source == Self.newFileTag }
    private var targetSource: String { creatingFile ? newFile.trimmingCharacters(in: .whitespaces) : source }
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }

    private var keyProblem: String? {
        guard isNew, !trimmedKey.isEmpty else { return nil }
        if !SecretKey.isValid(trimmedKey) { return String(localized: "Letters, digits and _ only, not starting with a digit.") }
        if !creatingFile, sources.first(where: { $0.id == source })?.entries.contains(where: { $0.key == trimmedKey }) == true { return String(localized: "This name already exists in this file.") }
        return nil
    }

    private var fileProblem: String? {
        guard creatingFile, !newFile.isEmpty else { return nil }
        if !SecretKey.isValidFileName(targetSource) { return String(localized: "A name ending in .env, optionally in an existing subfolder (projects/…).") }
        if sources.contains(where: { $0.id == targetSource }) { return String(localized: "This file already exists.") }
        return nil
    }

    private var canSave: Bool {
        !targetSource.isEmpty && !trimmedKey.isEmpty && keyProblem == nil && fileProblem == nil && !value.contains("\n")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isNew {
                        Picker("File", selection: $source) {
                            ForEach(sources) { Text($0.id).tag($0.id) }
                            Text("New File…").tag(Self.newFileTag)
                        }
                        if creatingFile {
                            TextField(text: $newFile) { Text(verbatim: "projects/stripe.env") }
                                .font(.system(.body, design: .monospaced))
                                .secretInput()
                            if let fileProblem { Text(fileProblem).font(.footnote).foregroundStyle(Color.bad) }
                        }
                        TextField("SECRET_NAME", text: $key)
                            .font(.system(.body, design: .monospaced))
                            .secretInput()
                        if let keyProblem { Text(keyProblem).font(.footnote).foregroundStyle(Color.bad) }
                    } else {
                        LabeledContent("File") { Text(draft.source).font(.system(.body, design: .monospaced)).foregroundStyle(Color.text2) }
                        LabeledContent("Name") { Text(draft.key ?? "").font(.system(.body, design: .monospaced)).foregroundStyle(Color.text2) }
                    }
                }
                Section {
                    HStack {
                        Group {
                            if showsValue {
                                TextField("Value", text: $value)
                            } else {
                                SecureField("Value", text: $value)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .secretInput()
                        Button {
                            showsValue.toggle()
                        } label: {
                            Image(systemName: showsValue ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.text2)
                        .accessibilityLabel(showsValue ? String(localized: "Hide Value") : String(localized: "Show Value"))
                    }
                } header: {
                    Text(isNew ? String(localized: "Value") : String(localized: "New value"))
                } footer: {
                    Text(isNew ? String(localized: "The NAME=value line is added at the end of the file, which keeps its permissions.") : String(localized: "Only this line changes; the file's export, quotes and comments are kept."))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? String(localized: "New Secret") : String(localized: "Edit Secret"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(.init(source: isNew ? targetSource : draft.source, key: isNew ? trimmedKey : draft.key ?? "", value: value, isNew: isNew, newFile: isNew && creatingFile))
                    }
                    .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 340)
        #endif
        .onAppear {
            source = draft.source.isEmpty ? Self.newFileTag : draft.source
            key = draft.key ?? ""
            value = draft.value
        }
    }
}

private extension View {
    /// Settings rows sit on cards on iPhone; the Mac's grouped form draws its own.
    @ViewBuilder func cardRows() -> some View {
        #if os(iOS)
        listRowBackground(Color.card)
        #else
        self
        #endif
    }

    /// No autocorrection, capitalisation or keyboard learning on names and values.
    func secretInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}

enum SecretsDemo {
    static var opensScreen: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demo") && arguments.contains("-demoSecrets")
    }

    static var revealsOne: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demo") && arguments.contains("-demoSecretRevealed")
    }
}

/// Values go to the clipboard for this device only and expire: Universal Clipboard never carries a secret.
enum SecretPasteboard {
    static let lifetime: TimeInterval = 90

    @MainActor static func copy(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(lifetime)])
        #else
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let change = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(lifetime))
            if board.changeCount == change { board.clearContents() }
        }
        #endif
    }

    @MainActor static func copyName(_ key: String) {
        PlatformPasteboard.copy(key)
    }
}
