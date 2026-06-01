import Foundation
import ActivityKit

/// Wraps ActivityKit so the rest of the app can start/update/end the workout
/// Live Activity with a single call. Also mirrors the staged session into
/// the App Group store so the widget's `ToggleSetIntent` can advance through
/// exercises without an open app.
///
/// All methods are safe to call on any iOS version; they no-op on iOS < 16.2.
final class LiveActivityService {

    // MARK: - Singleton

    static let shared = LiveActivityService()
    private init() {}

    // MARK: - In-memory reference

    private var currentActivity: Any?

    // MARK: - Capability check

    /// True iff iOS supports Live Activities AND the user has them enabled
    /// for this app in Settings.
    var isEnabled: Bool {
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }

    // MARK: - Start

    /// Start a fresh Live Activity for the given staged session.
    /// Returns the activity ID on success, throws on failure.
    ///
    /// Persists the session into the App Group store so the widget
    /// extension's `ToggleSetIntent` can read it back when the user
    /// taps a set button on the Lock Screen.
    /// Start a Live Activity for the staged session.
    ///
    /// - Parameters:
    ///   - staged: The session DTO mirrored into App Group storage.
    ///   - startExerciseIndex: Which exercise to surface on the
    ///     Lock Screen card initially. Defaults to 0 (first
    ///     exercise) but the caller in TrainView passes the index
    ///     of the first NOT-fully-completed exercise so a user
    ///     who's done half the workout in-app doesn't see the
    ///     Live Activity rewind to "exercise 1" when they tap
    ///     Start.
    ///   - initialSetsCompleted: Per-set completion flags for the
    ///     starting exercise. Lets the LA reflect partial in-app
    ///     progress on the visible exercise. Defaults to all-false
    ///     when the starting exercise hasn't been touched.
    ///   - priorSetsDone: Sets the user has already completed on
    ///     exercises BEFORE the starting one. Drives the top
    ///     session-wide progress bar so it shows the right "X / Y
    ///     done" number from the moment the LA appears.
    @available(iOS 16.2, *)
    @discardableResult
    func start(
        staged: StagedSessionDTO,
        startExerciseIndex: Int = 0,
        initialSetsCompleted: [Bool]? = nil,
        priorSetsDone: Int = 0
    ) async throws -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LAError.disabled
        }
        guard !staged.exercises.isEmpty else {
            throw LAError.emptySession
        }
        // Clamp the index defensively so a stale/oversized value
        // doesn't crash the request — fall back to 0 if out of range.
        let idx = staged.exercises.indices.contains(startExerciseIndex)
            ? startExerciseIndex
            : 0
        let startExercise = staged.exercises[idx]

        // Always end any lingering activity first (in-memory OR from previous
        // app sessions) — iOS limits each app to a small number of concurrent
        // activities, and a leftover one is a common cause of request failures.
        await endAll()

        // Persist staged session to App Group so the widget can advance
        // through exercises without IPC back to the main app.
        WorkoutGroupStore.saveStagedSession(staged)
        // Clear any stale pending sets from a previous session.
        WorkoutGroupStore.clearPendingSets()

        // Total session sets = sum across every exercise — drives the
        // top progress bar on the Live Activity card.
        let totalSessionSets = staged.exercises.reduce(0) { $0 + max($1.sets, 1) }

        // Set-completion flags for the starting exercise. Defaults
        // to all-false when the caller didn't provide partial
        // progress; otherwise we trust the caller to size the
        // array correctly (TrainView pads as needed).
        let setsForStart = initialSetsCompleted
            ?? Array(repeating: false, count: max(startExercise.sets, 1))

        let attrs = WorkoutActivityAttributes(sessionName: staged.name)
        let state = WorkoutActivityAttributes.ContentState(
            exerciseName:     startExercise.name,
            exerciseIndex:    idx,
            totalExercises:   staged.exercises.count,
            setsCompleted:    setsForStart,
            targetReps:       startExercise.reps,
            weightKg:         startExercise.weightKg,
            weightLabel:      startExercise.bodyweight ? "BW" : nil,
            targetRpe:        startExercise.rpe,
            tag:              startExercise.tag,
            focus:            startExercise.focus,
            restEndsAt:       .distantPast,
            // Per-exercise rest seconds. Fallback to session-level value
            // only if the per-exercise field wasn't populated.
            restSeconds:      max(15, startExercise.restSeconds > 0 ? startExercise.restSeconds : staged.restSeconds),
            priorSetsDone:    priorSetsDone,
            totalSessionSets: totalSessionSets
        )

        let activity = try Activity<WorkoutActivityAttributes>.request(
            attributes: attrs,
            content: .init(state: state, staleDate: nil),
            pushType: nil
        )
        currentActivity = activity
        print("[LiveActivity] started id=\(activity.id) exercise=\(startExercise.name) (idx=\(idx), prior=\(priorSetsDone))")
        return activity.id
    }

    // MARK: - Update

    /// Push a new state to the running activity. No-ops if none is running.
    /// Used by the main app's TrainView when the user taps a set inside the
    /// app — keeps the Lock Screen widget in sync.
    @available(iOS 16.2, *)
    func update(_ state: WorkoutActivityAttributes.ContentState) async {
        guard let activity = currentActivity as? Activity<WorkoutActivityAttributes> else { return }
        await activity.update(.init(state: state, staleDate: nil))
    }

    /// Reflect an in-app set toggle in the running Live Activity. Called
    /// from TrainView's `toggleSet` so the Lock Screen card mirrors the
    /// in-app checkmarks instead of staying frozen at the staged state.
    ///
    /// Behaviour:
    ///   • No-op if no activity is running.
    ///   • No-op if the activity is currently showing a DIFFERENT exercise
    ///     than the one being toggled — the Lock Screen card stays on
    ///     whatever it was advanced to, the user's in-app progress on
    ///     other exercises is just kept locally until they finish.
    ///   • Otherwise flips the bit at `setIdx`, kicks a rest timer when
    ///     the bit went false→true, and auto-advances to the next
    ///     exercise (if any) when every set is done — same flow the
    ///     `ToggleSetIntent` runs from a Lock Screen tap.
    @available(iOS 16.2, *)
    func syncSetCompletion(
        exerciseName: String,
        setIdx: Int,
        completed: Bool,
        restEndsAt: Date? = nil
    ) async {
        guard let activity = currentActivity as? Activity<WorkoutActivityAttributes>
        else { return }
        var state = activity.content.state
        // Only act when the LA is showing this exercise — case-insensitive
        // so casing drift in user data doesn't drop the sync.
        guard state.exerciseName.lowercased() == exerciseName.lowercased(),
              state.setsCompleted.indices.contains(setIdx)
        else { return }
        let was = state.setsCompleted[setIdx]
        state.setsCompleted[setIdx] = completed
        if completed && !was {
            // Set just completed — start the rest timer. Use the EXACT
            // end date the in-app timer computed (passed in) so both
            // countdowns target the same instant and never drift; fall
            // back to computing it here if the caller didn't supply one
            // (e.g. a Lock Screen tap, which has no in-app timer).
            state.restEndsAt = restEndsAt
                ?? Date().addingTimeInterval(Double(state.restSeconds))
        } else if !completed && was {
            // Un-toggle — cancel the timer for symmetry.
            state.restEndsAt = .distantPast
        }

        if state.allSetsDone {
            // Try to advance to the next exercise just like the App
            // Intent does. Don't end the activity here even on last
            // exercise — leave it for the in-app Finish Session
            // flow so the summary modal can run.
            if let staged = WorkoutGroupStore.loadStagedSession() {
                let nextIdx = state.exerciseIndex + 1
                if staged.exercises.indices.contains(nextIdx) {
                    let next = staged.exercises[nextIdx]
                    // Roll the session-progress counter forward: the
                    // current exercise's sets just moved from "current"
                    // to "prior".
                    let newPriorDone = state.priorSetsDone + state.setsCompleted.count
                    let nextRest = max(15, next.restSeconds > 0 ? next.restSeconds : state.restSeconds)
                    state = WorkoutActivityAttributes.ContentState(
                        exerciseName:     next.name,
                        exerciseIndex:    nextIdx,
                        totalExercises:   staged.exercises.count,
                        setsCompleted:    Array(repeating: false, count: max(next.sets, 1)),
                        targetReps:       next.reps,
                        weightKg:         next.weightKg,
                        weightLabel:      next.bodyweight ? "BW" : nil,
                        targetRpe:        next.rpe,
                        tag:              next.tag,
                        focus:            next.focus,
                        restEndsAt:       Date().addingTimeInterval(Double(nextRest)),
                        restSeconds:      nextRest,
                        priorSetsDone:    newPriorDone,
                        totalSessionSets: state.totalSessionSets
                    )
                }
            }
        }
        await activity.update(.init(state: state, staleDate: nil))
    }

    /// Reflect an in-app weight change in the running Live Activity so
    /// the Lock Screen card shows the same kg the user just dialled in.
    /// Called from TrainView's weight stepper. No-op unless the LA is
    /// currently showing the same exercise the user is editing.
    @available(iOS 16.2, *)
    func syncWeight(
        exerciseName: String,
        weightKg: Double,
        bodyweight: Bool
    ) async {
        guard let activity = currentActivity as? Activity<WorkoutActivityAttributes>
        else { return }
        var state = activity.content.state
        guard state.exerciseName.lowercased() == exerciseName.lowercased()
        else { return }
        state.weightKg = weightKg
        // Keep the BW label in sync: a >0 weight clears it, a 0/BW
        // exercise keeps showing "BW".
        state.weightLabel = (bodyweight || weightKg <= 0) ? "BW" : nil
        await activity.update(.init(state: state, staleDate: nil))
    }

    // MARK: - End

    /// End the current activity and dismiss it immediately. Also cleans up any
    /// lingering activities of the same type from previous app sessions and
    /// wipes the App Group staged session.
    func end() async {
        if #available(iOS 16.2, *) {
            await endAll()
        }
        WorkoutGroupStore.clearStagedSession()
    }

    // MARK: - Private

    @available(iOS 16.2, *)
    private func endAll() async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }

    // MARK: - Errors

    enum LAError: LocalizedError {
        case disabled
        case emptySession
        var errorDescription: String? {
            switch self {
            case .disabled:
                return "Live Activities are disabled. Enable them in Settings → HEX → Live Activities."
            case .emptySession:
                return "There are no exercises in the current session."
            }
        }
    }
}
