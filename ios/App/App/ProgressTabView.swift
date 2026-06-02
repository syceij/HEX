import SwiftUI

/// Progress tab — full port of src/components/ProgressTab.jsx.
///
/// Layout, top to bottom:
///   • "Progress" header (no subtitle — React doesn't have one).
///   • 2×2 tracked-lifts grid — slots come from `profiles.tracked_lifts`
///     so picks made on iOS surface on the web and vice versa.
///   • "View Gym Calendar" pill (navigates to CalendarView).
///   • "MOST IMPROVED" exercise list — top 4 by absolute kg delta;
///     hidden when there's no improvement yet, matching React.
///   • Muscle-progress chart (6 bars) with the "MOST IMPROVED / NEEDS
///     WORK" stats card pair under it.
///   • "HISTORY" expandable session list.
///
/// All sources of truth are Supabase — the workoutHistory, profile,
/// working_weights, and tracked lifts are loaded by AppState and read
/// here without any local-only mutations.
struct ProgressTabView: View {
    @EnvironmentObject var app: AppState

    // Picker state — when not nil, the ExercisePickerSheet opens and any
    // selection writes back to that specific slot.
    @State private var pickerSlot: Int? = nil

    // Action-sheet state — when not nil, the custom bottom sheet opens
    // for that filled slot with "View progress" / "Change exercise" /
    // "Remove". Wrapped in an Identifiable target struct so we can
    // present it via `.sheet(item:)` and get the standard system
    // slide-up animation + drag-to-dismiss for free.
    @State private var actionSheetTarget: LiftActionTarget? = nil

    /// Identifies which lift slot the action sheet is open for, so the
    /// `.sheet(item:)` modifier can pass it through to the body.
    struct LiftActionTarget: Identifiable, Hashable {
        let slot: Int
        var id: Int { slot }
    }

    // Set after the user taps "View progress" — drives the
    // navigationDestination to ExerciseLiftPage.
    @State private var viewingLiftName: String? = nil

    // History row expansion (one open at a time, like React).
    @State private var expandedSessionId: UUID? = nil

    private var ar: Bool { app.language == "ar" }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ────────────────────────────────────────
                Text(ar ? "تقدمك" : "Progress")
                    .font(.system(size: 26, weight: .heavy))
                    .kerning(ar ? 0 : -0.5)
                    .foregroundColor(HexTheme.text)
                    .padding(.bottom, 18)

                // ── Tracked lifts grid ────────────────────────────
                liftsGrid
                    .padding(.bottom, 24)

                // ── View Gym Calendar pill ────────────────────────
                calendarPill
                    .padding(.bottom, 24)

                // ── MOST IMPROVED exercise list (hidden if empty) ──
                if !mostImprovedExercises.isEmpty {
                    mostImprovedSection
                        .padding(.bottom, 24)
                }

                // ── Muscle progress chart ─────────────────────────
                muscleProgressCard
                    .padding(.bottom, 12)

                // ── Dual MOST IMPROVED / NEEDS WORK stats row ─────
                muscleStatsRow
                    .padding(.bottom, 24)

                // ── HISTORY ───────────────────────────────────────
                historySection

                Spacer(minLength: 100) // room for floating tab bar
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        .background(HexTheme.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        // ExercisePickerSheet — opens for a specific slot when pickerSlot
        // is non-nil. Picking writes through AppState.setTrackedLift.
        .sheet(isPresented: pickerSlotIsActive) {
            ExercisePickerSheet(
                currentName: pickerSlot.flatMap { app.trackedLiftSlots[$0]?.name }
            ) { lib in
                if let slot = pickerSlot {
                    Task {
                        await app.setTrackedLift(
                            slot: slot,
                            lift: TrackedLift(name: lib.name, key: lib.key)
                        )
                    }
                }
                pickerSlot = nil
            }
            .environmentObject(app)
        }
        // Action sheet — custom-styled bottom sheet for the lift card
        // tap. Three actions stacked vertically (lime primary "View
        // progress", neutral "Change exercise", red "Remove") so the
        // sheet matches the rest of the lime/dark app theme instead
        // of using the native iOS .confirmationDialog look.
        .sheet(item: $actionSheetTarget) { target in
            LiftActionSheet(
                lift: app.trackedLiftSlots[safe: target.slot] ?? nil,
                onViewProgress: {
                    if let lift = app.trackedLiftSlots[safe: target.slot] ?? nil {
                        viewingLiftName = lift.name
                    }
                    actionSheetTarget = nil
                },
                onChangeExercise: {
                    actionSheetTarget = nil
                    pickerSlot = target.slot
                },
                onRemove: {
                    Task { await app.setTrackedLift(slot: target.slot, lift: nil) }
                    actionSheetTarget = nil
                },
                onCancel: { actionSheetTarget = nil }
            )
            .environmentObject(app)
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
        }
        // ExerciseLiftPage navigation, driven by viewingLiftName.
        .navigationDestination(isPresented: viewingLiftIsActive) {
            if let name = viewingLiftName {
                ExerciseLiftPage(exerciseName: name)
                    .environmentObject(app)
            }
        }
    }

