import SwiftUI

/// Friend profile — port of `src/components/FriendProfilePage.jsx`.
/// Shows avatar + name, three stat cards (sessions / top muscle / lifts),
/// muscle progress bars, recent sessions, and working weights, all gated by
/// the friend's `privacy_settings` jsonb column.
struct FriendProfilePage: View {

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let friend: FriendListEntry

    @State private var profile: SupabaseManager.FriendProfileRow?
    @State private var sessions: [FriendSession] = []
    @State private var weights: [String: Double] = [:]
    @State private var monthlyHistory: [SupabaseManager.MonthlyResult] = []
    @State private var loading = true

    @State private var confirmingRemove = false
    @State private var removing = false

    /// Friend's active programme (read-only). Fetched alongside the
    /// rest of the profile data; nil while loading or if the friend
    /// has no active programme. Powers the "Programme" card + the
    /// weekly-slider sheet.
    @State private var friendProgramme: Programme?
    /// Drives the weekly slider sheet — tapping the programme card
    /// in the profile pops this up. Sheet shows one page per day
    /// with that day's session + exercises.
    @State private var showProgrammeSlider = false

    /// Specific earned-badge instance the user tapped in the friend's
    /// cabinet. Same UX as the user's own profile: tap a trophy →
    /// detail sheet showing when + what exercise / month they earned
    /// it from.
    @State private var selectedFriendBadge: EarnedBadge?

    /// Tapped session row in the "Recent sessions" card. Non-nil
    /// presents the FriendSessionDetailSheet — a read-only breakdown
    /// of the session's exercises, sets/reps, weights, RPEs, notes.
    @State private var selectedSession: FriendSession?

    private var ar: Bool { app.language == "ar" }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(HexTheme.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task { await load() }
        .sheet(item: $selectedSession) { session in
            FriendSessionDetailSheet(session: session, ar: ar)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: ar ? "chevron.right" : "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(HexTheme.text)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(HexTheme.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(HexTheme.border, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(loading
                     ? (ar ? "جارٍ التحميل…" : "Loading…")
                     : (profile?.username ?? profile?.name ?? friend.name ?? (ar ? "صديق" : "Bro")))
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                if let un = profile?.username {
                    Text("@\(un)")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                }
            }
            Spacer()

            // Hide the Remove button when viewing a user who isn't
            // actually in `app.friends` — happens when this page is
            // opened from a league member tap (the synthetic
            // FriendListEntry passed in won't be in the friend
            // list). Showing a Remove button for a non-friend would
            // be meaningless / confusing.
            let isActualFriend = app.friends.contains(where: { $0.id == friend.id })

