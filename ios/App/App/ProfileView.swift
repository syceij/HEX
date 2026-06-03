import SwiftUI

/// Profile tab — surfaces the user's stats prominently and pushes
/// the Account/Settings stuff behind a gear button in the corner.
///
/// Layout (top to bottom):
///   • Header: avatar + name + username, with a settings gear on
///     the trailing side that pushes into the existing AccountView.
///   • Score hero card: this month's leaderboard score with the
///     consistency + improvement breakdown, plus a "See older
///     months" button that opens a history sheet.
///   • Stats grid: friend count + programme name.
///   • Top exercises: 3 most-trained lifts this month (by set count).
///   • Top muscles: 3 most-trained muscle groups this month.
///
/// This file is the foundation for the future badges / trophies
/// system — once monthly score snapshots are accumulating in
/// Supabase, the history sheet will be the entry point for past
/// month / badge browsing.
struct ProfileView: View {
    @EnvironmentObject var app: AppState

    /// Drives the "See older months" sheet (foundation for the
    /// future badges/trophies system).
    @State private var showHistory = false
    /// Monthly history rows for the signed-in user, loaded when the
    /// history sheet opens.
    @State private var monthlyHistory: [SupabaseManager.MonthlyResult] = []
    @State private var loadingHistory = false

    /// Drives the Settings (AccountView) sheet. Opens as a modal
    /// rather than a navigation push so it doesn't persist on the
    /// tab's NavigationStack — previously, tapping the gear once
    /// then switching tabs left the user "stuck" on AccountView
    /// when they returned to the Profile tab (NavigationStack
    /// remembers its path across tab switches).
    @State private var showSettings = false

    /// Drives the "View all badges" full grid sheet.
    @State private var showAllBadges = false

    /// Currently-tapped badge slot in the All Trophies grid — when
    /// non-nil, presents a detail sheet showing the badge at large
    /// size with its unlock criteria. Uses `item:`-style sheet
    /// presentation so the detail dismisses with a single swipe
    /// and the All Trophies grid stays put underneath.
    @State private var selectedBadgeSlot: BadgeCatalogue.Slot?

    /// Earned badges for the signed-in user. Ship 1 reads from a
    /// hardcoded sample set so we can preview the rendered look
    /// (filled strip, featured slot, earned vs locked in the grid)
    /// before wiring real evaluation in Ship 2. Replace this body
    /// with `app.userBadges` once the Supabase column + evaluator
    /// hook land.
    ///
    /// Sample set covers the three families (monthly / power / meta)
    /// so every visual state is exercised:
    ///   • Jan 2026, Mar 2026, May 2026 monthlies (most recent
    ///     wins the featured slot — May here)
    ///   • 100% Power on Bench Press
    ///   • 200% Power on Squat
    ///   • Hero (earned because we have 3+ monthlies)
    /// Earned badges for the current user, read straight off the
    /// loaded profile row. Backed by the `profiles.badges` jsonb
    /// column added in the 2026-05-20 migration. Empty at launch —
    /// awarding logic that appends to this column ships later.
    private var earnedBadges: [EarnedBadge] {
        app.currentProfile?.badges ?? []
    }

    /// A specific earned badge tapped in the trophy cabinet. When
    /// non-nil, presents a detail sheet showing the badge with its
    /// per-instance context — for monthlies that's the year and
    /// month, for power badges it's the exercise + improvement %,
    /// plus the date earned. Different from `selectedBadgeSlot`,
    /// which holds a generic catalogue entry tapped in the All
    /// Trophies grid (shows criteria for locked badges).
    @State private var selectedEarnedBadge: EarnedBadge?

