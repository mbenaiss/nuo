import SwiftUI

/// Bot settings › Wake-ups: the bot's mail address and its webhooks, which start a turn from outside.
struct BotWakeSection: View {
    let botId: String
    @Environment(SessionStore.self) private var session
    @State private var wake: BotWake?
    @State private var error: String?
    @State private var naming = false
    @State private var newName = ""
    @State private var creating = false
    @State private var created: CreatedWakeHook?
    @State private var revoking: WakeHook?
    @State private var copied: String?

    private var api: (any NuoWakeAPI)? { session.api as? any NuoWakeAPI }

    var body: some View {
        Group {
            switch BotWakeDisplay.of(wake: wake, error: error) {
            case .hidden:
                EmptyView()
            case let .loadFailed(message):
                EditorSection(title: "Wake-ups") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.caption).foregroundStyle(Color.bad)
                        Button("Retry") { Task { await load() } }.buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
            case let .loaded(wake, error):
                EditorSection(title: "Wake-ups") {
                    mail(wake)
                    Divider().overlay(Color.line)
                    hooks(wake)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(Color.bad).padding(.horizontal, 16).padding(.bottom, 10)
                    }
                }
            }
        }
        .task { await load() }
        .alert("New webhook", isPresented: $naming) {
            TextField(text: $newName) { Text(verbatim: "Linear, GitHub…") }
            Button("Create") { Task { await create() } }
                .disabled(WakeHookName.normalized(newName) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Name it after the service that will call it.")
        }
        .confirmationDialog(
            revoking.map { String(localized: "Revoke “\($0.name)”?") } ?? "",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                guard let hook = revoking else { return }
                Task { await revoke(hook) }
            }
        } message: {
            Text("Its URL will stop working right away.")
        }
    }

    @ViewBuilder
    private func mail(_ wake: BotWake) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Email address").font(.caption).foregroundStyle(Color.text2)
            if let email = wake.email {
                HStack {
                    Text(email).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Color.ink).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    copyButton(email, label: String(localized: "Copy address"))
                }
                Text("An email to this address wakes the bot. Yours, once verified, are requests it carries through; anyone else's are information it reads without obeying.")
                    .font(.caption).foregroundStyle(Color.text2)
            } else {
                Text("The gateway has no mail domain (\("NUO_MAIL_DOMAIN")).").font(.caption).foregroundStyle(Color.text3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    @ViewBuilder
    private func hooks(_ wake: BotWake) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Webhooks").font(.caption).foregroundStyle(Color.text2)
            if let created {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(created.hook.name)” URL").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    HStack(alignment: .top) {
                        Text(created.url.absoluteString).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.ink).textSelection(.enabled)
                        Spacer()
                        copyButton(created.url.absoluteString, label: String(localized: "Copy URL"))
                    }
                    Text("Copy it now: it won't be shown again. Anyone who has it can wake the bot.")
                        .font(.caption).foregroundStyle(Color.accent)
                }
                .padding(12)
                .background(Color.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            ForEach(wake.hooks) { hook in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hook.name).font(.body).foregroundStyle(Color.ink)
                        Text(hook.activity).font(.caption).foregroundStyle(Color.text3)
                    }
                    Spacer()
                    Button(role: .destructive) { revoking = hook } label: {
                        Image(systemName: "trash").foregroundStyle(Color.bad)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Revoke \(hook.name)")
                }
            }
            if wake.hooksEnabled {
                Button {
                    newName = ""
                    naming = true
                } label: {
                    HStack {
                        Label("New webhook", systemImage: "plus.circle.fill").foregroundStyle(Color.accent)
                        if creating { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(creating)
                Text("Linear, GitHub or IFTTT send a POST to its URL: the bot reads what arrives as data, in a separate conversation, and lets you know.")
                    .font(.caption).foregroundStyle(Color.text2)
            } else {
                Text("The gateway has no webhook host (\("NUO_HOOKS_HOSTS")).").font(.caption).foregroundStyle(Color.text3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func copyButton(_ text: String, label: String) -> some View {
        Button {
            PlatformPasteboard.copy(text)
            Haptics.success()
            copied = text
        } label: {
            Image(systemName: copied == text ? "checkmark" : "doc.on.doc").foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func load() async {
        guard let api else { return }
        do {
            wake = try await api.botWake(botId: botId)
            error = nil
        } catch NuoError.notFound {
            // A gateway that predates wake-ups: the section stays hidden.
            wake = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        guard let api, let name = WakeHookName.normalized(newName) else { return }
        creating = true
        defer { creating = false }
        do {
            let result = try await api.createWakeHook(botId: botId, name: name)
            created = result
            wake?.hooks.append(result.hook)
            error = nil
            Haptics.success()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ hook: WakeHook) async {
        guard let api else { return }
        do {
            try await api.revokeWakeHook(botId: botId, hookId: hook.id)
            wake?.hooks.removeAll { $0.id == hook.id }
            if created?.hook.id == hook.id { created = nil }
            Haptics.success()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}
