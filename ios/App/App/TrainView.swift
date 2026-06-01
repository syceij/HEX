import SwiftUI

/// Train tab — workout logger. Visual port of src/components/TodayTab.jsx.
/// Header + Live Activity toggle + progress bar + exercise cards (each with
/// weight pill, expandable rest-timer chips, and numbered set buttons that
/// flip to a check when tapped) + finish session button.
///
/// Empty state matches the React version when no session is loaded.
struct TrainView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    // Local UI state (kept in this view for now — real persistence happens
    // when the session is saved via app.finishSession). Mirrors the
    // useState hooks in TodayTab.jsx.
    @State private var completedSets: [String: Bool] = [:]   // "exKey_setIdx" → done
    @State private var expandedKey: String? = nil            // which exercise has the
                                                              // weight/timer expand showing
    @State private var editedWeights: [String: Double] = [:] // per-exercise weight override
    @State private var restTimerChoice: [String: Int] = [:]  // exKey → seconds
    @State private var activeTimerKey: String? = nil
    @State private var timerRemaining: Int = 0
    @State private var timerDuration: Int = 0
    @State private var timerPaused: Bool = false
    @State private var liveActivityActive: Bool = false

    /// Absolute instant the rest timer fires. The displayed countdown is
    /// derived from this against the wall clock — NOT a decrementing
    /// counter — so locking the phone (which suspends background work)
    /// can't freeze it, and it stays exactly in lock-step with the Live
    /// Activity's date-based `Text(restEndsAt, style: .timer)`.
    @State private var timerEndsAt: Date? = nil
    /// When paused, the seconds that were left at the moment of pausing.
    /// `timerEndsAt` is cleared while paused; on resume we set it back to
    /// `now + pausedRemaining`.
    @State private var timerPausedRemaining: Int? = nil

    /// 0.5 s heartbeat that recomputes `timerRemaining` from
    /// `timerEndsAt`. 0.5 (not 1.0) keeps the ring smooth and means the
    /// digit never visibly lags the Live Activity by more than half a
    /// second.
    private let timerTick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var ar: Bool { app.language == "ar" }

    var body: some View {
        Group {
            if let session = app.currentSession,
               let exercises = session.data?.exercises, !exercises.isEmpty {
                sessionLayout(session: session, exercises: exercises)
            } else {
                emptyState
            }
        }
        .background(HexTheme.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        // Reset all per-session UI state whenever the staged session
        // changes — covers two flows:
        //   1. Just-finished session (`currentSession` → nil after
        //      `confirmFinishSession`) — clears the now-stale checkmarks.
        //   2. User picks a different day on Home — fresh session needs
        //      a clean slate, otherwise old `completedSets` keyed by
        //      `"<exIdx>_<name>_<si>"` could falsely match a new
        //      session's exercise at the same index with the same name.
        .onChange(of: app.currentSession?.id) { _ in
            resetSessionState()
        }
        // Merge sets the user completed via the Lock Screen Live Activity
        // into the local `completedSets` map. Runs on first appear and
        // every time the app foregrounds (in case the user did taps on
        // the LA while the app was backgrounded) AND whenever the
        // published completions map updates (drainPendingSets refreshes
        // it on scenePhase active).
        .onAppear {
            app.refreshLiveActivityCompletions()
            mergeLiveActivityCompletions()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                app.refreshLiveActivityCompletions()
                mergeLiveActivityCompletions()
                // Recompute the countdown immediately on foreground so
                // the digit is correct the instant the app reappears,
                // not after the next 0.5s tick.
                recomputeTimerRemaining()
            }
        }
        .onChange(of: app.liveActivityCompletions) { _ in
            mergeLiveActivityCompletions()
        }
        // Date-based countdown heartbeat. Recomputes the displayed
        // remaining seconds from `timerEndsAt` every 0.5s. Does nothing
        // when no timer is running or while paused.
        .onReceive(timerTick) { _ in
            recomputeTimerRemaining()
        }
    }

    /// Derive `timerRemaining` from the absolute `timerEndsAt`. Stops the
    /// timer (and clears the LA rest state implicitly via the in-app
    /// stopTimer path) when it reaches zero.
    private func recomputeTimerRemaining() {
        guard activeTimerKey != nil else { return }
        if timerPaused {
            // Frozen — keep showing the paused remaining value.
            if let r = timerPausedRemaining { timerRemaining = r }
            return
        }
        guard let ends = timerEndsAt else { return }
        let remaining = Int(ceil(ends.timeIntervalSinceNow))
        if remaining <= 0 {
            stopTimer()
        } else {
            timerRemaining = remaining
        }
    }

    /// Translate `app.liveActivityCompletions` (exerciseName → set indices)
    /// into TrainView's exKey-shaped map so set buttons render the same
    /// green checks the user saw on the Lock Screen. Only sets values to
    /// `true` — never clears, because the user might have un-toggled a
    /// completion in-app and we don't want a stale LA cache to undo that.
    private func mergeLiveActivityCompletions() {
        guard let session = app.currentSession,
              let exercises = session.data?.exercises else { return }
        for (idx, ex) in exercises.enumerated() {
            let indices = app.liveActivityCompletions[ex.name] ?? []
            guard !indices.isEmpty else { continue }
            let exKey = "\(idx)_\(ex.name)"
            for si in indices where si < ex.sets {
                let key = "\(exKey)_\(si)"
                if completedSets[key] != true {
                    completedSets[key] = true
                }
            }
        }
    }

    /// Wipe every @State variable that's scoped to the current workout.
    private func resetSessionState() {
        completedSets      = [:]
        editedWeights      = [:]
        expandedKey        = nil
        activeTimerKey     = nil
        restTimerChoice    = [:]
        timerRemaining     = 0
        timerDuration      = 0
        timerEndsAt        = nil
        timerPausedRemaining = nil
        timerPaused        = false
        liveActivityActive = false
        // Drop the Live-Activity-derived completions tied to the previous
        // session — exerciseName keys could otherwise collide with new
        // exercises on the freshly-staged session.
        app.liveActivityCompletions = [:]
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt")
                .font(.system(size: 40))
                .foregroundColor(HexTheme.mute)
            Text(ar ? "لم يتم تحميل جلسة." : "No session loaded.")
                .font(.system(size: 16))
                .foregroundColor(HexTheme.dim)
            Text(ar
                 ? "اذهب إلى الرئيسية لاختيار جلسة."
                 : "Go to Home to select one.")
                .font(.system(size: 16))
                .foregroundColor(HexTheme.dim)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main layout

    private func sessionLayout(session: WorkoutSession,
                               exercises: [Exercise]) -> some View {
        let totalSets = exercises.reduce(0) { $0 + $1.sets }
        let doneSets  = completedSets.values.filter { $0 }.count
        let progress  = totalSets > 0 ? Double(doneSets) / Double(totalSets) : 0

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Title ─────────────────────────────────────────
                Text(session.name)
                    .font(.system(size: 26, weight: .heavy))
                    .kerning(ar ? 0 : -0.4)
                    .foregroundColor(HexTheme.text)
                    .padding(.bottom, 16)

                // ── Live Activity toggle ──────────────────────────
                liveActivityButton
                    .padding(.bottom, 14)

                // ── Progress bar ──────────────────────────────────
                progressBar(progress: progress,
                            done: doneSets,
                            total: totalSets)
                    .padding(.bottom, 14)

                // ── Exercise cards ───────────────────────────────
                VStack(spacing: 12) {
                    ForEach(Array(exercises.enumerated()), id: \.offset) { idx, ex in
                        exerciseCard(ex: ex, exIdx: idx)
                    }
                }
                .padding(.bottom, 16)

                // ── Finish button ────────────────────────────────
                finishButton(exercises: exercises)

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
    }

    // MARK: - Live Activity button

    private var liveActivityButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if liveActivityActive {
                Task { await LiveActivityService.shared.end() }
                liveActivityActive = false
            } else {
                guard let session = app.currentSession,
                      let exercises = session.data?.exercises,
                      !exercises.isEmpty else { return }
                // Build the staged DTO the widget will read back from
                // the App Group store. Carries enough metadata to render
                // the full exercise card on the Lock Screen and to
                // advance to the next exercise on a "last set" tap.
                let dto = StagedSessionDTO(
                    sessionId:   session.id,
                    userId:      session.userId,
                    programmeId: session.programmeId,
                    name:        session.name,
                    weekNumber:  session.weekNumber,
                    block:       session.block,
                    startedAt:   Date(),
                    exercises:   exercises.enumerated().map { (idx, ex) -> StagedExerciseDTO in
                        let exKey = "\(idx)_\(ex.name)"
                        // The user's rest-timer chip choice for THIS
                        // exercise (90s default mirrors the chip presets).
                        let perExerciseRest = restTimerChoice[exKey] ?? 90
                        return StagedExerciseDTO(
                            key:         ex.key,
                            name:        ex.name,
                            sets:        max(ex.sets, 1),
                            reps:        ex.reps,
                            weightKg:    ex.weight ?? 0,
                            bodyweight:  ex.bodyweight,
                            rpe:         ex.rpe,
                            tag:         ex.tag,
                            // The "Calibrate week 1" italic line in the
                            // training card is the per-exercise note.
                            focus:       ex.notes,
                            notes:       ex.notes,
                            restSeconds: perExerciseRest
                        )
                    },
                    restSeconds: 90   // Session-level fallback (no longer
                                      // used now that each exercise carries
                                      // its own value, but kept for
                                      // backward compatibility with old
                                      // staged payloads still in storage).
                )
                // Figure out which exercise to surface on the LA
                // card first. If the user has done sets in-app
                // already, jumping back to exercise #1 would be
                // disorienting — we want the LA to land on the
                // first NOT-fully-completed exercise (or the very
                // first if none touched), and reflect any partial
                // set completions on that exercise so the buttons
                // are already half-checked.
                //
                // `priorSetsDone` accumulates sets done on every
                // exercise BEFORE the starting one — drives the
                // top session-wide progress bar so it reflects the
                // user's true point in the workout from second-zero.
                var startIdx = 0
                var partialSetsForStart: [Bool]? = nil
                var priorDone = 0
                for (i, ex) in exercises.enumerated() {
                    let exKey = "\(i)_\(ex.name)"
                    let exSets = max(ex.sets, 1)
                    let flags: [Bool] = (0..<exSets).map { si in
                        completedSets["\(exKey)_\(si)"] == true
                    }
                    let allDone = flags.allSatisfy { $0 }
                    if allDone {
                        priorDone += exSets
                        continue
                    }
                    // Found the first incomplete exercise — start
                    // here and pass its current set-completion
                    // pattern so the LA card matches in-app state.
                    startIdx = i
                    partialSetsForStart = flags
                    break
                }
                // Capture for the async closure (Swift can't auto-capture mutable vars).
                let capturedStart = startIdx
                let capturedFlags = partialSetsForStart
                let capturedPrior = priorDone

                if #available(iOS 16.2, *) {
                    Task {
                        do {
                            _ = try await LiveActivityService.shared.start(
                                staged: dto,
                                startExerciseIndex: capturedStart,
                                initialSetsCompleted: capturedFlags,
                                priorSetsDone: capturedPrior
                            )
                            await MainActor.run { liveActivityActive = true }
                        } catch {
                            print("[TrainView] LiveActivity start failed:", error)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: liveActivityActive ? "bolt.fill" : "bolt")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(HexTheme.accent)
                Text(liveActivityActive
                     ? (ar ? "النشاط المباشر فعّال" : "Live Activity Active")
                     : (ar ? "بدء النشاط المباشر" : "Start Live Activity"))
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(liveActivityActive ? HexTheme.accent : HexTheme.dim)
                Spacer()
                if liveActivityActive {
                    Circle()
                        .fill(HexTheme.accentFill)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(HexTheme.accent.opacity(liveActivityActive ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(HexTheme.accent.opacity(liveActivityActive ? 0.5 : 0.2), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Progress bar

    private func progressBar(progress: Double, done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(HexTheme.surface2)
                        .frame(height: 4)
                    Capsule()
                        .fill(HexTheme.accentFill)
                        .frame(width: geo.size.width * progress, height: 4)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85),
                                   value: progress)
                }
            }
            .frame(height: 4)

            Text(ar
                 ? "\(done) / \(total) مجموعات مكتملة"
                 : "\(done) / \(total) sets complete")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(HexTheme.dim)
        }
    }

    // MARK: - Exercise card

    @ViewBuilder
    private func exerciseCard(ex: Exercise, exIdx: Int) -> some View {
        let exKey = "\(exIdx)_\(ex.name)"
        let isExpanded = expandedKey == exKey

        VStack(alignment: .leading, spacing: 10) {

            // ── Top row: name+meta + weight pill ──────────────────
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ex.name)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(HexTheme.text)
                    metaLine(ex: ex)
                    if let notes = ex.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 11))
                            .italic()
                            .foregroundColor(HexTheme.mute)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                weightPill(ex: ex, exKey: exKey, isExpanded: isExpanded)
            }

            // ── Inline expand: weight stepper + rest timer chips ──
            if isExpanded {
                expandPanel(ex: ex, exKey: exKey)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── Set buttons + timer ring ──────────────────────────
            HStack(alignment: .center, spacing: 8) {
                setButtonsRow(ex: ex, exKey: exKey)
                if activeTimerKey == exKey {
                    timerRing
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HexTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HexTheme.border, lineWidth: 1)
        )
    }

    private func metaLine(ex: Exercise) -> some View {
        HStack(spacing: 6) {
            Text(metaText(ex: ex))
                .font(.system(size: 12))
                .foregroundColor(HexTheme.dim)
            if let tag = ex.tag, !tag.isEmpty {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(HexTheme.surface)
                    )
            }
        }
    }

    private func metaText(ex: Exercise) -> String {
        var s = "\(ex.sets) × \(ex.reps)"
        if let rpe = ex.rpe, !rpe.isEmpty {
            s += " · RPE \(rpe)"
        }
        return s
    }

    private func weightPill(ex: Exercise, exKey: String, isExpanded: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expandedKey = isExpanded ? nil : exKey
            }
        } label: {
            HStack(spacing: 4) {
                Text(weightLabel(ex: ex, exKey: exKey))
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(HexTheme.accent)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(HexTheme.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(HexTheme.accent.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(HexTheme.accent.opacity(0.30), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func weightLabel(ex: Exercise, exKey: String) -> String {
        let override = editedWeights[exKey]
        let w = override ?? ex.weight ?? 0
        if w <= 0 { return "BW" }
        if w == w.rounded() {
            return "\(Int(w))kg"
        }
        return String(format: "%.1fkg", w)
    }

    // MARK: - Expand panel

    private func expandPanel(ex: Exercise, exKey: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Weight stepper (±2.5 kg, persisted in editedWeights for the
            // duration of the session; baked into the saved Exercise on finish).
            if (ex.weight ?? 0) > 0 {
                weightStepper(ex: ex, exKey: exKey)
            }
            restTimerChips(exKey: exKey)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func weightStepper(ex: Exercise, exKey: String) -> some View {
        let current = editedWeights[exKey] ?? ex.weight ?? 0
        return HStack(spacing: 10) {
            stepperButton(symbol: "minus") {
                let next = max(0, current - 2.5)
                editedWeights[exKey] = next
                pushWeightToLiveActivity(ex: ex, weight: next)
            }
            VStack(spacing: 0) {
                Text(current == current.rounded()
                     ? "\(Int(current))"
                     : String(format: "%.1f", current))
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                Text("kg")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(HexTheme.mute)
            }
            .frame(maxWidth: .infinity)
            stepperButton(symbol: "plus") {
                let next = current + 2.5
                editedWeights[exKey] = next
                pushWeightToLiveActivity(ex: ex, weight: next)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HexTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HexTheme.border, lineWidth: 1)
        )
    }

    /// Mirror a weight-stepper change into the running Live Activity so
    /// the Lock Screen card shows the kg the user just dialled in. No-op
    /// when no LA is running; the service further no-ops unless the LA
    /// is currently showing this exact exercise.
    private func pushWeightToLiveActivity(ex: Exercise, weight: Double) {
        guard liveActivityActive, #available(iOS 16.2, *) else { return }
        Task {
            await LiveActivityService.shared.syncWeight(
                exerciseName: ex.name,
                weightKg: weight,
                bodyweight: ex.bodyweight
            )
        }
    }

    private func stepperButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .heavy))
                .foregroundColor(HexTheme.accent)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(HexTheme.accent.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(HexTheme.accent.opacity(0.3), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func restTimerChips(exKey: String) -> some View {
        let presets: [(label: String, seconds: Int)] = [
            ("30s", 30), ("60s", 60), ("90s", 90), ("2m", 120), ("3m", 180),
        ]
        let chosen = restTimerChoice[exKey] ?? 90

        return VStack(alignment: .leading, spacing: 8) {
            Text(ar ? "مؤقت الراحة" : "REST TIMER")
                .font(.system(size: 10, weight: .heavy))
                .kerning(ar ? 0 : 0.8)
                .foregroundColor(HexTheme.mute)

            HStack(spacing: 6) {
                ForEach(presets, id: \.seconds) { preset in
                    let active = preset.seconds == chosen
                    Button {
                        restTimerChoice[exKey] = preset.seconds
                    } label: {
                        Text(preset.label)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(active ? .black : HexTheme.dim)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(active ? HexTheme.accent : HexTheme.surface)
                            )
                            .overlay(
                                Capsule().stroke(active ? HexTheme.accent : HexTheme.border,
                                                 lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Set buttons

    private func setButtonsRow(ex: Exercise, exKey: String) -> some View {
        // Wrap-style flex row using LazyVGrid since SwiftUI lacks native flex-wrap
        FlexRow(spacing: 8) {
            ForEach(0..<ex.sets, id: \.self) { si in
                let key = "\(exKey)_\(si)"
                let done = completedSets[key] == true
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    toggleSet(exKey: exKey, setIdx: si, ex: ex)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(done ? HexTheme.accent : HexTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(done ? HexTheme.accent : HexTheme.border,
                                            lineWidth: 1.5)
                            )
                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundColor(.black)
                        } else {
                            Text("\(si + 1)")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(HexTheme.mute)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleSet(exKey: String, setIdx: Int, ex: Exercise) {
        let key = "\(exKey)_\(setIdx)"
        let wasDone = completedSets[key] == true
        let nowDone = !wasDone
        completedSets[key] = nowDone

        // Decide whether this toggle starts a rest timer, and if so
        // compute the SINGLE end date both the in-app ring and the
        // Live Activity will count down to. Sharing the exact instant
        // is what keeps them in lock-step.
        var sharedRestEndsAt: Date? = nil

        if nowDone {
            // Light haptic confirms the tap registered as "set done".
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let allDone = (0..<ex.sets).allSatisfy { completedSets["\(exKey)_\($0)"] == true }
            if allDone {
                // Stronger haptic when the whole exercise is finished.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if activeTimerKey == exKey { stopTimer() }
            } else {
                let dur = restTimerChoice[exKey] ?? 90
                // startTimer returns the end date it used — reuse it
                // verbatim for the LA so the two timers are identical.
                sharedRestEndsAt = startTimer(exKey: exKey, duration: dur)
            }
        } else {
            // Undo — softer feedback.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        // Push the same flip into the running Live Activity so the
        // Lock Screen / Dynamic Island card mirrors the in-app state
        // (it'll only act when the LA is currently showing this
        // exercise — different exercises stay frozen on the card
        // until the user explicitly advances). Pass the shared end
        // date so the LA timer matches the in-app ring exactly.
        if liveActivityActive, #available(iOS 16.2, *) {
            Task {
                await LiveActivityService.shared.syncSetCompletion(
                    exerciseName: ex.name,
                    setIdx: setIdx,
                    completed: nowDone,
                    restEndsAt: sharedRestEndsAt
                )
            }
        }
    }

    // MARK: - Rest timer ring

    private var timerRing: some View {
        let total = max(timerDuration, 1)
        let frac  = Double(timerRemaining) / Double(total)
        return Button {
            toggleTimerPause()
        } label: {
            ZStack {
                Circle()
                    .stroke(HexTheme.border, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(frac))
                    .stroke(HexTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.4), value: timerRemaining)
                VStack(spacing: 0) {
                    Text(formatSeconds(timerRemaining))
                        .font(.system(size: 12, weight: .heavy).monospacedDigit())
                        .foregroundColor(HexTheme.text)
                    if timerPaused {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .foregroundColor(HexTheme.accent)
                    }
                }
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
    }

    private func formatSeconds(_ s: Int) -> String {
        let m = s / 60
        let r = s % 60
        return m > 0 ? "\(m):\(String(format: "%02d", r))" : "\(r)"
    }

    /// Start (or restart) the rest timer for `exKey`, counting down to an
    /// absolute `endsAt`. If the caller already computed an end date
    /// (so it can hand the SAME instant to the Live Activity), it's
    /// passed in; otherwise we derive it from `duration`. Date-based so
    /// backgrounding the app can't freeze it.
    @discardableResult
    private func startTimer(exKey: String, duration: Int, endsAt: Date? = nil) -> Date {
        let end = endsAt ?? Date().addingTimeInterval(Double(duration))
        activeTimerKey       = exKey
        timerDuration        = duration
        timerEndsAt          = end
        timerPausedRemaining = nil
        timerPaused          = false
        timerRemaining       = max(0, Int(ceil(end.timeIntervalSinceNow)))
        return end
    }

    private func stopTimer() {
        activeTimerKey       = nil
        timerRemaining       = 0
        timerDuration        = 0
        timerEndsAt          = nil
        timerPausedRemaining = nil
        timerPaused          = false
    }

    /// Toggle pause on the rest timer. Pausing freezes the displayed
    /// remaining value; resuming re-anchors `timerEndsAt` to now + the
    /// frozen remaining so the countdown continues from where it left
    /// off. (The Live Activity can't itself pause a date-based timer, so
    /// pausing is an in-app-only nicety — the LA keeps counting. This is
    /// a deliberate trade: the common drift cause was backgrounding, now
    /// fixed; an intentional pause self-heals when the set is logged.)
    private func toggleTimerPause() {
        guard activeTimerKey != nil else { return }
        if timerPaused {
            // Resume.
            let remaining = timerPausedRemaining ?? timerRemaining
            timerEndsAt          = Date().addingTimeInterval(Double(remaining))
            timerPausedRemaining = nil
            timerPaused          = false
        } else {
            // Pause — capture what's left.
            if let ends = timerEndsAt {
                timerPausedRemaining = max(0, Int(ceil(ends.timeIntervalSinceNow)))
            }
            timerPaused = true
        }
    }

    // MARK: - Finish button

    private func finishButton(exercises: [Exercise]) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            finishSession(exercises: exercises)
        } label: {
            HStack(spacing: 6) {
                Text(ar ? "إنهاء الجلسة" : "Finish Session")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.black)
                Image(systemName: ar ? "arrow.left" : "arrow.right")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(HexTheme.accentFill)
            )
            .shadow(color: HexTheme.accent.opacity(0.35), radius: 24, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Persist workout

    /// Snapshot the (possibly weight-edited) exercises + checked-off sets
    /// and call `app.finishWorkout(_:sets:)`. Mirrors `finishSession` in
    /// src/App.jsx — saves the workout row plus one performed-set row per
    /// completed set.
    private func finishSession(exercises: [Exercise]) {
        guard let session = app.currentSession else { return }

        // Apply per-exercise weight overrides from the inline stepper.
        //
        // KEY ALIGNMENT (this used to be broken):
        //   • the stepper writes `editedWeights[exKey]` where
        //     `exKey = "<exIdx>_<ex.name>"` (TrainView:222).
        //   • finishSession used to read `editedWeights[ex.name]`, which
        //     never matched, so the user's bumped weights silently
        //     dropped on the floor.
        //
        // We also preserve every Exercise field via mutating-copy instead
        // of re-instantiating via the memberwise init — the old approach
        // dropped `key`, `bodyweight`, `restTimer`, `muscle`, etc., which
        // broke library-key lookups and turned BW exercises into weighted
        // ones on the history side.
        let finalExercises: [Exercise] = exercises.enumerated().map { (exIdx, ex) -> Exercise in
            let exKey = "\(exIdx)_\(ex.name)"
            guard let override = editedWeights[exKey] else { return ex }
            var copy = ex
            copy.weight = override
            return copy
        }

        // Build PerformedSet rows for every set the user marked complete.
        // Same key-alignment fix: completedSets is written with
        // `"<exKey>_<si>"` (TrainView:447), not `"<ex.name>_<si>"`.
        //
        // We also stop sending `reps: nil` — every downstream computation
        // (MusclePage volume, leaderboard score, "most improved" list)
        // multiplies weight × reps, so nil reps zeroed the whole flow.
        // Parse the upper bound of the reps prescription so e.g. "8-10"
        // becomes 10 and "5" stays 5.
        var sets: [PerformedSet] = []
        for (exIdx, ex) in finalExercises.enumerated() {
            let exKey = "\(exIdx)_\(ex.name)"
            let parsedReps = parseTargetReps(ex.reps)
            for setIdx in 0..<ex.sets {
                let key = "\(exKey)_\(setIdx)"
                guard completedSets[key] == true else { continue }
                sets.append(PerformedSet(
                    id:           UUID(),
                    sessionId:    session.id,
                    userId:       session.userId,
                    exerciseName: ex.name,
                    setNumber:    setIdx + 1,
                    reps:         parsedReps,
                    weight:       ex.weight,
                    rpe:          nil,
                    completed:    true,
                    failed:       false,
                    createdAt:    nil
                ))
            }
        }

        let completedSession = WorkoutSession(
            id:          session.id,
            userId:      session.userId,
            programmeId: session.programmeId,
            name:        session.name,
            date:        Date(),
            weekNumber:  session.weekNumber,
            block:       session.block,
            completed:   true,
            data:        WorkoutSessionData(exercises: finalExercises),
            createdAt:   session.createdAt
        )

        // Compute the session-complete summary BEFORE we clear local state
        // — the modal needs the volume + sets-done numbers, and clearing
        // happens after the user taps "Save Session" inside the sheet.
        let doneSets = sets.count
        let volumeKg: Double = sets.reduce(0) { acc, s in
            guard let w = s.weight, w > 0, let r = s.reps, r > 0 else { return acc }
            return acc + w * Double(r)
        }
        let summaryExercises: [SessionSummary.ExerciseLine] = finalExercises.map { ex in
            SessionSummary.ExerciseLine(
                name: ex.name,
                weightKg: ex.bodyweight ? nil : ex.weight,
                bodyweight: ex.bodyweight
            )
        }
        let summary = SessionSummary(
            session: completedSession,
            sets: sets,
            sessionName: completedSession.name,
            setsDone: doneSets,
            volumeKg: volumeKg,
            exercises: summaryExercises
        )

        // Surface the Session Complete modal. The actual persistence runs
        // when the user taps "Save Session ✓" inside the sheet — mirrors
        // React's `showSummary` → `<SummarySheet>` → `handleSave` flow.
        app.pendingSessionSummary = summary

        // Light success haptic on Finish tap so the modal feels responsive.
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Extract a numeric reps target from prescription strings like
    /// `"8-10"` (→10), `"8"` (→8), `"6 reps"` (→6). Falls back to 8 when
    /// nothing parses — that fallback matches React's TodayTab behaviour.
    private func parseTargetReps(_ raw: String) -> Int {
        // Pull out the last digit-run in the string.
        let chars = Array(raw)
        var i = chars.count - 1
        var endIdx = -1
        while i >= 0 {
            if chars[i].isNumber {
                endIdx = i
                break
            }
            i -= 1
        }
        guard endIdx >= 0 else { return 8 }
        var startIdx = endIdx
        while startIdx > 0, chars[startIdx - 1].isNumber {
            startIdx -= 1
        }
        let slice = String(chars[startIdx...endIdx])
        return Int(slice) ?? 8
    }
}

/// Tiny flex-wrap helper so the set buttons reflow onto multiple rows
/// when an exercise has more than ~5 sets at narrow widths. SwiftUI
/// doesn't ship a native flex wrap, so we measure width and lay out
/// children in rows by hand.
private struct FlexRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Simple HStack for now; this is sufficient up to ~5–6 set buttons
        // at normal device widths. A measured flow layout can replace this
        // later if you ever spec >6 sets on a phone.
        HStack(spacing: spacing) {
            content()
        }
    }
}

// MARK: - Session Complete sheet

/// Modal shown after the user taps "Finish Session" in TrainView. Mirrors
/// React's `<SummarySheet>` from TodayTab.jsx: SESSION COMPLETE banner,
/// session name, stat row (Sets / Volume), final-weights recap list,
/// and a big lime "Save Session ✓" button that fires the actual save.
///
/// Presented at the root of ContentView via
/// `.sheet(item: $app.pendingSessionSummary)`.
struct SessionCompleteView: View {
    let summary: SessionSummary
    @EnvironmentObject var app: AppState
    @State private var saving = false

    private var ar: Bool { app.language == "ar" }

    var body: some View {
        VStack(spacing: 0) {
            // ── Grabber ───────────────────────────────────────────
            Capsule()
                .fill(HexTheme.surface2)
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    // ── Banner ────────────────────────────────────
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(HexTheme.accent)
                        Text(ar ? "اكتملت الجلسة" : "SESSION COMPLETE")
                            .font(.system(size: 11, weight: .heavy))
                            .kerning(ar ? 0 : 1.2)
                            .foregroundColor(HexTheme.accent)
                    }

                    // ── Session name ──────────────────────────────
                    Text(summary.sessionName)
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundColor(HexTheme.text)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // ── Stats row ─────────────────────────────────
                    HStack(spacing: 10) {
                        statCard(
                            value: "\(summary.setsDone)",
                            label: ar ? "مجموعات" : "SETS"
                        )
                        statCard(
                            value: formatVolume(summary.volumeKg),
                            label: ar ? "الحجم" : "VOLUME"
                        )
                    }

                    // ── Final weights recap ───────────────────────
                    if !summary.exercises.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ar ? "الأوزان النهائية" : "FINAL WEIGHTS")
                                .font(.system(size: 10, weight: .heavy))
                                .kerning(ar ? 0 : 0.8)
                                .foregroundColor(HexTheme.dim)

                            VStack(spacing: 0) {
                                ForEach(Array(summary.exercises.enumerated()),
                                        id: \.offset) { idx, line in
                                    finalWeightRow(line: line)
                                    if idx < summary.exercises.count - 1 {
                                        Rectangle()
                                            .fill(HexTheme.border)
                                            .frame(height: 1)
                                    }
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(HexTheme.surface2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(HexTheme.border, lineWidth: 1)
                            )
                        }
                    }

                    Spacer(minLength: 8)

                    // ── Save Session button ───────────────────────
                    Button {
                        guard !saving else { return }
                        saving = true
                        Task {
                            await app.confirmFinishSession()
                            saving = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if saving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.black)
                                    .scaleEffect(0.85)
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundColor(.black)
                            }
                            Text(ar ? "حفظ الجلسة" : "Save Session")
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundColor(.black)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(HexTheme.accentFill)
                        )
                        .shadow(color: HexTheme.accent.opacity(0.35),
                                radius: 18, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)

                    // ── Cancel ────────────────────────────────────
                    Button {
                        app.cancelPendingSession()
                    } label: {
                        Text(ar ? "إلغاء" : "Cancel")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(HexTheme.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(HexTheme.bg.ignoresSafeArea())
    }

    // MARK: - Pieces

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(HexTheme.text)
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .kerning(ar ? 0 : 0.8)
                .foregroundColor(HexTheme.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HexTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HexTheme.border, lineWidth: 1)
        )
    }

    private func finalWeightRow(line: SessionSummary.ExerciseLine) -> some View {
        HStack {
            Text(line.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(HexTheme.text)
                .lineLimit(1)
            Spacer()
            Text(weightLabel(line: line))
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(line.bodyweight ? HexTheme.mute : HexTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func weightLabel(line: SessionSummary.ExerciseLine) -> String {
        if line.bodyweight { return ar ? "وزن الجسم" : "BW" }
        guard let w = line.weightKg, w > 0 else { return "—" }
        return w == w.rounded()
            ? "\(Int(w)) kg"
            : String(format: "%.1f kg", w)
    }

    private func formatVolume(_ vol: Double) -> String {
        let rounded = Int(vol.rounded())
        if rounded >= 1000 {
            let tonnes = Double(rounded) / 1000.0
            return tonnes == tonnes.rounded()
                ? "\(Int(tonnes))t"
                : String(format: "%.1ft", tonnes)
        }
        return "\(rounded) kg"
    }
}