    private var ar: Bool { app.language == "ar" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                    .padding(.top, 4)
                scoreCard
                trophyCaseSection
                statsGrid
                topExercisesSection
                topMusclesSection
                Spacer(minLength: 60) // room for the floating tab bar
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        .background(HexTheme.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(isPresented: $showAllBadges) {
            allBadgesSheet
        }
        .sheet(item: $selectedEarnedBadge) { badge in
            EarnedBadgeDetailView(badge: badge, ar: ar)
        }
        .sheet(isPresented: $showHistory) {
            historySheet
        }
        .sheet(isPresented: $showSettings) {
            // Wrap AccountView in its own NavigationStack so its
            // sub-pages (Build Programme, Manual Builder, Calendar
            // etc.) push correctly inside the sheet without
            // polluting the tab's stack. Dismissing the sheet
            // returns the user cleanly to the Profile tab.
            NavigationStack { AccountView() }
                .environmentObject(app)
        }
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }

    // MARK: - Header (avatar + name + settings gear)

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            avatarCircle
            VStack(alignment: .leading, spacing: 2) {
                Text(app.currentProfile?.name ?? "—")
                    .font(HexTheme.font(size: 20, weight: .heavy, ar: ar))
                    .foregroundColor(HexTheme.text)
                    .lineLimit(1)
                if let uname = app.currentProfile?.username, !uname.isEmpty {
                    Text("@" + uname)
                        .font(HexTheme.font(size: 13, weight: .regular, ar: ar))
                        .foregroundColor(HexTheme.dim)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(HexTheme.surface2)
                    )
                    .overlay(
                        Circle().stroke(HexTheme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    /// Avatar — uses AsyncImage when the user has a URL, falls back
    /// to a lime-tinted initial circle when they don't (same shape
    /// the React ProfileTab renders).
    private var avatarCircle: some View {
        Group {
            if let urlString = app.currentProfile?.avatarURL,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    initialFallback
                }
            } else {
                initialFallback
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .overlay(Circle().stroke(HexTheme.border, lineWidth: 1.5))
    }

    private var initialFallback: some View {
        ZStack {
            Circle().fill(HexTheme.surface2)
            Text(String((app.currentProfile?.name ?? "?").prefix(1)).uppercased())
                .font(HexTheme.font(size: 24, weight: .heavy, ar: ar))
                .foregroundColor(HexTheme.accent)
        }
    }

    // MARK: - Score hero card

    /// Pulls the cached current-month leaderboard from
    /// `currentProfile.leaderboard_data`. If absent or stale (wrong
    /// month), shows zeros — same defensive treatment the leaderboard
    /// in CrewView uses.
    private var currentMonthData: LeaderboardData? {
        let monthKey = Self.currentMonthKey()
        guard let ld = app.currentProfileLeaderboard else { return nil }
        return ld.month == monthKey ? ld : nil
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(ar ? "هذا الشهر" : "THIS MONTH")
                    .font(HexTheme.font(size: 10, weight: .heavy, ar: ar))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.accent)
                Spacer()
                Text(Self.formattedMonthYear(for: Date(), ar: ar))
                    .font(HexTheme.font(size: 11, weight: .heavy, ar: ar))
                    .foregroundColor(HexTheme.mute)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(currentMonthData?.score ?? 0)")
                    .font(HexTheme.font(size: 56, weight: .heavy, ar: ar))
                    .foregroundColor(HexTheme.accent)
                    .monospacedDigit()
                Text(ar ? "نقطة" : "pts")
                    .font(HexTheme.font(size: 14, weight: .heavy, ar: ar))
                    .foregroundColor(HexTheme.dim)
                Spacer()
            }

            // Breakdown row — consistency / improvement
            HStack(spacing: 0) {
                breakdownPill(
                    label: ar ? "الالتزام" : "Consistency",
                    value: consistencyText,
                    accent: HexTheme.accent
                )
                Rectangle()
                    .fill(HexTheme.border)
                    .frame(width: 1, height: 28)
                breakdownPill(
                    label: ar ? "التحسن" : "Improvement",
                    value: improvementText,
                    accent: HexTheme.accent.opacity(0.55)
                )
            }
            .padding(.top, 4)

            // History entry point
            Button {
                showHistory = true
            } label: {
                HStack(spacing: 6) {
                    Text(ar ? "عرض الأشهر السابقة" : "See older months")
                        .font(HexTheme.font(size: 13, weight: .heavy, ar: ar))
                    Image(systemName: ar ? "chevron.left" : "chevron.right")
                        .font(.system(size: 11, weight: .heavy))
                }
                .foregroundColor(HexTheme.accent)
                .padding(.top, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(HexTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(HexTheme.accent.opacity(0.20), lineWidth: 1.5)
        )
    }

    private var consistencyText: String {
        guard let ld = currentMonthData, ld.setsProgrammed > 0 else {
            return ar ? "—" : "—"
        }
        let pct = Int((Double(ld.setsCompleted) / Double(ld.setsProgrammed) * 100).rounded())
        return "\(ld.setsCompleted)/\(ld.setsProgrammed) (\(pct)%)"
    }
    private var improvementText: String {
        guard let ld = currentMonthData else { return ar ? "—" : "—" }
        return "+\(ld.improvementPct)%"
    }

    private func breakdownPill(label: String, value: String, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(HexTheme.font(size: 10, weight: .heavy, ar: ar))
                .foregroundColor(HexTheme.dim)
            Text(value)
                .font(HexTheme.font(size: 13, weight: .heavy, ar: ar))
                .foregroundColor(accent)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stats grid (friends + programme)

    private var statsGrid: some View {
        HStack(spacing: 12) {
            statCard(
                label: ar ? "الأصدقاء" : "Friends",
                value: "\(app.friends.count)",
                icon: "person.2.fill"
            )
            statCard(
                label: ar ? "البرنامج" : "Programme",
                value: app.activeProgramme?.name
                    ?? (ar ? "لا يوجد" : "None"),
                icon: "list.bullet.rectangle.fill"
            )
        }
    }

    private func statCard(label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HexTheme.accent)
                Text(label)
                    .font(HexTheme.font(size: 11, weight: .heavy, ar: ar))
                    .foregroundColor(HexTheme.dim)
            }
            Text(value)
                .font(HexTheme.font(size: 16, weight: .heavy, ar: ar))
                .foregroundColor(HexTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

    // MARK: - Top exercises (this month)

    /// Map of exercise-name → set count, restricted to sessions in
    /// the current calendar month. We use the saved
    /// `WorkoutSession.data.exercises[].sets` rather than the raw
    /// `sets` table because the history is already local and
    /// querying Supabase from inside a SwiftUI view is awkward.
    /// Future iteration: derive from a cached SetsRow query for
    /// accuracy.
    private var topExercisesThisMonth: [(name: String, sets: Int)] {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))
            ?? now
        var counts: [String: Int] = [:]
        for s in app.workoutHistory where s.date >= monthStart {
            for ex in s.data?.exercises ?? [] {
                counts[ex.name, default: 0] += max(ex.sets, 1)
            }
        }
        return counts
            .map { (name: $0.key, sets: $0.value) }
            .sorted { $0.sets > $1.sets }
            .prefix(3)
            .map { $0 }
    }

    @ViewBuilder
    private var topExercisesSection: some View {
        let rows = topExercisesThisMonth
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(ar ? "أكثر التمارين هذا الشهر" : "TOP EXERCISES THIS MONTH")
                    .font(HexTheme.font(size: 10, weight: .heavy, ar: ar))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.dim)
                    .padding(.bottom, 2)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        topRowView(rank: idx + 1,
                                   title: row.name,
                                   value: "\(row.sets) " + (ar ? "مجموعة" : "sets"))
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(HexTheme.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(HexTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: - Top muscles (this month)

    /// Resolve a muscle group for an exercise by looking it up in the
    /// shipped library. Falls back to "other" so an unmatched custom
    /// exercise doesn't disappear from the chart entirely.
    private func muscleFor(_ exerciseName: String) -> String {
        let lower = exerciseName.lowercased().trimmingCharacters(in: .whitespaces)
        if let match = ProgrammeBuilder.exercises.first(where: { $0.name.lowercased() == lower }) {
            return match.muscle
        }
        return "other"
    }

    private var topMusclesThisMonth: [(muscle: String, sets: Int)] {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))
            ?? now
        var counts: [String: Int] = [:]
        for s in app.workoutHistory where s.date >= monthStart {
            for ex in s.data?.exercises ?? [] {
                counts[muscleFor(ex.name), default: 0] += max(ex.sets, 1)
            }
        }
        return counts
            .map { (muscle: $0.key, sets: $0.value) }
            .sorted { $0.sets > $1.sets }
            .prefix(3)
            .map { $0 }
    }

    /// Bilingual + capitalised muscle name.
    private func muscleDisplayName(_ key: String) -> String {
        if ar {
            switch key {
            case "chest":      return "الصدر"
            case "shoulders":  return "الأكتاف"
            case "back":       return "الظهر"
            case "biceps":     return "البايسبس"
            case "triceps":    return "الترايسبس"
            case "quads":      return "الفخذ الأمامي"
            case "hamstrings": return "الفخذ الخلفي"
            case "calves":     return "السمانة"
            case "core":       return "البطن"
            case "other":      return "أخرى"
            default:           return key
            }
        }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    @ViewBuilder
    private var topMusclesSection: some View {
        let rows = topMusclesThisMonth
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(ar ? "أكثر العضلات هذا الشهر" : "TOP MUSCLES THIS MONTH")
                    .font(HexTheme.font(size: 10, weight: .heavy, ar: ar))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.dim)
                    .padding(.bottom, 2)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        topRowView(rank: idx + 1,
                                   title: muscleDisplayName(row.muscle),
                                   value: "\(row.sets) " + (ar ? "مجموعة" : "sets"))
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(HexTheme.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(HexTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: - Top-row cell

    private func topRowView(rank: Int, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(HexTheme.font(size: 12, weight: .heavy, ar: ar))
                .foregroundColor(rank == 1 ? HexTheme.accent : HexTheme.dim)
                .frame(width: 20, alignment: .center)
            Text(title)
                .font(HexTheme.font(size: 14, weight: .heavy, ar: ar))
                .foregroundColor(HexTheme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(HexTheme.font(size: 12, weight: .heavy, ar: ar))
                .foregroundColor(HexTheme.dim)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(
            Rectangle()
                .fill(HexTheme.border.opacity(rank == 1 ? 0 : 0.7))
                .frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - History sheet (older months)

    /// Foundation for the badges/trophies system — for now it's a
    /// placeholder explaining that history will populate as the user
    /// completes more months. Future iteration: query historical
    /// snapshots from a dedicated table once we start writing them.
    private var historySheet: some View {
        VStack(spacing: 16) {
            // Drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(HexTheme.border)
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            Text(ar ? "السجل الشهري" : "Monthly History")
                .font(HexTheme.font(size: 18, weight: .heavy, ar: ar))
                .foregroundColor(HexTheme.text)
                .padding(.top, 6)

            // Merge the stored history with the live current-month score
            // (from leaderboard_data) so the current month always shows
            // even before its first snapshot lands.
            let rows = mergedHistoryRows()

            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 36))
                        .foregroundColor(HexTheme.accent.opacity(0.45))
                    Text(ar
                         ? "ابدأ التدريب وسيظهر سجلك الشهري هنا"
                         : "Train this month and your history starts here")
                        .font(HexTheme.font(size: 14, weight: .heavy, ar: ar))
                        .foregroundColor(HexTheme.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 28)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(rows) { row in
                            monthlyRow(row)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HexTheme.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task {
            loadingHistory = true
            if let uid = app.currentProfile?.id
                ?? SupabaseManager.shared.currentUser?.id {
                monthlyHistory = (try? await SupabaseManager.shared
                    .fetchLeaderboardHistory(userId: uid)) ?? []
            }
            loadingHistory = false
        }
    }

    /// Combine stored history rows with the live current-month score so
    /// the timeline shows the current month immediately (its snapshot may
    /// not have been written yet). De-dupes on month, current data wins.
    private func mergedHistoryRows() -> [SupabaseManager.MonthlyResult] {
        var byMonth: [String: SupabaseManager.MonthlyResult] = [:]
        for r in monthlyHistory { byMonth[r.month] = r }
        if let ld = app.currentProfileLeaderboard {
            byMonth[ld.month] = .init(
                month:          ld.month,
                score:          ld.score,
                setsCompleted:  ld.setsCompleted,
                setsProgrammed: ld.setsProgrammed,
                improvementPct: ld.improvementPct
            )
        }
        return byMonth.values.sorted { $0.month > $1.month }
    }

    /// A single month card: localized month name + score + consistency.
    @ViewBuilder
    private func monthlyRow(_ r: SupabaseManager.MonthlyResult) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.formattedMonthYear(for: monthDate(r.month), ar: ar))
                    .font(HexTheme.font(size: 14, weight: .heavy, ar: ar))
                    .foregroundColor(HexTheme.text)
                Text(ar
                     ? "\(r.setsCompleted)/\(r.setsProgrammed) مجموعة · +\(r.improvementPct)٪"
                     : "\(r.setsCompleted)/\(r.setsProgrammed) sets · +\(r.improvementPct)%")
                    .font(HexTheme.font(size: 11, weight: .regular, ar: ar))
                    .foregroundColor(HexTheme.mute)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(r.score)")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(HexTheme.accent)
                Text(ar ? "نقطة" : "pts")
                    .font(HexTheme.font(size: 10, weight: .regular, ar: ar))
                    .foregroundColor(HexTheme.mute)
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

    /// Parse "YYYY-MM" → a Date on the 1st of that month (Gregorian).
    private func monthDate(_ key: String) -> Date {
        let parts = key.split(separator: "-")
        var c = DateComponents()
        c.year = parts.count > 0 ? Int(parts[0]) : nil
        c.month = parts.count > 1 ? Int(parts[1]) : nil
        c.day = 1
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    // MARK: - Helpers

    // Featured-badge code (slot, picker sheet, pin/unpin) was
    // removed per user request — earned badges now live exclusively
    // in the trophy cabinet (strip + grid). A user can have
    // multiple instances of the same kind (e.g. 100% Power on
    // both bench and squat), and tapping any cabinet tile shows
    // the per-instance detail (date earned, exercise / month).

    // MARK: - Trophy case section (between score card and stats grid)

    /// Horizontal-scroll strip of earned badges. When empty, shows a
    /// dim "no badges yet" placeholder with a CTA to view all the
    /// possible ones. Tapping any badge — or the "View all" link —
    /// opens the full grid sheet.
    @ViewBuilder
    private var trophyCaseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ar ? "خزانة الشارات" : "TROPHY CASE")
                    .font(HexTheme.font(size: 10, weight: .heavy, ar: ar))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.dim)
                Spacer()
                Button {
                    showAllBadges = true
                } label: {
                    HStack(spacing: 4) {
                        Text(ar ? "عرض الكل" : "View all")
                            .font(HexTheme.font(size: 12, weight: .heavy, ar: ar))
                        Image(systemName: ar ? "chevron.left" : "chevron.right")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundColor(HexTheme.accent)
                }
                .buttonStyle(.plain)
            }

            if earnedBadges.isEmpty {
                trophyStripEmptyState
            } else {
                trophyStrip
            }
        }
    }

    private var trophyStripEmptyState: some View {
        Text(ar
             ? "لا توجد شارات بعد — انقر «عرض الكل» لمشاهدة ما يمكنك ربحه"
             : "No badges yet — tap View all to see what you can earn")
            .font(HexTheme.font(size: 12, weight: .regular, ar: ar))
            .foregroundColor(HexTheme.mute)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(HexTheme.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(HexTheme.border, lineWidth: 1)
            )
    }

    private var trophyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Cabinet shows EVERY earned instance — a user with
                // 100% Power on bench AND 100% Power on squat sees
                // both tiles. Tap any tile → detail sheet with that
                // specific instance's metadata (date earned + which
                // exercise / month).
                ForEach(earnedBadges.sorted(by: { $0.earnedAt > $1.earnedAt })) { badge in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedEarnedBadge = badge
                    } label: {
                        badgeTile(image: badge.imageName,
                                  caption: badge.kind.label(ar: ar),
                                  locked: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Single badge tile — used by both the earned strip and the
    /// View All grid. Locked tiles render the image at reduced
    /// opacity with a lock chip overlay so users see what's
    /// possible without revealing what they've earned.
    private func badgeTile(image: String, caption: String, locked: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(HexTheme.surface2)
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .opacity(locked ? 0.20 : 1.0)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(HexTheme.mute)
                        .padding(4)
                        .background(Circle().fill(HexTheme.surface))
                }
            }
            .frame(width: 80, height: 80)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(HexTheme.border, lineWidth: 1)
            )
            Text(caption)
                .font(HexTheme.font(size: 9, weight: .heavy, ar: ar))
                .foregroundColor(locked ? HexTheme.mute : HexTheme.text)
                .lineLimit(1)
                .frame(width: 80)
        }
    }

    // MARK: - View All badges sheet

    /// Full grid of every possible badge. Earned ones render in
    /// colour with an "earned" check; locked ones render as dim
    /// silhouettes with their unlock criteria underneath. This is
    /// the foundation surface for the future badge-detail popovers
    /// and the planned share-to-friends flow.
    private var allBadgesSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 14
                ) {
                    ForEach(BadgeCatalogue.allSlots) { slot in
                        // Each tile is a button — tap opens the
                        // detail sheet explaining what the trophy is
                        // and how to earn it. Earned trophies show
                        // the same sheet but with an "Earned" stamp
                        // instead of a "Locked" one.
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedBadgeSlot = slot
                        } label: {
                            badgeTile(
                                image: slot.imageName,
                                caption: slot.label(ar),
                                locked: !hasEarned(slot)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(HexTheme.bg.ignoresSafeArea())
            .navigationTitle(ar ? "كل الشارات" : "All Trophies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ar ? "تم" : "Done") {
                        showAllBadges = false
                    }
                    .foregroundColor(HexTheme.accent)
                }
            }
            // Nested sheet — presented from INSIDE the All Trophies
            // sheet so the user keeps the grid as context. Sheet
            // dismisses cleanly back to the grid; the grid stays
            // mounted underneath.
            .sheet(item: $selectedBadgeSlot) { slot in
                badgeDetailSheet(for: slot)
            }
        }
        .presentationDetents([.large])
    }

    /// Detail popover for a tapped badge slot — large badge image
    /// + name + criteria copy + earned/locked status. Foundation
    /// for the future share-to-friends + featured-pinning flows.
    private func badgeDetailSheet(for slot: BadgeCatalogue.Slot) -> some View {
        let earned = hasEarned(slot)
        return VStack(spacing: 18) {
            // Drag handle proxy — system provides one but we add
            // padding so the badge image doesn't start at the very
            // top edge.
            Spacer().frame(height: 8)

            // Large badge image. Earned: full colour. Locked:
            // dimmed to ~28% so the design is still recognisable
            // but clearly "not yet yours".
            Image(slot.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .opacity(earned ? 1.0 : 0.28)
                .padding(.vertical, 6)

            // Earned / Locked pill
            HStack(spacing: 6) {
                Image(systemName: earned ? "checkmark.seal.fill" : "lock.fill")
                    .font(.system(size: 11, weight: .heavy))
                Text(earned
                     ? (ar ? "تم الربح" : "EARNED")
                     : (ar ? "مقفل" : "LOCKED"))
                    .font(HexTheme.font(size: 11, weight: .heavy, ar: ar))
                    .kerning(ar ? 0 : 0.8)
            }
            .foregroundColor(earned ? HexTheme.accent : HexTheme.mute)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(earned
                               ? HexTheme.accent.opacity(0.12)
                               : HexTheme.surface2)
            )
            .overlay(
                Capsule().stroke(earned
                                 ? HexTheme.accent.opacity(0.45)
                                 : HexTheme.border,
                                 lineWidth: 1)
            )

            // Badge name (large, bold)
            Text(slotDisplayTitle(for: slot))
                .font(HexTheme.font(size: 22, weight: .heavy, ar: ar))
                .foregroundColor(HexTheme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // How to earn it
            VStack(spacing: 8) {
                Text(ar ? "كيف تحصل عليها" : "HOW TO EARN")
                    .font(HexTheme.font(size: 10, weight: .heavy, ar: ar))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.dim)
                Text(slotCriteria(for: slot))
                    .font(HexTheme.font(size: 15, weight: .regular, ar: ar))
                    .foregroundColor(HexTheme.text)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
            }
            .padding(.vertical, 10)

            // "Set as featured" was removed with the featured slot.
            // Earned-instance details now surface via the cabinet
            // tile tap → EarnedBadgeDetailView.

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(HexTheme.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Human-readable badge title — for monthlies, includes the
    /// month name (e.g. "May King"). For other types, the base
    /// label from `BadgeKind.label(ar:)`.
    private func slotDisplayTitle(for slot: BadgeCatalogue.Slot) -> String {
        if slot.kind == .monthly, let n = slot.month {
            let month = BadgeKind.monthShortName(for: n, ar: ar)
            return ar ? "ملك \(month)" : "\(month) King"
        }
        return slot.kind.label(ar: ar)
    }

    /// Unlock criteria — month-specific copy for monthlies,
    /// generic criteria for the others.
    private func slotCriteria(for slot: BadgeCatalogue.Slot) -> String {
        if slot.kind == .monthly, let n = slot.month {
            let month = BadgeKind.monthShortName(for: n, ar: ar)
            return ar
                ? "أكمل ١٠٠٪ من برنامج \(month) — كل المجموعات المبرمجة لذلك الشهر"
                : "Hit 100% of your programme in \(month) — every set you planned for that month"
        }
        return slot.kind.criteria(ar: ar)
    }

    /// Whether the user has earned at least one instance of the
    /// given catalogue slot. Matches monthlies on month number and
    /// power/meta on raw kind.
    private func hasEarned(_ slot: BadgeCatalogue.Slot) -> Bool {
        firstEarnedBadge(for: slot) != nil
    }

    /// The most-recently-earned `EarnedBadge` matching this slot
    /// (or nil if none). Used by the "Set as featured" button in
    /// the detail sheet — when a slot represents a stackable
    /// family (any monthly, any 200% Power instance), we pin the
    /// freshest one by default.
    private func firstEarnedBadge(for slot: BadgeCatalogue.Slot) -> EarnedBadge? {
        let candidates: [EarnedBadge]
        switch slot.kind {
        case .monthly:
            guard let target = slot.month else { return nil }
            candidates = earnedBadges.filter { b in
                guard b.kind == .monthly,
                      let m = b.month?.suffix(2),
                      let n = Int(m)
                else { return false }
                return n == target
            }
        case .power100, .power200, .power500, .hero, .lebron, .invincible:
            candidates = earnedBadges.filter { $0.kind == slot.kind }
        }
        return candidates.sorted(by: { $0.earnedAt > $1.earnedAt }).first
    }

    private static func currentMonthKey() -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    private static func formattedMonthYear(for date: Date, ar: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: ar ? "ar" : "en")
        // Pin Gregorian — without this, Arabic locale defaulted to
        // Islamic Civil and produced "ذو الحجة 2026" for May 2026.
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "MMMM yyyy"
        return df.string(from: date).uppercased()
    }
}

// MARK: - Earned badge detail sheet (shared by ProfileView + FriendProfilePage)

/// Detail sheet that surfaces a SPECIFIC earned-badge instance's
/// context — when it was earned and from which exercise / month.
/// Distinct from the catalogue-detail sheet which shows generic
/// criteria for locked badges; this one assumes the badge IS
/// earned and renders that instance's metadata.
///
/// Reusable across the user's own profile cabinet and a friend's
/// cabinet — same display rules, same shape. Caller is responsible
/// for presenting via `.sheet(item:)`.
struct EarnedBadgeDetailView: View {
    let badge: EarnedBadge
    let ar: Bool

    var body: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 8)

            Image(badge.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .padding(.vertical, 6)

            // Earned pill
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .heavy))
                Text(ar ? "تم الربح" : "EARNED")
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(ar ? 0 : 0.8)
            }
            .foregroundColor(HexTheme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(HexTheme.accent.opacity(0.12)))
            .overlay(Capsule().stroke(HexTheme.accent.opacity(0.45), lineWidth: 1))

