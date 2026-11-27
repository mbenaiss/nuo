import SwiftUI

struct WatchSettingsView: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        @Bindable var session = session
        List {
            Section {
                Toggle(isOn: $session.speaksAnswers) {
                    Label("Read replies aloud", systemImage: "speaker.wave.2.fill")
                }
            } footer: {
                Text("Tap the screen to stop the voice.")
            }
            Section("Gateway") {
                LabeledContent("Address", value: session.isDemo ? String(localized: "Demo") : session.gatewayHost)
                Button {
                    session.askPhoneForCredentials()
                } label: {
                    Label("Resync iPhone", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(session.isDemo)
            }
        }
        .navigationTitle("Settings")
    }
}

struct PairingPromptView: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                MascotView(state: .idle, size: 64)
                Text("Open Nuo on your iPhone")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("The watch picks up access to your gateway on its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { session.askPhoneForCredentials() }
                    .tint(.accent)
            }
            .padding(.top, 6)
        }
    }
}
