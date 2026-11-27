import AuthenticationServices
import SwiftUI

/// Réglages › Comptes Google: the profile's Google accounts, which its bots use for Gmail, Drive and Agenda.
struct GoogleAccountsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var state: GoogleAccountsState?
    @State private var error: String?
    @State private var notice: String?
    @State private var connecting = false
    @State private var request: GoogleConnectRequest?
    @State private var disconnecting: GoogleAccount?

    private var api: (any NuoGoogleAPI)? { session.api as? any NuoGoogleAPI }

    var body: some View {
        GroupedList {
            if let error {
                Section { Text(error).foregroundStyle(Color.bad) }.cardRows()
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Color.ink) }.cardRows()
            }
            if let state, !state.configured {
                Section {
                    Label("The gateway has no Google client yet: add GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET to its configuration.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.text2)
                }
                .cardRows()
            }
            Section {
                ForEach(state?.accounts ?? []) { account in
                    GoogleAccountRow(account: account, onReconnect: { request = GoogleConnectRequest(account: account) }, onDisconnect: { disconnecting = account })
                }
                Button {
                    request = GoogleConnectRequest(account: nil)
                } label: {
                    HStack {
                        Label("Add a Google account", systemImage: "plus.circle.fill").foregroundStyle(Color.accent)
                        Spacer()
                        if connecting { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(connecting || state?.configured == false)
            } header: {
                Text("Connected accounts")
            } footer: {
                Text("Your bots read and search Gmail, Drive and Calendar, and prepare drafts; they only send an email once you confirm. Tokens stay encrypted on your gateway, specific to this profile.")
            }
            .cardRows()
            Section {
                Text("Google shows “Google hasn't verified this app”: Nuo is your private app. Tap “Advanced”, then “Go to Nuo (unsafe)”, and check the requested access.")
                    .font(.footnote)
                    .foregroundStyle(Color.text2)
            } header: {
                Text("Google warning")
            }
            .cardRows()
        }
        .overlay { if state == nil && error == nil { ProgressView() } }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Google Accounts")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $request) { request in
            GoogleServicesSheet(request: request) { services in
                self.request = nil
                Task { await connect(services: services, email: request.account?.email) }
            }
        }
        .confirmationDialog(
            disconnecting.map { String(localized: "Disconnect \($0.email)?") } ?? "",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                guard let account = disconnecting else { return }
                Task { await disconnect(account) }
            }
        } message: {
            Text("Nuo revokes its access at Google: your bots will no longer read these emails, files and calendars.")
        }
    }

    private func load() async {
        guard let api else { return }
        do {
            state = try await api.googleAccounts()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connect(services: [GoogleService], email: String?) async {
        guard let api else { return }
        connecting = true
        defer { connecting = false }
        notice = nil
        do {
            let start = try await api.connectGoogle(services: services, email: email)
            // The demo backend answers with the app's own callback: there is no Google page to open.
            let callback = AppIdentity.isAppScheme(start.url.scheme) ? start.url : try await webAuthenticationSession.authenticate(using: start.url, callbackURLScheme: "nuo")
            let result = GoogleConnectResult(url: callback)
            if result.error == nil {
                Haptics.success()
                notice = result.message
                error = nil
            } else {
                Haptics.error()
                error = result.message
            }
            await load()
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }

    private func disconnect(_ account: GoogleAccount) async {
        guard let api else { return }
        do {
            try await api.disconnectGoogle(email: account.email)
            Haptics.success()
            notice = nil
            state?.accounts.removeAll { $0.email == account.email }
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}

/// Which services to grant; a reconnection starts from the account's current ones plus whatever is added.
private struct GoogleConnectRequest: Identifiable {
    let account: GoogleAccount?
    var id: String { account?.email ?? "new" }
}

private struct GoogleServicesSheet: View {
    let request: GoogleConnectRequest
    let onContinue: ([GoogleService]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<GoogleService>

    init(request: GoogleConnectRequest, onContinue: @escaping ([GoogleService]) -> Void) {
        self.request = request
        self.onContinue = onContinue
        let current = Set(request.account?.grantedServices ?? [])
        _selected = State(initialValue: current.isEmpty ? Set(GoogleService.allCases) : current)
    }

    var body: some View {
        NavigationStack {
            GroupedList {
                Section {
                    ForEach(GoogleService.allCases) { service in
                        Toggle(isOn: Binding(get: { selected.contains(service) }, set: { on in
                            if on { selected.insert(service) } else { selected.remove(service) }
                        })) {
                            Label(service.label, systemImage: service.symbol)
                        }
                    }
                } header: {
                    Text(request.account?.email ?? String(localized: "Services"))
                } footer: {
                    Text("Google will ask you to pick the account, then to allow this access. Gmail: read, search, prepare and send (once you confirm). Drive: search and read your files. Calendar: read and create events.")
                }
                .cardRows()
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(request.account == nil ? String(localized: "Add an Account") : String(localized: "Reconnect"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { onContinue(GoogleService.allCases.filter { selected.contains($0) }) }
                        .disabled(selected.isEmpty)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}

private struct GoogleAccountRow: View {
    let account: GoogleAccount
    let onReconnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(String(account.email.prefix(1)).uppercased())
                .font(.headline)
                .foregroundStyle(Color.accentInk)
                .frame(width: 36, height: 36)
                .background(Color.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(account.email).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    ForEach(account.grantedServices) { service in
                        Badge(text: service.label)
                    }
                    if account.grantedServices.isEmpty { Badge(text: String(localized: "No service")) }
                }
                if account.needsReconnect {
                    Text(account.lastError ?? String(localized: "Needs reconnecting")).font(.caption).foregroundStyle(Color.bad).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Reconnect", systemImage: "arrow.triangle.2.circlepath", action: onReconnect)
                Button("Disconnect", systemImage: "person.crop.circle.badge.minus", role: .destructive, action: onDisconnect)
            } label: {
                Image(systemName: account.needsReconnect ? "exclamationmark.circle.fill" : "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(account.needsReconnect ? Color.bad : Color.text2)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(account.email)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reconnect", systemImage: "arrow.triangle.2.circlepath", action: onReconnect)
            Button("Disconnect", systemImage: "person.crop.circle.badge.minus", role: .destructive, action: onDisconnect)
        }
    }
}

enum GoogleAccountsDemo {
    static var opensScreen: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demo") && arguments.contains("-demoGoogle")
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
}
