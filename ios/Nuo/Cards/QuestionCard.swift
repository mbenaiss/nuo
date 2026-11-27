import SwiftUI

/// Where a message's question cards stand in the conversation.
struct QuestionContext: Equatable {
    /// The user's message that came after the card's message: once there is one, the card is answered.
    var reply: String?
    /// False while the bot is still writing, or answering another message.
    var canAnswer = true
}

/// `::question` markers of one message, asked one after the other; the answers go back to the bot as one message.
struct QuestionCard: View {
    let questions: [QuestionPayload]
    @Environment(\.sendCardPrompt) private var sendPrompt
    @Environment(\.questionContext) private var context
    @State private var step = 0
    @State private var answers: [Int: QuestionAnswer] = [:]
    @State private var writing = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.headerGap) {
            header
            if let reply = context.reply {
                answered(reply)
            } else {
                asking
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var index: Int { min(step, questions.count - 1) }
    private var isLast: Bool { index == questions.count - 1 }
    private var interactive: Bool { context.canAnswer && context.reply == nil && sendPrompt != nil }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Kicker(text: questions.count > 1 ? String(localized: "Questions") : String(localized: "Question"), symbol: "questionmark.bubble.fill")
            Spacer(minLength: 0)
            if context.reply != nil {
                Label("Answered", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.good)
            } else if questions.count > 1 {
                Text("\(index + 1)/\(questions.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.text2)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Question \(index + 1) of \(questions.count)")
            }
        }
    }

    // MARK: - Asking

    private var asking: some View {
        let question = questions[index]
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(inlineMarkdown(question.question))
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if question.multiple {
                    Text("Several choices allowed").font(.caption).foregroundStyle(Color.text2)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                VStack(spacing: Spacing.xs) {
                    ForEach(question.options, id: \.self) { option in
                        optionButton(option, in: question)
                    }
                    otherAnswer(question)
                }
                if step > 0 || question.multiple {
                    footer(question)
                }
            }
            .disabled(!interactive)
            .opacity(interactive ? 1 : 0.6)
        }
        .id(index)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
    }

    private func optionButton(_ option: String, in question: QuestionPayload) -> some View {
        let selected = answers[index]?.choices.contains(option) == true
        return Button { pick(option, in: question) } label: {
            HStack(spacing: Spacing.xs) {
                if question.multiple {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.body)
                        .foregroundStyle(selected ? Color.accent : Color.text3)
                }
                Text(option)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if selected && !question.multiple {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Color.accent)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentSoft : Color.chip, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(selected ? Color.accent.opacity(0.45) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func otherAnswer(_ question: QuestionPayload) -> some View {
        if writing {
            HStack(alignment: .bottom, spacing: Spacing.xs) {
                TextField("Your answer", text: otherText, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { submitOther(question) }
                if !question.multiple {
                    Button { submitOther(question) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(trimmedOther.isEmpty ? Color.text3 : Color.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedOther.isEmpty)
                    .accessibilityLabel(isLast ? String(localized: "Send") : String(localized: "Next question"))
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.accent.opacity(0.45), lineWidth: 1))
        } else {
            Button {
                Haptics.selection()
                writing = true
                Task { @MainActor in fieldFocused = true }
            } label: {
                Label("Other answer…", systemImage: "square.and.pencil")
                    .font(.subheadline)
                    .foregroundStyle(Color.text2)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func footer(_ question: QuestionPayload) -> some View {
        HStack(spacing: Spacing.xs) {
            if step > 0 {
                Button { back() } label: { ChipButtonLabel(title: String(localized: "Previous"), symbol: "chevron.left") }
                    .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if question.multiple {
                Button { commit() } label: {
                    ChipButtonLabel(title: isLast ? String(localized: "Send") : String(localized: "question.next", defaultValue: "Next"), symbol: isLast ? "paperplane.fill" : "chevron.right", prominent: true)
                }
                .buttonStyle(.plain)
                .disabled(answers[index]?.isEmpty ?? true)
                .opacity(answers[index]?.isEmpty ?? true ? 0.5 : 1)
            }
        }
    }

    private var otherText: Binding<String> {
        Binding(
            get: { answers[index]?.other ?? "" },
            set: { answers[index, default: QuestionAnswer()].other = $0 })
    }

    private var trimmedOther: String {
        (answers[index]?.other ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pick(_ option: String, in question: QuestionPayload) {
        Haptics.selection()
        guard question.multiple else {
            answers[index] = QuestionAnswer(choices: [option])
            advance()
            return
        }
        var picked = Set(answers[index]?.choices ?? [])
        if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
        answers[index, default: QuestionAnswer()].choices = question.options.filter(picked.contains)
    }

    private func submitOther(_ question: QuestionPayload) {
        guard question.multiple else {
            guard !trimmedOther.isEmpty else { return }
            answers[index] = QuestionAnswer(other: trimmedOther)
            advance()
            return
        }
        commit()
    }

    private func commit() {
        answers[index, default: QuestionAnswer()].other = trimmedOther.nilIfEmpty
        guard answers[index]?.isEmpty == false else { return }
        advance()
    }

    private func advance() {
        fieldFocused = false
        guard !isLast else { return send() }
        move(to: index + 1)
    }

    private func back() {
        Haptics.selection()
        move(to: index - 1)
    }

    private func move(to target: Int) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            step = target
            writing = !(answers[target]?.other ?? "").isEmpty
        }
    }

    private func send() {
        let all = questions.indices.map { answers[$0] ?? QuestionAnswer() }
        Haptics.send()
        sendPrompt?.send(QuestionReply.message(for: questions, answers: all))
    }

    // MARK: - Answered

    private func answered(_ reply: String) -> some View {
        let found = QuestionReply.answers(in: reply, for: questions)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(questions.enumerated()), id: \.offset) { position, question in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(inlineMarkdown(question.question))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let answer = found[position] {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                            Image(systemName: "arrowshape.turn.up.left.fill").font(.caption2).foregroundStyle(Color.text3)
                            Text(answer.text).font(.subheadline).foregroundStyle(Color.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Answer: \(answer.text)")
                    }
                }
            }
        }
    }
}
