import SwiftUI

/// Home tab — mirrors src/components/HomeTab.jsx.
/// Greeting + lang toggle, today's session card (or rest-day card), week
/// badge, stats grid, and a "View full programme" link.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var showProgramme = false

    private var ar: Bool { app.language == "ar" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Greeting + lang toggle ────────────────────────
                HStack(alignment: .top, spacing: 12) {
                    Text(greetingLine)
                        .font(.system(size: 26, weight: .heavy))
                        .kerning(ar ? 0 : -0.5)
                        .foregroundColor(HexTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            app.language = ar ? "en" : "ar"
                        }
                    } label: {
                        Text(ar ? "EN" : "AR")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(HexTheme.dim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(HexTheme.surface2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(HexTheme.border, lineWidth: 1.5)
                            )
                    }
                    .padding(.top, 4)
                }
                .padding(.bottom, 20)

                // ── Today / rest card ─────────────────────────────
                // Mirrors React HomeTab.jsx:101-163: if today's programme
                // session exists, render a tap-to-train CTA; otherwise
                // render the lime rest-day card.
                todayOrRestCard
                    .padding(.bottom, 14)

                // ── Week badge ────────────────────────────────────
                weekBadge
                    .padding(.bottom, 16)

                // ── Week pill strip (imported, multi-week only) ───
                // Mirrors HomeTab.jsx:184-212.
                if let weeks = app.activeProgramme?.data?.weeks, weeks.count > 1 {
                    weekPillStrip(weeks: weeks)
                        .padding(.bottom, 16)
                }

                // ── 7-day grid ────────────────────────────────────
                // Mirrors HomeTab.jsx:214-247.
                if let weeks = app.activeProgramme?.data?.weeks, !weeks.isEmpty {
                    dayGrid(weeks: weeks)
                        .padding(.bottom, 20)
                }

                // ── Auto-mode: streak row ─────────────────────────
                // 5 Mon-Fri dots, lit when there's a logged session
                // on that weekday this week. Mirrors HomeTab.jsx:252-269.
                // Only renders for auto-mode programmes (flat session
                // list with no day-keys) — imported programmes get the
                // day grid above instead.
                if isAutoMode {
                    autoStreakRow
                        .padding(.bottom, 20)
                }

                // ── Stats grid ────────────────────────────────────
                statsGrid
                    .padding(.bottom, 20)

                // ── Auto-mode: Up Next card ───────────────────────
                // Mirrors HomeTab.jsx:295-310 — preview the next
                // session in the rotation + its first 3 exercises.
                // Only renders for auto programmes with 2+ sessions.
                if let upNext = upNextSession {
                    upNextCard(session: upNext)
                        .padding(.bottom, 14)
                }

                // ── Programme link ────────────────────────────────
                programmeLink

                Spacer(minLength: 100) // room for floating tab bar
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        .scrollContentBackground(.hidden)
        .background(HexTheme.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(isPresented: $showProgramme) {
            ProgrammeModalView()
                .environmentObject(app)
        }
    }

    // MARK: - Pieces

    private var greetingLine: String {
        let h = Calendar.current.component(.hour, from: Date())
        let name = app.currentProfile?.name ?? (ar ? "" : "there")
        if ar {
            let g = h < 12 ? "صــباح الخير" : "مسـاء الخيـر"
            return name.isEmpty ? "\(g) 👋" : "\(g)، \(name) 👋"
        }
        let g = h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
        return "\(g), \(name) 👋"
    }

    // MARK: - Today / rest day

    /// Today's session in the user-selected `currentWeek` of the active
    /// programme — mirrors React's `sessionForTodayImported(imp, currentWeek)`
    /// + the auto-mode fallback in HomeTab.jsx:33-41.
    private var todaySessionForCurrentWeek: ProgrammeSession? {
        guard let weeks = app.activeProgramme?.data?.weeks, !weeks.isEmpty
        else { return nil }
        let week = weeks.first(where: { $0.weekNumber == app.currentWeek })
                ?? weeks.first!
        let hasDayKeys = week.sessions.contains(where: { !$0.day.isEmpty })
        if hasDayKeys {
            return week.sessions.first(where: {
                Self.normalisedDayKey($0.day) == todayDayKey && !$0.isRest
            })
        }
        // Auto programme — no day keys; use the first session.
        return week.sessions.first
    }

    /// Renders either the lime "TODAY'S SESSION" CTA (tap → Train tab) or
    /// the lime REST DAY card. Mirrors React's HomeTab ternary at
    /// HomeTab.jsx:101-163. Source is `todaySessionForCurrentWeek` so the
    /// card flips as the user pages through weeks in the pill strip.
    @ViewBuilder
    private var todayOrRestCard: some View {
        if let session = todaySessionForCurrentWeek,
           !session.isRest,
           !session.name.isEmpty {
            Button {
                // Stage this session before navigating so Train opens to it.
                app.selectProgrammeSession(session, inWeek: app.currentWeek)
                app.activeTab = .train
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                todaySessionCardBody(name: session.name,
                                     exerciseCount: session.exercises.count)
            }
            .buttonStyle(.plain)
        } else {
            restDayCardBody
        }
    }

    /// "TODAY'S SESSION" lime card body. Shows the session name plus an
    /// `N exercises · ~M min` line, matching HomeTab.jsx:147-159.
    private func todaySessionCardBody(name: String, exerciseCount n: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.black.opacity(0.6))
                    Text(ar ? "جلسة اليوم" : "TODAY'S SESSION")
                        .font(.system(size: 10, weight: .heavy))
                        .kerning(ar ? 0 : 1.2)
                        .foregroundColor(Color.black.opacity(0.6))
                }

                Text(name)
                    .font(.system(size: 22, weight: .heavy))
                    .kerning(ar ? 0 : -0.4)
                    .foregroundColor(.black)
                    .padding(.top, 2)

                let mins = Int((Double(max(n, 5)) * 6).rounded())
                Text(ar
                     ? "\(n) تمارين · ≈ \(mins) دقيقة"
                     : "\(n) exercises · ~\(mins) min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.black.opacity(0.55))
            }
            Spacer()
            Image(systemName: ar ? "chevron.left" : "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color.black.opacity(0.6))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(HexTheme.accentFill)
        )
    }

    /// Lime REST DAY card — same copy + styling as before, isolated so the
    /// tap-vs-static branching in `todayOrRestCard` stays readable.
    private var restDayCardBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ar ? "يوم راحة" : "REST DAY")
                .font(.system(size: 10, weight: .heavy))
                .kerning(ar ? 0 : 1.2)
                .foregroundColor(Color.black.opacity(0.6))

            Text(ar ? "استمتع بيوم إجازتك" : "Enjoy your off day")
                .font(.system(size: 22, weight: .heavy))
                .kerning(ar ? 0 : -0.4)
                .foregroundColor(.black)
                .padding(.top, 2)

            Text(ar ? "التعافي جزء من البرنامج" : "Recovery is part of the programme")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.black.opacity(0.55))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(HexTheme.accentFill)
        )
    }

    // MARK: - Week badge

    /// Week badge. For auto programmes shows `Week N · Block 1` where N is
    /// derived from history count divided by sessions-per-week, matching
    /// `HomeTab.jsx:43`. For imported programmes (multi-week) shows
    /// `Week N / total` instead.
    private var weekBadge: some View {
        Text(weekBadgeText)
            .font(.system(size: 12, weight: .heavy))
            .foregroundColor(HexTheme.dim)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(HexTheme.surface2)
            )
            .overlay(
                Capsule().stroke(HexTheme.border, lineWidth: 1.5)
            )
    }

    private var weekBadgeText: String {
        let weeks = app.activeProgramme?.data?.weeks ?? []
        let totalWeeks = app.activeProgramme?.data?.totalWeeks ?? max(weeks.count, 1)
        if totalWeeks > 1 {
            // Imported programme — read the user-selected current week.
            let curWeek = max(1, min(totalWeeks, app.currentWeek))
            return ar
                ? "الأسبوع \(curWeek) / \(totalWeeks)"
                : "Week \(curWeek) / \(totalWeeks)"
        }
        // Auto programme — derive an ever-incrementing week number from
        // completed-session count, like React's `Math.ceil((history+1)/sessionsPerWeek)`.
        let sessionsPerWeek = max(1, weeks.first?.sessions.count ?? 1)
        let weekNum = max(1, Int(ceil(Double(app.workoutHistory.count + 1) / Double(sessionsPerWeek))))
        return ar
            ? "الأسبوع \(weekNum) · المرحلة ١"
            : "Week \(weekNum) · Block 1"
    }

    // MARK: - Week pill strip + day grid

    /// Sun-first day key for today, matching React's
    /// `DAY_KEYS[new Date().getDay()]`.
    private var todayDayKey: String {
        let keys = ["sun","mon","tue","wed","thu","fri","sat"]
        let idx = Calendar.current.component(.weekday, from: Date()) - 1
        return keys[max(0, min(6, idx))]
    }

    /// Mon-first iteration order for the 7-day grid, matching React's
    /// `DAY_ORDER` in importHelpers.js.
    private let dayOrder: [String] = ["mon","tue","wed","thu","fri","sat","sun"]

    /// English: short 3-letter abbreviation ("Mon" / "Tue"). Arabic:
    /// full localised day name with the definite article prefix
    /// (الإثنين / الثلاثاء / …) matching the React HomeTab.jsx version.
    /// Returned by `dayLabel(_:)` and rendered in the accent colour
    /// alongside each row of the weekly schedule.
    private func dayLabel(_ key: String) -> String {
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
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    /// Horizontal scrollable strip of week pills (W1, W2, …, WN). Highlights
    /// the active week and writes to `app.currentWeek` on tap.
    private func weekPillStrip(weeks: [ProgrammeWeek]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(weeks, id: \.weekNumber) { w in
                    let active = w.weekNumber == app.currentWeek
                    Button {
                        app.currentWeek = w.weekNumber
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(weekPillLabel(w))
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(active ? .black : HexTheme.dim)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(active ? HexTheme.accent : HexTheme.surface2)
                            )
                            .overlay(
                                Capsule().stroke(
                                    active ? HexTheme.accent : HexTheme.border,
                                    lineWidth: 1.5
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4) // breathing room for the capsule shadow
        }
        .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
    }

    /// Pill text — React uses `w.label.replace('Week ', 'W')` else `W{n}`.
    private func weekPillLabel(_ w: ProgrammeWeek) -> String {
        if let lbl = w.label, !lbl.isEmpty {
            return lbl.replacingOccurrences(of: "Week ", with: "W")
        }
        return ar ? "أ\(w.weekNumber)" : "W\(w.weekNumber)"
    }

    /// 7-row column for the selected week, one row per Mon→Sun day. Rest
    /// days render muted/non-tappable; workout days are buttons that stage
    /// that session and switch the user to the Train tab.
    private func dayGrid(weeks: [ProgrammeWeek]) -> some View {
        // Pick the displayed week (the one matching currentWeek, else fall
        // back to the first week so the user always sees something).
        let week = weeks.first(where: { $0.weekNumber == app.currentWeek })
                ?? weeks.first!
        // Use `uniquingKeysWith` instead of `uniqueKeysWithValues:` so
        // duplicate day-keys in user-supplied imported JSON don't crash —
        // first match wins, matching React's `find(...)` semantics.
        let sessionsByDay: [String: ProgrammeSession] = Dictionary(
            week.sessions
                .filter { !$0.day.isEmpty }
                .map { (Self.normalisedDayKey($0.day), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return VStack(spacing: 1) {
            ForEach(dayOrder, id: \.self) { dayKey in
                dayRow(dayKey: dayKey,
                       session: sessionsByDay[dayKey],
                       weekNumber: week.weekNumber)
            }
        }
    }

    /// Normalise free-form day strings ("Friday" / "FRI" / "fri") down to
    /// the 3-letter lowercase key used by `dayOrder`.
    static func normalisedDayKey(_ raw: String) -> String {
        let lc = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let abbreviations = ["sun","mon","tue","wed","thu","fri","sat"]
        if abbreviations.contains(lc) { return lc }
        for abbr in abbreviations where lc.hasPrefix(abbr) { return abbr }
        return lc
    }

    /// One row in the day grid. Today's row gets a faint accent tint and
    /// border, rest days render muted text without a chevron.
    private func dayRow(dayKey: String,
                        session: ProgrammeSession?,
                        weekNumber: Int) -> some View {
        let isToday = dayKey == todayDayKey
        let isRest  = session == nil || session?.isRest == true
            || (session?.name.isEmpty ?? true)

        let bgColor: Color = isToday
            ? HexTheme.accent.opacity(0.06)
            : HexTheme.surface
        let strokeColor: Color = isToday
            ? HexTheme.accent.opacity(0.20)
            : HexTheme.border
        let dayColor: Color = isRest ? HexTheme.mute : HexTheme.accent

        let title: String = isRest
            ? (ar ? "راحة" : "Rest")
            : (session?.name ?? "")
        let focus: String? = isRest ? nil : (session?.focus)

        let rowContent = HStack(alignment: .center, spacing: 12) {
            Text(dayLabel(dayKey))
                .font(HexTheme.font(size: ar ? 14 : 12, weight: .heavy, ar: ar))
                .foregroundColor(dayColor)
                // `.leading` respects the layout direction:
                //   • LTR: flush-left within the column ("Mon" sits at
                //     the left edge of its 36pt slot).
                //   • RTL: flush-right within the column ("الإثنين"
                //     sits at the right edge of its 70pt slot — what
                //     the user asked for, "lean to right not middle").
                // Using `.trailing` here previously was wrong: in RTL
                // it pushed Arabic text to the left side of the slot,
                // making it look misaligned next to the session text.
                .frame(width: ar ? 70 : 36, alignment: .leading)
                .lineLimit(1)

            // Title + focus stacked VERTICALLY (was previously a
            // single inline HStack with " · " glue, which made the
            // longer focus strings overrun and visually merge with
            // the title or even the day-name column on narrower
            // screens). Title gets its own line in heavy weight,
            // focus sits beneath it dimmed — same shape as React's
            // HomeTab session row.
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(HexTheme.font(size: 14, weight: .heavy, ar: ar))
                    .foregroundColor(isRest ? HexTheme.mute : HexTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let f = focus, !f.isEmpty {
                    Text(f)
                        .font(HexTheme.font(size: 11, weight: .regular, ar: ar))
                        .foregroundColor(HexTheme.dim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isRest {
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
            }
        }
        .padding(.horizontal, 14)
        // Row taller now — 14pt vertical (was 11) so the title +
        // focus stack breathes and the row reads as a comfortable
        // tap target rather than a tightly-packed list item.
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bgColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )

        return Group {
            if let session = session, !isRest {
                // Workout day — tap to stage + jump to Train.
                Button {
                    app.selectProgrammeSession(session, inWeek: weekNumber)
                    app.activeTab = .train
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                // Rest day (or no session at all) — static display.
                rowContent
            }
        }
    }

    private var statsGrid: some View {
        HStack(spacing: 8) {
            statCard(value: "\(totalSessions)",
                     label: ar ? "جلسات"    : "SESSIONS")
            statCard(value: "\(streakCount) 🔥",
                     label: ar ? "الإنجاز"   : "STREAK")
        }
    }

    // MARK: - Auto-mode chrome (streak row + Up Next card)

    /// True when the active programme is an auto-generated rotation
    /// (single week, sessions carry no day-key). React calls this
    /// `programmeMode === 'auto'`. Imported programmes return false
    /// and get the day-grid chrome instead.
    private var isAutoMode: Bool {
        guard let weeks = app.activeProgramme?.data?.weeks,
              weeks.count == 1,
              let firstWeek = weeks.first
        else { return false }
        // A flat session list with no day-keys is the auto-mode shape;
        // any session carrying a day slug means imported.
        return !firstWeek.sessions.contains(where: { !$0.day.isEmpty })
    }

    /// Five dots representing Mon-Fri training, lit when a session
    /// was logged on that weekday this calendar week. Mirrors
    /// HomeTab.jsx:252-269.
    private var autoStreakRow: some View {
        // Bool array indexed Mon → Fri (iOS weekday 2-6, JS getDay 1-5).
        let cal = Calendar.current
        // logicalToday honours the 2am rollover so the weekly streak
        // dots reflect the user's intended day of training.
        let today = AppState.logicalToday
        let weekStart = cal.date(
            from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        ) ?? today
        var dots: [Bool] = Array(repeating: false, count: 5)
        for session in app.workoutHistory {
            let d = cal.startOfDay(for: session.date)
            guard d >= weekStart else { continue }
            // iOS Calendar weekday: 1=Sun, 2=Mon, ..., 7=Sat.
            // Map Mon..Fri → 0..4.
            let wd = cal.component(.weekday, from: d)
            if wd >= 2 && wd <= 6 {
                dots[wd - 2] = true
            }
        }

        return HStack(spacing: 8) {
            Text(ar ? "الإنجاز" : "Streak")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(HexTheme.dim)

            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(dots[i] ? HexTheme.accent : HexTheme.surface2)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle().stroke(
                                dots[i] ? HexTheme.accent : HexTheme.border,
                                lineWidth: 1.5
                            )
                        )
                }
            }

            if streakCount > 0 {
                Text("\(streakCount) 🔥")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(HexTheme.accent)
            }
            Spacer()
        }
    }

    /// The session in the auto-rotation that comes RIGHT AFTER whatever
    /// the user just finished — i.e. `sessions[1]` from the staged
    /// programme. Returns nil when auto mode is off OR the rotation
    /// has fewer than two sessions (nothing to preview).
    private var upNextSession: ProgrammeSession? {
        guard isAutoMode,
              let sessions = app.activeProgramme?.data?.weeks.first?.sessions,
              sessions.count > 1
        else { return nil }
        // Find the index of the currently-staged session, default 0,
        // then return the session that comes AFTER it.
        let currentName = app.currentSession?.name
        let curIdx = sessions.firstIndex(where: { $0.name == currentName }) ?? 0
        let nextIdx = (curIdx + 1) % sessions.count
        return sessions[nextIdx]
    }

    /// UP NEXT preview card. Shows the next session's name + first 3
    /// exercises (bulleted). Mirrors HomeTab.jsx:295-310.
    private func upNextCard(session: ProgrammeSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ar ? "التالي" : "UP NEXT")
                .font(.system(size: 10, weight: .heavy))
                .kerning(ar ? 0 : 1.0)
                .foregroundColor(HexTheme.dim)
                .padding(.bottom, 8)

            Text(session.name)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(HexTheme.text)
                .padding(.bottom, 6)

            ForEach(Array(session.exercises.prefix(3).enumerated()),
                    id: \.offset) { _, ex in
                Text("· \(ex.name)")
                    .font(.system(size: 12))
                    .foregroundColor(HexTheme.dim)
                    .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Stats

    /// Total completed/in-progress sessions in history.
    private var totalSessions: Int {
        app.workoutHistory.count
    }

    /// Current streak — consecutive days (including today or yesterday)
    /// with at least one logged session. Mirrors the React implementation
    /// in src/components/HomeTab.jsx.
    private var streakCount: Int {
        let cal = Calendar.current
        let dayKeys: Set<Date> = Set(
            app.workoutHistory.map { cal.startOfDay(for: $0.date) }
        )
        guard !dayKeys.isEmpty else { return 0 }
        var streak = 0
        // Start the streak walk from logicalToday — a session logged
        // last night at 23:30 should keep the streak alive when the
        // user checks at 01:30, not break it because "today" hasn't
        // technically rolled over yet in the user's perception.
        var cursor = AppState.logicalToday
        // Allow the streak to start from "yesterday" if today wasn't logged
        // yet — matches React.
        if !dayKeys.contains(cursor) {
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            if !dayKeys.contains(cursor) { return 0 }
        }
        while dayKeys.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(HexTheme.text)
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .kerning(ar ? 0 : 0.6)
                .foregroundColor(HexTheme.mute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HexTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HexTheme.border, lineWidth: 1)
        )
    }

    private var programmeLink: some View {
        Button {
            showProgramme = true
        } label: {
            HStack {
                Text(ar ? "عرض البرنامج كاملاً" : "View full programme")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HexTheme.text)
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
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
}
