import PhotosUI
import SwiftUI
import UIKit

struct Composer: View {
    @Bindable var store: ConversationStore
    @Binding var focused: Bool
    let onVoice: () -> Void
    let tags: ToolTagPalette
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsCamera = false
    @State private var showsFiles = false
    @State private var dictationKey = "composer-\(UUID().uuidString)"
    @State private var clipboardHasImage = false
    @State private var handledPasteboard = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DictationNoticeLabel(key: dictationKey)
            if clipboardHasImage {
                clipboardChip.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !store.queued.isEmpty {
                QueuedPromptsView(store: store)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.attachments) { attachment in
                            PendingThumb(attachment: attachment) {
                                withAnimation(.snappy) { store.attachments.removeAll { $0.id == attachment.id } }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .top, spacing: 8) {
                RecipientChip(config: store.config)
                ZStack(alignment: .topLeading) {
                    if store.draft.isEmpty {
                        Text(store.commands.isEmpty ? String(localized: "Message or #tool") : String(localized: "Message, /command or #tool"))
                            .font(.body)
                            .foregroundStyle(Color(uiColor: .placeholderText))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $store.draft, focused: focused, onFocusChange: { focused = $0 },
                        autocorrects: !store.draft.hasPrefix("/") && tagQuery == nil,
                        capitalizes: !store.draft.hasPrefix("/") && tagQuery == nil,
                        onKey: composerKey, onPasteImage: pasteImages)
                }
                .padding(.top, 4)
                if !dictating {
                    DictationButton(key: dictationKey, text: $store.draft, vocabulary: [store.config?.name ?? ""],
                                    size: 30, compact: true, finishesOnDisappear: false)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 2)
            .padding(.top, 4)

            HStack(spacing: 8) {
                if dictating {
                    DictationBar { store.send() }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Menu {
                        Button { showsCamera = true } label: { Label("Take photo", systemImage: "camera") }
                        Button { showsPhotos = true } label: { Label("Photo library", systemImage: "photo.on.rectangle") }
                        Button { showsFiles = true } label: { Label("File", systemImage: "doc") }
                        Divider()
                        Button { store.localCommand = .barcode } label: {
                            Label(AppCommandAction.barcode.label, systemImage: AppCommandAction.barcode.symbol)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 34, height: 34)
                            .background(Color.chip, in: Circle())
                    }
                    .accessibilityLabel("Attach or scan")

                    Button { store.togglePalette(); focused = true } label: {
                        Text("/")
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .foregroundStyle(store.paletteQuery != nil ? Color.onInk : Color.ink)
                            .frame(width: 34, height: 34)
                            .background(store.paletteQuery != nil ? Color.inkFill : Color.chip, in: Circle())
                            .contentTransition(.interpolate)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Commands")

                    ViewThatFits(in: .horizontal) {
                        modelControls(effort: .full)
                        modelControls(effort: .icon)
                        modelControls(effort: .hidden)
                    }
                    Spacer(minLength: 0)
                    trailingButton
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .glassSurface(radius: 28, interactive: false)
        .animation(.snappy(duration: 0.25), value: store.attachments)
        .animation(.snappy(duration: 0.25), value: store.queued)
        .animation(.snappy(duration: 0.25), value: clipboardHasImage)
        .onAppear(perform: refreshClipboard)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refreshClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in refreshClipboard() }
        .animation(.snappy(duration: 0.2), value: store.isRunning)
        .animation(.snappy(duration: 0.25), value: dictating)
        .onAppear { DictationController.shared.prewarm() }
        .onDisappear {
            DictationController.shared.leave(dictationKey)
        }
        .task {
            if DictationDemo.isOn, !DictationDemo.onHome, !DictationDemo.inSmallField, !dictating {
                await DictationController.shared.start(key: dictationKey, vocabulary: [],
                                                       field: DictationField(read: { store.draft }, write: { store.draft = $0 }))
            }
        }
        .photosPicker(isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let jpeg = await ImageCompressor.jpeg(from: data) {
                        store.attachments.append(PendingAttachment(jpeg: jpeg))
                    }
                }
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task {
                for url in urls.prefix(4) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let attachment = await PendingAttachment.load(url) { store.attachments.append(attachment) }
                }
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in
                Task {
                    if let jpeg = await ImageCompressor.jpeg(from: data) { store.attachments.append(PendingAttachment(jpeg: jpeg)) }
                }
            }
            .ignoresSafeArea()
        }
    }

    /// `hasImages` reads no content, so it never triggers the paste permission prompt; only tapping the chip does.
    private func refreshClipboard() {
        let board = UIPasteboard.general
        clipboardHasImage = board.hasImages && board.changeCount != handledPasteboard
    }

    private func pasteImages() {
        let board = UIPasteboard.general
        handledPasteboard = board.changeCount
        clipboardHasImage = false
        let images = board.images ?? []
        guard !images.isEmpty else { return Haptics.error() }
        Task {
            for image in images.prefix(4) {
                guard let data = image.pngData(), let jpeg = await ImageCompressor.jpeg(from: data) else { continue }
                store.attachments.append(PendingAttachment(jpeg: jpeg))
            }
        }
    }

    private var clipboardChip: some View {
        HStack(spacing: 8) {
            Button(action: pasteImages) {
                Label("Paste copied image", systemImage: "doc.on.clipboard")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ink)
            }
            .buttonStyle(.plain)
            Button {
                handledPasteboard = UIPasteboard.general.changeCount
                clipboardHasImage = false
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.text2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.chip, in: Capsule())
    }

    private var tagQuery: String? { store.paletteQuery == nil ? ToolTag.query(in: store.draft) : nil }

    private var dictating: Bool { DictationController.shared.isActive(dictationKey) }

    private enum EffortChip { case full, icon, hidden }

    /// Narrow phones drop the effort label, then the effort chip: the model menu still holds the effort picker.
    private func modelControls(effort chip: EffortChip) -> some View {
        HStack(spacing: 8) {
            ModelMenu(store: store) {
                PillLabel(symbol: "asterisk", text: shortModelName(store.modelLabel))
            }
            if chip != .hidden, let efforts = store.modelInfo?.efforts, !efforts.isEmpty {
                Menu {
                    Picker("Effort", selection: Binding(get: { store.effort ?? "" }, set: { store.selectEffort($0) })) {
                        ForEach(efforts, id: \.self) { Text(Effort.label($0)).tag($0) }
                    }
                } label: {
                    if chip == .full {
                        PillLabel(symbol: "circle.lefthalf.filled", text: Effort.label(store.effort))
                    } else {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 34, height: 34)
                            .background(Color.chip, in: Circle())
                    }
                }
                .accessibilityLabel("Effort: \(Effort.label(store.effort))")
            }
        }
        .fixedSize(horizontal: chip != .hidden, vertical: false)
    }

    private func composerKey(_ key: ComposerKey) -> Bool {
        switch key {
        case .up: paletteKey({ store.movePaletteHighlight(-1) }, tag: { tags.move(-1, text: store.draft) })
        case .down: paletteKey({ store.movePaletteHighlight(1) }, tag: { tags.move(1, text: store.draft) })
        case .tab, .enter: paletteKey({ _ = store.pickHighlighted() }, tag: pickTag)
        case .escape: paletteKey({ store.draft = "" }, tag: { store.draft = String(store.draft.dropLast((tagQuery?.count ?? 0) + 1)) })
        }
    }

    private func paletteKey(_ action: () -> Void, tag: () -> Void) -> Bool {
        if store.paletteQuery != nil {
            action()
            return true
        }
        guard tagQuery != nil else { return false }
        tag()
        return true
    }

    private func pickTag() {
        if let text = tags.pickHighlighted(in: store.draft) { store.draft = text }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if store.canSend {
            RoundIconButton(symbol: "arrow.up", size: 40, label: store.isRunning ? String(localized: "Queue message") : String(localized: "Send")) { store.send() }
        } else if store.isRunning {
            RoundIconButton(symbol: "stop.fill", size: 40, label: String(localized: "Stop")) { store.stopTapped() }
        } else {
            Button(action: onVoice) {
                VoiceGlyph(size: 17).frame(width: 40, height: 40).background(Color.inkFill, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Voice mode")
        }
    }
}

/// Compact "à Coach" tag at the start of the composer: the recipient is always explicit.
struct RecipientChip: View {
    let config: BotConfig?

    var body: some View {
        HStack(spacing: 5) {
            Text("to").foregroundStyle(Color.text3)
            Text(config?.emoji ?? "✨")
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .background(Color(hexString: config?.color ?? "") ?? Color.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(config?.name ?? "Bot").foregroundStyle(Color.ink).lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Color.chip, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recipient: \(config?.name ?? "bot")")
    }
}

struct PillLabel: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.bold))
            Text(text).lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Color.chip, in: Capsule())
    }
}