            // Title
            Text(displayTitle)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(HexTheme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // "Earned from / on" — the per-instance details: which
            // exercise (for power badges) or which month (for
            // monthlies), plus the absolute / relative date.
            VStack(spacing: 8) {
                Text(ar ? "تفاصيل الإنجاز" : "EARNED FROM")
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.dim)
                Text(contextDetail)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(HexTheme.text)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
                Text(dateDetail)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(HexTheme.dim)
                    .padding(.top, 2)
            }
            .padding(.vertical, 10)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(HexTheme.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Badge title — includes month name for monthlies (e.g. "May
    /// King") so the user knows WHICH monthly they earned.
    private var displayTitle: String {
        if badge.kind == .monthly,
           let m = badge.month?.suffix(2),
           let n = Int(m) {
            let monthName = BadgeKind.monthShortName(for: n, ar: ar)
            return ar ? "ملك \(monthName)" : "\(monthName) King"
        }
        return badge.kind.label(ar: ar)
    }

    /// "From: Bench Press (+115% improvement)" for power, "May 2026"
    /// for monthlies, generic criteria for meta.
    private var contextDetail: String {
        switch badge.kind {
        case .monthly:
            guard let m = badge.month,
                  let monthN = Int(m.suffix(2)),
                  let yearN = Int(m.prefix(4))
            else { return "—" }
            let name = BadgeKind.monthShortName(for: monthN, ar: ar)
            return ar
                ? "أكملت برنامج \(name) \(yearN) بنسبة ١٠٠٪"
                : "Hit 100% of your \(name) \(yearN) programme"
        case .power100, .power200, .power500:
            let exName = badge.exercise ?? (ar ? "تمرين" : "exercise")
            if let v = badge.value {
                return ar
                    ? "\(exName) — تحسّن +\(v)٪"
                    : "\(exName) — +\(v)% improvement"
            }
            return exName
        case .hero, .lebron, .invincible:
            return badge.kind.criteria(ar: ar)
        }
    }

    /// Date earned — absolute month/year, plus a relative "5 days
    /// ago" line so recent unlocks read as fresh.
    private var dateDetail: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: ar ? "ar" : "en")
        // Both formatters get Gregorian pinned explicitly. The
        // absolute DateFormatter needs it because Arabic locale
        // defaults to Islamic Civil; the RelativeDateTimeFormatter
        // needs it for the same reason when computing month
        // boundaries (e.g. "last month" vs "this month").
        df.calendar = Calendar(identifier: .gregorian)
        df.dateStyle = .medium
        let abs = df.string(from: badge.earnedAt)
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: ar ? "ar" : "en")
        rel.calendar = Calendar(identifier: .gregorian)
        rel.unitsStyle = .full
        let relText = rel.localizedString(for: badge.earnedAt, relativeTo: Date())
        return ar ? "\(abs) · \(relText)" : "\(abs) · \(relText)"
    }
}
