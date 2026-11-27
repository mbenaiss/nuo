import SwiftUI

/// Settings rows for app lock, paired devices and the security log.
struct SecuritySettingsSection: View {
    @State private var lock = AppLock.shared
    private let biometry = BiometricGate.biometryName

    var body: some View {
        Section {
            Toggle("Lock with \(biometry)", isOn: Binding(get: { lock.isEnabled }, set: { value in Task { await lock.setEnabled(value) } }))
            if lock.isEnabled {
                Picker("Lock", selection: $lock.delay) {
                    ForEach(AppLock.Delay.allCases) { Text($0.label).tag($0) }
                }
            }
            NavigationLink {
                DevicesView()
            } label: {
                Label {
                    Text("Devices")
                } icon: {
                    Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(Color.ink)
                }
            }
            #if os(iOS)
            NavigationLink {
                RelayAccessView()
            } label: {
                Label {
                    Text("Relay Access for Apple Watch")
                } icon: {
                    Image(systemName: "applewatch.radiowaves.left.and.right").foregroundStyle(Color.ink)
                }
            }
            #endif
            NavigationLink {
                SecurityActivityView()
            } label: {
                Label {
                    Text("Security Activity")
                } icon: {
                    Image(systemName: "checkmark.shield").foregroundStyle(Color.ink)
                }
            }
        } header: {
            SectionHeader(title: "Security")
        } footer: {
            Text("\(biometry) is also required to revoke a device, change financial data or command tasks, and delete a document.")
        }
        .listRowBackground(Color.card)
    }
}

struct DevicesView: View {
    @Environment(SessionStore.self) private var session
    @State private var devices: [PairedDevice] = []
    @State private var error: String?
    @State private var confirming: PairedDevice?
    @State private var loading = true

    private var api: (any NuoSecurityAPI)? { session.api as? any NuoSecurityAPI }

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(Color.bad).listRowBackground(Color.card)
            }
            Section {
                ForEach(devices) { device in
                    DeviceRow(device: device)
                        .swipeActions {
                            Button("Revoke", role: .destructive) { confirming = device }
                        }
                        .contextMenu {
                            Button("Revoke", systemImage: "xmark.shield", role: .destructive) { confirming = device }
                        }
                }
            } footer: {
                Text("Revoking cuts access right away, extensions included (widgets, sharing, Apple Watch). The device will need to be paired again, from the gateway's network, with a 2FA code.")
            }
            .listRowBackground(Color.card)
        }
        .overlay { if loading && devices.isEmpty { ProgressView() } }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            confirming.map { String(localized: "Revoke “\($0.name)”?") } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                guard let device = confirming else { return }
                Task { await revoke(device) }
            }
        } message: {
            if confirming?.current == true { Text("This is this device: Nuo will ask you to pair it again.") }
        }
    }

    private func load() async {
        guard let api else { return }
        loading = true
        defer { loading = false }
        do {
            devices = try await api.devices()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ device: PairedDevice) async {
        guard let api else { return }
        do {
            try await api.revokeDevice(id: device.id)
            Haptics.success()
            if device.current {
                session.unpair()
                return
            }
            devices.removeAll { $0.id == device.id }
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}

private struct DeviceRow: View {
    let device: PairedDevice

    private var icon: String {
        switch device.platform {
        case "macOS": "laptopcomputer"
        case "iPadOS": "ipad"
        case "watchOS": "applewatch"
        default: "iphone"
        }
    }

    private var subtitle: String {
        let paired = String(localized: "Paired \(device.createdAt.formatted(date: .abbreviated, time: .omitted))")
        guard let seen = device.lastSeenAt else { return paired }
        return String(localized: "\(paired) · seen \(seen.formatted(.relative(presentation: .named)))")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.ink).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).foregroundStyle(Color.ink).lineLimit(1)
                    if device.current { Tag(text: "This device", color: Color.good) }
                    if device.legacy { Tag(text: "Old pairing", color: Color.bad) }
                }
                Text(subtitle)
                    .font(.footnote).foregroundStyle(Color.text2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Tag: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

struct SecurityActivityView: View {
    @Environment(SessionStore.self) private var session
    @State private var activity: SecurityActivity?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(Color.bad).listRowBackground(Color.card)
            }
            if let activity {
                Section {
                    LabeledContent("TOTP", value: activity.totp ? String(localized: "Enabled") : String(localized: "Not set up"))
                    LabeledContent("Recovery codes left", value: "\(activity.recoveryCodesLeft)")
                } header: {
                    SectionHeader(title: "Two-factor authentication")
                }
                .listRowBackground(Color.card)
                Section {
                    ForEach(Array(activity.events.enumerated()), id: \.offset) { _, event in
                        EventRow(event: event)
                    }
                } header: {
                    SectionHeader(title: "Events")
                }
                .listRowBackground(Color.card)
                if !activity.internet.isEmpty {
                    Section {
                        ForEach(activity.internet, id: \.self) { client in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(client.deviceName ?? String(localized: "No authenticated device")).foregroundStyle(client.deviceName == nil ? Color.bad : Color.ink)
                                Text(verbatim: [client.ip, String(localized: "\(client.requests) requests"), String(localized: "\(client.errors) errors"), client.lastAt.formatted(.relative(presentation: .named))].joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(Color.text2)
                            }
                        }
                    } header: {
                        SectionHeader(title: "Internet access (7 days)")
                    }
                    .listRowBackground(Color.card)
                }
            }
        }
        .overlay { if activity == nil && error == nil { ProgressView() } }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Security Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = session.api as? any NuoSecurityAPI else { return }
        do {
            activity = try await api.securityActivity()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EventRow: View {
    let event: SecurityActivity.Event

    private var title: String {
        switch (event.type, event.ok) {
        case ("pair", true): String(localized: "New device paired")
        case ("pair", false): String(localized: "Pairing failed")
        case ("refresh", true): String(localized: "Sign-in")
        case ("refresh", false): String(localized: "Sign-in refused")
        case ("step_up", true): String(localized: "Biometric confirmation")
        case ("step_up", false): String(localized: "Confirmation refused")
        case ("revoke", _): String(localized: "Device revoked")
        case ("legacy_token", _): String(localized: "Old token refused")
        case ("local_token_rejected", _): String(localized: "Local token refused outside the gateway host")
        case ("totp_setup", _): String(localized: "2FA set up")
        case ("totp_reset", _): String(localized: "2FA reset")
        case ("google_connect", true): String(localized: "Google account connected")
        case ("google_connect", false): String(localized: "Google sign-in failed")
        case ("google_disconnect", _): String(localized: "Google account disconnected")
        case ("google_error", _): String(localized: "Google access needs renewing")
        case ("secret_reveal", true): String(localized: "Secret shown")
        case ("secret_reveal", false): String(localized: "Secret display refused")
        case ("secret_create", true): String(localized: "Secret added")
        case ("secret_create", false): String(localized: "Secret creation refused")
        case ("secret_update", true): String(localized: "Secret changed")
        case ("secret_update", false): String(localized: "Secret change refused")
        case ("secret_delete", true): String(localized: "Secret deleted")
        case ("secret_delete", false): String(localized: "Secret deletion refused")
        default: event.type
        }
    }

    /// File and name of the secret; other events keep their detail to the raw log.
    private var detail: String? {
        event.type.hasPrefix("secret_") ? event.detail : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(event.ok ? Color.good : Color.bad)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(Color.ink)
                if let detail {
                    Text(detail).font(.system(.footnote, design: .monospaced)).foregroundStyle(Color.text2)
                }
                Text([event.deviceName, event.ip, event.at.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Color.text2)
            }
        }
    }
}