/// Model switcher for the open conversation (from the bot agent's model list).
struct ModelMenu<Label: View>: View {
    let store: ConversationStore
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            if store.switchableAgents.count > 1, let current = store.agentID {
                Picker(selection: Binding(get: { current }, set: { store.selectAgent($0) })) {
                    ForEach(store.switchableAgents) { Text($0.name).tag($0.id) }
                } label: {
                    Text("Agent")
                    Text(store.agent?.name ?? current.rawValue)
                }
                .pickerStyle(.menu)
            }
            if let models = store.agent?.models, !models.isEmpty {
                Picker("Model", selection: Binding(get: { store.model ?? "" }, set: { store.selectModel($0) })) {
                    ForEach(models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                if let efforts = store.modelInfo?.efforts, !efforts.isEmpty {
                    Picker("Effort", selection: Binding(get: { store.effort ?? "" }, set: { store.selectEffort($0) })) {
                        ForEach(efforts, id: \.self) { Text(Effort.label($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            } else {
                Text("No other models available")
            }
            Picker("Permissions", selection: Binding(get: { store.permissionPolicy }, set: { store.selectPermissions($0) })) {
                ForEach(PermissionPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
        } label: {
            label()
        }
    }
}

private struct PendingThumb: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void
    @State private var image: UIImage?

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
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.chip
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .padding(3)
            .accessibilityLabel(attachment.fileName == nil ? String(localized: "Remove image") : String(localized: "Remove file"))
        }
        .task {
            guard attachment.fileName == nil else { return }
            image = await UIImage(data: attachment.data)?.byPreparingThumbnail(ofSize: CGSize(width: 192, height: 192))
        }
    }
}

enum ImageCompressor {
    static let maxBytes = 1_500_000

    /// Re-encodes as JPEG under 1.5 MB, downscaling to 2048 px first (gateway attachment budget).
    static func jpeg(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            var current = resized(image, maxDimension: 2048)
            var quality: CGFloat = 0.82
            while true {
                guard let encoded = current.jpegData(compressionQuality: quality) else { return nil }
                if encoded.count <= maxBytes { return encoded }
                if quality > 0.45 {
                    quality -= 0.12
                } else {
                    current = resized(current, maxDimension: max(current.size.width, current.size.height) * 0.75)
                    quality = 0.7
                }
            }
        }.value
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
