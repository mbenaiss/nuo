import ActivityKit
import Foundation

/// The lock screen and Dynamic Island activity of the session in progress: local updates only, the rest counts down
/// by itself (`Text(timerInterval:)`), so a suspended app still shows it right.
@MainActor
final class MuscuActivity {
    private typealias State = MuscuActivityAttributes.ContentState

    private var activityId: String?
    private var lastState: State?

    func update(session: MuscuSession, run: MuscuRun) {
        let state = State(step: run.stepLabel(in: session), restUntil: run.rest?.until, restTotal: run.rest?.total,
                          setsDone: run.setsDone, setsTotal: session.sets * session.blocks.count)
        guard state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: nil)
        // One left by a previous launch (app killed mid-session) is taken back rather than doubled.
        if activityId == nil {
            activityId = Activity<MuscuActivityAttributes>.activities.first { $0.activityState == .active }?.id
        }
        if let id = activityId {
            Self.withActivities(where: { $0.id == id }) { await $0.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activityId = try? Activity.request(
            attributes: MuscuActivityAttributes(sessionName: session.name, startedAt: run.startedAt), content: content, pushType: nil).id
    }

    func end() {
        lastState = nil
        activityId = nil
        Self.withActivities(where: { _ in true }) { await $0.end(nil, dismissalPolicy: .immediate) }
    }

    nonisolated private static func withActivities(
        where match: @escaping @Sendable (Activity<MuscuActivityAttributes>) -> Bool,
        _ body: @escaping @Sendable (Activity<MuscuActivityAttributes>) async -> Void
    ) {
        Task.detached {
            for activity in Activity<MuscuActivityAttributes>.activities where match(activity) { await body(activity) }
        }
    }
}
