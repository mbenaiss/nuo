import SwiftUI

/// The gym session of the day, opened from the Coach's chat or `nuo://muscu`: one card per machine with its photo,
/// the sets to tick and the loads, the rest timer, and the session logged for the Coach at the end.
struct MuscuScreen: View {
    let onClose: () -> Void
    @Environment(SessionStore.self) private var session
    @State private var store = MuscuStore.shared
    @State private var confirmsAbandon = false
    @State private var confirmsFinish = false

    var body: some View {
        NavigationStack {
            content
                .background(Color.canvas)
                .navigationTitle(store.session?.name ?? String(localized: "Gym"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .task {
            store.attach(session.api)
            await store.load()
        }
        .confirmationDialog("Abandon this session?", isPresented: $confirmsAbandon, titleVisibility: .visible) {
            Button("Abandon without saving", role: .destructive) { store.abandon() }
        }
        .confirmationDialog("Finish now?", isPresented: $confirmsFinish, titleVisibility: .visible) {
            Button("Finish and save") { store.finishNow() }
        } message: {
            Text("The sets you did are sent to the Coach.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let current = store.session {
            if let run = store.run, run.sessionId == current.id {
                if run.isFinished {
                    MuscuRecap(store: store, session: current, run: run, onClose: {
                        store.close()
                        onClose()
                    })
                } else {
                    MuscuRunView(store: store, session: current, run: run)
                }
            } else {
                MuscuStart(store: store, session: current)
            }
        } else if store.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No session", systemImage: "dumbbell")
            } description: {
                Text(store.loadError ?? String(localized: "Ask the Coach to prepare a gym session."))
            } actions: {
                Button("Retry") { Task { await store.load() } }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: onClose) { Image(systemName: "xmark") }
                .accessibilityLabel("Close")
        }
        if let run = store.run, !run.isFinished {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { confirmsFinish = true } label: { Label("Finish session", systemImage: "flag.checkered") }
                    Button(role: .destructive) { confirmsAbandon = true } label: { Label("Abandon", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Options")
            }
        }
    }
}

// MARK: - Before starting

private struct MuscuStart: View {
    let store: MuscuStore
    let session: MuscuSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Kicker(text: MuscuPlan.isPlanned(session, on: .now) ? String(localized: "Today's session") : String(localized: "Session"), symbol: "dumbbell.fill")
                    Text(session.name).font(.title2.weight(.bold)).foregroundStyle(Color.ink)
                    Text(MuscuFormat.summary(session)).font(.subheadline).foregroundStyle(Color.text2)
                    if !session.note.isEmpty {
                        Text(session.note).font(.footnote).foregroundStyle(Color.text2).padding(.top, Spacing.xxs)
                    }
                }
                ForEach(Array(session.blocks.enumerated()), id: \.offset) { bi, block in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Block \(MuscuFormat.letter(bi))").font(.headline).foregroundStyle(Color.ink)
                        ForEach(Array(block.exercises.enumerated()), id: \.offset) { _, exercise in
                            HStack(spacing: Spacing.sm) {
                                MuscuPhoto(path: store.photo(for: exercise.name), size: 52)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                                    Text(startLine(exercise)).font(.caption).foregroundStyle(Color.text2)
                                }
                            }
                        }
                    }
                    .padding(CardMetrics.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md))
                }
                let others = store.sessions.filter { $0.id != session.id }
                if !others.isEmpty {
                    Text("Other sessions").font(.headline).foregroundStyle(Color.ink).padding(.top, Spacing.xs)
                    ForEach(others) { other in
                        Button { store.select(other.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(other.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                                    Text(MuscuFormat.summary(other)).font(.caption).foregroundStyle(Color.text2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3)
                            }
                            .padding(CardMetrics.padding)
                            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .padding(Spacing.gutter)
        }
        .safeAreaInset(edge: .bottom) {
            MuscuPrimaryButton(title: String(localized: "Start"), symbol: "play.fill") { store.start() }
                .padding(Spacing.gutter)
                .background(Color.canvas)
        }
    }

    private func startLine(_ exercise: MuscuExercise) -> String {
        var parts = ["\(session.sets) × \(exercise.reps)"]
        if let kg = store.loads.kg(for: exercise.name) { parts.append(String(localized: "\(MuscuFormat.kg(kg)) kg last time")) }
        if let alt = exercise.alts.first { parts.append(String(localized: "or \(alt)")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - During the session

private struct MuscuRunView: View {
    let store: MuscuStore
    let session: MuscuSession
    let run: MuscuRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Label { Text(run.startedAt, style: .timer).monospacedDigit() } icon: { Image(systemName: "stopwatch") }
                    Spacer()
                    Text("\(run.setsDone)/\(session.sets * session.blocks.count) sets")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.text2)

                if let rest = run.rest {
                    MuscuRestCard(rest: rest, next: run.stepLabel(in: session), onAdd: { store.addRest(15) }, onSkip: { store.endRest() })
                }

                MuscuBlockCard(store: store, session: session, run: run)

                let remaining = run.remainingBlocks(in: session)
                if !remaining.isEmpty {
                    Text("Switch block").font(.headline).foregroundStyle(Color.ink).padding(.top, Spacing.xs)
                    Text("Machine taken? Do another block, this one will wait.").font(.caption).foregroundStyle(Color.text2)
                    ForEach(remaining, id: \.self) { bi in
                        Button { store.switchBlock(to: bi) } label: {
                            HStack(spacing: Spacing.sm) {
                                Text(MuscuFormat.letter(bi)).font(.headline).frame(width: 32, height: 32)
                                    .background(Color.chip, in: Circle()).foregroundStyle(Color.ink)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(run.exercises(of: bi, in: session).map(\.name).joined(separator: " + "))
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).multilineTextAlignment(.leading)
                                    Text("\(run.done[bi])/\(session.sets) sets").font(.caption).foregroundStyle(Color.text2)
                                }
                                Spacer()
                            }
                            .padding(CardMetrics.compactPadding)
                            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .padding(Spacing.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Spacing.sm) {
                Button("Skip") { store.skipSet() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.text2)
                    .frame(height: 54)
                    .padding(.horizontal, Spacing.md)
                    .background(Color.chip, in: RoundedRectangle(cornerRadius: Radius.md))
                    .accessibilityHint("Skips this set without saving it")
                MuscuPrimaryButton(title: String(localized: "Set done"), symbol: "checkmark") { store.completeSet() }
            }
            .padding(Spacing.gutter)
            .background(Color.canvas)
        }
    }
}

private struct MuscuRestCard: View {
    let rest: MuscuRun.Rest
    let next: String
    let onAdd: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Text(rest.kind == .block ? String(localized: "Block change") : String(localized: "Rest")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentInk)
            // A rest that ends while this renders would make an empty range.
            let now = Date.now
            let end = max(rest.until, now)
            let start = min(now, end.addingTimeInterval(-TimeInterval(rest.total)))
            Text(timerInterval: now...end, countsDown: true)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
            ProgressView(timerInterval: start...end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(Color.accent)
            Text("Up next: \(next)").font(.footnote).foregroundStyle(Color.text2)
            HStack(spacing: Spacing.sm) {
                Button(action: onAdd) { Text(verbatim: "+15 s") }
                Button("Resume now", action: onSkip)
            }
            .buttonStyle(.bordered)
            .font(.subheadline.weight(.semibold))
        }
        .padding(CardMetrics.padding)
        .frame(maxWidth: .infinity)
        .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

private struct MuscuBlockCard: View {
    let store: MuscuStore
    let session: MuscuSession
    let run: MuscuRun

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text(run.stepLabel(in: session)).font(.title3.weight(.bold)).foregroundStyle(Color.ink)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<session.sets, id: \.self) { i in
                        Circle()
                            .fill(i < run.done[run.current] ? Color.good : i < run.done[run.current] + run.skipped[run.current] ? Color.text3 : Color.line)
                            .frame(width: 9, height: 9)
                    }
                }
                .accessibilityLabel("\(run.done[run.current]) of \(session.sets) sets done")
            }
            if let note = session.blocks[run.current].note {
                Text(note).font(.footnote).foregroundStyle(Color.text2)
            }
            ForEach(run.exercises(of: run.current, in: session)) { exercise in
                MuscuExerciseRow(store: store, block: run.current, exercise: exercise)
                if exercise.index < session.blocks[run.current].exercises.count - 1 {
                    Divider()
                }
            }
            if let rir = session.rir {
                Text("Keep \(rir) reps in reserve.").font(.caption).foregroundStyle(Color.text3)
            }
        }
        .padding(CardMetrics.padding)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

private struct MuscuExerciseRow: View {
    let store: MuscuStore
    let block: Int
    let exercise: MuscuRun.LiveExercise
    @State private var kgText = ""
    @FocusState private var kgFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                MuscuPhoto(path: store.photo(for: exercise.name), size: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.swapped ? "⇄ \(exercise.name)" : exercise.name)
                        .font(.headline).foregroundStyle(Color.ink)
                    if exercise.swapped {
                        Text("instead of \(exercise.base.name)").font(.caption).foregroundStyle(Color.text2)
                    }
                    if !exercise.alts.isEmpty {
                        Menu {
                            ForEach(exercise.alts, id: \.self) { alt in
                                Button(alt) { store.replace(block: block, exercise: exercise.index, with: alt) }
                            }
                        } label: {
                            Label(exercise.swapped ? String(localized: "Swap") : String(localized: "Machine taken"), systemImage: "arrow.triangle.swap")
                                .font(.caption.weight(.semibold))
                        }
                        .tint(Color.accentInk)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Spacing.md) {
                MuscuStepper(label: String(localized: "reps"), value: "\(exercise.reps)",
                             minus: { store.setReps(exercise.reps - 1, key: exercise.key) },
                             plus: { store.setReps(exercise.reps + 1, key: exercise.key) })
                HStack(spacing: 6) {
                    TextField(text: $kgText, prompt: Text(verbatim: "0")) { Text("Weight") }
                        .keyboardType(.decimalPad)
                        .focused($kgFocused)
                        .multilineTextAlignment(.center)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .frame(width: 72, height: 40)
                        .background(Color.chip, in: RoundedRectangle(cornerRadius: Radius.xs))
                    Text(verbatim: "kg").font(.subheadline).foregroundStyle(Color.text2)
                }
            }
        }
        .onAppear { kgText = exercise.kg.map { MuscuFormat.kg($0) } ?? "" }
        .onChange(of: exercise.kg) { _, kg in
            // A replacement brings its own last load; the user's own typing is left as typed.
            if Self.parse(kgText) != kg { kgText = kg.map { MuscuFormat.kg($0) } ?? "" }
        }
        .onChange(of: kgText) { _, text in
            let kg = Self.parse(text)
            if kg != exercise.kg { store.setKg(kg, key: exercise.key) }
        }
        .toolbar {
            if kgFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("OK") { kgFocused = false }
                }
            }
        }
    }

    static func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }
}

