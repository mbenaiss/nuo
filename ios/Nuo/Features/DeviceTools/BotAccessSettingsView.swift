import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Réglages › Accès des bots: which of this device's position, weather, maps, Santé data and workout scheduling the
/// bots may use. Calendars are set in Réglages › Calendrier, next to the access they share with the calendar tab.
struct BotAccessSettingsView: View {
    @State private var center = DeviceToolsCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                ForEach(DeviceToolGroup.available.filter { $0 != .calendars }) { group in
                    row(group)
                }
            } footer: {
                Text("Your bots ask \(PlatformDevice.name) for this information when they need it, even when Nuo is closed. The iPhone always answers first; an open Mac takes over only if the iPhone does not answer. Nothing is stored on the gateway: your health data stays on the iPhone and only leaves in the answer to the bot that asks for it. Bot access to calendars is set in Settings › Calendar.")
            }
            .listRowBackground(Color.card)

            #if os(macOS)
            SharedFoldersSection()
            #endif

            if let activity = center.lastActivity {
                Section {
                    LabeledContent("Last request") {
                        Text("\(activity.tool) · \(activity.at.formatted(date: .omitted, time: .shortened))")
                    }
                    if let error = activity.error {
                        Text(error).font(.footnote).foregroundStyle(Color.text3)
                    }
                }
                .listRowBackground(Color.card)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Bot access")
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        center.permissionsChanged()
    }

    @ViewBuilder
    private func row(_ group: DeviceToolGroup) -> some View {
        let _ = center.revision
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { center.isEnabled(group) }, set: { center.setEnabled(group, $0) })) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                        Text(group.detail).font(.footnote).foregroundStyle(Color.text3)
                    }
                } icon: {
                    Image(systemName: group.symbol).foregroundStyle(Color.ink)
                }
            }
            if center.isEnabled(group), let status = status(group) {
                HStack {
                    Text(status.text).font(.footnote).foregroundStyle(Color.text3)
                    Spacer()
                    Button(status.action) { authorize(group) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private struct Status {
        let text: String
        let action: String
    }

    private func status(_ group: DeviceToolGroup) -> Status? {
        let locator = DeviceLocator.shared
        switch group {
        case .folders:
            return nil
        case .health:
            return center.isAuthorized(.health)
                ? Status(text: String(localized: "Choose the shared data in Settings › Privacy › Health."), action: String(localized: "Open Settings"))
                : Status(text: String(localized: "Health not authorized yet: you choose each piece of shared data."), action: String(localized: "Allow"))
        case .workouts:
            return center.isAuthorized(.workouts) ? nil : Status(text: String(localized: "Scheduling workouts not authorized yet."), action: String(localized: "Allow"))
        case .weather, .maps, .calendars:
            return locator.isAuthorized ? nil : Status(text: String(localized: "“Here” needs your location; other places work without it."), action: String(localized: "Allow"))
        case .location:
            if locator.isDenied { return Status(text: String(localized: "Location denied."), action: String(localized: "Open Settings")) }
            if !locator.isAuthorized { return Status(text: String(localized: "Location not authorized yet."), action: String(localized: "Allow")) }
            #if os(iOS)
            if !locator.isAlways { return Status(text: String(localized: "Choose “Always” to answer when Nuo is closed."), action: String(localized: "Always")) }
            #endif
            return nil
        }
    }

    private func authorize(_ group: DeviceToolGroup) {
        switch group {
        case .health where center.isAuthorized(.health):
            openHealthSettings()
        case .health, .workouts:
            Task { await center.requestAccess(group) }
            return
        default:
            let locator = DeviceLocator.shared
            if locator.isDenied { openSystemSettings() } else { locator.requestAccess() }
        }
        center.permissionsChanged()
    }

    /// Santé keeps what an app may read in its own screen; iOS opens it from the app's settings page.
    private func openHealthSettings() {
        #if os(iOS)
        if let url = URL(string: "x-apple-health://") { openURL(url) }
        #endif
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { openURL(url) }
        #endif
    }
}

#if os(macOS)
/// The folders the bots may work in; the composer's folder menu adds to the same list.
private struct SharedFoldersSection: View {
    @State private var access = FolderAccess.shared

    var body: some View {
        Section {
            ForEach(access.folders) { folder in
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                            Text(folder.path).font(.footnote).foregroundStyle(Color.text3).lineLimit(1).truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "folder").foregroundStyle(Color.ink)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { access.remove(folder) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            Button("Add a folder…") { _ = access.choose() }
        } header: {
            Text("Shared folders")
        } footer: {
            Text("Pick a folder under a conversation's message field: the bot reads, searches and writes files there, and only there.")
        }
        .listRowBackground(Color.card)
    }
}
#endif
