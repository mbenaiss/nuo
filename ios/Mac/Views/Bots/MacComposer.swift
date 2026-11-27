import SwiftUI
import UniformTypeIdentifiers

/// Return sends, ⌥Return adds a line; ↑ ↓ ⇥ drive the / and # palettes; images come from ⌘V, drag and drop or the picker.
struct MacComposer: View {
    @Bindable var store: ConversationStore
    var focused: Binding<Bool>
    let tags: ToolTagPalette
    @State private var importing = false
    @State private var dictationKey = "composer-\(UUID().uuidString)"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DictationNoticeLabel(key: dictationKey)
            if store.goalMode {
                GoalNotice()
            }
            if !store.queued.isEmpty {
                QueuedPromptsView(store: store)
            }
            if !store.attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(store.attachments) { attachment in
                        MacPendingThumb(attachment: attachment) {
                            withAnimation(.snappy) { store.attachments.removeAll { $0.id == attachment.id } }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                if !dictating {
                    Button { importing = true } label: {
                        Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("Attach an image or a file")

                    FolderMenu(store: store)

                    Button { store.goalMode.toggle() } label: {
                        Image(systemName: "scope").font(.body.weight(.semibold))
                            .foregroundStyle(store.goalMode ? Color.onInk : Color.primary)
                            .frame(width: 28, height: 28)
                            .background(store.goalMode ? Color.inkFill : Color.clear, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .help(store.goalMode ? String(localized: "Goal on: each message is seen through to the end, until you turn it off") : String(localized: "Goal: the bot sees it through without asking at each step"))
                    .accessibilityLabel("Goal")
                    .accessibilityValue(store.goalMode ? String(localized: "Enabled") : String(localized: "Disabled"))
                }

                ComposerTextView(
                    text: TextAccess($store.draft), history: ObjectIdentifier(store),
                    placeholder: store.goalMode
                        ? String(localized: "Goal: the expected result")
                        : store.commands.isEmpty
                        ? String(localized: "Message \(store.config?.name ?? String(localized: "your bot")) or #tool")
                        : String(localized: "Message, /command or #tool"),
                    isFocused: focused, onKey: key, onPaste: pasteAttachments)

                if !dictating {
                    DictationButton(key: dictationKey, text: $store.draft, vocabulary: [store.config?.name ?? ""], size: 28, compact: true,
                                    finishesOnDisappear: false)
                }

                if dictating {
                    EmptyView()
                } else if store.isRunning, !store.canSend {
                    Button { store.stopTapped() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.onInk)
                            .frame(width: 28, height: 28).background(Color.inkFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop (Esc)")
                } else {
                    Button { submit() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.onInk)
                            .frame(width: 28, height: 28)
                            .background(store.canSend ? Color.accent : Color.text3.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canSend)
                    .help(store.isRunning ? String(localized: "Send after the reply (↩)") : String(localized: "Send (↩)"))
                }
            }
            if dictating {
                DictationBar(compact: true) { store.send() }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(focused.wrappedValue ? Color.accent.opacity(0.5) : Color.line))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .animation(.snappy(duration: 0.2), value: store.attachments)
        .animation(.snappy(duration: 0.2), value: store.queued)
        .animation(.snappy(duration: 0.2), value: store.goalMode)
        .animation(.snappy(duration: 0.2), value: dictating)
        .onChange(of: focused.wrappedValue, initial: true) { _, isFocused in
            if isFocused { DictationController.shared.prewarm() }
        }
        .onDisappear {
            DictationController.shared.leave(dictationKey)
        }
        .task {
            if DictationDemo.isOn {
                await DictationController.shared.start(key: dictationKey, vocabulary: [],
                                                       field: DictationField(read: { store.draft }, write: { store.draft = $0 }))
            }
        }
        // The pane keeps its composer from one conversation to the next: a dictation ends where it started, as it
        // did when the pane went away with it.
        .onChange(of: ObjectIdentifier(store)) {
            DictationController.shared.leave(dictationKey)
            dictationKey = "composer-\(UUID().uuidString)"
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task { await MacAttachmentIntake.add(urls, to: store) }
        }
    }

    private var tagQuery: String? { store.paletteQuery == nil ? ToolTag.query(in: store.draft) : nil }

    private var dictating: Bool { DictationController.shared.isActive(dictationKey) }

    /// The dictation writes into the draft until it ends: sending meanwhile would bring the sent text back.
    private func submit() {
        if dictating {
            DictationController.shared.finish()
            return
        }
        store.send()
    }

    private func key(_ key: ComposerKey) -> Bool {
        switch key {
        case .up: return paletteKey({ store.movePaletteHighlight(-1) }, tag: { tags.move(-1, text: store.draft) })
        case .down: return paletteKey({ store.movePaletteHighlight(1) }, tag: { tags.move(1, text: store.draft) })
        case .tab: return paletteKey({ _ = store.pickHighlighted() }, tag: pickTag)
        case .escape:
            if store.isRunning, store.paletteQuery == nil, tagQuery == nil {
                store.cancel()
                return true
            }
            return paletteKey({ store.draft = "" }, tag: { store.draft = String(store.draft.dropLast((tagQuery?.count ?? 0) + 1)) })
        case .send:
            if !paletteKey({ _ = store.pickHighlighted() }, tag: pickTag) { submit() }
            return true
        }
    }

    /// A palette with no match lets the key through: « /Users/… » or « l'issue #42 » are sent with Return.
    private func paletteKey(_ action: () -> Void, tag: () -> Void) -> Bool {
        if store.paletteQuery != nil {
            guard !store.paletteMatches.isEmpty else { return false }
            action()
            return true
        }
        guard tagQuery != nil, !tags.matches(for: store.draft).isEmpty else { return false }
        tag()
        return true
    }

    private func pickTag() {
        if let text = tags.pickHighlighted(in: store.draft) { store.draft = text }
    }

    /// ⌘V and Edit › Paste: copied files and screenshots become attachments, text goes into the draft.
    private func pasteAttachments() -> Bool {
        let board = NSPasteboard.general
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            Task { await MacAttachmentIntake.add(files, to: store) }
            return true
        }
        guard board.availableType(from: [.string]) == nil,
              let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return false }
        Task { await MacAttachmentIntake.add(imageData: data, to: store) }
        return true
    }
}

extension AttachmentLimits {
    static let gateway = AttachmentLimits(
        maxCount: 4, maxFileBytes: PendingAttachment.maxFileBytes, maxImageBytes: PendingAttachment.maxImageSourceBytes,
        maxEncodedBytes: PendingAttachment.maxEncodedBytes)
}

/// Every way into the composer (picker, ⌘V, drag and drop) goes through here, so a refused file is always explained.
@MainActor
enum MacAttachmentIntake {
    static func add(_ urls: [URL], to store: ConversationStore) async {
        let limits = AttachmentLimits.gateway
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let candidate = AttachmentCandidate(url: url)
            if let refusal = limits.refusal(for: candidate, alreadyAttached: store.attachments.count) {
                store.reportAttachmentProblem(refusal.message)
                if case .tooMany = refusal { return }
                continue
            }
            guard let attachment = await PendingAttachment.load(url) else {
                store.reportAttachmentProblem(AttachmentRefusal.unreadable(name: candidate.name).message)
                continue
            }
            if !accept(attachment, named: candidate.name, into: store) { return }
        }
    }

    static func add(imageData data: Data, to store: ConversationStore) async {
        guard let jpeg = await ImageCompressor.jpeg(from: data) else {
            store.reportAttachmentProblem(String(localized: "This image can't be read."))
            return
        }
        accept(PendingAttachment(jpeg: jpeg), named: String(localized: "Pasted image"), into: store)
    }

    /// Counted again after loading: several drops and pastes load at the same time.
    @discardableResult
    private static func accept(_ attachment: PendingAttachment, named name: String, into store: ConversationStore) -> Bool {
        let limits = AttachmentLimits.gateway
        let refusal = store.attachments.count >= limits.maxCount
            ? .tooMany(max: limits.maxCount)
            : limits.refusal(adding: attachment.data.count, named: name, toAttached: store.attachments.map(\.data.count))
        if let refusal {
            store.reportAttachmentProblem(refusal.message)
            return false
        }
        withAnimation(.snappy) { store.attachments.append(attachment) }
        return true
    }
}

private struct MacPendingThumb: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void
    @State private var image: PlatformImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let name = attachment.fileName {
                    VStack(spacing: 3) {
                        Image(systemName: "doc.text").font(.title3).foregroundStyle(Color.accentColor)
                        Text(name).font(.caption2).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.chip)
                } else if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    Color.chip
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help(attachment.fileName == nil ? String(localized: "Remove image") : String(localized: "Remove file"))
        }
        .task {
            guard attachment.fileName == nil else { return }
            let data = attachment.data
            image = await Task.detached { PlatformImage.decoded(data, maxPixel: 160) }.value
        }
    }
}
