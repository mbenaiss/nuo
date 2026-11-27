import SwiftUI

/// Drafts sent from a card during this launch: a card scrolled back into view says “Sent” rather than “deleted”.
@MainActor enum EmailDraftMemory {
    static var sent: Set<String> = []
}

/// `::email`: a Gmail draft the bot prepared. The card loads the draft as Gmail has it now, lets the user edit and save
/// it, and sends it after a native confirmation. Without the gateway it shows the line's fields, read only.
struct EmailDraftCard: View {
    let payload: EmailDraftPayload
    @Environment(\.emailDraftAPI) private var api
    @State private var latest: EmailDraftPayload?
    @State private var form: EmailDraftForm?
    @State private var phase = Phase.loading
    @State private var error: String?
    @State private var confirming = false
    @State private var expanded = false

    enum Phase: Equatable {
        case loading, ready, busy, offline, sent, gone
    }

    private var draft: EmailDraftPayload { latest ?? payload }
    private var editable: Bool { api != nil && (phase == .ready || phase == .busy) }
    private var pending: EmailDraftUpdate { form?.update ?? EmailDraftUpdate(to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject, body: draft.body) }

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.headerGap) {
            header
            if form != nil { editor } else { reader }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Color.bad).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task(id: payload) { await load() }
        .confirmationDialog(EmailDraftText.sendPrompt(pending), isPresented: $confirming, titleVisibility: .visible) {
            Button("Send") { Task { await send() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pending.subject.isEmpty ? String(localized: "(no subject)") : String(localized: "“\(pending.subject)”"))
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Kicker(text: String(localized: "Email draft"), symbol: "envelope.fill")
            Spacer(minLength: Spacing.xs)
            switch phase {
            case .loading, .busy:
                ProgressView().controlSize(.small)
            case .sent:
                status(String(localized: "Sent"), tint: .good)
            case .gone:
                status(String(localized: "Already sent or deleted"), tint: .text2)
            case .ready, .offline:
                EmptyView()
            }
        }
    }

    private func status(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold)).foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var reader: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if !draft.account.isEmpty { row(String(localized: "From"), draft.account) }
                row(String(localized: "To"), draft.to.isEmpty ? String(localized: "No recipient") : draft.to.joined(separator: ", "))
                if !draft.cc.isEmpty { row("Cc", draft.cc.joined(separator: ", ")) }
                if !draft.bcc.isEmpty { row(String(localized: "Bcc"), draft.bcc.joined(separator: ", ")) }
            }
            Text(draft.subject.isEmpty ? String(localized: "(no subject)") : draft.subject)
                .font(.headline).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Color.line)
            Text(draft.body)
                .font(.body).foregroundStyle(Color.ink)
                .lineSpacing(TextMetrics.lineSpacing)
                .lineLimit(expanded ? nil : 12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !expanded, isLong {
                Button("Show all") { withAnimation(.smooth) { expanded = true } }
                    .font(.subheadline.weight(.semibold)).tint(Color.accentInk).buttonStyle(.plain).foregroundStyle(Color.accentInk)
            }
        }
    }

    private var isLong: Bool {
        draft.body.count > 700 || draft.body.filter { $0 == "\n" }.count >= 12
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Color.text2).frame(width: 36, alignment: .leading)
            Text(value).font(.subheadline).foregroundStyle(Color.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !draft.account.isEmpty { row(String(localized: "From"), draft.account) }
            field(String(localized: "To"), text: binding(\.to), recipients: true)
            field("Cc", text: binding(\.cc), recipients: true)
            field(String(localized: "Bcc"), text: binding(\.bcc), recipients: true)
            field(String(localized: "Subject"), text: binding(\.subject), recipients: false)
            TextField("Message", text: binding(\.body), axis: .vertical)
                .lineLimit(5...18)
                .font(.body)
                .textFieldStyle(.plain)
                .padding(Spacing.sm)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
                .accessibilityLabel("Message")
        }
        .disabled(phase == .busy)
    }

    private func field(_ label: String, text: Binding<String>, recipients: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Color.text2).frame(width: 52, alignment: .leading)
            TextField(recipients ? String(localized: "name@example.com") : String(localized: "Subject"), text: text)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(recipients)
                #if os(iOS)
                .keyboardType(recipients ? .emailAddress : .default)
                .textInputAutocapitalization(recipients ? .never : .sentences)
                #endif
                .accessibilityLabel(label)
        }
        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
    }

    private func binding(_ key: WritableKeyPath<EmailDraftForm, String>) -> Binding<String> {
        Binding(get: { form?[keyPath: key] ?? "" }, set: { form?[keyPath: key] = $0 })
    }

    @ViewBuilder private var footer: some View {
        switch phase {
        case .sent:
            Text(draft.account.isEmpty ? String(localized: "Email sent.") : String(localized: "Email sent from \(draft.account)."))
                .font(.caption).foregroundStyle(Color.text2)
        case .gone:
            Text("This draft no longer exists in Gmail: it was sent or deleted.")
                .font(.caption).foregroundStyle(Color.text2)
        case .offline:
            HStack(spacing: Spacing.xs) {
                Text(api == nil ? String(localized: "Draft preview, read only.") : String(localized: "Gateway unreachable: read-only preview."))
                    .font(.caption).foregroundStyle(Color.text2)
                Spacer(minLength: 0)
                if api != nil {
                    Button { Task { await load() } } label: { ChipButtonLabel(title: String(localized: "Retry"), symbol: "arrow.clockwise") }
                        .buttonStyle(.plain)
                }
            }
        case .loading, .ready, .busy:
            if api != nil { actions }
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.xs) {
            if form == nil {
                Button {
                    Haptics.tap()
                    error = nil
                    withAnimation(.smooth) { form = EmailDraftForm(draft) }
                } label: { ChipButtonLabel(title: String(localized: "Edit"), symbol: "pencil") }
            } else {
                Button {
                    error = nil
                    withAnimation(.smooth) { form = nil }
                } label: { ChipButtonLabel(title: String(localized: "Cancel")) }
                Button { Task { await save() } } label: { ChipButtonLabel(title: String(localized: "Save")) }
            }
            Spacer(minLength: 0)
            Button(action: askToSend) { ChipButtonLabel(title: String(localized: "Send"), symbol: "paperplane.fill", prominent: true) }
        }
        .buttonStyle(.plain)
        .disabled(!editable || phase == .busy)
    }

    // MARK: - Gateway

    private func load() async {
        if EmailDraftMemory.sent.contains(payload.draftId) {
            phase = .sent
            return
        }
        guard let api else {
            phase = .offline
            return
        }
        phase = .loading
        do {
            latest = try await api.emailDraft(id: payload.draftId, account: payload.account.nilIfEmpty)
            phase = .ready
        } catch NuoError.notFound {
            phase = .gone
        } catch {
            phase = .offline
        }
    }

    @discardableResult
    private func save() async -> Bool {
        guard let api, let form else { return true }
        if let problem = form.problem {
            error = problem
            return false
        }
        phase = .busy
        do {
            let saved = try await api.saveEmailDraft(id: payload.draftId, account: payload.account.nilIfEmpty, update: form.update)
            withAnimation(.smooth) {
                latest = saved
                self.form = nil
            }
            error = nil
            phase = .ready
            Haptics.success()
            return true
        } catch NuoError.notFound {
            self.form = nil
            phase = .gone
            return false
        } catch {
            self.error = error.localizedDescription
            phase = .ready
            Haptics.error()
            return false
        }
    }

    private func askToSend() {
        if let problem = form?.problem ?? (draft.to.isEmpty ? String(localized: "Add at least one recipient.") : nil) {
            error = problem
            return
        }
        error = nil
        Haptics.tap()
        confirming = true
    }

    private func send() async {
        guard let api else { return }
        if let form {
            if form.differs(from: draft) {
                guard await save() else { return }
            } else {
                self.form = nil
            }
        }
        phase = .busy
        do {
            try await api.sendEmailDraft(id: payload.draftId, account: payload.account.nilIfEmpty)
            EmailDraftMemory.sent.insert(payload.draftId)
            withAnimation(.smooth) { phase = .sent }
            Haptics.success()
        } catch NuoError.notFound {
            phase = .gone
        } catch {
            self.error = error.localizedDescription
            phase = .ready
            Haptics.error()
        }
    }
}
