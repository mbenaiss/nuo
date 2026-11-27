import SwiftUI

/// What a bot remembers across conversations: one fact per line, editable here or as raw text.
struct BotMemoryView: View {
    let botId: String
    @Environment(SessionStore.self) private var session
    @Environment(BotsStore.self) private var bots
    #if os(macOS)
    @Environment(MacNavigator.self) private var navigator: MacNavigator?
    #endif
    @State private var store: MemoryStore
    @State private var search = ""
    @State private var editingLine: Int?
    @State private var draft = ""
    @State private var showsAdd = false
    @State private var newFact = ""
    @State private var showsRaw = false
    @State private var confirmsClear = false
    @State private var actionError: String?
    @State private var appliedDemo = false
    @FocusState private var editorFocused: Bool

    init(botId: String) {
        self.botId = botId
        _store = State(initialValue: MemoryStore(botId: botId))
    }

    private var bot: Bot? { bots.bot(id: botId) }

    private var facts: [MemoryDocument.Fact] {
        let all = store.document.facts.sorted { ($0.day ?? "", $0.line) > ($1.day ?? "", $1.line) }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(query) }
    }

    var body: some View {
        let document = store.document
        GroupedList {
            Section {
                header(document)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if store.isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if document.facts.isEmpty && document.otherLines.isEmpty {
                emptyState.listRowBackground(Color.clear)
            } else {
                Section {
                    if facts.isEmpty {
                        Text("No fact contains “\(search)”.").font(.subheadline).foregroundStyle(Color.text2)
                    }
                    ForEach(facts) { fact in
                        row(fact)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await perform { try await store.remove(fact) } }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await perform { try await store.remove(fact) } }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    SectionHeader(title: "Facts")
                } footer: {
                    if !document.facts.isEmpty {
                        Text(Self.factsHint).font(.caption).foregroundStyle(Color.text3)
                    }
                }
                .listRowBackground(Color.card)

                if !document.otherLines.isEmpty {
                    Section {
                        Text(document.otherLines.joined(separator: "\n"))
                            .font(.footnote.monospaced())
                            .foregroundStyle(Color.text2)
                            .textSelection(.enabled)
                    } header: {
                        SectionHeader(title: "Free text")
                    } footer: {
                        Text("Editable with “Edit raw text”.").font(.caption).foregroundStyle(Color.text3)
                    }
                    .listRowBackground(Color.card)
                }
            }
            if let actionError {
                Text(actionError).font(.footnote).foregroundStyle(Color.bad).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search facts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { showsRaw = true } label: { Label("Edit raw text", systemImage: "doc.plaintext") }
                    Button(role: .destructive) { confirmsClear = true } label: { Label("Erase all", systemImage: "trash") }
                        .disabled(document.lines.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More options")
                Button {
                    Haptics.tap()
                    newFact = ""
                    showsAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a fact")
            }
        }
        .alert("New fact", isPresented: $showsAdd) {
            TextField("Prefers the train to the plane", text: $newFact)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let fact = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fact.isEmpty else { return }
                Task { await perform { try await store.add(String(fact.prefix(500))) } }
            }
        } message: {
            Text("\(bot?.config?.name ?? String(localized: "The bot")) will reread it at the start of every conversation.")
        }
        .sheet(isPresented: $showsRaw) {
            RawMemoryEditor(store: store)
        }
        .confirmationDialog("Erase all memory of \(bot?.config?.name ?? String(localized: "this bot"))?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Erase all", role: .destructive) {
                Task { await perform { try await store.write("") } }
            }
        } message: {
            Text("The bot will forget everything it has kept. This cannot be undone.")
        }
        .task(id: refreshTick) {
            store.attach(session.api)
            await store.load()
            applyDemo()
        }
        .refreshable { await store.load() }
    }

    private var refreshTick: Int {
        #if os(macOS)
        navigator?.refreshTick ?? 0
        #else
        0
        #endif
    }

    #if os(macOS)
    private static var factsHint: String { String(localized: "Click a fact to correct it, right-click to delete it.") }
    #else
    private static var factsHint: String { String(localized: "Tap a fact to correct it, swipe to delete it.") }
    #endif

    private func header(_ document: MemoryDocument) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BotAvatar(config: bot?.config, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(bot?.config?.name ?? "Bot").font(.headline).foregroundStyle(Color.ink)
                Text(summary(document)).font(.subheadline).foregroundStyle(Color.text2)
                Text("Read at the start of every conversation, whichever agent is used.")
                    .font(.caption)
                    .foregroundStyle(Color.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summary(_ document: MemoryDocument) -> String {
        let count = document.facts.count
        let facts = count == 0 ? String(localized: "No facts") : String(localized: "\(count) facts")
        guard let updated = store.memory?.updatedAt else { return facts }
        return String(localized: "\(facts) · updated \(MemoryDocument.updatedLabel(updated))")
    }

    @ViewBuilder
    private func row(_ fact: MemoryDocument.Fact) -> some View {
        if editingLine == fact.line {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Fact", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($editorFocused)
                    .submitLabel(.done)
                    .onSubmit { save(fact) }
                    .padding(10)
                    .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    if let date = fact.date {
                        Text(MemoryDocument.dayLabel(date)).font(.caption).foregroundStyle(Color.text3)
                    }
                    Spacer()
                    Button("Cancel") { editingLine = nil }
                        .font(.subheadline)
                        .foregroundStyle(Color.text2)
                    Button("Save") { save(fact) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentInk)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        } else {
            Button {
                draft = fact.text
                editingLine = fact.line
                editorFocused = true
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    if let date = fact.date {
                        Text(MemoryDocument.dayLabel(date)).font(.caption).foregroundStyle(Color.text3)
                    }
                    Text(fact.text).font(.body).foregroundStyle(Color.ink).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            MascotView(state: store.loadError == nil ? .think : .sleep, size: MascotMetrics.emptyState)
            Text(store.loadError == nil ? String(localized: "Memory is empty") : String(localized: "Memory unavailable")).font(.headline).foregroundStyle(Color.ink)
            Text(store.loadError ?? String(localized: "The bot fills it in itself when you tell it “remember that…” or when it learns a lasting preference. You can also add a fact here."))
                .font(.subheadline).foregroundStyle(Color.text2).multilineTextAlignment(.center)
            if store.loadError == nil {
                Button("Add a fact") { showsAdd = true }
                    .buttonStyle(InkButtonStyle())
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func save(_ fact: MemoryDocument.Fact) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        editingLine = nil
        guard text != fact.text else { return }
        Task { await perform { try await store.update(fact, text: text) } }
    }

    private func perform(_ work: () async throws -> Void) async {
        actionError = nil
        do {
            try await work()
            Haptics.success()
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            await store.load()
        }
    }

    private func applyDemo() {
        guard !appliedDemo, let line = MemoryDemo.editingLine, let fact = store.document.fact(at: line) else { return }
        appliedDemo = true
        draft = fact.text
        editingLine = line
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            editorFocused = true
        }
    }
}

/// The memory file as text, for content that does not follow the one-fact-per-line format.
private struct RawMemoryEditor: View {
    let store: MemoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var error: String?

    init(store: MemoryStore) {
        self.store = store
        _text = State(initialValue: store.memory?.content ?? "")
    }

    private var bytes: Int { text.utf8.count }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .font(.footnote.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line))
                HStack {
                    Text("One line per fact: “- YYYY-MM-DD fact”.").font(.caption).foregroundStyle(Color.text3)
                    Spacer()
                    Text("\((Double(bytes) / 1024).formatted(.number.precision(.fractionLength(1)))) / 64 KB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(bytes > 64 * 1024 ? Color.bad : Color.text3)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Color.bad)
                }
            }
            .padding(16)
            .background(Color.canvas)
            .navigationTitle("Raw text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .tint(Color.accent)
                            .disabled(bytes > 64 * 1024)
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await store.write(text)
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}