            if !loading && isActualFriend {
                Button { handleRemove() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.fill.xmark")
                            .font(.system(size: 11))
                        Text(removing
                             ? (ar ? "جارٍ الإزالة…" : "Removing…")
                             : (confirmingRemove
                                ? (ar ? "تأكيد؟" : "Confirm?")
                                : (ar ? "إزالة" : "Remove")))
                            .font(.system(size: 12, weight: .heavy))
                    }
                    .foregroundColor(confirmingRemove
                                     ? Color(red: 1.0, green: 0.42, blue: 0.42)
                                     : HexTheme.mute)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(confirmingRemove
                                  ? Color(red: 1.0, green: 0.31, blue: 0.31).opacity(0.10)
                                  : HexTheme.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(confirmingRemove
                                    ? Color(red: 1.0, green: 0.31, blue: 0.31).opacity(0.40)
                                    : HexTheme.border,
                                    lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(removing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(HexTheme.surface)
        .overlay(Rectangle().fill(HexTheme.border).frame(height: 1),
                 alignment: .bottom)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack {
                Spacer(minLength: 60)
                Text(ar ? "جارٍ تحميل الملف الشخصي…" : "Loading profile…")
                    .font(.system(size: 14))
                    .foregroundColor(HexTheme.mute)
                Spacer()
            }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    avatarBlock.padding(.top, 16)

                    // Trophy cabinet — friend's earned badges in a
                    // horizontal scroll. Featured slot was removed
                    // (per user spec) so the cabinet is the only
                    // place trophies show. Each tile is tappable and
                    // opens an EarnedBadgeDetailView with the
                    // when/where context for that instance.
                    if !friendEarnedBadges.isEmpty {
                        friendTrophyStrip
                    }

                    pointsCard

                    // Programme card — friend's active programme name.
                    // Tap to open a weekly slider showing every session.
                    if let progName = friendProgrammeName {
                        friendProgrammeCard(name: progName)
                    }

                    if canSeeProgress, !muscleImprovements.isEmpty {
                        muscleProgressCard
                    }

                    if canSeeSessions, !sessions.isEmpty {
                        recentSessionsCard
                    }

                    if !pastMonths.isEmpty {
                        monthlyHistoryCard
                    }

                    if canSeeWeights, !weights.isEmpty {
                        workingWeightsCard
                    }

                    if showEmptyState {
                        Text(privacyMessage)
                            .font(.system(size: 14))
                            .foregroundColor(HexTheme.mute)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Pieces

    private var avatarBlock: some View {
        VStack(spacing: 10) {
            // Render the friend's actual avatar when one is set, with
            // a gradient/initial fallback to match the previous look
            // when the URL is missing or the load fails. Avatar URL
            // can come from either the freshly-loaded FriendProfileRow
            // (preferred — has the latest from `profiles`) or the
            // friend list entry we navigated in from.
            let urlString = profile?.avatarURL ?? friend.avatarURL
            ZStack {
                if let url = urlString {
                    // Same three-branch decode as AccountView: data
                    // URLs decode locally, http URLs go via AsyncImage,
                    // everything else falls through to the gradient.
                    if let dataImg = decodeDataURLImage(url) {
                        Image(uiImage: dataImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                    } else if let parsed = URL(string: url),
                              parsed.scheme == "http" || parsed.scheme == "https" {
                        AsyncImage(url: parsed) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                avatarFallback
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                    } else {
                        avatarFallback
                            .frame(width: 72, height: 72)
                    }
                } else {
                    avatarFallback
                        .frame(width: 72, height: 72)
                }
                Circle()
                    .stroke(HexTheme.accent.opacity(0.27), lineWidth: 2)
                    .frame(width: 72, height: 72)
            }
            Text(profile?.name ?? profile?.username ?? friend.name ?? "Gym Bro")
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(HexTheme.text)
            if let un = profile?.username {
                Text("@\(un)")
                    .font(.system(size: 13))
                    .foregroundColor(HexTheme.mute)
            }
        }
    }

    /// Lime-tinted gradient + initial — same look the page had before
    /// when no avatar URL was available. Used as the AsyncImage
    /// placeholder + the no-URL branch.
    private var avatarFallback: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [HexTheme.accent.opacity(0.20),
                             HexTheme.accent.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint:   .bottomTrailing))
            Text(initial)
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(HexTheme.text)
        }
    }

    // MARK: - Points hero card

    /// Friend's leaderboard data for the CURRENT calendar month. We
    /// drop stale data (different month key) so the card reads zeros
    /// instead of showing March's score in May. Matches how
    /// `rebuildLeaderboard()` in AppState treats stale rows.
    ///
    /// Reads from the freshly-loaded `profile.leaderboardData` first
    /// (always has the latest server values), then falls back to
    /// the `friend.leaderboardData` passed in by the parent view.
    /// The fallback is necessary because some entry points
    /// (notably tapping a league row) pass a synthetic
    /// FriendListEntry with `leaderboardData: nil` — previously
    /// that made the card read 0 even when the user had a real
    /// score in their profile row.
    private var currentMonthData: LeaderboardData? {
        let key = Self.currentMonthKey()
        if let ld = profile?.leaderboardData, ld.month == key {
            return ld
        }
        if let ld = friend.leaderboardData, ld.month == key {
            return ld
        }
        return nil
    }

    private var pointsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(ar ? "هذا الشهر" : "THIS MONTH")
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(ar ? 0 : 0.8)
                    .foregroundColor(HexTheme.accent)
                Spacer()
                Text(Self.formattedMonthYear(for: Date(), ar: ar))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(HexTheme.mute)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(currentMonthData?.score ?? 0)")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundColor(HexTheme.accent)
                    .monospacedDigit()
                Text(ar ? "نقطة" : "pts")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(HexTheme.dim)
                Spacer()
            }

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
        guard let ld = currentMonthData, ld.setsProgrammed > 0 else { return "—" }
        let pct = Int((Double(ld.setsCompleted) / Double(ld.setsProgrammed) * 100).rounded())
        return "\(ld.setsCompleted)/\(ld.setsProgrammed) (\(pct)%)"
    }
    private var improvementText: String {
        guard let ld = currentMonthData else { return "—" }
        return "+\(ld.improvementPct)%"
    }

    private func breakdownPill(label: String, value: String, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(HexTheme.dim)
            Text(value)
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(accent)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private static func currentMonthKey() -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    private static func formattedMonthYear(for date: Date, ar: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: ar ? "ar" : "en")
        // Force Gregorian so Arabic doesn't slip into Islamic Civil.
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "MMMM yyyy"
        return df.string(from: date).uppercased()
    }

    private var muscleProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ar ? "تقدم العضلات" : "MUSCLE PROGRESS")
                .font(.system(size: 12, weight: .heavy))
                .kerning(ar ? 0 : 0.7)
                .foregroundColor(HexTheme.dim)
            ForEach(muscleImprovements) { mg in
                muscleBar(mg)
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

    private func muscleBar(_ mg: MuscleImprovement) -> some View {
        let isTop = mg.id == muscleImprovements.first?.id
        return HStack(spacing: 10) {
            Text(mg.label)
                .font(.system(size: 12))
                .foregroundColor(HexTheme.dim)
                .frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(HexTheme.surface).frame(height: 6)
                    Capsule()
                        .fill(isTop ? HexTheme.accent : Color(white: 0.23))
                        .frame(width: geo.size.width * CGFloat(min(mg.pct, 100)) / 100.0,
                               height: 6)
                        .animation(.easeOut(duration: 0.6), value: mg.pct)
                }
            }
            .frame(height: 6)
            Text("+\(mg.pct)%")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(isTop ? HexTheme.accent : HexTheme.mute)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var recentSessionsCard: some View {
        VStack(spacing: 0) {
            Text(ar ? "الجلسات الأخيرة" : "RECENT SESSIONS")
                .font(.system(size: 12, weight: .heavy))
                .kerning(ar ? 0 : 0.7)
                .foregroundColor(HexTheme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ForEach(Array(sessions.prefix(5).enumerated()), id: \.element.id) { _, s in
                // Each row is a button that presents FriendSession-
                // DetailSheet with the exercises / weights / RPEs from
                // that session. We already loaded the full exercise
                // payload in `load()`, so the sheet is instant — no
                // extra fetch needed.
                Button {
                    selectedSession = s
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "dumbbell.fill")
                            .font(.system(size: 12))
                            .foregroundColor(HexTheme.mute)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(HexTheme.surface)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(HexTheme.text)
                                .lineLimit(1)
                            Text(ar
                                 ? "\(s.exercises.count) تمرين"
                                 : "\(s.exercises.count) exercise\(s.exercises.count == 1 ? "" : "s")")
                                .font(.system(size: 11))
                                .foregroundColor(HexTheme.mute)
                        }
                        Spacer()
                        Text(formatDate(s.date))
                            .font(.system(size: 12))
                            .foregroundColor(HexTheme.mute)
                        Image(systemName: ar ? "chevron.left" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(HexTheme.mute)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                    .overlay(
                        Rectangle().fill(HexTheme.border).frame(height: 1),
                        alignment: .top
                    )
                }
                .buttonStyle(.plain)
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
    }

    /// Friend's COMPLETED past months (current month excluded — its
    /// score isn't final yet). Newest first.
    private var pastMonths: [SupabaseManager.MonthlyResult] {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        let current = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        return monthlyHistory.filter { $0.month < current }.sorted { $0.month > $1.month }
    }

    /// Friend's month-by-month score timeline (past months, newest
    /// first), read from leaderboard_history. Hidden when empty.
    private var monthlyHistoryCard: some View {
        VStack(spacing: 0) {
            Text(ar ? "السجل الشهري" : "MONTHLY HISTORY")
                .font(.system(size: 12, weight: .heavy))
                .kerning(ar ? 0 : 0.7)
                .foregroundColor(HexTheme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ForEach(pastMonths.prefix(12)) { r in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monthLabel(r.month))
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundColor(HexTheme.text)
                        Text(ar
                             ? "\(r.setsCompleted)/\(r.setsProgrammed) مجموعة · +\(r.improvementPct)٪"
                             : "\(r.setsCompleted)/\(r.setsProgrammed) sets · +\(r.improvementPct)%")
                            .font(.system(size: 11))
                            .foregroundColor(HexTheme.mute)
                    }
                    Spacer()
                    Text(ar ? "\(r.score) نقطة" : "\(r.score) pts")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(HexTheme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .overlay(
                    Rectangle().fill(HexTheme.border).frame(height: 1),
                    alignment: .top
                )
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
    }

    /// "YYYY-MM" → localized "Month YYYY", Gregorian-pinned.
    private func monthLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        var c = DateComponents()
        c.year = parts.count > 0 ? Int(parts[0]) : nil
        c.month = parts.count > 1 ? Int(parts[1]) : nil
        c.day = 1
        let date = Calendar(identifier: .gregorian).date(from: c) ?? Date()
        let df = DateFormatter()
        df.locale = Locale(identifier: ar ? "ar" : "en")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "MMMM yyyy"
        return df.string(from: date)
    }

    private var workingWeightsCard: some View {
        VStack(spacing: 0) {
            Text(ar ? "أوزان العمل" : "WORKING WEIGHTS")
                .font(.system(size: 12, weight: .heavy))
                .kerning(ar ? 0 : 0.7)
                .foregroundColor(HexTheme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // working_weights are intentionally written under BOTH the
            // exercise's display name ("Chest Press Machine") AND its
            // slug ("chest_press_machine") so the Progress tab can
            // resolve a lookup via either — see AppState.finishWorkout
            // line ~1255. For display we collapse them: each canonical
            // (lowercase, spaces-not-underscores) key keeps the highest
            // weight and the more readable name.
            let sorted = dedupedWorkingWeights(weights).prefix(8)
            ForEach(Array(sorted), id: \.name) { item in
                let name = item.name
                let w = item.weight
                HStack {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                        .lineLimit(1)
                    Spacer()
                    Text("\(trimWeight(w)) kg")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(HexTheme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .overlay(
                    Rectangle().fill(HexTheme.border).frame(height: 1),
                    alignment: .top
                )
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
    }

    // MARK: - Friend trophies + featured

    /// Friend's earned badges — read straight from the loaded
    /// `FriendProfileRow.badges`. nil during the brief window
    /// between view appear and `load()` returning. Empty array
    /// when the friend has no trophies yet (the launch state for
    /// everyone until awarding logic ships).
    private var friendEarnedBadges: [EarnedBadge] {
        profile?.badges ?? []
    }

    // Featured-badge helpers were removed alongside the slot —
    // friend trophies are now a flat cabinet, no pin.

    /// Horizontal scroll strip of all earned trophies. Each tile is
    /// tappable and surfaces the per-instance EarnedBadgeDetailView
    /// — same UX as the user's own cabinet. Sheet binding lives on
    /// the friend page so taps don't cross-talk with ProfileView.
    private var friendTrophyStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ar ? "الشارات" : "TROPHIES")
                .font(.system(size: 10, weight: .heavy))
                .kerning(ar ? 0 : 0.8)
                .foregroundColor(HexTheme.dim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(friendEarnedBadges.sorted(by: { $0.earnedAt > $1.earnedAt })) { badge in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedFriendBadge = badge
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(HexTheme.surface2)
                                    Image(badge.imageName)
                                        .resizable()
                                        .scaledToFit()
                                        .padding(6)
                                }
                                .frame(width: 80, height: 80)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(HexTheme.border, lineWidth: 1)
                                )
                                Text(badge.kind.label(ar: ar))
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(HexTheme.text)
                                    .lineLimit(1)
                                    .frame(width: 80)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .sheet(item: $selectedFriendBadge) { badge in
            EarnedBadgeDetailView(badge: badge, ar: ar)
        }
    }

    // MARK: - Friend programme card + weekly slider

    /// Active programme name shown beneath the trophy section.
    /// Returns nil while loading or if the friend has no active
    /// programme (or it's private to them).
    private var friendProgrammeName: String? {
        guard let p = friendProgramme, !p.name.isEmpty else { return nil }
        return p.name
    }

    /// Tappable card showing the friend's programme name. Tap →
    /// opens the weekly slider sheet so the user can see every day
    /// of the programme as a swipeable page.
    private func friendProgrammeCard(name: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showProgrammeSlider = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(HexTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(HexTheme.accent.opacity(0.10))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "البرنامج النشط" : "ACTIVE PROGRAMME")
                        .font(.system(size: 10, weight: .heavy))
                        .kerning(ar ? 0 : 0.8)
                        .foregroundColor(HexTheme.dim)
                    Text(name)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(HexTheme.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(HexTheme.mute)
            }
            .padding(14)
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
        .buttonStyle(.plain)
        .sheet(isPresented: $showProgrammeSlider) {
            programmeSliderSheet
        }
    }

    /// Weekly programme slider — TabView page-style so each day is
    /// one full-width page, swipe to flip. Each page shows the
    /// session name + every exercise in that day's slot. Rest days
    /// render an empty-state card.
    private var programmeSliderSheet: some View {
        let week = friendProgramme?.data?.weeks.first
        let dayOrder = ["mon","tue","wed","thu","fri","sat","sun"]
        let sessionsByDay: [String: ProgrammeSession] = {
            guard let sessions = week?.sessions else { return [:] }
            var m: [String: ProgrammeSession] = [:]
            for s in sessions {
                let key = s.day.lowercased().prefix(3)
                if !key.isEmpty { m[String(key)] = s }
            }
            return m
        }()

        return NavigationStack {
            TabView {
                ForEach(dayOrder, id: \.self) { dayKey in
                    programmePage(
                        dayKey: dayKey,
                        session: sessionsByDay[dayKey]
                    )
                    .tag(dayKey)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(HexTheme.bg.ignoresSafeArea())
            .navigationTitle(friendProgramme?.name ?? (ar ? "البرنامج" : "Programme"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ar ? "تم" : "Done") { showProgrammeSlider = false }
                        .foregroundColor(HexTheme.accent)
                }
            }
        }
        .presentationDetents([.large])
    }

    /// One day in the slider — full-bleed page with session info or
    /// "Rest day" empty state.
    @ViewBuilder
    private func programmePage(dayKey: String, session: ProgrammeSession?) -> some View {
        let dayName = programmeDayName(dayKey)
        let isRest = session == nil || session?.isRest == true || (session?.name.isEmpty ?? true)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Day pill
                Text(dayName)
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(ar ? 0 : 0.7)
                    .foregroundColor(HexTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(HexTheme.accent.opacity(0.12)))

                if isRest {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 36))
                            .foregroundColor(HexTheme.accent.opacity(0.45))
                        Text(ar ? "يوم راحة" : "Rest day")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundColor(HexTheme.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else if let s = session {
                    Text(s.name)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(HexTheme.text)
                    if let focus = s.focus, !focus.isEmpty {
                        Text(focus)
                            .font(.system(size: 13))
                            .foregroundColor(HexTheme.dim)
                    }

                    Text(ar ? "التمارين" : "EXERCISES")
                        .font(.system(size: 10, weight: .heavy))
                        .kerning(ar ? 0 : 0.7)
                        .foregroundColor(HexTheme.dim)
                        .padding(.top, 6)

                    VStack(spacing: 0) {
                        ForEach(Array(s.exercises.enumerated()), id: \.offset) { idx, ex in
                            exerciseRow(ex)
                            if idx < s.exercises.count - 1 {
                                Divider().background(HexTheme.border)
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
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func exerciseRow(_ ex: Exercise) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.name)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                Text("\(max(ex.sets, 1)) × \(ex.reps)")
                    .font(.system(size: 12))
                    .foregroundColor(HexTheme.dim)
            }
            Spacer()
            if let w = ex.weight, w > 0 {
                Text("\(formatWeight(w)) kg")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(HexTheme.accent)
            } else if ex.bodyweight {
                Text(ar ? "وزن الجسم" : "BW")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(HexTheme.dim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func formatWeight(_ w: Double) -> String {
        w == w.rounded() ? "\(Int(w))" : String(format: "%.1f", w)
    }

    private func programmeDayName(_ key: String) -> String {
        if ar {
            switch key {
            case "mon": return "الإثنين"
            case "tue": return "الثلاثاء"
            case "wed": return "الأربعاء"
            case "thu": return "الخميس"
            case "fri": return "الجمعة"
            case "sat": return "السبت"
            case "sun": return "الأحد"
            default:    return key
            }
        }
        switch key {
        case "mon": return "MONDAY"
        case "tue": return "TUESDAY"
        case "wed": return "WEDNESDAY"
        case "thu": return "THURSDAY"
        case "fri": return "FRIDAY"
        case "sat": return "SATURDAY"
        case "sun": return "SUNDAY"
        default:    return key.uppercased()
        }
    }

    // MARK: - Data loaders

    private func load() async {
        loading = true
        async let prof    = SupabaseManager.shared.fetchFriendProfile(friendId: friend.id)
        async let sess    = SupabaseManager.shared.fetchFriendSessions(friendId: friend.id, limit: 10)
        async let weights = SupabaseManager.shared.fetchFriendWeights(friendId: friend.id)
        // Friend's active programme — independent fetch so a failure
        // here doesn't take the whole page down. Use `try?` and let
        // the programme card just stay hidden if it 404s.
        async let prog: Programme? = try? await SupabaseManager.shared.fetchFriendActiveProgramme(friendId: friend.id)
        do {
            let (p, s, w) = try await (prof, sess, weights)
            self.profile  = p
            self.sessions = s
            self.weights  = w
        } catch {
            print("[FriendProfilePage] load failed:", error)
        }
        self.friendProgramme = await prog
        // Friend's monthly history — best-effort, hidden if empty.
        self.monthlyHistory = (try? await SupabaseManager.shared
            .fetchLeaderboardHistory(userId: friend.id)) ?? []
        loading = false
    }

    private func handleRemove() {
        if !confirmingRemove {
            confirmingRemove = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                confirmingRemove = false
            }
            return
        }
        removing = true
        Task {
            await app.removeFriend(friend.id)
            await MainActor.run {
                removing = false
                dismiss()
            }
        }
    }

    // MARK: - Privacy

    private var canSeeProgress: Bool { privacyAllows("showProgress") }
    private var canSeeSessions: Bool { privacyAllows("showSessions") }
    private var canSeeWeights:  Bool { privacyAllows("showWeights")  }

    /// Defaults to true (visible) when the flag is missing.
    private func privacyAllows(_ key: String) -> Bool {
        guard let p = profile?.privacySettings else { return true }
        if let v = p[key]?.value as? Bool { return v }
        return true
    }

    private var showEmptyState: Bool {
        // Mirror the React condition: nothing is renderable
        (!canSeeSessions || sessions.isEmpty) &&
        (!canSeeWeights  || weights.isEmpty) &&
        (!canSeeProgress || muscleImprovements.isEmpty)
    }

    private var privacyMessage: String {
        if !canSeeSessions && !canSeeWeights && !canSeeProgress {
            return ar ? "هذا الصديق يبقي إحصاءاته خاصة 🔒"
                      : "This Bro keeps their stats private 🔒"
        }
        return ar ? "لا بيانات بعد" : "No data yet"
    }

    // MARK: - Muscle improvement computation

    struct MuscleImprovement: Identifiable, Hashable {
        let id: String
        let label: String
        let pct: Int
    }

    private var muscleImprovements: [MuscleImprovement] {
        guard !sessions.isEmpty, canSeeProgress else { return [] }
        // exerciseName → (muscle, weights[])
        var exMap: [String: (muscle: String, weights: [Double])] = [:]
        for s in sessions {
            for ex in s.exercises {
                if ex.name.isEmpty { continue }
                // Same heuristic as React: skip bodyweight exercises (no
                // weight to improve). We don't have a bodyweight flag on
                // the Exercise struct, so skip rows with no weight at all.
                guard let m = MuscleUtils.resolveMuscle(fromName: ex.name) else { continue }
                guard let w = ex.weight, w > 0 else { continue }
                if exMap[ex.name] == nil {
                    exMap[ex.name] = (muscle: m, weights: [])
                }
                exMap[ex.name]?.weights.append(w)
            }
        }
        // Per-exercise improvement %, capped at 100
        var grouped: [String: [Int]] = [:]
        for (_, info) in exMap {
            guard info.weights.count >= 2 else { continue }
            let first = info.weights.first ?? 0
            let last  = info.weights.last  ?? 0
            guard first > 0 else { continue }
            let imp = min(Int(((last - first) / first * 100).rounded()), 100)
            grouped[info.muscle, default: []].append(imp)
        }
        var out: [MuscleImprovement] = []
        for mg in MuscleUtils.groups {
            // Sum across all primary-muscle slugs that map to this group.
            let pcts = mg.muscles.flatMap { grouped[$0] ?? [] }
            if pcts.isEmpty { continue }
            let avg = pcts.reduce(0, +) / pcts.count
            if avg > 0 { out.append(.init(id: mg.id, label: mg.label, pct: avg)) }
        }
        return out.sorted { $0.pct > $1.pct }
    }

    private var topMuscle: MuscleImprovement? { muscleImprovements.first }

    // MARK: - Helpers

    private var initial: String {
        let raw = profile?.username ?? profile?.name ?? friend.name ?? friend.username ?? "?"
        return String((raw.first.map(String.init) ?? "?")).uppercased()
    }

    private func formatDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: ar ? "ar_SA" : "en_GB")
        // Force Gregorian. Without this, ar_SA defaulted to Islamic
        // Civil — that's how recent-session dates were rendering as
        // "ذو الحجة ٣" (Dhu al-Hijjah 3) instead of Gregorian May 3.
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "MMM d"
        return df.string(from: d)
    }

    private func trimWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(w))
            : String(format: "%.1f", w)
    }

    /// Collapse working_weights rows that point at the same exercise
    /// under two different keys ("Chest Press Machine" + the slug
    /// "chest_press_machine"). For each canonical key, keep the
    /// highest weight value and the most readable name.
    ///
    /// Background: AppState.finishWorkout intentionally writes weights
    /// under BOTH the display name AND the slug so the Progress tab
    /// can resolve a lookup via either form. That helps lookups but
    /// means the friend profile renders duplicate rows for every
    /// exercise. This helper restores a single row per exercise for
    /// display while leaving the storage alone.
    private func dedupedWorkingWeights(
        _ raw: [String: Double]
    ) -> [(name: String, weight: Double)] {
        // Canonical key — lowercase, underscores → spaces, trimmed.
        // "chest_press_machine" and "Chest Press Machine" both
        // collapse to "chest press machine".
        func canonical(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Group all incoming names by their canonical form.
        var groups: [String: [(name: String, weight: Double)]] = [:]
        for (name, weight) in raw {
            groups[canonical(name), default: []].append((name, weight))
        }

        // For each group: pick the most readable name (preferring
        // versions WITH spaces over snake_case slugs) and the heaviest
        // weight any of the duplicates carry.
        let collapsed = groups.values.map { items -> (name: String, weight: Double) in
            let bestName = items.max { a, b in
                let aHasSpace = a.name.contains(" ")
                let bHasSpace = b.name.contains(" ")
                if aHasSpace != bHasSpace { return !aHasSpace }
                // Tie-break: longer string usually means the human name.
                return a.name.count < b.name.count
            }?.name ?? items.first!.name
            let heaviest = items.map(\.weight).max() ?? 0
            return (name: bestName, weight: heaviest)
        }

        // Heaviest first — matches the existing UX where the user's
        // strongest lifts surface at the top of the card.
        return collapsed.sorted { $0.weight > $1.weight }
    }
}

// MARK: - Recent-session detail sheet

/// Read-only breakdown of one of a friend's logged sessions. Presented
/// as a sheet from FriendProfilePage when the user taps a row in the
/// Recent Sessions card. Shows: session name + date in the header,
/// total volume pill, then a list of every exercise with its sets,
/// reps, weight (or BW), RPE, and notes if present.
///
/// No editing — friends can only ever look. Mirrors how the React
/// side renders the same data in src/components/FriendProfilePage.jsx.
private struct FriendSessionDetailSheet: View {
    let session: FriendSession
    let ar: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                volumeRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)

                Text(ar ? "التمارين" : "EXERCISES")
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(ar ? 0 : 0.7)
                    .foregroundColor(HexTheme.dim)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(Array(session.exercises.enumerated()), id: \.offset) { idx, ex in
                        exerciseRow(ex)
                        if idx < session.exercises.count - 1 {
                            Divider().background(HexTheme.border)
                        }
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
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(HexTheme.bg.ignoresSafeArea())
    }

    // MARK: - Header (name + date)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(HexTheme.text)
            Text(formattedDate(session.date))
                .font(.system(size: 12))
                .foregroundColor(HexTheme.mute)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Date string matching the rest of the FriendProfilePage —
    /// "MMM d" in the user's language, Gregorian calendar pinned so
    /// Arabic doesn't slip into Islamic Civil.
    private func formattedDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: ar ? "ar_SA" : "en_GB")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "MMM d, yyyy"
        return df.string(from: d)
    }

    // MARK: - Volume pill

    private var volumeRow: some View {
        let vol = session.volume
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        nf.locale = Locale(identifier: "en_US_POSIX")
        let formatted = nf.string(from: NSNumber(value: Int(vol))) ?? "\(Int(vol))"
        return HStack(spacing: 8) {
            Image(systemName: "scalemass.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(ar
                 ? "\(formatted) كجم حجم إجمالي"
                 : "\(formatted) kg total volume")
                .font(.system(size: 13, weight: .heavy))
        }
        .foregroundColor(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(HexTheme.accent)
        )
    }

    // MARK: - Exercise row

    @ViewBuilder
    private func exerciseRow(_ ex: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name + tag pill
            HStack(spacing: 6) {
                if let tag = ex.tag {
                    Text(tag.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(tag == "compound" ? HexTheme.accent : HexTheme.mute)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(HexTheme.surface)
                        )
                }
                Text(ex.name)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                    .lineLimit(1)
                Spacer()
            }

            // Stats row — sets · reps · weight · RPE
            HStack(spacing: 14) {
                statCell(label: ar ? "مج" : "Sets",
                         value: "\(ex.sets)")
                statCell(label: ar ? "عد"  : "Reps",
                         value: ex.reps.isEmpty ? "—" : ex.reps)
                statCell(label: ar ? "وزن" : "Weight",
                         value: weightLabel(ex),
                         color: (ex.weight ?? 0) > 0 ? HexTheme.accent : HexTheme.mute)
                statCell(label: "RPE",
                         value: ex.rpe ?? "—",
                         color: HexTheme.dim)
                Spacer()
            }

            // Notes (if any)
            if let notes = ex.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11).italic())
                    .foregroundColor(HexTheme.mute)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Single stat cell — labelled tiny caption + bold value below.
    /// Compact horizontal layout so the four cells fit on one row.
    private func statCell(label: String,
                          value: String,
                          color: Color = HexTheme.text) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(HexTheme.mute)
            Text(value)
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(color)
        }
    }

    /// Weight rendered as "30 kg" / "BW" / fractional like "27.5 kg".
    private func weightLabel(_ ex: Exercise) -> String {
        guard let w = ex.weight, w > 0 else { return ar ? "وزن الجسم" : "BW" }
        let formatted = w.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(w))
            : String(format: "%.1f", w)
        return ar ? "\(formatted) كجم" : "\(formatted) kg"
    }
}
