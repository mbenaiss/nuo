import SwiftUI

/// The watch's one button: opens on the microphone. Sent within the minute, it is a request whose answer replaces this
/// screen; past the minute, the recorder takes over without stopping.
struct CaptureView: View {
    @Binding var path: [WatchRoute]
    @Environment(WatchSession.self) private var session
    private var recorder: VoiceRecorder { VoiceRecorder.shared }
    private var ask: AskCenter { AskCenter.shared }
    private var uplink: RecordingUplink { RecordingUplink.shared }

    var body: some View {
        Group {
            switch recorder.phase {
            case .starting:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Starting the microphone…").font(.footnote).foregroundStyle(.secondary)
                }
            case .recording where recorder.isTentative:
                ScrollView {
                    ListeningPanel(targetName: targetName, level: recorder.level, seconds: recorder.elapsed, becomesRecording: true,
                                   onSend: { Task { await recorder.send() } }, onCancel: cancel)
                }
            case .recording, .interrupted:
                RecorderScreen(
                    state: recorder.phase == .recording ? .recording : .interrupted, elapsed: recorder.elapsed, level: recorder.level,
                    markers: recorder.markerCount, markerPulse: recorder.markerPulse, warning: recorder.error ?? recorder.warning,
                    onMark: recorder.mark, onResume: recorder.resume, onStop: recorder.stop)
            case .finished:
                ScrollView {
                    RecorderFinishedScreen(
                        duration: recorder.journal?.duration ?? 0, markers: recorder.markerCount, transfer: transfer,
                        interrupted: recorder.journal?.manifest.interrupted ?? false) {
                        recorder.dismiss()
                        leave()
                    }
                }
            case .idle:
                ScrollView {
                    request.frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(isRecorder ? String(localized: "Record") : "Nuo")
        .task {
            // A request still on its way lives in the queue: it never stops a new capture.
            if recorder.phase == .idle, recorder.error == nil { start() }
        }
        .onDisappear {
            // Left within the minute: a request is not sent behind the user's back. A recording goes on.
            if recorder.isTentative { recorder.cancel() }
            if recorder.phase == .idle { ask.resetPhase() }
        }
        .onChange(of: recorder.answer) { _, delivery in
            guard let delivery else { return }
            recorder.consumeAnswer()
            open(delivery)
        }
        .onChange(of: ask.arrived) { _, delivery in
            // Sent as a file with the iPhone in reach: the answer opens on the iPhone's word.
            guard let delivery, recorder.phase == .idle else { return }
            ask.consumeArrived()
            open(delivery)
        }
    }

    private var isRecorder: Bool {
        switch recorder.phase {
        case .recording: !recorder.isTentative
        case .interrupted, .finished: true
        case .idle, .starting: false
        }
    }

    private var targetName: String { AskTarget.defaultBot(in: session.bots)?.displayName ?? "Nuo" }

    /// After the capture: the request on its way, kept, refused, or the microphone again.
    @ViewBuilder private var request: some View {
        VStack(spacing: 8) {
            if let error = recorder.error {
                Label(error, systemImage: "mic.slash.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.accent)
                Button("Try again", action: start)
            } else {
                switch ask.phase {
                case .sending:
                    ProgressView()
                    Text(ask.sendingLive ? String(localized: "Sending via iPhone…") : String(localized: "Sending to iPhone…")).font(.footnote).foregroundStyle(.secondary)
                case .queued:
                    QueuedAskPanel(reason: ask.queuedReason, onDone: leave)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.accent)
                    Button("Try again", action: start)
                case .idle, .listening, .capped:
                    VoiceButton(size: 80, action: start)
                    Text("Tap to talk to \(targetName)").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }

    private var transfer: RecordingTransferState {
        guard let id = recorder.journal?.id else { return .sending(left: 0) }
        if recorder.isDemo { return .sending(left: 1) }
        if uplink.isDelivered(id) { return .delivered }
        let left = uplink.pendingSegments(id)
        return uplink.phoneReachable ? .sending(left: left) : .waitingPhone(left: left)
    }

    private func start() {
        ask.resetPhase()
        Task { await recorder.start() }
    }

    private func cancel() {
        recorder.cancel()
        leave()
    }

    /// Only this screen is taken off the stack, never the one under it.
    private func leave() {
        if path.last == .capture { path.removeLast() }
    }

    private func open(_ delivery: AskCenter.Delivery) {
        // The iPhone's reply and its acknowledgement can both bring the same answer: a second screen would miss the turn's start.
        if case let .answer(shown) = path.last, shown.askId == delivery.askId { return }
        leave()
        path.append(.answer(delivery))
    }
}
