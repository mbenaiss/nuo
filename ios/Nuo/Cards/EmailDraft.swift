import Foundation

/// What `PUT /api/google/drafts/:id` takes: every field, so the draft becomes exactly what the card shows.
struct EmailDraftUpdate: Encodable, Equatable, Sendable {
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
}

/// The card's editable copy of a draft: recipients as the comma lists a person types.
struct EmailDraftForm: Equatable {
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String

    init(_ draft: EmailDraftPayload) {
        to = draft.to.joined(separator: ", ")
        cc = draft.cc.joined(separator: ", ")
        bcc = draft.bcc.joined(separator: ", ")
        subject = draft.subject
        body = draft.body
    }

    var update: EmailDraftUpdate {
        EmailDraftUpdate(
            to: EmailDraftPayload.addresses(to), cc: EmailDraftPayload.addresses(cc), bcc: EmailDraftPayload.addresses(bcc),
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines), body: body)
    }

    /// Whether saving would change the draft; spacing around commas is not a change.
    func differs(from draft: EmailDraftPayload) -> Bool {
        update != EmailDraftUpdate(to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject, body: draft.body)
    }

    /// Why the draft cannot be sent as it stands, in the card's words.
    var problem: String? {
        update.to.isEmpty ? String(localized: "Add at least one recipient.") : nil
    }
}

enum EmailDraftText {
    /// `Julie Martin <julie.martin@lumen.example>` → `julie.martin@lumen.example`.
    static func address(_ recipient: String) -> String {
        guard let open = recipient.lastIndex(of: "<"), let close = recipient.lastIndex(of: ">"), open < close else {
            return recipient.trimmingCharacters(in: .whitespaces)
        }
        return String(recipient[recipient.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }

    /// “Send to julie.martin@lumen.example?”, with the others counted rather than listed.
    static func sendPrompt(_ update: EmailDraftUpdate) -> String {
        let everyone = update.to + update.cc + update.bcc
        guard let first = everyone.first else { return String(localized: "Send this email?") }
        let recipient = address(first)
        return switch everyone.count - 1 {
        case 0: String(localized: "Send to \(recipient)?")
        case 1: String(localized: "Send to \(recipient) and 1 other recipient?")
        case let others: String(localized: "Send to \(recipient) and \(others) other recipients?")
        }
    }
}