private struct MuscuStepper: View {
    let label: String
    let value: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: minus) { Image(systemName: "minus").frame(width: 40, height: 40) }
                .accessibilityLabel("Fewer \(label)")
            VStack(spacing: 0) {
                Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
                Text(label).font(.caption2).foregroundStyle(Color.text2)
            }
            .frame(minWidth: 44)
            Button(action: plus) { Image(systemName: "plus").frame(width: 40, height: 40) }
                .accessibilityLabel("More \(label)")
        }
        .foregroundStyle(Color.ink)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: Radius.xs))
    }
}

// MARK: - Recap

private struct MuscuRecap: View {
    let store: MuscuStore
    let session: MuscuSession
    let run: MuscuRun
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Kicker(text: String(localized: "Session finished"), symbol: "flag.checkered", tint: Color.good)
                    Text(session.name).font(.title2.weight(.bold)).foregroundStyle(Color.ink)
                    let sent = run.finishedBody()
                    Text("\(MuscuFormat.clock(sent.seconds)) · \(run.setsDone)/\(session.sets * session.blocks.count) sets")
                        .font(.subheadline).foregroundStyle(Color.text2)
                }
                ForEach(run.realOrder, id: \.self) { bi in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Block \(MuscuFormat.letter(bi))").font(.headline).foregroundStyle(Color.ink)
                        ForEach(lines(block: bi), id: \.self) { line in
                            Text(line).font(.subheadline).foregroundStyle(Color.ink)
                        }
                    }
                    .padding(CardMetrics.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.md))
                }
                uploadStatus
            }
            .padding(Spacing.gutter)
        }
        .safeAreaInset(edge: .bottom) {
            MuscuPrimaryButton(title: String(localized: "Close"), symbol: "checkmark", action: onClose)
                .padding(Spacing.gutter)
                .background(Color.canvas)
        }
    }

    @ViewBuilder
    private var uploadStatus: some View {
        if run.uploaded {
            Label("Saved for the Coach", systemImage: "checkmark.circle.fill").foregroundStyle(Color.good)
        } else if case let .failed(message) = store.upload {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Not sent to the Coach yet", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.bad)
                Text(message).font(.caption).foregroundStyle(Color.text2)
                Button("Retry") { Task { await store.send() } }.buttonStyle(.bordered)
            }
        } else {
            Label("Sending to the Coach…", systemImage: "arrow.up.circle").foregroundStyle(Color.text2)
        }
    }

    /// "Pec Fly · 3 × 12 · 40 → 42.5 kg" per exercise of the block, in the order of the superset.
    private func lines(block: Int) -> [String] {
        var rows: [(index: Int, name: String, base: String, reps: [Int], kgs: [Double])] = []
        for set in run.log where set.block == block {
            for (index, exercise) in set.exercises.enumerated() {
                if let i = rows.firstIndex(where: { $0.index == index && $0.name == exercise.name }) {
                    rows[i].reps.append(exercise.reps)
                    if let kg = exercise.kg { rows[i].kgs.append(kg) }
                } else {
                    rows.append((index, exercise.name, exercise.base, [exercise.reps], exercise.kg.map { [$0] } ?? []))
                }
            }
        }
        return rows.sorted { $0.index < $1.index }.map { row in
            let reps = Set(row.reps).count == 1 ? "\(row.reps.count) × \(row.reps[0])" : row.reps.map(String.init).joined(separator: ", ")
            var line = (row.name != row.base ? "⇄ " : "") + "\(row.name) · \(reps)"
            if let first = row.kgs.first, let last = row.kgs.last {
                line += first == last ? " · \(MuscuFormat.kg(last)) kg" : " · \(MuscuFormat.kg(first)) → \(MuscuFormat.kg(last)) kg"
            }
            return line
        }
    }
}

// MARK: - Pieces

private struct MuscuPhoto: View {
    let path: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let path {
                RemoteImage(url: path)
            } else {
                Image(systemName: "dumbbell.fill").font(.system(size: size * 0.35)).foregroundStyle(Color.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.chip)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
        .accessibilityHidden(true)
    }
}

private struct MuscuPrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(Color.onInk)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.inkFill, in: RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(PressableStyle())
    }
}
