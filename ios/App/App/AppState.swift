import Foundation
import SwiftUI
import Supabase
import Combine
import ActivityKit

/// Top-level observable state shared across the app.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Auth

    enum AuthPhase: Equatable {
        case checking      // initial load — restoring session
        case signedOut
        case awaitingOTP(email: String)
        case signedIn
    }

    /// Tab selection mirrored from MainTabView so any view can request a
    /// switch (Home's "Today's session" card → Train, for example). The
    /// raw value matches React's `activeTab` strings to keep the parity
    /// model legible.
    enum Tab: String, Hashable {
        case home, train, progress, bros, pt, profile
    }

    // MARK: - Logical day rollover (late-night training grace period)

    /// Hours after midnight where the app still treats the previous
    /// day as "today". Lets users who train late (e.g. finishing at
    /// 01:30 local) have their session count for the day they intended
    /// rather than tomorrow.
    ///
    /// With offset = 2:
    ///   • Sun 23:30 → logicalToday = Sunday
    ///   • Mon 00:30 → logicalToday = Sunday (still grace period)
    ///   • Mon 01:59 → logicalToday = Sunday
    ///   • Mon 02:00 → logicalToday = Monday
    ///
    /// Used by: session save date, calendar "today" indicator, streak
    /// counter, "trained today" flag, programme's today-session pick.
    /// NOT used for relative-time displays ("3 min ago") — those keep
    /// using `Date()` so the time matches reality.
    static let dayRolloverOffsetHours: Int = 2

    /// `Date()` shifted back by `dayRolloverOffsetHours`. Use anywhere
    /// you'd reach for `Date()` to answer "what day is it".
    static var logicalNow: Date {
        Date().addingTimeInterval(-Double(dayRolloverOffsetHours) * 3600)
    }

    /// Start-of-day of `logicalNow`. Equivalent to "the calendar cell
    /// the user is currently inside" given the rollover offset.
    static var logicalToday: Date {
        Calendar.current.startOfDay(for: logicalNow)
    }

    /// Map any timestamp to its logical day (start-of-day after the
    /// offset is subtracted). Used to compare timestamps from other
    /// users (activity feed, friend sessions) against the current
    /// user's logical day on equal footing.
    static func logicalDate(of date: Date) -> Date {
        let shifted = date.addingTimeInterval(-Double(dayRolloverOffsetHours) * 3600)
        return Calendar.current.startOfDay(for: shifted)
    }

    @Published var authPhase: AuthPhase = .checking
    @Published var currentProfile: Profile?
    @Published var activeTab: Tab = .home

    // MARK: - Programme + session state

    @Published var activeProgramme: Programme?
    @Published var currentSession: WorkoutSession?
    /// Set when the user taps "Finish Session" — drives the Session
    /// Complete sheet at the root of ContentView. Tapping "Save Session"
    /// inside the sheet triggers `confirmFinishSession()` which runs the
    /// actual persistence; tapping Cancel just clears this back to nil.
    /// Mirrors React's `showSummary` flag + `<SummarySheet>` modal.
    @Published var pendingSessionSummary: SessionSummary?
    /// Currently-selected week index (1-based) for the Home tab week pills.
    /// Mirrors React's `currentWeek` state. Defaults to 1 and is clamped
    /// to the programme's available weeks whenever the programme arrives.
    @Published var currentWeek: Int = 1
    /// Most recent N completed/in-progress sessions, ordered newest first.
    /// Populated by `loadHistory()` after sign-in and refreshed after each
    /// `finishWorkout(_:sets:)` call.
    @Published var workoutHistory: [WorkoutSession] = []

    /// Cached working-weights map (exercise key/name → current weight in kg).
    /// Used by PT chat for the "current lifts" snapshot.
    @Published var workingWeights: [String: Double] = [:]

    /// User-created exercises that show up in `ExercisePickerSheet`. Loaded
    /// once on sign-in, then mutated in-memory and replace-written by
    /// `addCustomExercise(_:)`.
    @Published var customExercises: [CustomExercise] = []

    // MARK: - Social state (friends / requests / activity)

    @Published var friends: [FriendListEntry] = []
    @Published var pendingRequests: [PendingRequest] = []
    @Published var activityFeed: [ActivityRow] = []

    /// All leagues the current user is an accepted member of, each
    /// pre-bundled with its full leaderboard so CrewView and
    /// LeagueDetailView can render without a per-card secondary
    /// fetch. Loaded by `loadLeagues()` alongside friends/activity.
    @Published var myLeagues: [LeagueWithMembers] = []
    /// Cached "user trained today" set used for friend-bubble ring colour.
    @Published var friendsTrainedToday: Set<UUID> = []
    /// Composed leaderboard rows (me + friends) ranked by score DESC. Recomputed
    /// every time `friends` or `currentProfile.leaderboard_data` changes.
    @Published var leaderboard: [LeaderboardEntry] = []

    // MARK: - UI state

    /// Language is now persisted to `profiles.language` whenever it changes.
    /// Call `setLanguage(_:)` to update it — the published var is the source
    /// of truth in-memory and writes round-trip through Supabase so the
    /// choice survives across iOS↔web sign-ins.
    @Published var language: String = "en"   // "en" | "ar"
    /// One-shot toast text. Setting any non-nil value auto-clears after 3s,
    /// so any code path (including direct `app.toast = "..."` assignments)
    /// gets the dismiss-timer behaviour for free.
    @Published var toast: String? {
        didSet {
            guard let msg = toast else { return }
            // Capture the message we just set; only clear if it's still the
            // current value 3s later (so a newer toast wins).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.toast == msg { self.toast = nil }
            }
        }
    }
    /// One-shot confetti trigger — TrainView increments this on session save
    /// and ContentView watches it to play the burst animation.
    @Published var confettiTrigger: Int = 0

    /// Sets completed via the Live Activity Lock Screen / Dynamic Island
    /// during the current session, keyed by exercise name and storing the
    /// 0-indexed set positions. TrainView merges this into its local
    /// `completedSets` map on appear / scenePhase active, so opening the
    /// app mid-session shows the same green checks the user already saw
    /// on the Lock Screen card.
    ///
    /// Populated by `refreshLiveActivityCompletions()` from the App Group
    /// pending-set queue PLUS the currently-running activity's
    /// `ContentState.setsCompleted`. Survives `drainPendingSets` clearing
    /// the queue because the map is held here in-memory until the
    /// session resets.
    @Published var liveActivityCompletions: [String: Set<Int>] = [:]

    /// User-selected accent colour (the signature green/cream/etc. used
    /// across the app). Driven by the swatch picker in AccountView's
    /// Preferences section. Persisted to App Group UserDefaults so the
    /// WorkoutWidget extension reads the same value when rendering the
    /// Live Activity card.
    ///
    /// The actual `Color` value is computed live by
    /// `HexTheme.accent` / `HexTheme.accentDark` which read the same
    /// UserDefaults key — but we publish the raw string here so
    /// SwiftUI views observing AppState re-render and pick up the new
    /// `HexTheme.accent` value on the next body evaluation.
    /// Default is `cream` (#E7E5E0) per the user's choice of the
    /// app's main signature colour. Stored UserDefaults override
    /// this in `init()` if the user has previously picked something
    /// else.
    @Published var accentChoice: String = AccentChoice.cream.rawValue

    /// User-selected accent MATERIAL — matte (flat), glossy (wet-look
    /// vertical gradient), metal (brushed diagonal sheen), or neon
    /// (radial hot-spot glow). Same persistence and re-render story as
    /// `accentChoice`: written to App Group UserDefaults so the widget
    /// reads it, @Published here so SwiftUI views re-evaluate their
    /// body and pick up the new `HexTheme.accentFill` on next render.
    @Published var accentMaterial: String = AccentMaterial.matte.rawValue
    /// Invite code captured from a `hex://invite/...` deep link while signed
    /// out. Replayed automatically once `loadUserData` finishes.
    var pendingInviteCode: String?

    // MARK: - Realtime

    /// Subscriptions to friendships + activity_feed. Lifetime tied to
    /// signed-in state — started in `loadUserData`, stopped on sign-out.
    private lazy var realtimeSync = RealtimeSync(app: self)

    /// Combine bag for in-class subscriptions (e.g. the programme→session
    /// staging observer). Cleared automatically when AppState is released.
    private var bag: Set<AnyCancellable> = []

    // MARK: - Init / session restore

    init() {
        // Restore the user's accent-colour choice from App Group
        // UserDefaults (falls back to standard suite, then to cream
        // for fresh installs). Done before the rest of init so the
        // very first body evaluation already sees the user's chosen
        // colour rather than briefly flashing the default.
        let raw =
            UserDefaults(suiteName: "group.com.hexapp.training")?
                .string(forKey: HexTheme.accentChoiceKey)
            ?? UserDefaults.standard.string(forKey: HexTheme.accentChoiceKey)
            ?? AccentChoice.cream.rawValue
        if AccentChoice(rawValue: raw) != nil {
            self.accentChoice = raw
        }
        // Same restore for the accent material (matte / glossy / metal / neon).
        let rawMat =
            UserDefaults(suiteName: "group.com.hexapp.training")?
                .string(forKey: HexTheme.accentMaterialKey)
            ?? UserDefaults.standard.string(forKey: HexTheme.accentMaterialKey)
            ?? AccentMaterial.matte.rawValue
        if AccentMaterial(rawValue: rawMat) != nil {
            self.accentMaterial = rawMat
        }

        // Re-stage today's session whenever the active programme arrives or
        // changes (matches React's HomeTab effect on `programme/importedProgramme`
        // changes). Without this, if `loadActiveProgramme` finishes AFTER the
        // initial `stageCurrentSessionFromActiveProgramme` call, `currentSession`
        // is never set and the Train tab is stuck on its empty state.
        //
        // @Published fires its publisher in `willSet` (the subscriber gets the
        // new value but `self.activeProgramme` is still the OLD value at sink
        // time). Hopping through RunLoop.main defers to after the assignment
        // lands so `stageCurrentSessionFromActiveProgramme` sees the new row.
        $activeProgramme
            .removeDuplicates { $0?.id == $1?.id }
            .receive(on: RunLoop.main)
            .sink { [weak self] newProg in
                guard let self = self, let prog = newProg else { return }
                // Clamp currentWeek to the programme's actual week count so
                // the Home week-pill strip starts on a valid week even if
                // a previous programme had more weeks.
                let total = prog.data?.weeks.count ?? 1
                if self.currentWeek < 1 || self.currentWeek > total {
                    self.currentWeek = 1
                }
                if self.currentSession == nil {
                    self.stageCurrentSessionFromActiveProgramme()
                }
            }
            .store(in: &bag)

        Task { await restoreSession() }
    }

    // MARK: - Accent colour

    /// Persist the user's accent choice. Writes to App Group UserDefaults
    /// (so the WorkoutWidget extension picks up the new colour on the
    /// next Live Activity render), updates the @Published value (which
    /// re-renders every view observing AppState), and nudges any running
    /// Live Activity by re-pushing its current state — same `ContentState`,
    /// but the update call forces the widget to re-evaluate its body and
    /// read the new accent from UserDefaults.
    func setAccentChoice(_ choice: AccentChoice) {
        // No-op if the user tapped the already-selected swatch — avoids
        // a pointless Activity.update + UserDefaults write.
        guard accentChoice != choice.rawValue else { return }
        accentChoice = choice.rawValue

        // Write through to both App Group + standard suite so the
        // widget extension and any sandboxed read paths find it.
        let groupDefaults = UserDefaults(suiteName: "group.com.hexapp.training")
        groupDefaults?.set(choice.rawValue, forKey: HexTheme.accentChoiceKey)
        UserDefaults.standard.set(choice.rawValue, forKey: HexTheme.accentChoiceKey)

        // Swap the home-screen app icon to match the chosen accent.
        // Each accent has its own dumbbell-tinted variant bundled at
        // build time (`AppIconLime`, `AppIconCream`, ...).
        // `setAlternateIconName` requires the call from the main
        // thread; UIApplication.shared.supportsAlternateIcons is the
        // gate. iOS will show its system "HEX has changed its icon"
        // confirmation on each switch — unavoidable, every iOS app
        // that supports alt icons does this.
        let altName = "AppIcon\(choice.rawValue.capitalized)"
        DispatchQueue.main.async {
            guard UIApplication.shared.supportsAlternateIcons else { return }
            UIApplication.shared.setAlternateIconName(altName) { error in
                if let error = error {
                    print("[AppState] setAlternateIconName(\(altName)) failed:", error)
                }
            }
        }

        // Re-push the running Live Activity so the Lock Screen card
        // recolours immediately instead of waiting for the next set
        // toggle. Wrapped in `if #available` because the widget API
        // requires iOS 16.2+.
        if #available(iOS 16.2, *) {
            Task {
                for activity in Activity<WorkoutActivityAttributes>.activities {
                    await activity.update(.init(state: activity.content.state, staleDate: nil))
                }
            }
        }
    }

    /// Persist the user's accent-material choice (matte / glossy /
    /// metal / neon). Same triple-write + LA-refresh pattern as
    /// `setAccentChoice`: App Group + standard defaults so both
    /// processes see it, then a no-op Activity.update so the Lock
    /// Screen card repaints with the new material gradient.
    func setAccentMaterial(_ material: AccentMaterial) {
        guard accentMaterial != material.rawValue else { return }
        accentMaterial = material.rawValue

        let groupDefaults = UserDefaults(suiteName: "group.com.hexapp.training")
        groupDefaults?.set(material.rawValue, forKey: HexTheme.accentMaterialKey)
        UserDefaults.standard.set(material.rawValue, forKey: HexTheme.accentMaterialKey)

        if #available(iOS 16.2, *) {
            Task {
                for activity in Activity<WorkoutActivityAttributes>.activities {
                    await activity.update(.init(state: activity.content.state, staleDate: nil))
                }
            }
        }
    }

    // MARK: - Live Activity pending-set drain

    /// Read every Lock-Screen-completed set for the current session and
    /// publish a name→indices map onto `liveActivityCompletions`.
    /// Sources:
    ///   • App Group pending queue (sets the widget intent hasn't
    ///     handed off to the main app yet).
    ///   • Currently-running Activity's ContentState (the user's most
    ///     recent taps before the queue is observed, AND the source of
    ///     truth for the exercise currently visible on the LA card).
    ///
    /// Called from TrainView on appear + on scenePhase active so the
    /// in-app set-button grid mirrors what's checked on the Lock Screen.
    /// Cheap (synchronous, in-process) so re-running it on every
    /// foreground is fine. (Class is already @MainActor — no decorator
    /// needed on the method.)
    func refreshLiveActivityCompletions() {
        var map: [String: Set<Int>] = [:]

        // (1) Sets already queued from the Lock Screen (most recent,
        //     before drain runs).
        for p in WorkoutGroupStore.loadPendingSets() {
            // setNumber is 1-indexed in the DTO; store as 0-indexed
            // because that's what TrainView's exKey_<i> uses.
            let idx = max(0, p.setNumber - 1)
            map[p.exerciseName, default: []].insert(idx)
            // Feed the Lock-Screen tap's REAL timestamp into the
            // active-training-time store. The queue persists until
            // drain, so this re-runs on every foreground — the store
            // dedups identical instants, making the repeat harmless.
            recordSetTick(at: p.completedAt, sessionId: p.sessionId)
        }

        // (2) Currently-visible exercise on the LA card — its
        //     `setsCompleted` is the freshest signal for that one
        //     exercise (the queue can lag by a hop if the user just
        //     tapped while the app was already foregrounding).
        if #available(iOS 16.2, *) {
            if let activity = Activity<WorkoutActivityAttributes>.activities.first {
                let state = activity.content.state
                for (i, done) in state.setsCompleted.enumerated() where done {
                    map[state.exerciseName, default: []].insert(i)
                }
            }
        }

        // Merge over previous published value rather than replace, so
        // exercises already advanced past (where the LA card has moved
        // on but their completions were captured earlier) don't get
        // dropped.
        var merged = liveActivityCompletions
        for (name, indices) in map {
            merged[name, default: []].formUnion(indices)
        }
        liveActivityCompletions = merged
    }

    /// Drain the App Group pending-sets queue written by the Lock Screen
    /// `ToggleSetIntent`. Called from `loadUserData()` and from
    /// ContentView's `.onChange(of: scenePhase)` handler so completed
    /// sets land in Supabase the next time the main app surfaces.
    ///
    /// Behaviour:
    ///   • Group queued sets by sessionId.
    ///   • For each group, if the sessionId matches the currently-staged
    ///     in-app session, merge the completions into `currentSession.data`
    ///     (so the Train tab reflects them instantly).
    ///   • Persist each set row to Supabase `sets`.
    ///   • If the Live Activity also marked a session as fully finished
    ///     (last-set tap drained), run the full `finishWorkout` path —
    ///     this writes the `sessions` row, recalculates leaderboard,
    ///     and inserts the activity-feed entry, matching what would have
    ///     happened if the user tapped "Save session" inside the app.
    func drainPendingSets() async {
        let pending = WorkoutGroupStore.loadPendingSets()
        let finishedIds = WorkoutGroupStore.loadFinishedSessionIds()
        // Seed the in-memory completions map BEFORE we clear the queue
        // below. Once the queue is gone, TrainView would otherwise lose
        // its ability to back-fill set-button checkmarks for prior
        // exercises (the LA's ContentState only carries the current
        // exercise). This call also fires when no pending sets exist —
        // cheap, idempotent, no harm. AppState is @MainActor so a
        // direct call here is already on the main actor.
        refreshLiveActivityCompletions()
        guard !pending.isEmpty || !finishedIds.isEmpty else { return }

        // Snapshot the staged session BEFORE we clear it — the finish
        // path needs the exercise list to reconstruct a WorkoutSession.
        let staged = WorkoutGroupStore.loadStagedSession()

        // Persist set rows first so the Supabase `sets` table reflects
        // exactly what the user tapped on the Lock Screen.
        let setRows: [PerformedSet] = pending.map { p in
            PerformedSet(
                id:           p.id,
                sessionId:    p.sessionId,
                userId:       currentProfile?.id ?? SupabaseManager.shared.currentUser?.id ?? UUID(),
                exerciseName: p.exerciseName,
                setNumber:    p.setNumber,
                reps:         p.reps,
                weight:       p.weightKg,
                rpe:          nil,
                completed:    true,
                failed:       false,
                createdAt:    p.completedAt
            )
        }
        if !setRows.isEmpty {
            do {
                try await SupabaseManager.shared.savePerformedSets(setRows)
            } catch {
                // Keep the queue intact so we retry next launch.
                print("[AppState] drainPendingSets — savePerformedSets failed:", error)
                return
            }
        }

        // Now finish any sessions the Lock Screen marked as complete.
        if !finishedIds.isEmpty, let staged = staged,
           finishedIds.contains(staged.sessionId)
        {
            do {
                try await finishWorkoutFromStaged(staged, pending: pending)
                toast = language == "ar" ? "تم حفظ الجلسة ✓" : "Session saved ✓"
            } catch {
                print("[AppState] drainPendingSets — finishWorkout failed:", error)
                // Don't clear the queue — let next launch retry.
                return
            }
        }

        // All good — clear the queue + finish markers.
        WorkoutGroupStore.clearPendingSets()
        WorkoutGroupStore.clearFinishedSessionIds()
        await loadHistory()
    }

    /// Reconstruct a WorkoutSession from a staged-DTO + the user's
    /// Lock-Screen taps, then run the same finish flow the in-app
    /// "Save session" button uses.
    private func finishWorkoutFromStaged(
        _ staged: StagedSessionDTO,
        pending: [PendingSetDTO]
    ) async throws {
        guard let uid = SupabaseManager.shared.currentUser?.id else { return }

        // Project the staged DTO back to runtime Exercises so the saved
        // session.data.exercises matches what the Train tab would have
        // produced. Weight 0 + bodyweight=true preserves the "BW" semantic.
        let exercises: [Exercise] = staged.exercises.map { dto in
            Exercise(
                name:       dto.name,
                tag:        dto.tag,
                sets:       dto.sets,
                reps:       dto.reps,
                weight:     dto.weightKg > 0 ? dto.weightKg : nil,
                rpe:        dto.rpe,
                notes:      dto.notes,
                key:        dto.key,
                bodyweight: dto.bodyweight
            )
        }
        // Active training time straight from the Lock-Screen taps' real
        // instants. No "now" endpoint here — this path can run the next
        // morning when the user finally reopens the app, so the last
        // tick IS the end of the workout.
        let duration = Self.activeTrainingSeconds(pending.map(\.completedAt))
        let session = WorkoutSession(
            id:          staged.sessionId,
            userId:      uid,
            programmeId: staged.programmeId,
            name:        staged.name,
            date:        staged.startedAt,
            weekNumber:  staged.weekNumber,
            block:       staged.block,
            completed:   true,
            data:        WorkoutSessionData(exercises: exercises,
                                            durationSeconds: duration > 0 ? duration : nil),
            createdAt:   nil
        )
        let setRows: [PerformedSet] = pending.map { p in
            PerformedSet(
                id:           p.id,
                sessionId:    p.sessionId,
                userId:       uid,
                exerciseName: p.exerciseName,
                setNumber:    p.setNumber,
                reps:         p.reps,
                weight:       p.weightKg,
                rpe:          nil,
                completed:    true,
                failed:       false,
                createdAt:    p.completedAt
            )
        }
        try await finishWorkout(session, sets: setRows)
    }

    /// On launch, check whether Supabase has a stored session and update
    /// phase.
    ///
    /// `authPhase` is intentionally flipped to `.signedIn` AFTER
    /// `loadUserData()` finishes — not before. This keeps the splash
    /// screen visible during the data fetch so HomeView / TrainView /
    /// Bros / Profile never render with zero-state placeholders on a
    /// returning user (visible to the user as the "0 sessions / 0
    /// streak / —" flash that appeared for ~1 second on every
    /// launch).
    func restoreSession() async {
        let sb = SupabaseManager.shared
        do {
            // .session throws if no session is stored
            _ = try await sb.client.auth.session
            // Fetch profile + programme + history + social etc.
            // BEFORE flipping the UI into the signed-in state.
            await loadUserData()
            authPhase = .signedIn
            // Re-register for remote notifications if the user
            // previously granted permission. Covers reinstalls + token
            // rotation. Also replays any device token that arrived
            // before the auth session was restored.
            await PushService.shared.reregisterIfPermitted()
            await PushService.shared.uploadCachedTokenIfAny()
        } catch {
            authPhase = .signedOut
        }
    }

    /// Fan out the signed-in data loads in parallel. Called after every
    /// entry point into the signed-in state (restore, sign in, OTP).
    func loadUserData() async {
        // Make sure a profile row exists for this user BEFORE every other
        // read fans out. iOS signups don't get the React trigger-created
        // row, so without this the user looks like a brand-new account
        // every login (no username, no programme, etc.).
        await ensureOwnProfileExists()

        async let profile:   () = loadOwnProfile()
        async let programme: () = loadActiveProgramme()
        async let history:   () = loadHistory()
        async let social:    () = loadSocial()
        async let weights:   () = loadWorkingWeights()
        async let custom:    () = loadCustomExercises()
        _ = await (profile, programme, history, social, weights, custom)
        // If the user's `working_weights` table is empty but they have
        // past sessions (e.g. existed before the iOS port wrote to that
        // table reliably), backfill from history so tracked-lift cards
        // populate. Mirrors React's App.jsx:319-340 backfill path.
        await backfillWorkingWeightsIfNeeded()
        // Drain any sets the user completed on the Lock Screen while the
        // app was backgrounded — the queue lives in the App Group store
        // and was written by `ToggleSetIntent`. Has to run AFTER
        // currentProfile/auth are ready (uid is required for the writes).
        await drainPendingSets()
        // Open Realtime listeners so the Bros tab + activity feed update live.
        await realtimeSync.start()
        // Replay any invite code captured while the user was signed out.
        if let code = pendingInviteCode {
            pendingInviteCode = nil
            if let name = await acceptInvite(code: code) {
                toast = language == "ar"
                    ? "أنت الآن صديق \(name) ✓"
                    : "You're now Bros with \(name) ✓"
            }
        }
        // Once the active programme is loaded, pre-stage today's session
        // so the Train tab has something to show without an extra round-trip.
        if currentSession == nil {
            stageCurrentSessionFromActiveProgramme()
        }
        // Leaderboard depends on currentProfile + friends — recompose now.
        rebuildLeaderboard()
    }

    // MARK: - Social loading

    /// Load friends + pending + activity feed in two stages — the feed
    /// depends on the friend list. Never throws; logs and recovers.
    ///
    /// On transient errors (network blip, server hiccup) we KEEP the
    /// previously-loaded data instead of wiping it. The old behaviour —
    /// `self.activityFeed = []` inside the catch block — caused a
    /// visible regression where pull-to-refresh on the Bros tab would
    /// erase the "recent activity" list every time the request failed,
    /// even though we already had perfectly valid stale data in memory.
    /// Pull-to-refresh should be a best-effort sync, not a destructive
    /// reset.
    func loadSocial() async {
        do {
            async let friendsT = SupabaseManager.shared.fetchFriends()
            async let pendingT = SupabaseManager.shared.fetchPendingRequests()
            let (fr, pend) = try await (friendsT, pendingT)
            self.friends         = fr
            self.pendingRequests = pend
        } catch {
            // Keep stale `friends` / `pendingRequests` rather than wiping.
            // First-launch users start at [] which is a fine initial
            // state; the only way data becomes non-empty is a successful
            // fetch, so there's nothing to "go back to" after a failure.
            print("[AppState] loadSocial (friends/pending) failed — keeping stale:", error)
        }
        // Activity feed — fetched after friends so we can scope by IDs.
        do {
            let friendIds = friends.map(\.id)
            self.activityFeed = try await SupabaseManager.shared
                .fetchActivityFeed(friendIds: friendIds)
        } catch {
            // Keep stale `activityFeed` rather than wiping. This is the
            // user-visible "recent activity disappears on refresh" bug.
            print("[AppState] loadSocial (feed) failed — keeping stale:", error)
        }
        // Leagues — independent fetch from friends/activity. If it
        // fails, keep stale data (same pattern as friends).
        do {
            self.myLeagues = try await SupabaseManager.shared.fetchMyLeagues()
        } catch {
            print("[AppState] loadSocial (leagues) failed — keeping stale:", error)
        }
        recomputeTrainedToday()
    }

    /// Refresh ONLY the activity feed. Called by RealtimeSync when an
    /// activity_feed INSERT/DELETE event fires — we don't need to
    /// refetch the friend list (with its full `leaderboard_data` jsonb
    /// per row) just because a friend logged a set. Their cached score
    /// can lag until the next pull-to-refresh on the bro tab or until
    /// the user's own session save. This is the single biggest data-
    /// transfer win on the social tab: activity events are the firehose
    /// (one per set logged across all friends) and they used to refetch
    /// the entire friends array on every event.
    func refreshActivityFeed() async {
        do {
            let friendIds = friends.map(\.id)
            self.activityFeed = try await SupabaseManager.shared
                .fetchActivityFeed(friendIds: friendIds)
        } catch {
            // Same keep-stale policy as loadSocial — silent failure
            // is better than wiping the user's visible feed.
            print("[AppState] refreshActivityFeed failed — keeping stale:", error)
        }
    }

    /// Refresh ONLY the leagues list. Called by LeagueDetailView and
    /// CreateLeagueSheet after a mutation (create / add member /
    /// kick / leave) so the CrewView leagues section + open detail
    /// view both re-render with fresh data.
    func loadLeagues() async {
        do {
            self.myLeagues = try await SupabaseManager.shared.fetchMyLeagues()
        } catch {
            print("[AppState] loadLeagues failed — keeping stale:", error)
        }
    }

    /// Re-derive `friendsTrainedToday` from the current activity feed.
    /// Both the cutoff and each row's timestamp run through the same
    /// rollover offset so a friend who trained at 01:00 local also
    /// shows as "trained today" for someone checking at 01:30.
    private func recomputeTrainedToday() {
        let today = AppState.logicalToday
        var set: Set<UUID> = []
        for row in activityFeed where row.type == "session_completed" {
            if AppState.logicalDate(of: row.createdAt) == today {
                set.insert(row.userId)
            }
        }
        self.friendsTrainedToday = set
    }

    /// Rebuild leaderboard rows from `currentProfile.leaderboardData` + friends.
    /// Filters out non-current-month rows so stale scores read as zero.
    func rebuildLeaderboard() {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let monthKey = String(format: "%04d-%02d",
                              cal.component(.year,  from: now),
                              cal.component(.month, from: now))

        let myProfile = currentProfile
        let myUid     = myProfile?.id
            ?? SupabaseManager.shared.currentUser?.id
            ?? UUID()

        let myLd  = currentProfileLeaderboard
        let myOK  = myLd?.month == monthKey
        let me = LeaderboardEntry(
            id:             myUid,
            rank:           0,
            name:           myProfile?.name ?? "You",
            username:       myProfile?.username,
            avatarURL:      myProfile?.avatarURL,
            score:          myOK ? (myLd?.score          ?? 0) : 0,
            setsCompleted:  myOK ? (myLd?.setsCompleted  ?? 0) : 0,
            improvementPct: myOK ? (myLd?.improvementPct ?? 0) : 0,
            isMe:           true
        )

        let friendEntries: [LeaderboardEntry] = friends.map { f in
            let ld = f.leaderboardData
            let current = ld?.month == monthKey
            return LeaderboardEntry(
                id:             f.id,
                rank:           0,
                name:           f.name,
                username:       f.username,
                avatarURL:      f.avatarURL,
                score:          current ? (ld?.score          ?? 0) : 0,
                setsCompleted:  current ? (ld?.setsCompleted  ?? 0) : 0,
                improvementPct: current ? (ld?.improvementPct ?? 0) : 0,
                isMe:           false
            )
        }

        let sorted = ([me] + friendEntries).sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return (a.name ?? "").localizedCaseInsensitiveCompare(b.name ?? "") == .orderedAscending
        }
        var ranked = sorted
        for i in ranked.indices { ranked[i].rank = i + 1 }
        self.leaderboard = ranked
    }

    /// In-memory mirror of the user's cached leaderboard score —
    /// populated after `loadOwnProfile()` and updated by
    /// `updateLeaderboardScore` (post-session save). Exposed and made
    /// @Published so the new ProfileView can subscribe to changes
    /// and re-render the score hero card the moment a recalculation
    /// lands.
    @Published var currentProfileLeaderboard: LeaderboardData?

    // MARK: - Social mutations

    /// Send a friend request and toast on success.
    func sendFriendRequest(toUserId uid: UUID) async {
        do {
            try await SupabaseManager.shared.sendFriendRequest(toUserId: uid)
            toast = language == "ar" ? "تم إرسال طلب الصداقة ✓" : "Friend request sent ✓"
            // Notify the recipient. Best-effort — never blocks success.
            let me = currentProfile?.name
                ?? currentProfile?.username
                ?? (language == "ar" ? "شخص ما" : "Someone")
            await SupabaseManager.shared.sendPush(
                toUserIds: [uid],
                category:  "friend_request",
                title:     language == "ar" ? "طلب صداقة جديد" : "New friend request",
                body:      language == "ar"
                    ? "\(me) يريد أن يصبح صديقك"
                    : "\(me) wants to be your bro"
            )
        } catch {
            print("[AppState] sendFriendRequest failed:", error)
            toast = language == "ar" ? "تعذّر إرسال الطلب" : "Couldn't send request"
        }
    }

    /// Accept or decline an incoming request. On accept, add the sender to
    /// `friends` optimistically; on either, remove from `pendingRequests`.
    func respondToRequest(_ req: PendingRequest, accept: Bool) async {
        do {
            try await SupabaseManager.shared
                .respondFriendRequest(friendshipId: req.friendshipId, accept: accept)
            pendingRequests.removeAll { $0.friendshipId == req.friendshipId }
            if accept {
                friends.append(FriendListEntry(
                    id: req.userId,
                    name: req.name,
                    username: req.username,
                    avatarURL: req.avatarURL,
                    leaderboardData: nil
                ))
                rebuildLeaderboard()
                // Tell the requester their request was accepted. Skipped
                // on decline — declining a request silently is kinder.
                let me = currentProfile?.name
                    ?? currentProfile?.username
                    ?? (language == "ar" ? "صديقك الجديد" : "your new bro")
                await SupabaseManager.shared.sendPush(
                    toUserIds: [req.userId],
                    category:  "friend_accepted",
                    title:     language == "ar" ? "تم قبول طلبك 🤝" : "Request accepted 🤝",
                    body:      language == "ar"
                        ? "\(me) قبل طلب الصداقة"
                        : "\(me) accepted your bro request"
                )
            }
        } catch {
            print("[AppState] respondToRequest failed:", error)
        }
    }

    /// Remove an existing friend (both directions). Updates local state.
    func removeFriend(_ friendId: UUID) async {
        do {
            try await SupabaseManager.shared.removeFriend(friendId: friendId)
            friends.removeAll { $0.id == friendId }
            rebuildLeaderboard()
            toast = language == "ar" ? "تمت إزالة الصديق" : "Bro removed"
        } catch {
            print("[AppState] removeFriend failed:", error)
        }
    }

    /// Accept an invite code (deep-link or pasted manually). Returns the
    /// inviter's name on success, or nil on failure. Reloads social.
    @discardableResult
    func acceptInvite(code: String) async -> String? {
        do {
            let result = try await SupabaseManager.shared.acceptInvite(code: code)
            await loadSocial()
            return result.inviterName
        } catch {
            print("[AppState] acceptInvite failed:", error)
            toast = (error as? SupabaseManager.InviteError)?.errorDescription
                  ?? "Couldn't accept invite"
            return nil
        }
    }

    // MARK: - Auth actions

    /// Sign in with either an email or a username. If the input doesn't look
    /// like an email, we resolve the email via the `profiles` table before
    /// calling Supabase auth — mirrors src/components/AuthScreen.jsx.
    func signIn(emailOrUsername: String, password: String) async throws {
        let trimmed = emailOrUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeEmail: Bool = {
            guard let at = trimmed.firstIndex(of: "@") else { return false }
            let domain = trimmed[trimmed.index(after: at)...]
            return domain.contains(".")
        }()

        let resolvedEmail: String
        if looksLikeEmail {
            resolvedEmail = trimmed
        } else {
            guard let mapped = try await SupabaseManager.shared
                .emailForUsername(trimmed.lowercased()), !mapped.isEmpty
            else {
                throw AuthError.usernameNotFound
            }
            resolvedEmail = mapped
        }

        _ = try await SupabaseManager.shared.signIn(
            email: resolvedEmail, password: password
        )
        // Load user data first; flip into `.signedIn` only once the
        // home/train tabs will render with real numbers. Avoids the
        // zero-state flash on returning users.
        await loadUserData()
        authPhase = .signedIn
        // Re-register push token now that we know the user — handles
        // sign-in on a fresh device, account switch, etc.
        await PushService.shared.reregisterIfPermitted()
        await PushService.shared.uploadCachedTokenIfAny()
    }

    enum AuthError: LocalizedError {
        case usernameNotFound
        case invalidCredentials
        var errorDescription: String? {
            switch self {
            case .usernameNotFound:   return "No account found with that username."
            case .invalidCredentials: return "Incorrect email/username or password."
            }
        }
    }

    // Captured at signUp() and replayed during verifyOTP() so the username
    // can be persisted to profiles RIGHT after the OTP succeeds — matching
    // React's AuthScreen flow. The username is a one-time signup field and
    // is never editable elsewhere.
    private var pendingSignupName: String?
    private var pendingSignupUsername: String?
    private var pendingSignupEmail: String?

    func signUp(name: String, username: String, email: String, password: String) async throws {
        pendingSignupName = name
        pendingSignupUsername = username
        pendingSignupEmail = email
        let metadata: [String: AnyJSON] = [
            "name":     .string(name),
            "username": .string(username)
        ]
        _ = try await SupabaseManager.shared.signUp(
            email: email, password: password, metadata: metadata
        )
        authPhase = .awaitingOTP(email: email)
    }

    func verifyOTP(email: String, token: String) async throws {
        _ = try await SupabaseManager.shared.verifyOTP(email: email, token: token)
        // Write the canonical {id, name, username, email, language} row.
        // Mirrors React's AuthScreen post-OTP upsert. This is the ONLY
        // place in the app that writes to profiles.username.
        if let uid = SupabaseManager.shared.currentUser?.id {
            do {
                try await SupabaseManager.shared.upsertOwnSignupProfile(
                    uid: uid,
                    name: pendingSignupName,
                    username: pendingSignupUsername,
                    email: pendingSignupEmail ?? email
                )
            } catch {
                print("[AppState] signup-profile upsert failed:", error)
            }
        }
        pendingSignupName = nil
        pendingSignupUsername = nil
        pendingSignupEmail = nil
        // Load user data first so the new account's empty state
        // doesn't flash through HomeView / TrainView. For a brand
        // new signup most loaders return immediately empty anyway,
        // but it keeps the auth → main-app transition smooth.
        await loadUserData()
        authPhase = .signedIn
        // Brand-new account just verified OTP. We DON'T ask for push
        // permission here — that's deferred until the user finishes
        // their first session (better acceptance rate). Token will be
        // requested at that point.
    }

    func resendOTP(email: String) async throws {
        try await SupabaseManager.shared.resendSignupOTP(email: email)
    }

    /// Go back from the OTP screen to the signed-out (login/signup) flow.
    func cancelOTP() async {
        try? await SupabaseManager.shared.signOut()
        authPhase = .signedOut
    }

    func signOut() async {
        await realtimeSync.stop()
        // Drop this device's push token first — otherwise the phone
        // keeps receiving notifications addressed to the previous user
        // until they sign in again. Best-effort; failure is fine.
        if let token = UserDefaults.standard.string(forKey: "last_apns_token") {
            await SupabaseManager.shared.deletePushDevice(token: token)
            UserDefaults.standard.removeObject(forKey: "last_apns_token")
        }
        try? await SupabaseManager.shared.signOut()
        currentProfile = nil
        activeProgramme = nil
        currentSession = nil
        workoutHistory = []
        friends = []
        pendingRequests = []
        activityFeed = []
        leaderboard = []
        workingWeights = [:]
        authPhase = .signedOut
    }

    // MARK: - Profile

    /// Insert a bare `profiles` row for the current user if one doesn't yet
    /// exist. Idempotent. Mirrors the React `ensureProfileExists` helper.
    func ensureOwnProfileExists() async {
        guard let user = SupabaseManager.shared.currentUser else { return }
        // Pull the name we stashed in user_metadata at signup so the fallback
        // row carries the actual display name, not just "Athlete".
        let metaName: String? = {
            guard let anyValue = user.userMetadata["name"] else { return nil }
            if case let .string(s) = anyValue { return s }
            return nil
        }()
        do {
            try await SupabaseManager.shared.ensureOwnProfileRow(
                uid: user.id,
                fallbackName: metaName,
                email: user.email
            )
        } catch {
            // Surface the error in a toast — silent failure here is exactly
            // the bug that causes the "username asked every login" loop and
            // the "data not loading" symptom.
            print("[AppState] ensureOwnProfileExists failed:", error)
            toast = "Profile setup failed: \(error.localizedDescription)"
        }
    }

    /// 4-slot view of the tracked lifts persisted on `profiles.tracked_lifts`,
    /// always padded to exactly 4 entries so the Progress grid can render
    /// empty slots without a count check. Mirrors React's `slots` shape.
    var trackedLiftSlots: [TrackedLift?] {
        let raw = currentProfile?.trackedLifts ?? []
        var padded: [TrackedLift?] = Array(raw.prefix(4))
        while padded.count < 4 { padded.append(nil) }
        return padded
    }

    /// Write a single tracked-lift slot. Updates the in-memory profile
    /// optimistically (so the UI flips immediately) then persists the full
    /// 4-element array to `profiles.tracked_lifts` so iOS and web stay in
    /// sync. Pass `lift: nil` to clear a slot.
    func setTrackedLift(slot: Int, lift: TrackedLift?) async {
        guard (0..<4).contains(slot) else { return }
        var next = trackedLiftSlots
        next[slot] = lift
        currentProfile?.trackedLifts = next
        do {
            try await SupabaseManager.shared.saveTrackedLifts(next)
        } catch {
            print("[AppState] saveTrackedLifts failed:", error)
            toast = "Couldn't save tracked lift"
        }
    }

    /// Toggle / set the display language and persist the choice to
    /// `profiles.language`. Mirrors React's `handleSetLang` writer.
    func setLanguage(_ lang: String) async {
        let normalised = (lang == "ar") ? "ar" : "en"
        language = normalised
        currentProfile?.language = normalised
        do {
            try await SupabaseManager.shared.updateOwnLanguage(normalised)
        } catch {
            print("[AppState] updateOwnLanguage failed:", error)
            // Non-fatal — the user can retry next toggle. No toast so we
            // don't spam the home screen on a flaky network.
        }
    }

    /// Persist a new display name to `profiles.name`. Username is NEVER
    /// touched — it's a one-time signup field per the project rule.
    func updateOwnName(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        currentProfile?.name = trimmed
        do {
            try await SupabaseManager.shared.updateOwnName(trimmed)
        } catch {
            print("[AppState] updateOwnName failed:", error)
            toast = "Couldn't update name"
        }
    }

    func loadOwnProfile() async {
        do {
            currentProfile = try await SupabaseManager.shared.fetchOwnProfile()
            if let lang = currentProfile?.language, !lang.isEmpty {
                language = lang
            }
            // Fire-and-forget — leaderboard score blob lives in jsonb column
            // outside the typed Profile model.
            currentProfileLeaderboard =
                try? await SupabaseManager.shared.fetchOwnLeaderboardData()
        } catch {
            print("[AppState] loadOwnProfile failed:", error)
            // Surface the error so the user knows why their data isn't
            // showing. Only the first loader-failure toast wins — by the
            // didSet timer the next failure replaces this one in <3s.
            if toast == nil {
                toast = "Profile fetch failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Programme

    /// Fetch the currently active programme row for this user. Surfaces the
    /// error via toast so the user knows why their programme didn't appear —
    /// silent failure here was a major contributor to the "no data showing"
    /// reports during early testing.
    func loadActiveProgramme() async {
        do {
            activeProgramme = try await SupabaseManager.shared.fetchActiveProgramme()
        } catch {
            print("[AppState] loadActiveProgramme failed:", error)
            if toast == nil {
                toast = "Programme fetch failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Workout history

    /// Pull the most recent sessions for this user (DESC by date).
    /// On error, leaves `workoutHistory` untouched so a transient failure
    /// doesn't blank out the stats grid. A toast is shown only when no
    /// other toast is currently visible so we don't spam the screen.
    func loadHistory() async {
        do {
            workoutHistory = try await SupabaseManager.shared.fetchHistory()
        } catch {
            print("[AppState] loadHistory failed:", error)
            if toast == nil {
                toast = "History fetch failed: \(error.localizedDescription)"
            }
        }
    }

    /// Pull the working-weights map from Supabase. Surface errors via toast
    /// so a silent failure here doesn't show up as blank Progress cards
    /// without any user-visible signal.
    func loadWorkingWeights() async {
        do {
            workingWeights = try await SupabaseManager.shared.fetchWorkingWeights()
        } catch {
            print("[AppState] loadWorkingWeights failed:", error)
            if toast == nil {
                toast = "Working weights fetch failed: \(error.localizedDescription)"
            }
        }
    }

    /// Reconcile `working_weights` from session history on every sign-in.
    /// Mirrors React's `App.jsx:319-340` recovery path but RUNS UNCONDITIONALLY,
    /// not just when working_weights is empty — that gated version meant a
    /// once-bad backfill (e.g. arbitrary same-day ordering picked 70 kg
    /// instead of 107.5 kg as the "latest" Dumbbell Bench Press) stuck
    /// permanently because the gate kept it from re-running.
    ///
    /// Idempotent: walking sessions in chronological order and overwriting
    /// the dict means the last entry per exercise = the latest weight ever
    /// logged. Upserting the same value twice is a no-op write. Cheap on
    /// every load (one walk through history, one batched upsert).
    ///
    /// Crucial: ordering uses `session.createdAt ?? session.date` so
    /// multiple sessions logged on the same calendar day still order
    /// chronologically. `session.date` alone is the day-coarse finish-time
    /// timestamp and breaks ties arbitrarily.
    func backfillWorkingWeightsIfNeeded() async {
        guard !workoutHistory.isEmpty else { return }
        // Sort ASC by effective date so the chronologically-last session
        // overwrites earlier entries in the dict.
        let chronologicallyAsc = workoutHistory.sorted { lhs, rhs in
            let l = lhs.createdAt ?? lhs.date
            let r = rhs.createdAt ?? rhs.date
            return l < r
        }
        var backfill: [String: Double] = [:]
        for session in chronologicallyAsc {
            for ex in session.data?.exercises ?? [] {
                if ex.bodyweight { continue }
                let name = ex.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let w = ex.weight, w > 0 else { continue }
                backfill[name] = w
                if !ex.key.isEmpty, ex.key != name {
                    backfill[ex.key] = w
                }
            }
        }
        guard !backfill.isEmpty else { return }
        // Only write to Supabase if anything actually differs from what
        // we already have locally — avoids spamming the upsert endpoint
        // on every sign-in when nothing has changed.
        let changed = backfill.contains { (k, v) in workingWeights[k] != v }
        guard changed else { return }
        print("[AppState] reconciling working_weights from history:",
              backfill.keys.sorted())
        do {
            try await SupabaseManager.shared.upsertWorkingWeights(backfill)
            for (k, v) in backfill { workingWeights[k] = v }
        } catch {
            print("[AppState] backfillWorkingWeights upsert failed:", error)
        }
    }

    /// Pull user-created exercises from the profile jsonb column.
    func loadCustomExercises() async {
        do {
            customExercises = try await SupabaseManager.shared.fetchOwnCustomExercises()
        } catch {
            print("[AppState] loadCustomExercises failed:", error)
        }
    }

    /// Append a new custom exercise, persist the full array, and mirror
    /// it in-memory so the picker shows it immediately.
    func addCustomExercise(_ ex: CustomExercise) async {
        // Dedupe by lowercased name
        let exists = customExercises.contains { $0.name.lowercased() == ex.name.lowercased() }
        guard !exists else { return }
        var next = customExercises
        next.append(ex)
        do {
            try await SupabaseManager.shared.saveCustomExercises(next)
            customExercises = next
        } catch {
            print("[AppState] saveCustomExercises failed:", error)
        }
    }

    // MARK: - Active training time
    //
    // Duration is computed from the timestamps of set ticks, NOT from a
    // start/end pair — a single stray tick outside the gym would poison
    // an endpoint-based span. Instead we sum only the gaps between
    // consecutive ticks that are ≤ 30 minutes; longer gaps count as
    // "not training" and contribute zero. Ticks are persisted per
    // session id (UserDefaults) so an app kill mid-workout doesn't lose
    // the timeline; Lock-Screen Live Activity taps flow in with their
    // real `completedAt` instants via `refreshLiveActivityCompletions`.

    private static let setTickStoreKey = "hex.set_tick_times_v1"
    /// Drop a session's tick timeline once its newest tick is older than
    /// this — keeps the store from accumulating abandoned sessions.
    private static let tickStoreMaxAge: TimeInterval = 48 * 3600

    /// Record one set-tick instant for a session (defaults to the
    /// current staged session, "now"). Dedups identical instants so
    /// re-merging the Live Activity queue can't double-record.
    func recordSetTick(at date: Date = Date(), sessionId: UUID? = nil) {
        guard let sid = sessionId ?? currentSession?.id else { return }
        var store = (UserDefaults.standard.dictionary(forKey: Self.setTickStoreKey)
                     as? [String: [Double]]) ?? [:]
        var times = store[sid.uuidString] ?? []
        let epoch = date.timeIntervalSince1970
        guard !times.contains(epoch) else { return }
        times.append(epoch)
        store[sid.uuidString] = times
        // Prune sessions whose latest activity is ancient.
        let cutoff = Date().timeIntervalSince1970 - Self.tickStoreMaxAge
        store = store.filter { (_, v) in (v.max() ?? 0) >= cutoff }
        UserDefaults.standard.set(store, forKey: Self.setTickStoreKey)
    }

    /// All recorded tick instants for a session, unsorted.
    func setTickTimes(for sessionId: UUID) -> [Date] {
        let store = (UserDefaults.standard.dictionary(forKey: Self.setTickStoreKey)
                     as? [String: [Double]]) ?? [:]
        return (store[sessionId.uuidString] ?? []).map(Date.init(timeIntervalSince1970:))
    }

    /// Forget a session's tick timeline (called after a successful save).
    func clearSetTickTimes(for sessionId: UUID) {
        var store = (UserDefaults.standard.dictionary(forKey: Self.setTickStoreKey)
                     as? [String: [Double]]) ?? [:]
        store.removeValue(forKey: sessionId.uuidString)
        UserDefaults.standard.set(store, forKey: Self.setTickStoreKey)
    }

    /// Gap-capped sum: sort the instants, then add up only the
    /// consecutive gaps that are ≤ `maxGap` (default 30 min). Returns
    /// whole seconds — 0 when there's no real activity window.
    static func activeTrainingSeconds(_ times: [Date],
                                      maxGap: TimeInterval = 1800) -> Int {
        guard times.count >= 2 else { return 0 }
        let sorted = times.map(\.timeIntervalSince1970).sorted()
        var total: TimeInterval = 0
        for i in 1..<sorted.count {
            let gap = sorted[i] - sorted[i - 1]
            if gap > 0, gap <= maxGap { total += gap }
        }
        return Int(total.rounded())
    }

    /// User tapped "Save Session" inside the Session Complete sheet.
    /// Persists the workout, fires confetti + toast, and clears the
    /// summary so the sheet dismisses. Wraps `finishWorkout` so the
    /// existing persistence path stays a single source of truth.
    func confirmFinishSession() async {
        guard let summary = pendingSessionSummary else { return }
        // Clear the trigger first so the sheet dismisses immediately —
        // any UI behind the sheet animates back in while we finish the
        // network round-trip on the side.
        pendingSessionSummary = nil

        // End any running Live Activity so the lock-screen widget
        // doesn't outlive the session.
        await LiveActivityService.shared.end()

        // Snap the celebratory feedback in BEFORE the network call so
        // the user gets a snappy "done" feel even on slow connections.
        confettiTrigger &+= 1

        do {
            try await finishWorkout(summary.session, sets: summary.sets)
            toast = language == "ar" ? "تم حفظ الجلسة ✓" : "Session saved ✓"
        } catch {
            print("[AppState] confirmFinishSession failed:", error)
            toast = language == "ar"
                ? "تعذّر حفظ الجلسة"
                : "Couldn't save session: \(error.localizedDescription)"
        }
    }

    /// User tapped Cancel inside the Session Complete sheet. Just dismiss.
    func cancelPendingSession() {
        pendingSessionSummary = nil
    }

    /// Persist a completed workout: writes the session row and any performed
    /// sets, refreshes `workoutHistory`, inserts an activity-feed row, and
    /// recalculates the leaderboard score so friends see updated stats.
    ///
    /// Ordering: working_weights are upserted BEFORE `loadHistory` so that
    /// when ProgressTab re-renders off the new `workoutHistory`, the
    /// `workingWeights` dictionary is already current — otherwise the
    /// History row appears first with the tracked-lift cards still showing
    /// the old kg.
    func finishWorkout(_ session: WorkoutSession,
                       sets: [PerformedSet]) async throws {
        try await SupabaseManager.shared.saveWorkoutSession(session)
        try await SupabaseManager.shared.savePerformedSets(sets)
        currentSession = nil
        // The session is durably saved — its set-tick timeline has served
        // its purpose (durationSeconds is already inside session.data).
        clearSetTickTimes(for: session.id)

        // Update working_weights with the heaviest non-bodyweight load per
        // exercise. Key by `ex.name.trim()` (matches React App.jsx:836)
        // AND also by `ex.key` when present, so the Progress tab's
        // `resolveWorkingWeight` lookup hits via EITHER `lift.name` or
        // `lift.key`. Previously this used a lossy `canonicalLiftKey`
        // helper that mapped "Barbell OHP" → "ohp" and broke the lookup.
        var liftMaxes: [String: Double] = [:]
        for ex in session.data?.exercises ?? [] {
            guard let w = ex.weight, w > 0, !ex.bodyweight else { continue }
            let displayKey = ex.name.trimmingCharacters(in: .whitespaces)
            if !displayKey.isEmpty {
                liftMaxes[displayKey] = max(liftMaxes[displayKey] ?? 0, w)
            }
            if !ex.key.isEmpty, ex.key != displayKey {
                liftMaxes[ex.key] = max(liftMaxes[ex.key] ?? 0, w)
            }
        }
        if !liftMaxes.isEmpty {
            do {
                try await SupabaseManager.shared.upsertWorkingWeights(liftMaxes)
                // Mirror locally so subsequent PT prompts read the new values
                for (k, v) in liftMaxes { workingWeights[k] = v }
            } catch {
                print("[AppState] upsertWorkingWeights failed:", error)
            }
        }

        // Reload history AFTER working-weights so Progress tab re-renders
        // with both new values in one shot.
        await loadHistory()

        // Compute completed-set volume for the activity-feed row
        let volume: Double = sets.reduce(0) { acc, s in
            if s.completed, let w = s.weight, w > 0, let r = s.reps, r > 0 {
                return acc + w * Double(r)
            }
            return acc
        }
        // Best-effort activity insert (never throws)
        await SupabaseManager.shared.insertActivity(
            type: "session_completed",
            data: [
                "session_name": session.name,
                "volume":       volume,
                "exercises":    session.data?.exercises.count ?? 0,
            ]
        )
        // Refresh the local feed immediately so the user sees their own
        // just-completed session right away. Previously this only
        // happened when the Realtime INSERT event fired (~1.5s debounce),
        // so on a flaky connection the user's own session could be
        // missing from Recent Activity until they left and re-entered
        // the tab. This explicit refresh makes it appear deterministically.
        await refreshActivityFeed()

        // Ask for push permission now if we haven't yet. This is the
        // best moment in the app — the user just finished their first
        // session, dopamine is high, they're bought in. iOS only shows
        // the dialog once per install, so PushService.requestPermissionIfNeeded
        // no-ops on subsequent saves.
        await PushService.shared.requestPermissionIfNeeded()

        // Notify all friends that the session was completed (if the
        // user's "friend_sessions" toggle isn't a thing on THEIR side —
        // they each control whether they hear about it). The Edge
        // Function reads each recipient's notification_prefs and skips
        // anyone opted out, plus enforces quiet hours for this category.
        if !friends.isEmpty {
            let displayName = currentProfile?.name
                ?? currentProfile?.username
                ?? (language == "ar" ? "صديقك" : "your bro")
            await SupabaseManager.shared.sendPush(
                toUserIds: friends.map { $0.id },
                category:  "friend_session",
                title:     language == "ar" ? "جلسة جديدة" : "New session",
                body:      language == "ar"
                    ? "\(displayName) أتم \(session.name)"
                    : "\(displayName) completed \(session.name)",
                data:      ["session_name": session.name]
            )
        }
        // Recalculate leaderboard score so the friends-leaderboard refreshes
        // on next CrewView load. Detach so it doesn't block the caller.
        Task.detached { [weak self] in
            let newScore = await SupabaseManager.shared
                .recalculateAndStoreLeaderboardScore()
            if let newScore = newScore {
                await MainActor.run {
                    self?.currentProfileLeaderboard = newScore
                    self?.rebuildLeaderboard()
                }
            }
        }
    }

    // MARK: - Programme creation entry points

    /// Generate a starter programme from the onboarding wizard answers and
    /// persist it as the active programme. Mirrors the React App.jsx
    /// `enterApp` callback that runs after the 7-step onboarding completes.
    func enterApp(profile: OnboardingProfile,
                  weights: [String: Double]) async {
        let data = ProgrammeBuilder.buildProgramme(profile: profile, weights: weights)
        await saveAndActivateProgramme(data: data)
    }

    /// Persist a validated imported programme and make it active. Mirrors
    /// the React `enterAppWithImport` callback used by ImportScreen.jsx.
    /// `raw` is the dict you get from `JSONSerialization.jsonObject(with:)`
    /// after `ImportHelpers.validateImported` returned no errors.
    func enterAppWithImport(_ raw: [String: Any]) async {
        guard let data = ImportHelpers.programmeData(fromImported: raw) else { return }
        await saveAndActivateProgramme(data: data)
    }

    /// Common tail: build a Programme row from generated/imported data,
    /// upsert it, mark it active, refresh in-memory state, and pre-stage
    /// today's session into `currentSession` so the Train tab is ready.
    private func saveAndActivateProgramme(data: ProgrammeData) async {
        guard let uid = SupabaseManager.shared.currentUser?.id else {
            print("[AppState] saveAndActivateProgramme: no user")
            return
        }
        let programme = Programme(
            id: UUID(),
            userId: uid,
            name: data.name,
            active: true,
            data: data,
            createdAt: nil
        )
        do {
            try await SupabaseManager.shared.upsertProgramme(programme)
            try await SupabaseManager.shared.markProgrammeActive(programme.id)
            await loadActiveProgramme()
            stageCurrentSessionFromActiveProgramme()
        } catch {
            print("[AppState] saveAndActivateProgramme failed:", error)
        }
    }

    /// Fields editable on a session header in ProgrammePage.
    enum SessionField { case name, focus, block }

    /// Fields editable on a single exercise in ProgrammePage.
    /// `.restTimer` mirrors React's persisted per-exercise rest seconds
    /// (Off/30/45/60/90/120/custom). 0 means "Off"; nil means "use default".
    enum ExerciseField { case sets, reps, weight, rpe, notes, restTimer }

    /// Edit a session header field (name/focus/block) inside the active
    /// programme and persist. Mirrors `updateAutoSessionField` /
    /// `updateImportedSessionField` from React App.jsx.
    func updateSessionField(weekIdx: Int,
                            sessionIdx: Int,
                            field: SessionField,
                            value: String) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        guard sessionIdx < week.sessions.count else { return }
        var session = week.sessions[sessionIdx]
        switch field {
        case .name:
            session.name = value
        case .focus:
            session.focus = value.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : value
        case .block:
            session.block = value.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : value
        }
        week.sessions[sessionIdx] = session
        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme
        mirrorCurrentSessionAfterEdit(programmeId: programme.id, name: session.name)
        await persist(programme)
    }

    /// Edit one exercise field (sets/reps/weight/rpe/notes). Numeric values
    /// for sets/weight parse from the string; bad parses leave the field
    /// unchanged so the user can correct without losing context.
    func updateExerciseField(weekIdx: Int,
                             sessionIdx: Int,
                             exerciseIdx: Int,
                             field: ExerciseField,
                             value: String) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        guard sessionIdx < week.sessions.count else { return }
        var session = week.sessions[sessionIdx]
        guard exerciseIdx < session.exercises.count else { return }
        var ex = session.exercises[exerciseIdx]

        switch field {
        case .sets:
            if let n = Int(value), n > 0 { ex.sets = n }
        case .reps:
            ex.reps = value
        case .weight:
            // Empty / "bw" / "bodyweight" / "0" → switch to bodyweight
            // (nil). A non-zero number → set as the working weight.
            // Anything else → leave unchanged so a typo doesn't blow
            // away a valid weight.
            let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.isEmpty
                || trimmed == "bw"
                || trimmed == "bodyweight"
                || trimmed == "وزن الجسم" {
                ex.weight = nil
            } else if let w = Double(trimmed), w > 0 {
                ex.weight = w
            } else if let w = Double(trimmed), w == 0 {
                ex.weight = nil
            }
        case .rpe:
            ex.rpe = value.isEmpty ? nil : value
        case .notes:
            ex.notes = value.isEmpty ? nil : value
        case .restTimer:
            // Empty / unparseable → nil (means "use the default"), so the
            // user can reset to the tag-based default by clearing the field.
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                ex.restTimer = nil
            } else if let n = Int(trimmed), n >= 0 {
                ex.restTimer = n
            }
        }
        session.exercises[exerciseIdx] = ex
        week.sessions[sessionIdx] = session
        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme
        mirrorCurrentSessionAfterEdit(programmeId: programme.id, name: session.name,
                                      exercises: session.exercises)
        await persist(programme)
    }

    /// Push updated session content into `currentSession` when it points
    /// at the same programme + session — keeps the Train tab in sync with
    /// edits made from ProgrammePage without an extra reload.
    private func mirrorCurrentSessionAfterEdit(programmeId: UUID,
                                               name: String,
                                               exercises: [Exercise]? = nil) {
        guard let cur = currentSession,
              cur.programmeId == programmeId,
              cur.name == name else { return }
        var updated = cur
        if let exercises = exercises, var d = cur.data {
            d.exercises = exercises
            updated.data = d
        }
        currentSession = updated
    }

    /// Best-effort Supabase upsert. Errors are logged but non-fatal — the
    /// in-memory mutation already landed, and the next signed-in load
    /// will rehydrate from whatever the DB has.
    private func persist(_ programme: Programme) async {
        do {
            try await SupabaseManager.shared.upsertProgramme(programme)
        } catch {
            print("[AppState] programme upsert failed:", error)
        }
    }

    /// Replace one exercise in the active programme with a different one
    /// from the library (typically picked from ExercisePickerSheet) and
    /// persist the resulting programme. Indices come from ProgrammePage,
    /// which threads (weekIdx, sessionIdx, exerciseIdx) through its rows.
    ///
    /// The replacement preserves the user's sets/reps/RPE/notes/weight
    /// (except the weight resets when the swap is to a bodyweight move)
    /// and updates the tag from the library's `isMain` flag.
    func swapExercise(weekIdx: Int,
                      sessionIdx: Int,
                      exerciseIdx: Int,
                      replacement: ProgrammeBuilder.LibraryExercise) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        guard sessionIdx < week.sessions.count else { return }
        var session = week.sessions[sessionIdx]
        guard exerciseIdx < session.exercises.count else { return }

        let old = session.exercises[exerciseIdx]
        let newWeight: Double? = replacement.bodyweight ? nil : (old.weight ?? 20)
        let newTag: String = replacement.isMain ? "compound" : "accessory"
        let swappedNotes: String? = {
            let prefix = old.notes.flatMap { $0.isEmpty ? nil : "\($0) · " } ?? ""
            return "\(prefix)Swapped from \(old.name)"
        }()

        session.exercises[exerciseIdx] = Exercise(
            name:   replacement.name,
            tag:    newTag,
            sets:   old.sets,
            reps:   old.reps,
            weight: newWeight,
            rpe:    old.rpe,
            notes:  swappedNotes
        )
        week.sessions[sessionIdx] = session
        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme

        // Reflect the swap in `currentSession` too, so the Train tab
        // refreshes if the user happens to be looking at the swapped
        // session right now.
        if let cur = currentSession,
           cur.programmeId == programme.id,
           cur.name == session.name,
           var d = cur.data {
            d.exercises = session.exercises
            var updated = cur
            updated.data = d
            currentSession = updated
        }

        do {
            try await SupabaseManager.shared.upsertProgramme(programme)
        } catch {
            print("[AppState] swapExercise persist failed:", error)
        }
    }

    // MARK: - Programme exercise add/delete

    /// Append a new exercise to a session, picked from the library.
    /// Used by ProgrammePage's "+ Add exercise" button. Defaults match
    /// what the swap-picker uses for a fresh slot: 3 sets, "8-10" reps,
    /// 20 kg if not bodyweight, RPE 7-8.
    func addExercise(
        weekIdx: Int,
        sessionIdx: Int,
        exercise picked: ProgrammeBuilder.LibraryExercise
    ) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        guard sessionIdx < week.sessions.count else { return }
        var session = week.sessions[sessionIdx]

        let newEx = Exercise(
            name:    picked.name,
            tag:     picked.isMain ? "compound" : "accessory",
            sets:    3,
            reps:    "8-10",
            weight:  picked.bodyweight ? nil : 20,
            rpe:     "7-8",
            key:     picked.key,
            bodyweight: picked.bodyweight,
            muscle:  picked.muscle
        )
        session.exercises.append(newEx)
        week.sessions[sessionIdx] = session
        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme

        mirrorCurrentSessionAfterEdit(
            programmeId: programme.id,
            name: session.name,
            exercises: session.exercises
        )
        await persistProgrammeChange(programme, op: "addExercise")
    }

    /// Remove an exercise from a session.
    func deleteExercise(
        weekIdx: Int,
        sessionIdx: Int,
        exerciseIdx: Int
    ) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        guard sessionIdx < week.sessions.count else { return }
        var session = week.sessions[sessionIdx]
        guard exerciseIdx < session.exercises.count else { return }

        session.exercises.remove(at: exerciseIdx)
        week.sessions[sessionIdx] = session
        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme

        mirrorCurrentSessionAfterEdit(
            programmeId: programme.id,
            name: session.name,
            exercises: session.exercises
        )
        await persistProgrammeChange(programme, op: "deleteExercise")
    }

    // MARK: - Programme day management (move / rest / delete / add)

    /// Canonical Mon→Sun ordering used when re-sorting sessions after a
    /// day change so the schedule grid stays in calendar order.
    private static let dayOrder: [String: Int] = [
        "mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6,
    ]

    /// Move the session at `sessionIdx` to `newDay`. If `newDay` already
    /// has a session, the two swap days (so "Upper on Mon, Rest on Tue"
    /// → tap Mon's session, pick Tue → Mon becomes Rest, Tue becomes
    /// Upper). After the swap the sessions array is re-sorted Mon→Sun
    /// so the schedule grid renders correctly.
    func setSessionDay(weekIdx: Int, sessionIdx: Int, newDay: String) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        guard sessionIdx < week.sessions.count else { return }

        let oldDay = week.sessions[sessionIdx].day
        guard oldDay != newDay else { return }

        // Swap if the target day is already occupied.
        if let targetIdx = week.sessions.firstIndex(where: { $0.day == newDay }),
           targetIdx != sessionIdx {
            week.sessions[targetIdx].day = oldDay
        }
        week.sessions[sessionIdx].day = newDay
        week.sessions.sort {
            (Self.dayOrder[$0.day.lowercased()] ?? 99)
            < (Self.dayOrder[$1.day.lowercased()] ?? 99)
        }

        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme
        await persistProgrammeChange(programme, op: "setSessionDay")
    }

    /// Toggle a session between training and rest. Rest sessions keep
    /// their `day` slot in the week but clear their exercises + name —
    /// the schedule grid still shows them so the user knows the day
    /// is intentionally a rest, not just missing.
    func toggleSessionRest(weekIdx: Int, sessionIdx: Int) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        guard sessionIdx < week.sessions.count else { return }

        var session = week.sessions[sessionIdx]
        if session.isRest {
            // Rest → Training. Empty session ready for the user to fill.
            session.isRest = false
            session.name = "Training"
            session.exercises = []
        } else {
            // Training → Rest. Drop name + exercises but keep the slot.
            session.isRest = true
            session.name = "Rest"
            session.exercises = []
        }
        week.sessions[sessionIdx] = session

        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme
        await persistProgrammeChange(programme, op: "toggleSessionRest")
    }

    /// Delete a session entirely (vs. converting to rest, which keeps
    /// the slot). The day becomes "missing" in the schedule grid.
    func deleteSession(weekIdx: Int, sessionIdx: Int) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        guard sessionIdx < week.sessions.count else { return }

        week.sessions.remove(at: sessionIdx)

        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme
        await persistProgrammeChange(programme, op: "deleteSession")
    }

    /// Add a new (empty) training session on the given day. No-op if a
    /// session already exists for that day — caller is expected to
    /// gate the menu to unused days only.
    func addSession(weekIdx: Int, day: String) async {
        guard var programme = activeProgramme,
              var data = programme.data,
              weekIdx < data.weeks.count else { return }
        var week = data.weeks[weekIdx]
        if week.sessions.contains(where: { $0.day == day }) { return }

        let newSession = ProgrammeSession(
            day:       day,
            name:      "Training",
            exercises: [],
            focus:     nil,
            block:     nil,
            isRest:    false
        )
        week.sessions.append(newSession)
        week.sessions.sort {
            (Self.dayOrder[$0.day.lowercased()] ?? 99)
            < (Self.dayOrder[$1.day.lowercased()] ?? 99)
        }

        data.weeks[weekIdx] = week
        programme.data = data
        activeProgramme = programme
        await persistProgrammeChange(programme, op: "addSession")
    }

    /// Common tail for the four mutators above: persist the updated
    /// programme to Supabase and log on failure. Kept silent on success
    /// so the user doesn't get a toast on every micro-edit.
    private func persistProgrammeChange(_ programme: Programme,
                                        op: String) async {
        do {
            try await SupabaseManager.shared.upsertProgramme(programme)
        } catch {
            print("[AppState] \(op) persist failed:", error)
        }
    }

    /// Pick today's session from the active programme and stage it as
    /// `currentSession`, ready to be logged on the Train tab. Mirrors
    /// React's `sessionForTodayImported` + auto-mode fallback:
    ///
    ///   - Imported programme (sessions have day-keys "mon"…"sun"):
    ///       stage if today's day matches a session; otherwise leave
    ///       `currentSession = nil` so the rest-day card shows.
    ///   - Auto programme (flat list, day-keys are empty strings):
    ///       always stage the first session so the user has something
    ///       to do — React keeps a rotation pointer here but iOS hasn't
    ///       implemented one yet, so first-up is the closest match.
    func stageCurrentSessionFromActiveProgramme() {
        guard let prog = activeProgramme,
              let weeks = prog.data?.weeks,
              !weeks.isEmpty,
              let uid = SupabaseManager.shared.currentUser?.id
        else { return }
        // Pick the week matching `currentWeek` if it exists; otherwise
        // fall back to the first week so we always have something to stage.
        let week = weeks.first(where: { $0.weekNumber == currentWeek })
                ?? weeks.first!
        guard !week.sessions.isEmpty else { return }
        let dayKeys = ["sun","mon","tue","wed","thu","fri","sat"]
        // Use logicalNow so the user who opens the app at 01:30 still
        // sees yesterday's session staged (not tomorrow's). Programmes
        // are weekday-keyed, so the rollover affects which session
        // card is "today's session" on the Train tab.
        let todayIdx = Calendar.current.component(.weekday, from: AppState.logicalNow) - 1
        let todayKey = dayKeys[max(0, min(6, todayIdx))]

        let hasDayKeys = week.sessions.contains(where: { !$0.day.isEmpty })
        // Match the React DAY_KEYS contract (lowercase 3-letter abbreviation)
        // but tolerate "Friday" / "FRI" / "fri" from imported programmes
        // where the author chose a different convention.
        func matchesToday(_ day: String) -> Bool {
            let lc = day.lowercased().trimmingCharacters(in: .whitespaces)
            if lc.isEmpty { return false }
            if lc == todayKey { return true }
            // "Friday" → prefix "fri" matches "friday"
            return lc.hasPrefix(todayKey)
        }
        let picked: ProgrammeSession? = hasDayKeys
            ? week.sessions.first(where: { matchesToday($0.day) && !$0.isRest })
            : week.sessions.first

        guard let picked = picked,
              !picked.isRest,
              !picked.name.isEmpty else {
            // Real rest day (imported, today not scheduled OR scheduled as
            // an explicit `{day, isRest: true}` slot) — leave the staged
            // session empty so HomeView renders the REST DAY card.
            currentSession = nil
            return
        }
        currentSession = WorkoutSession(
            id: UUID(),
            userId: uid,
            programmeId: prog.id,
            name: picked.name,
            // logicalNow honours the 2am rollover — a session staged
            // at 01:30 Mon gets dated as Sunday, matching the day the
            // user intended to train (and what the calendar shows).
            date: AppState.logicalNow,
            weekNumber: week.weekNumber,
            block: picked.block,
            completed: false,
            data: WorkoutSessionData(exercises: picked.exercises),
            createdAt: nil
        )
    }

    /// Stage a specific session as `currentSession`, used when the user taps
    /// a row in the Home day-grid. Mirrors React's `selectImportedSession`
    /// in HomeTab.jsx:49-52.
    func selectProgrammeSession(_ session: ProgrammeSession, inWeek weekNumber: Int) {
        guard !session.isRest,
              !session.name.isEmpty,
              let prog = activeProgramme,
              let uid = SupabaseManager.shared.currentUser?.id
        else { return }
        currentSession = WorkoutSession(
            id: UUID(),
            userId: uid,
            programmeId: prog.id,
            name: session.name,
            // Same rollover treatment as stageCurrentSessionFromActiveProgramme.
            date: AppState.logicalNow,
            weekNumber: weekNumber,
            block: session.block,
            completed: false,
            data: WorkoutSessionData(exercises: session.exercises),
            createdAt: nil
        )
    }

    // MARK: - Toast

    func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == msg { toast = nil }
        }
    }

    // MARK: - PT-driven session mutations

    /// Scale every exercise's weight in `currentSession` by `factor`, rounded
    /// to nearest 0.5 kg. Mirrors React's "lighter today" handler.
    func scaleCurrentSessionWeights(by factor: Double) {
        guard var session = currentSession,
              var data = session.data else { return }
        data.exercises = data.exercises.map { ex in
            var copy = ex
            if let w = ex.weight {
                let scaled = (w * factor * 2.0).rounded() / 2.0
                copy.weight = scaled
            }
            return copy
        }
        session.data = data
        currentSession = session
    }

    /// Move an exercise within the staged session (drag-to-reorder in
    /// TrainView). In-memory only — like every other staged-session
    /// mutation, nothing persists until the user finishes the workout.
    /// TrainView remaps its index-keyed UI state (completedSets etc.)
    /// before calling this so ticked sets follow their exercise.
    func moveCurrentSessionExercise(from: Int, to: Int) {
        guard from != to,
              var session = currentSession,
              var data = session.data,
              data.exercises.indices.contains(from),
              data.exercises.indices.contains(to) else { return }
        let moved = data.exercises.remove(at: from)
        data.exercises.insert(moved, at: to)
        session.data = data
        currentSession = session
    }

    /// Add `deltaKg` to the matching exercise in the current session (by
    /// name or library-key heuristic).  Persists no DB writes — the change
    /// lives in `currentSession` only until the user finishes the workout.
    func bumpLiftInCurrentSession(name: String, deltaKg: Double) async {
        guard var session = currentSession,
              var data = session.data else { return }
        let key = name.lowercased()
        data.exercises = data.exercises.map { ex in
            var copy = ex
            // Match by exercise name substring OR canonical-key alias
            if ex.name.lowercased().contains(key)
                || liftKeyMatches(ex.name, key: key)
            {
                let curr = ex.weight ?? 0
                copy.weight = max(0, curr + deltaKg)
            }
            return copy
        }
        session.data = data
        currentSession = session
        // Also reflect the bump in workingWeights so the chat-side snapshot
        // stays in sync until the next finishWorkout cycle.
        workingWeights[key] = (workingWeights[key] ?? 0) + deltaKg
    }

    /// Reverse-lookup an exercise display name into its canonical short
    /// key ("bench", "squat", ...). Returns nil for non-tracked lifts.
    private func canonicalLiftKey(forName name: String) -> String? {
        let lower = name.lowercased()
        if lower.contains("bench")    { return "bench" }
        if lower.contains("squat")    { return "squat" }
        if lower.contains("deadlift") { return "deadlift" }
        if lower.contains("overhead") || lower.contains("ohp")
            || lower.contains("press") { return "ohp" }
        if lower.contains("row")      { return "row" }
        return nil
    }

    /// Lightweight alias matcher — turns "bench" into a match for
    /// "Barbell Bench Press" etc. Backed by the canonical exercise library.
    private func liftKeyMatches(_ exerciseName: String, key: String) -> Bool {
        let needle = exerciseName.lowercased()
        switch key {
        case "bench":    return needle.contains("bench")
        case "squat":    return needle.contains("squat")
        case "deadlift": return needle.contains("deadlift")
        case "ohp":      return needle.contains("overhead") || needle.contains("ohp") || needle.contains("press")
        case "row":      return needle.contains("row")
        default:         return false
        }
    }
}

