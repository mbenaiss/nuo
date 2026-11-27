import SwiftUI

/// Réglages › Dictée: the gateway's transcription or on-device, Whisper model, language and storage.
struct DictationSettingsView: View {
    @State private var store = DictationModelStore.shared
    @State private var confirmDelete: WhisperModel?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Online transcription", isOn: $store.useCloud)
            } header: {
                SectionHeader(title: "Online")
            } footer: {
                Text(store.useCloud
                    ? String(localized: "When you stop, your gateway transcribes the whole recording at once with its transcription service, without the “uh” and “um”, and the text is written all at once. The recording goes through your gateway, which keeps the service key. Without a network, Whisper or Apple on-device dictation takes over.")
                    : String(localized: "Everything stays on \(Self.deviceName): Whisper, or Apple dictation as long as no model is ready."))
            }
            .settingsRow()

            Section {
                Picker("Model", selection: $store.selected) {
                    ForEach(WhisperModel.allCases) { model in
                        Text("\(model.title) · \(model.detail)").tag(model)
                    }
                }
                ForEach(WhisperModel.allCases) { model in
                    ModelRow(model: model, state: store.state(model), bytes: store.bytesOnDisk[model] ?? 0, selected: store.selected == model) {
                        store.download(model)
                    } onCancel: {
                        store.cancel(model)
                    } onDelete: {
                        confirmDelete = model
                    }
                }
            } header: {
                SectionHeader(title: "On device")
            } footer: {
                Text("Offline, or with online transcription turned off. Accurate recognizes proper names and punctuation better, Fast answers a little quicker. As long as no model is ready, Apple on-device dictation takes over.")
            }
            .settingsRow()

            Section {
                Picker("Language", selection: $store.language) {
                    ForEach(DictationLanguage.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                SectionHeader(title: "Language")
            } footer: {
                Text("In automatic mode, Nuo writes in French unless you clearly speak another language.")
            }
            .settingsRow()

            Section {
                LabeledContent("Space used", value: store.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file) : String(localized: "None"))
            } header: {
                SectionHeader(title: "Privacy")
            } footer: {
                Text("On device, your voice is never sent: the model is downloaded once from Hugging Face, then dictation works offline. In every case, the dictated text stays in the field until you send it.")
            }
            .settingsRow()
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        #else
        .formStyle(.grouped)
        #endif
        .onAppear { store.refresh() }
        .confirmationDialog("Delete the model?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            if let model = confirmDelete {
                Button("Delete \(model.title)", role: .destructive) { store.delete(model) }
            }
        } message: {
            Text("You will need to download it again to dictate with Whisper.")
        }
    }

    private static var deviceName: String {
        #if os(iOS)
        String(localized: "your iPhone")
        #else
        String(localized: "your Mac")
        #endif
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    let state: DictationModelStore.State
    let bytes: Int64
    let selected: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(model.detail).foregroundStyle(Color.ink)
                    if selected {
                        Text("Selected")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentSoft, in: Capsule())
                    }
                }
                Text(status).font(.footnote).foregroundStyle(statusColor)
                if case let .downloading(progress) = state {
                    ProgressView(value: progress).tint(Color.accent)
                }
            }
            Spacer(minLength: Spacing.xs)
            action
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .absent, .failed:
            Button("Download", action: onDownload).buttonStyle(.borderless).tint(Color.accent)
        case .downloading:
            Button("Cancel", action: onCancel).buttonStyle(.borderless).tint(Color.text2)
        case .preparing:
            ProgressView().controlSize(.small)
        case .ready:
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(model.detail)")
        }
    }

    private var status: String {
        let size = ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
        switch state {
        case .absent: return String(localized: "\(model.title) · \(size) to download")
        case let .downloading(progress): return String(localized: "Downloading… \(progress.formatted(.percent.precision(.fractionLength(0)))) of \(size)")
        case .preparing: return String(localized: "Preparing for the chip (about a minute)…")
        case .ready: return String(localized: "Ready · \(ByteCountFormatter.string(fromByteCount: max(bytes, 1), countStyle: .file)) on device")
        case let .failed(message): return message
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed: .bad
        case .ready: .good
        default: .text2
        }
    }
}

private extension View {
    @ViewBuilder
    func settingsRow() -> some View {
        #if os(iOS)
        listRowBackground(Color.card)
        #else
        self
        #endif
    }
}