    // MARK: - Binding helpers

    private var pickerSlotIsActive: Binding<Bool> {
        Binding(get: { pickerSlot != nil },
                set: { if !$0 { pickerSlot = nil } })
    }
    private var viewingLiftIsActive: Binding<Bool> {
        Binding(get: { viewingLiftName != nil },
                set: { if !$0 { viewingLiftName = nil } })
    }

    // MARK: - Tracked lifts grid

    private var liftsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ar ? "أوزانك" : "TRACKED LIFTS")
                .font(.system(size: 10, weight: .heavy))
                .kerning(ar ? 0 : 0.9)
                .foregroundColor(HexTheme.dim)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    if let lift = app.trackedLiftSlots[i] {
                        Button {
                            actionSheetTarget = LiftActionTarget(slot: i)
                        } label: {
                            filledLiftCard(lift: lift)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            pickerSlot = i
                        } label: {
                            emptyLiftCard
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Empty slot: dashed-border placeholder with a "+" and copy CTA.
    private var emptyLiftCard: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(HexTheme.surface2)
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(HexTheme.dim)
            }
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(HexTheme.border, lineWidth: 1))

            Text(ar ? "اضغط لإضافة تمرين" : "Tap to add a lift to track")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(HexTheme.mute)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HexTheme.border, style: StrokeStyle(
                    lineWidth: 1.5, dash: [5, 4]))
        )
    }

    /// Filled slot: uppercase tiny name + big kg value + sparkline polyline.
    /// Name reserves space for two lines even when it only renders one,
    /// so a long name like "DUMBBELL BENCH PRESS" doesn't make that
    /// card visibly taller than its three siblings in the 2×2 grid.
    private func filledLiftCard(lift: TrackedLift) -> some View {
        let weight = resolveWorkingWeight(for: lift)
        let sparkData = sparklineWeights(for: lift.name)

        return VStack(alignment: .leading, spacing: 0) {
            // Name + pencil row — fixed 2-line height for grid alignment.
            HStack(alignment: .top, spacing: 4) {
                Text(lift.name.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(0.5)
                    .foregroundColor(HexTheme.dim)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
            }
            .padding(.bottom, 6)

            // Weight value (or em dash when unknown)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let w = weight {
                    Text(formatWeight(w))
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(HexTheme.text)
                    Text("kg")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(HexTheme.dim)
                } else {
                    Text("—")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(HexTheme.text)
                }
            }
            .padding(.bottom, 8)

            // Polyline sparkline
            sparkline(weights: sparkData.isEmpty
                      ? (weight.map { [$0] } ?? [])
                      : sparkData)
                .frame(height: 28)
        }
        .padding(.horizontal, 13)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HexTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HexTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Sparkline (polyline + endpoint dot)

    /// Polyline sparkline matching React's Sparkline component:
    /// W ≈ container width, H = 28, stroke 1.5, dot r=2.5, accent colour.
    /// Renders nothing for <2 data points (returns empty space).
    private func sparkline(weights: [Double]) -> some View {
        GeometryReader { geo in
            if weights.count >= 2 {
                let w = geo.size.width, h: CGFloat = 28
                let lo  = weights.min() ?? 0
                let hi  = weights.max() ?? 1
                let range = max(hi - lo, 1)
                let pts: [CGPoint] = weights.enumerated().map { i, v in
                    let x = CGFloat(i) / CGFloat(weights.count - 1) * w
                    let y = h - CGFloat((v - lo) / range) * (h - 4) - 2
                    return CGPoint(x: x, y: y)
                }
                ZStack(alignment: .topLeading) {
                    Path { p in
                        if let first = pts.first { p.move(to: first) }
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(HexTheme.accent, style: StrokeStyle(
                        lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    if let last = pts.last {
                        Circle()
                            .fill(HexTheme.accentFill)
                            .frame(width: 5, height: 5)
                            .position(x: last.x, y: last.y)
                    }
                }
            } else {
                // <2 points — just an empty band, matches React's blank div.
                Color.clear
            }
        }
    }

    // MARK: - Calendar pill

    private var calendarPill: some View {
        NavigationLink {
            CalendarView().environmentObject(app)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HexTheme.accent)
                Text(ar ? "عرض التقويم" : "View Gym Calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HexTheme.text)
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
            }
            .padding(.horizontal, 16)
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
        .buttonStyle(.plain)
    }

    // MARK: - MOST IMPROVED exercise list

    /// Top 4 weighted exercises by absolute kg delta. Mirrors React's
    /// `getMostImproved` in ProgressTab.jsx — skip bodyweight, require
    /// 2+ entries, delta > 0, descending order, take 4.
    private struct ImprovedExercise: Identifiable, Hashable {
        let id: String        // exercise key (or lowercased name)
        let name: String
        let first: Double
        let last: Double
        var delta: Double { last - first }
        var pct: Int { Int(((last - first) / max(first, 0.0001) * 100).rounded()) }
    }

    private var mostImprovedExercises: [ImprovedExercise] {
        struct Entry { var name: String; var entries: [(Date, Double)] = [] }
        var byKey: [String: Entry] = [:]
        for session in app.workoutHistory {
            // Prefer the row-level Postgres timestamp so multiple
            // sessions logged on the same calendar day still order
            // chronologically — `session.date` alone is day-coarse and
            // would leave the sort to break ties arbitrarily.
            let effectiveDate = session.createdAt ?? session.date
            for ex in session.data?.exercises ?? [] {
                if ex.bodyweight { continue }
                guard let w = ex.weight, w > 0 else { continue }
                // Group by lowercased name only. Using `ex.key` (or
                // splitting on key vs name) caused case-variants of the
                // same exercise — e.g. "Dumbbell Bench Press" and
                // "Dumbbell bench press" — to appear as two separate
                // MOST IMPROVED rows even though they're the same lift.
                let key = ex.name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                var e = byKey[key] ?? Entry(name: ex.name)
                e.entries.append((effectiveDate, w))
                byKey[key] = e
            }
        }
        var out: [ImprovedExercise] = []
        for (key, entry) in byKey where entry.entries.count >= 2 {
            let sorted = entry.entries.sorted(by: { $0.0 < $1.0 })
            let first = sorted.first!.1
            let last  = sorted.last!.1
            if last - first > 0 {
                out.append(ImprovedExercise(
                    id: key, name: entry.name, first: first, last: last
                ))
            }
        }
        return out
            .sorted(by: { $0.delta > $1.delta })
            .prefix(4)
            .map { $0 }
    }

    private var mostImprovedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HexTheme.accent)
                Text(ar ? "الأكثر تحسناً" : "MOST IMPROVED")
                    .font(.system(size: 12, weight: .heavy))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.dim)
            }
            VStack(spacing: 8) {
                ForEach(mostImprovedExercises) { item in
                    improvedRow(item: item)
                }
            }
        }
    }

    private func improvedRow(item: ImprovedExercise) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                Text("\(formatWeight(item.first)) kg → \(formatWeight(item.last)) kg")
                    .font(.system(size: 11))
                    .foregroundColor(HexTheme.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(formatWeight(item.delta)) kg")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(Color(red: 74/255, green: 222/255, blue: 128/255))
                Text("+\(item.pct)%")
                    .font(.system(size: 11))
                    .foregroundColor(HexTheme.dim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(HexTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HexTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Muscle progress chart + stats row

    private var muscleProgressCard: some View {
        let stats  = muscleStats
        let maxPct = max(stats.map(\.pct).max() ?? 1, 1)
        let bestId = stats.filter { $0.seen && $0.pct > 0 }
                          .max(by: { $0.pct < $1.pct })?.id

        return VStack(alignment: .leading, spacing: 14) {
            Text(ar ? "تقدم العضلات" : "MUSCLE PROGRESS")
                .font(.system(size: 12, weight: .heavy))
                .kerning(ar ? 0 : 0.8)
                .foregroundColor(HexTheme.dim)

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(stats, id: \.id) { stat in
                    NavigationLink {
                        MusclePage(muscleId: stat.id)
                            .environmentObject(app)
                    } label: {
                        muscleBar(stat: stat, maxPct: maxPct, bestId: bestId)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 130)
        }
    }

    /// One bar in the chart. Same logic as before but extracted from the
    /// previous file so the stats-cards row can render alongside.
    private func muscleBar(stat: MuscleStat, maxPct: Int, bestId: String?) -> some View {
        let label = barLabel(forId: stat.id)
        let pctClamped = max(min(stat.pct, 100), 0)
        let frac: CGFloat = stat.seen
            ? max(CGFloat(pctClamped) / CGFloat(maxPct), 0.10)
            : 0.06
        let isBest = stat.id == bestId
        let pctLabel: String = {
            if !stat.seen { return "—" }
            if stat.pct > 0 { return "+\(stat.pct)%" }
            return "0%"
        }()

        return VStack(spacing: 4) {
            Text(pctLabel)
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(isBest ? HexTheme.accent
                                 : stat.seen ? HexTheme.dim : HexTheme.mute)
                .frame(height: 11)

            GeometryReader { geo in
                VStack {
                    Spacer(minLength: 0)
                    if stat.seen {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isBest ? HexTheme.accent : HexTheme.border)
                            .frame(height: max(8, geo.size.height * frac))
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(HexTheme.border, style: StrokeStyle(
                                lineWidth: 1.5, dash: [4, 3]))
                            .frame(height: max(8, geo.size.height * frac))
                            .opacity(0.45)
                    }
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(isBest ? HexTheme.accent
                                 : stat.seen ? HexTheme.text : HexTheme.mute)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// Pair of cards under the muscle chart: best muscle group (accent
    /// background) + worst muscle group (neutral). Hidden when there's
    /// no data at all (matches React's `withData.length > 0` guard).
    @ViewBuilder
    private var muscleStatsRow: some View {
        let stats = muscleStats
        let withData = stats.filter { $0.seen }
        let improved = stats.filter { $0.seen && $0.pct > 0 }
        let best = improved.max(by: { $0.pct < $1.pct })
        let worst = withData.count > 1
            ? withData.min(by: { $0.pct < $1.pct })
            : nil

        if withData.isEmpty {
            Text(ar
                 ? "سجّل جلستك الأولى لرؤية تقدم العضلات"
                 : "Log your first session to see muscle progress")
                .font(.system(size: 12))
                .foregroundColor(HexTheme.mute)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            HStack(spacing: 8) {
                bestImprovementCard(best: best)
                if let worst = worst, worst.id != best?.id {
                    needsWorkCard(worst: worst)
                }
            }
        }
    }

    @ViewBuilder
    private func bestImprovementCard(best: MuscleStat?) -> some View {
        // When a positive improvement exists, render the lime-accent
        // card matching React. Otherwise fall back to a neutral
        // "Keep training" card with the same dimensions.
        if let b = best {
            VStack(alignment: .leading, spacing: 4) {
                Text(ar ? "الأكثر تحسناً" : "MOST IMPROVED")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(ar ? 0 : 0.6)
                    .foregroundColor(HexTheme.accent)
                Text(barLabel(forId: b.id, full: true))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                Text("+\(b.pct)%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(HexTheme.accent)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(HexTheme.accent.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(HexTheme.accent.opacity(0.20), lineWidth: 1)
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(ar ? "التقدم" : "PROGRESS")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(ar ? 0 : 0.6)
                    .foregroundColor(HexTheme.mute)
                Text(ar ? "واصل التدريب" : "Keep training")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(HexTheme.dim)
                Text(ar
                     ? "يظهر التحسن بعد عدة جلسات"
                     : "Improvements appear after more sessions")
                    .font(.system(size: 11))
                    .foregroundColor(HexTheme.mute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(HexTheme.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(HexTheme.border, lineWidth: 1)
            )
        }
    }

    private func needsWorkCard(worst: MuscleStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ar ? "بحاجة لعمل" : "NEEDS WORK")
                .font(.system(size: 9, weight: .heavy))
                .kerning(ar ? 0 : 0.6)
                .foregroundColor(HexTheme.mute)
            Text(barLabel(forId: worst.id, full: true))
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(HexTheme.text)
            Text(worst.pct > 0
                 ? "+\(worst.pct)%"
                 : (ar ? "لا تقدم بعد" : "No gains yet"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(HexTheme.dim)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HexTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HexTheme.border, lineWidth: 1)
        )
    }

    // MARK: - HISTORY

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ar ? "السجل" : "HISTORY")
                .font(.system(size: 12, weight: .heavy))
                .kerning(ar ? 0 : 0.8)
                .foregroundColor(HexTheme.dim)

            if app.workoutHistory.isEmpty {
                Text(ar
                     ? "أكمل تمرينك الأول لعرض السجل."
                     : "Complete your first session to see history.")
                    .font(.system(size: 13))
                    .foregroundColor(HexTheme.mute)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 8) {
                    // workoutHistory is already DESC by date — render as-is.
                    ForEach(app.workoutHistory) { session in
                        historyRow(session: session)
                    }
                }
            }
        }
    }

    private func historyRow(session: WorkoutSession) -> some View {
        let expanded = expandedSessionId == session.id
        let exercises = session.data?.exercises ?? []
        let volume = exercises.reduce(0.0) { acc, ex in
            if ex.bodyweight { return acc }
            guard let w = ex.weight, w > 0 else { return acc }
            return acc + w * Double(max(ex.sets, 1))
        }

        return VStack(spacing: 0) {
            Button {
                expandedSessionId = expanded ? nil : session.id
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.name)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(HexTheme.text)
                            .multilineTextAlignment(.leading)
                        Text(historySubtitle(date: session.date,
                                             exerciseCount: exercises.count,
                                             volume: volume))
                            .font(.system(size: 11))
                            .foregroundColor(HexTheme.dim)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(HexTheme.mute)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(exercises.enumerated()), id: \.offset) { idx, ex in
                        HStack {
                            Text(ex.name)
                                .font(.system(size: 13))
                                .foregroundColor(HexTheme.text)
                            Spacer()
                            Text(exerciseSummary(ex))
                                .font(.system(size: 12))
                                .foregroundColor(HexTheme.dim)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        if idx < exercises.count - 1 {
                            Rectangle()
                                .fill(HexTheme.border)
                                .frame(height: 1)
                                .padding(.horizontal, 14)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 10)
                .overlay(
                    Rectangle()
                        .fill(HexTheme.border)
                        .frame(height: 1),
                    alignment: .top
                )
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func historySubtitle(date: Date, exerciseCount: Int, volume: Double) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        let dateStr = df.string(from: date)
        let vol = Int(volume.rounded())
        return ar
            ? "\(dateStr) · \(exerciseCount) تمارين · \(vol) كغ"
            : "\(dateStr) · \(exerciseCount) exercises · \(vol) kg vol."
    }

    private func exerciseSummary(_ ex: Exercise) -> String {
        let load: String = {
            if ex.bodyweight { return ar ? "وزن الجسم" : "BW" }
            if let w = ex.weight, w > 0 { return "\(formatWeight(w))kg" }
            return "—"
        }()
        return "\(ex.sets)×\(ex.reps) @ \(load)"
    }

    // MARK: - Working-weight resolution + sparkline data

    /// Resolve the current weight for a tracked lift.
    ///
    /// Priority order (different from React because iOS history can have
    /// case-variant duplicates of the same exercise — e.g. "Dumbbell Bench
    /// Press" and "Dumbbell bench press" coexisting as separate working_weights
    /// rows, fragmenting the lookup):
    ///
    ///   1. LATEST weight from `workoutHistory` matching the lift name
    ///      case-insensitively. This is the same source the drill-down
    ///      uses for its "CURRENT" stat pill, so the card and the
    ///      drill-down agree by construction.
    ///   2. Case-insensitive exact-match in `workingWeights` (name OR
    ///      library key). Picks the MAX across any case-variant rows
    ///      so a stale lower-case row can't shadow a fresher
    ///      title-case row (or vice versa).
    ///   3. First-2-word prefix fallback — handles "Lateral Raise" →
    ///      "Lateral raise (DB)" etc.
    private func resolveWorkingWeight(for lift: TrackedLift) -> Double? {
        let targetName = lift.name.lowercased()
        let targetKey  = lift.key?.lowercased() ?? ""

        // 1. Latest session weight from history (chronological, matches
        //    the drill-down's CURRENT). Walk sessions newest → oldest
        //    using effective date so same-day sessions still order
        //    correctly.
        let sortedDesc = app.workoutHistory.sorted { lhs, rhs in
            let l = lhs.createdAt ?? lhs.date
            let r = rhs.createdAt ?? rhs.date
            return l > r
        }
        for session in sortedDesc {
            if let ex = session.data?.exercises.first(where: {
                $0.name.lowercased() == targetName && !$0.bodyweight
            }), let w = ex.weight, w > 0 {
                return w
            }
        }

        // 2. Case-insensitive max across working_weights — covers the
        //    case where a tracked lift exists but the user hasn't logged
        //    a session with this name yet (e.g. a freshly-added slot).
        var bestMatch: Double = 0
        for (k, v) in app.workingWeights where v > 0 {
            let lower = k.lowercased()
            if lower == targetName || (!targetKey.isEmpty && lower == targetKey) {
                bestMatch = max(bestMatch, v)
            }
        }
        if bestMatch > 0 { return bestMatch }

        // 3. First-2-word prefix match (case-insensitive max).
        let prefix = lift.name
            .split(separator: " ").prefix(2)
            .joined(separator: " ").lowercased()
        if !prefix.isEmpty {
            for (k, v) in app.workingWeights
                where v > 0 && k.lowercased().contains(prefix) {
                bestMatch = max(bestMatch, v)
            }
            if bestMatch > 0 { return bestMatch }
        }
        return nil
    }

    /// Up to 8 weights chronologically (oldest → newest) for the sparkline.
    private func sparklineWeights(for name: String) -> [Double] {
        // Sort by the precise timestamp (createdAt), falling back to the
        // day-coarse `date`, ascending = oldest → newest.
        //
        // The old code walked `workoutHistory.reversed()` assuming the
        // array was strictly DESC by time. But fetchHistory orders by
        // `date` (the calendar DAY, not the timestamp), so two sessions
        // on the SAME day come back in an undefined order — reversing
        // could yield newest→oldest and render an INCREASE as a
        // downward-sloping line (the reported bug: 30→37.5 kg drew a
        // declining sparkline). Sorting on createdAt here matches what
        // the detail chart and muscleStats already do.
        let chronological = app.workoutHistory.sorted { lhs, rhs in
            (lhs.createdAt ?? lhs.date) < (rhs.createdAt ?? rhs.date)
        }
        var weights: [Double] = []
        for session in chronological {
            if let ex = session.data?.exercises.first(where: {
                $0.name.lowercased() == name.lowercased()
            }), !ex.bodyweight, let w = ex.weight, w > 0 {
                weights.append(w)
            }
        }
        if weights.count > 8 {
            weights = Array(weights.suffix(8))
        }
        return weights
    }

    private func formatWeight(_ w: Double) -> String {
        if w == w.rounded() { return "\(Int(w))" }
        return String(format: "%.1f", w)
    }

    // MARK: - Muscle stats (unchanged from previous file)

    private struct MuscleStat { let id: String; let pct: Int; let seen: Bool }

    /// Aggregate stats per muscle group computed from `workoutHistory`.
    /// Same logic React uses in `calcMuscleImprovements` — but each
    /// weight is now stored alongside its session's effective date so
    /// the "first" and "last" picks order chronologically even when
    /// multiple sessions share the same `session.date` (the day-coarse
    /// finish timestamp). Without this, 13 same-day Dumbbell Bench
    /// sessions would pick `first` and `last` arbitrarily from the
    /// dict-iteration order and surface 0% improvement on Chest even
    /// when the load actually climbed 30 → 107.5 kg.
    private var muscleStats: [MuscleStat] {
        struct Entry { var muscle: String; var entries: [(Date, Double)] = [] }
        var byName: [String: Entry] = [:]
        for session in app.workoutHistory {
            let effectiveDate = session.createdAt ?? session.date
            for ex in session.data?.exercises ?? [] {
                if ex.bodyweight { continue }
                guard let w = ex.weight, w > 0 else { continue }
                guard let muscle = MuscleUtils.resolveMuscle(for: ex) else { continue }
                let key = ex.name.lowercased()
                var e = byName[key] ?? Entry(muscle: muscle)
                e.entries.append((effectiveDate, w))
                byName[key] = e
            }
        }
        var pctsByGroup: [String: [Double]] = [:]
        var seenByGroup: Set<String>        = []
        for (_, entry) in byName {
            for mg in MuscleUtils.groups where mg.muscles.contains(entry.muscle) {
                seenByGroup.insert(mg.id)
                if entry.entries.count >= 2 {
                    let sorted = entry.entries.sorted(by: { $0.0 < $1.0 })
                    let first = sorted.first!.1
                    let last  = sorted.last!.1
                    if first > 0 {
                        pctsByGroup[mg.id, default: []].append((last - first) / first * 100)
                    }
                }
            }
        }
        return MuscleUtils.groups.map { mg in
            let pcts = pctsByGroup[mg.id] ?? []
            let avg  = pcts.isEmpty ? 0 : pcts.reduce(0, +) / Double(pcts.count)
            return MuscleStat(
                id:   mg.id,
                pct:  Int(max(avg, 0).rounded()),
                seen: seenByGroup.contains(mg.id)
            )
        }
    }

    /// Bar label — short variant for the chart, full variant for stats cards.
    private func barLabel(forId id: String, full: Bool = false) -> String {
        if ar {
            switch id {
            case "chest":     return "صدر"
            case "back":      return "ظهر"
            case "shoulders": return "كتف"
            case "arms":      return "ذراع"
            case "legs":      return "أرجل"
            case "core":      return "بطن"
            default:          return id
            }
        }
        switch id {
        case "chest":     return "Chest"
        case "back":      return "Back"
        case "shoulders": return full ? "Shoulders" : "Shldr"
        case "arms":      return "Arms"
        case "legs":      return "Legs"
        case "core":      return "Core"
        default:          return id.capitalized
        }
    }
}

// MARK: - Lift action sheet (filled tracked-lift card → "what to do" bottom sheet)

/// Custom bottom sheet shown when the user taps a filled tracked-lift
/// card. Replaces the native `.confirmationDialog` so the look matches
/// the rest of the lime/dark app surface (the system dialog renders
/// with iOS standard glass + light blue button text).
///
/// Layout, top → bottom:
///   • TRACKED LIFT mini-label + the lift's name (big)
///   • "View Progress" — primary lime button → opens ExerciseLiftPage
///   • "Change exercise" — neutral surface button → re-opens the picker
///   • "Remove" — red destructive button → clears the slot
///   • implicit dismiss via the drag handle / pull-down
struct LiftActionSheet: View {
    let lift: TrackedLift?
    let onViewProgress: () -> Void
    let onChangeExercise: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject var app: AppState
    private var ar: Bool { app.language == "ar" }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header (label + lift name) ────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text(ar ? "وزن متتبع" : "TRACKED LIFT")
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.dim)
                Text(lift?.name ?? "—")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)

            // ── Action buttons ────────────────────────────────────
            VStack(spacing: 10) {
                // Primary: View Progress
                Button(action: onViewProgress) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(.black)
                        Text(ar ? "عرض التقدم" : "View Progress")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(HexTheme.accentFill)
                    )
                }
                .buttonStyle(.plain)

                // Secondary: Change exercise
                Button(action: onChangeExercise) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(HexTheme.text)
                        Text(ar ? "تغيير التمرين" : "Change exercise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(HexTheme.text)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(HexTheme.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(HexTheme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Destructive: Remove
                Button(action: onRemove) {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(HexTheme.danger)
                        Text(ar ? "إزالة" : "Remove")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(HexTheme.danger)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .background(HexTheme.bg.ignoresSafeArea())
    }
}

// MARK: - Array safe-index subscript

extension Array {
    /// Out-of-bounds-safe subscript so `app.trackedLiftSlots[safe: 2]`
    /// returns nil instead of crashing when the index is past the end.
    /// Used by `LiftActionSheet` lookups so the sheet can't crash if
    /// the slot count ever drops mid-animation.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
