import SwiftUI

struct PairingView: View {
    @Environment(SessionStore.self) private var session
    @State private var gateway = SessionStore.defaultGateway
    @State private var profile = ""
    @State private var code = ""
    @State private var secondFactor = ""
    @State private var isPairing = false
    @State private var error: String?
    @State private var editingURL = SessionStore.defaultGateway.isEmpty
    @FocusState private var focus: Field?

    fileprivate enum Field { case url, profile, code, secondFactor }

    /// Six digits from the authenticator app, or a recovery code (xxxxx-xxxxx).
    private var secondFactorReady: Bool {
        let value = secondFactor.trimmingCharacters(in: .whitespaces)
        return (value.count == 6 && value.allSatisfy(\.isNumber)) || value.filter { $0.isLetter || $0.isNumber }.count == 10
    }

    private var profileReady: Bool { !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var canPair: Bool { SessionStore.normalizedURL(gateway) != nil && profileReady && code.count == 6 && secondFactorReady }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    MascotView(state: .idle, size: MascotMetrics.hero)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to Nuo").font(.largeTitle.bold()).foregroundStyle(Color.ink)
                        Text("Talk to your bots, wherever you are. Pair this iPhone with your gateway to get started.")
                            .font(.body).foregroundStyle(Color.text2)
                    }
                }
                .padding(.top, 40)

                if let notice = session.pairingNotice {
                    Label(notice, systemImage: "lock.shield.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Gateway")
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack").foregroundStyle(Color.text2)
                        if editingURL {
                            TextField(text: $gateway) { Text(verbatim: "https://…") }
                                .urlInput()
                                .focused($focus, equals: .url)
                                .submitLabel(.done)
                                .onSubmit {
                                    editingURL = SessionStore.normalizedURL(gateway) == nil
                                    focus = .profile
                                }
                        } else {
                            Text(SessionStore.normalizedURL(gateway)?.host() ?? gateway).lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(Color.ink)
                            Spacer()
                            Button("Edit") {
                                editingURL = true
                                focus = .url
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(16)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line))
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Profile")
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle").foregroundStyle(Color.text2)
                        TextField("Profile name", text: $profile)
                            .plainIdentifierInput()
                            .focused($focus, equals: .profile)
                            .submitLabel(.next)
                            .onSubmit { focus = .code }
                    }
                    .padding(16)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line))
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Pairing code")
                    CodeField(code: $code, focus: $focus)
                    Text("Run the pairing command (`bun run pair`) on the gateway host: a 6-digit code valid for 10 minutes appears. Pair from the same network as the gateway.")
                        .font(.footnote).foregroundStyle(Color.text2)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "2FA code")
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield").foregroundStyle(Color.text2)
                        TextField("123456 or recovery code", text: $secondFactor)
                            .oneTimeCodeInput(numeric: false)
                            .font(.title3.monospacedDigit())
                            .focused($focus, equals: .secondFactor)
                            .submitLabel(.go)
                            .onSubmit { Task { await pair() } }
                    }
                    .padding(16)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.line))
                    Text("The code from your authenticator app (Nuo), or one of the recovery codes shown by `auth-totp-setup`.")
                        .font(.footnote).foregroundStyle(Color.text2)
                }

                Button {
                    Task { await pair() }
                } label: {
                    HStack(spacing: 8) {
                        if isPairing { ProgressView().tint(Color.onInk) }
                        Text(isPairing ? String(localized: "Pairing…") : String(localized: "Pair"))
                    }
                }
                .buttonStyle(InkButtonStyle())
                .disabled(!canPair || isPairing)
                .opacity(canPair ? 1 : 0.35)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.bad)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .animation(.smooth, value: error)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.canvas)
        .onAppear {
            if session.isDemo, gateway.isEmpty {
                gateway = "https://nuo.example.com"
                editingURL = false
            }
            focus = editingURL ? .url : .profile
        }
        .onChange(of: profile) { _, _ in error = nil }
        .onChange(of: code) { _, value in
            error = nil
            if value.count == 6 { focus = .secondFactor }
        }
        .onChange(of: secondFactor) { _, value in
            error = nil
            if value.count == 6, value.allSatisfy(\.isNumber), canPair { Task { await pair() } }
        }
    }

    private func pair() async {
        guard !isPairing, canPair else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            try await session.pair(gateway: gateway, profile: profile, code: code, secondFactor: secondFactor)
            Haptics.success()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            secondFactor = ""
            // A refused pairing code is not consumed; keep it unless the gateway locked pairing.
            if case let NuoError.server(status, _) = error, status == 429 || status == 404 { code = "" }
        }
    }
}

/// Six boxes over a hidden text field, auto-filled from the one-time-code suggestion.
private struct CodeField: View {
    @Binding var code: String
    var focus: FocusState<PairingView.Field?>.Binding

    private var focused: Bool { focus.wrappedValue == .code }

    var body: some View {
        ZStack {
            TextField(text: $code) { EmptyView() }
                .oneTimeCodeInput(numeric: true)
                .focused(focus, equals: .code)
                .opacity(0.02)
                .onChange(of: code) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value { code = digits }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let digit = index < code.count ? String(Array(code)[index]) : ""
                    Text(digit)
                        .font(.title.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(index == code.count && focused ? Color.accent : Color.line, lineWidth: index == code.count && focused ? 2 : 1)
                        )
                        .contentTransition(.numericText())
                        .animation(.snappy, value: code)
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = .code }
    }
}
