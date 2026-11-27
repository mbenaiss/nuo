import SwiftUI

/// What the relay access does and what it costs, said the same way on the consent screen and in « Sécurité ».
enum RelayAccessCopy {
    static let consent = String(localized: "relay.consent", defaultValue: "When the iPhone is locked, the watch will pass your voice requests through a key kept in the iPhone's secure chip. This key can only transcribe your request, then add reminders, events, notes and collection items, check off a reminder or pass a message to a bot, each addition after your confirmation on the watch. It does not read your emails, files, documents or other conversations, and sends no email or invitation. Everything else waits until you unlock the iPhone.")
    static let footer = String(localized: "relay.footer", defaultValue: "With the iPhone locked, the watch passes its voice requests through a key kept in the iPhone's secure chip since its first unlock. This relay can only transcribe the request, then add reminders, events (in the default calendar, with no guests), notes and collection items (excluding finances), check off a reminder or pass a message to a bot, each addition after your confirmation on the watch, which shows what will be added. It does not read your emails, files, documents, bot memory, location, or any conversation other than the ones it opened, and sends no email or invitation. An event added to a shared calendar is visible to its other members. Everything else waits until you unlock the iPhone, then goes through normally in the same conversation, which the relay can no longer read afterwards. Someone holding your locked iPhone could therefore add items or write to your bots: if the iPhone is lost, revoke it from another device, in Security › Devices. “Revoke” above only acts on this iPhone.")
}

/// « Sécurité › Accès de relais pour la montre »: whether the watch's requests can go through the locked iPhone,
/// and the means to revoke that access or make a new key.
struct RelayAccessView: View {
    @Environment(SessionStore.self) private var session
    @State private var status: RelayEnrollment.Status?
    @State private var keyMatches = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmsRevoke = false
    @State private var confirmsEnable = false

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    if let status {
                        Text(stateLabel(status)).foregroundStyle(status.registered && keyMatches ? Color.good : Color.text2)
                    } else {
                        ProgressView()
                    }
                }
                Button(status?.registered == true ? String(localized: "Recreate key") : String(localized: "Enable")) { confirmsEnable = true }
                    .disabled(working)
                if status?.registered == true {
                    Button("Revoke", role: .destructive) { confirmsRevoke = true }
                        .disabled(working)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text(RelayAccessCopy.footer)
            }
        }
        .navigationTitle("Relay Access")
        .task { await refresh() }
        .confirmationDialog("Enable relay access?", isPresented: $confirmsEnable, titleVisibility: .visible) {
            Button("Enable") { Task { await register() } }
        } message: {
            Text(RelayAccessCopy.consent)
        }
        .confirmationDialog("Revoke relay access?", isPresented: $confirmsRevoke, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { Task { await revoke() } }
        } message: {
            Text("The watch will no longer send anything while the iPhone is locked, and its pending requests stop.")
        }
    }

    private var client: NuoClient? { session.isDemo ? nil : session.api as? NuoClient }

    private func stateLabel(_ status: RelayEnrollment.Status) -> String {
        guard status.registered else { return String(localized: "Disabled") }
        return keyMatches ? String(localized: "relay.key.active", defaultValue: "Active") : String(localized: "Key needs recreating")
    }

    private func refresh() async {
        guard let client else {
            status = .init(registered: true, thumbprint: nil)
            keyMatches = true
            return
        }
        status = try? await RelayEnrollment.status(client: client)
        if case let .key(_, thumbprint) = RelayEnrollment.localKey() {
            keyMatches = status?.thumbprint == thumbprint
        } else {
            keyMatches = false
        }
    }

    private func register() async {
        guard let client, let deviceId = UserDefaults.standard.string(forKey: "nuo.deviceId") else { return }
        working = true
        defer { working = false }
        do {
            try await RelayEnrollment.register(client: client, deviceId: deviceId, profileId: session.profile?.id)
            error = nil
        } catch let failure as NuoError {
            if case let .server(403, message) = failure, message.contains("home") {
                error = RelayEnrollment.EnrollmentError.awayFromHome.errorDescription
            } else if failure != .stepUpCancelled {
                error = failure.localizedDescription
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await refresh()
    }

    private func revoke() async {
        guard let client else { return }
        working = true
        defer { working = false }
        do {
            try await RelayEnrollment.revoke(client: client)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }
}
