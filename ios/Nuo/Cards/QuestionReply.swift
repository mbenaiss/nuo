import Foundation

/// What the user picked for one `::question`: some of its options, their own words, or both.
struct QuestionAnswer: Hashable {
    var choices: [String] = []
    var other: String?

    var isEmpty: Bool { choices.isEmpty && (other ?? "").isEmpty }

    var text: String {
        (choices + [other].compactMap { $0?.nilIfEmpty }).joined(separator: ", ")
    }
}

/// The message a question card sends back, and the answers it can read again from that message.
enum QuestionReply {
    static let arrow = " → "

    /// A lone question is answered as the user would type it; a series puts each question before its answer so the
    /// bot knows which answer goes where.
    static func message(for questions: [QuestionPayload], answers: [QuestionAnswer]) -> String {
        guard questions.count > 1 else { return answers.first.map(\.text) ?? "" }
        return zip(questions, answers).map { question, answer in
            singleLine(question.question) + arrow + singleLine(answer.text)
        }
        .joined(separator: "\n")
    }

    /// The answers found in the user's reply, one per question; nil where the reply does not say.
    static func answers(in reply: String, for questions: [QuestionPayload]) -> [QuestionAnswer?] {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard questions.count > 1 else {
            return questions.map { question in choices(in: reply, options: question.options).map { QuestionAnswer(choices: $0) } }
        }
        let lines = reply.components(separatedBy: .newlines)
        return questions.map { question in
            let head = singleLine(question.question) + arrow
            guard let line = lines.first(where: { $0.range(of: head, options: [.anchored, .caseInsensitive]) != nil }) else { return nil }
            let said = String(line.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
            guard !said.isEmpty else { return nil }
            return choices(in: said, options: question.options).map { QuestionAnswer(choices: $0) } ?? QuestionAnswer(other: said)
        }
    }

    /// Reads `text` as options joined by ", ". Longest options first, so an option holding a comma still matches.
    static func choices(in text: String, options: [String]) -> [String]? {
        let candidates = options.sorted { $0.count > $1.count }
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var found: [String] = []
        while !rest.isEmpty {
            let match = candidates.lazy.compactMap { option -> (String, Substring)? in
                guard let range = rest.range(of: option, options: [.anchored, .caseInsensitive]) else { return nil }
                let after = rest[range.upperBound...]
                if after.isEmpty { return (option, after) }
                guard after.hasPrefix(",") else { return nil }
                return (option, after.dropFirst().drop(while: \.isWhitespace))
            }.first
            guard let (option, after) = match else { return nil }
            if !found.contains(option) { found.append(option) }
            rest = after
        }
        return found.isEmpty ? nil : found
    }

    /// The series format reads one question per line, so typed answers keep to one line there.
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
