import SwiftUI

/// Lets the user pick the system voice the bot speaks with; tapping a row previews it.
struct VoicePickerSheet: View {
    var currentVoiceId: String
    var onPreview: (VoiceCatalog.Option) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: [VoiceCatalog.Option] = []

    var body: some View {
        NavigationStack {
            List {
                if !options.contains(where: { $0.quality >= .enhanced }) {
                    Section {
                        Text("For a more natural voice, download an “Enhanced” or “Premium” voice in Settings › Accessibility › Spoken Content › Voices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(options) { option in
                        Button {
                            onPreview(option)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name).foregroundStyle(.primary)
                                    Text("\(option.quality.label) · \(regionName(option.language))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if option.id == currentVoiceId {
                                    Image(systemName: "checkmark").foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Tap a voice to hear it and choose it.")
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .task { options = VoiceCatalog.options() }
    }

    private func regionName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