// MARK: - Session Complete summary

/// Snapshot of a just-finished workout displayed in the Session Complete
/// sheet. TrainView populates this from the current session + the user's
/// completed sets when the Finish Session button is tapped; the sheet
/// presents it for review and the user then taps "Save Session" to fire
/// `AppState.confirmFinishSession()`.
///
/// Conforms to `Identifiable` so the sheet can be presented via
/// `.sheet(item: $app.pendingSessionSummary)`.
struct SessionSummary: Identifiable, Hashable {
    let id = UUID()

    /// Fully-built WorkoutSession ready for `finishWorkout`. Carries the
    /// final (override-applied) exercises list inside its `.data`.
    let session: WorkoutSession
    /// Per-set rows ready for `savePerformedSets`. Each carries the
    /// parsed reps target and the user's chosen weight.
    let sets: [PerformedSet]

    /// Display fields the sheet reads.
    let sessionName: String
    let setsDone: Int
    let volumeKg: Double
    /// Active training time (gap-capped set-tick sum). nil/0 when the
    /// tick timeline contains no real activity window — the sheet hides
    /// the TIME box rather than showing a meaningless value.
    let durationSeconds: Int?
    let exercises: [ExerciseLine]

    /// One line in the "Final weights" recap inside the sheet.
    struct ExerciseLine: Hashable {
        let name: String
        let weightKg: Double?    // nil for bodyweight
        let bodyweight: Bool
    }

    // Custom Hashable conformance because WorkoutSession + PerformedSet
    // already conform; the auto-synthesized version chokes on the
    // optional Date fields under some compiler settings. Hash on `id`
    // since each summary is unique by construction.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SessionSummary, rhs: SessionSummary) -> Bool {
        lhs.id == rhs.id
    }
}
