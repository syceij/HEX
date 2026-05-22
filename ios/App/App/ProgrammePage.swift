import SwiftUI

/// Full-screen programme view — port of src/components/ProgrammePage.jsx.
/// Distinct from ProgrammeModalView (the sheet summary): this one is the
/// editor surface — top bar with edits-count pill, weekly schedule grid
/// (auto mode) or week tabs + day overview (imported mode), and
/// expandable session cards with per-exercise rows.
///
/// This is the visual port; per-field inline editing + exercise swap
/// will be wired in a follow-up commit (along with ExercisePickerSheet).
struct ProgrammePage: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// Programme-day expansion state, keyed by `weekNumber_day` (auto uses
    /// week 1 always; imported uses the selected week's day).
    @State private var expanded: Set<String> = []
    /// Selected week tab in imported mode (defaults to week 1).
    @State private var importedTab: Int = 1
    /// Set when the user taps an exercise's swap chevron. Drives the
    /// ExercisePickerSheet via .sheet(item:).
    @State private var swapContext: SwapContext?
    /// Stable keys of fields the user has edited this session — drives
    /// the accent-coloured dashed underline + the "N edit(s)" pill in
    /// the top bar (mirrors React's `editedKeys` list on App state).
    @State private var editedKeys: Set<String> = []
    /// editKey of whichever exercise's "Custom" rest-timer input is open
    /// right now (only one at a time, like React's bottom-sheet pattern).
    @State private var customRestKey: String? = nil
    /// In-progress text for the open custom-rest input.
    @State private var customRestDraft: String = ""

    /// Identifies a single exercise slot in the active programme so the
    /// picker callback knows where to write the replacement.
    private struct SwapContext: Identifiable {
        let id = UUID()
        let weekIdx: Int
        let sessionIdx: Int
        let exerciseIdx: Int
        let currentName: String
    }

    /// Identifies the session that just tapped "+ Add exercise" — the
    /// picker callback appends to this session on selection. Separate
    /// from SwapContext because add has no source exerciseIdx.
    private struct AddContext: Identifiable {
        let id = UUID()
        let weekIdx: Int
        let sessionIdx: Int
    }

    /// Bound to the "+ Add exercise" picker sheet.
    @State private var addContext: AddContext?

    private var ar: Bool { app.language == "ar" }

    private var programmeData: ProgrammeData? {
        app.activeProgramme?.data
    }
    private var isImported: Bool {
        (programmeData?.weeks.count ?? 0) > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let data = programmeData, !data.weeks.isEmpty {
                        if isImported {
                            importedContent(data: data)
                        } else {
                            autoContent(week: data.weeks.first!)
                        }
                    } else {
                        emptyState
                    }
                    Spacer(minLength: 28)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .background(HexTheme.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(item: $swapContext) { ctx in
            ExercisePickerSheet(currentName: ctx.currentName) { picked in
                Task {
                    await app.swapExercise(
                        weekIdx: ctx.weekIdx,
                        sessionIdx: ctx.sessionIdx,
                        exerciseIdx: ctx.exerciseIdx,
                        replacement: picked
                    )
                }
            }
            .environmentObject(app)
            .presentationDetents([.fraction(0.82), .large])
            .presentationDragIndicator(.hidden)
        }
        // Add-exercise sheet — same picker UI, different callback.
        // Reusing ExercisePickerSheet lets users pick from the same
        // library they'd use for a swap, and the picker's "current
        // name" affordance just becomes irrelevant (empty string).
        .sheet(item: $addContext) { ctx in
            ExercisePickerSheet(currentName: "") { picked in
                Task {
                    await app.addExercise(
                        weekIdx: ctx.weekIdx,
                        sessionIdx: ctx.sessionIdx,
                        exercise: picked
                    )
                }
            }
            .environmentObject(app)
            .presentationDetents([.fraction(0.82), .large])
            .presentationDragIndicator(.hidden)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
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
                Text(isImported
                     ? (ar ? "برنامج مستورد" : "IMPORTED PROGRAMME")
                     : (ar ? "برنامجك" : "YOUR PROGRAMME"))
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(ar ? 0 : 0.9)
                    .foregroundColor(HexTheme.accent)
                Text(programmeData?.name ?? (ar ? "تلقائي" : "Auto-generated"))
                    .font(.system(size: 16, weight: .heavy))
                    .kerning(ar ? 0 : -0.4)
                    .foregroundColor(HexTheme.text)
                    .lineLimit(1)
            }
            Spacer()

            if !editedKeys.isEmpty {
                Text("\(editedKeys.count) " +
                     (ar
                      ? "تعديلات"
                      : (editedKeys.count == 1 ? "edit" : "edits")))
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(HexTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(HexTheme.accent.opacity(0.10))
                    )
                    .overlay(
                        Capsule().stroke(HexTheme.accent.opacity(0.30), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(HexTheme.surface)
        .overlay(
            Rectangle().fill(HexTheme.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 36))
                .foregroundColor(HexTheme.mute)
            Text(ar ? "لا يوجد برنامج بعد" : "No programme yet")
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(HexTheme.text)
            Text(ar
                 ? "ابنِ برنامجك أو استورد واحداً من شاشة الحساب."
                 : "Build a programme or import one from the Profile tab.")
                .font(.system(size: 13))
                .foregroundColor(HexTheme.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Auto mode

    @ViewBuilder
    private func autoContent(week: ProgrammeWeek) -> some View {
        let dayLetters = ar
            ? ["إ","ث","أ","خ","ج","س","ح"]
            : ["M","T","W","T","F","S","S"]

        // Schedule grid
        VStack(alignment: .leading, spacing: 10) {
            Text(ar ? "الجدول" : "SCHEDULE")
                .font(.system(size: 11, weight: .heavy))
                .kerning(ar ? 0 : 0.6)
                .foregroundColor(HexTheme.dim)

            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    let s = i < week.sessions.count ? week.sessions[i] : nil
                    let isTraining = s != nil
                    VStack(spacing: 4) {
                        Text(dayLetters[i])
                            .font(.system(size: 9))
                            .foregroundColor(HexTheme.mute)
                        Text(isTraining
                             ? String(s?.name.prefix(1) ?? "T")
                             : "—")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(isTraining ? HexTheme.accent : HexTheme.mute)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isTraining
                                          ? HexTheme.accent.opacity(0.12)
                                          : HexTheme.surface2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(isTraining
                                            ? HexTheme.accent.opacity(0.25)
                                            : HexTheme.border, lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(.bottom, 20)

        Text(ar
             ? "كل الجلسات — اضغط للتوسيع"
             : "ALL SESSIONS — TAP TO EXPAND & EDIT")
            .font(.system(size: 11, weight: .heavy))
            .kerning(ar ? 0 : 0.6)
            .foregroundColor(HexTheme.dim)
            .padding(.bottom, 12)

        VStack(spacing: 10) {
            ForEach(Array(week.sessions.enumerated()), id: \.offset) { idx, session in
                sessionCard(session: session,
                            keyPrefix: "auto_\(idx)",
                            isToday: session.name == app.currentSession?.name,
                            weekIdx: 0,
                            sessionIdx: idx)
            }

            // "+ Add training day" button. Shows only if at least one
            // weekday isn't already in the sessions list — otherwise
            // there's nothing meaningful to add.
            if !availableDays(in: week).isEmpty {
                addDayButton(weekIdx: 0, week: week)
            }
        }

        Text(ar
             ? "يدور البرنامج تلقائياً. تُحفظ التعديلات فوراً وتستمر بين الجلسات."
             : "Programme cycles automatically. Edits are saved instantly and persist across sessions.")
            .font(.system(size: 11))
            .foregroundColor(HexTheme.mute)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    // MARK: - Imported mode

    @ViewBuilder
    private func importedContent(data: ProgrammeData) -> some View {
        let weeks = data.weeks
        let activeWeek = weeks.first(where: { $0.weekNumber == importedTab }) ?? weeks.first!

        let activeWeekIdxForOverview = weeks.firstIndex(where: {
            $0.weekNumber == activeWeek.weekNumber
        }) ?? 0

        // Week tab strip with `●` current-week indicator (matches React
        // ProgrammePage.jsx:547-571).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(weeks, id: \.weekNumber) { w in
                    let active = w.weekNumber == importedTab
                    let isCurrent = w.weekNumber == app.currentWeek
                    Button {
                        withAnimation(.spring(response: 0.35)) {
                            importedTab = w.weekNumber
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(ar ? "أ\(arabicNumber(w.weekNumber))" : "W\(w.weekNumber)")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundColor(active ? .black : HexTheme.dim)
                            if isCurrent {
                                Circle()
                                    .fill(active ? .black : HexTheme.accent)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(active ? HexTheme.accent : HexTheme.surface2)
                        )
                        .overlay(
                            Capsule().stroke(active ? HexTheme.accent : HexTheme.border,
                                             lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)
        }
        .padding(.bottom, 10)

        // Block / week label pill — e.g. "Block 1 · base volume · week 1".
        // Only shown when the active week carries a `label` string.
        if let label = activeWeek.label, !label.isEmpty {
            Text(label)
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(HexTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(HexTheme.accent.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(HexTheme.accent.opacity(0.35), lineWidth: 1.2)
                )
                .padding(.bottom, 12)
        }

        // Day overview header
        Text((ar ? "الأسبوع " : "Week ") + "\(importedTab) — " +
             (ar ? "نظرة اليوم" : "DAY OVERVIEW"))
            .font(.system(size: 11, weight: .heavy))
            .kerning(ar ? 0 : 0.6)
            .foregroundColor(HexTheme.dim)
            .padding(.bottom, 6)

        // 7 day rows — each tappable to edit the session name/focus
        // (matches React's DAY OVERVIEW at ProgrammePage.jsx:584-622).
        VStack(spacing: 0) {
            ForEach(["mon","tue","wed","thu","fri","sat","sun"], id: \.self) { dayKey in
                dayOverviewRow(dayKey: dayKey,
                               weekIdx: activeWeekIdxForOverview,
                               week: activeWeek)
            }
        }
        .padding(.bottom, 16)

        // Session detail cards
        Text((ar ? "الجلسات — الأسبوع " : "SESSIONS — Week ") + "\(importedTab)")
            .font(.system(size: 11, weight: .heavy))
            .kerning(ar ? 0 : 0.6)
            .foregroundColor(HexTheme.dim)
            .padding(.bottom, 10)

        VStack(spacing: 10) {
            ForEach(Array(activeWeek.sessions.enumerated()), id: \.offset) { idx, session in
                sessionCard(session: session,
                            keyPrefix: "imp_w\(activeWeek.weekNumber)_\(session.day)",
                            isToday: session.name == app.currentSession?.name,
                            weekIdx: activeWeekIdxForOverview,
                            sessionIdx: idx)
            }

            // Add-day button for imported mode (per-week — the menu
            // adds the new training day to the currently visible week).
            if !availableDays(in: activeWeek).isEmpty {
                addDayButton(weekIdx: activeWeekIdxForOverview, week: activeWeek)
            }
        }

        Text(ar
             ? "تُحفظ التعديلات فوراً، والذكاء الاصطناعي يقرأ برنامجك الحالي — لا الاستيراد الأصلي."
             : "Edits save instantly and the AI reads your current programme — not the original import.")
            .font(.system(size: 11))
            .foregroundColor(HexTheme.mute)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
    }

    private func dayLabel(_ key: String) -> String {
        switch key {
        case "mon": return ar ? "اثنين"  : "Mon"
        case "tue": return ar ? "ثلاثاء"  : "Tue"
        case "wed": return ar ? "أربعاء"  : "Wed"
        case "thu": return ar ? "خميس"   : "Thu"
        case "fri": return ar ? "جمعة"    : "Fri"
        case "sat": return ar ? "سبت"     : "Sat"
        case "sun": return ar ? "أحد"     : "Sun"
        default:    return key
        }
    }

    /// One row of the DAY OVERVIEW grid. Renders the day key + session
    /// name (or "Rest") + focus subtitle. Name + focus are tappable
    /// `EditableField`s when the day is a real session (not rest), so
    /// edits made here surface in the session card below + on Home.
    @ViewBuilder
    private func dayOverviewRow(dayKey: String,
                                weekIdx: Int,
                                week: ProgrammeWeek) -> some View {
        let sessionIdx = week.sessions.firstIndex(where: { $0.day == dayKey })
        let s: ProgrammeSession? = sessionIdx.map { week.sessions[$0] }
        let isRest = s == nil || s?.isRest == true || (s?.name.isEmpty ?? true)

        HStack(alignment: .top, spacing: 10) {
            Text(dayLabel(dayKey))
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(isRest ? HexTheme.mute : HexTheme.accent)
                .frame(width: 50, alignment: .leading)
                .padding(.top, 2)

            if let s = s, let sIdx = sessionIdx, !isRest {
                VStack(alignment: .leading, spacing: 2) {
                    EditableField(
                        value: s.name,
                        editKey: sessionEditKey(weekIdx, sIdx, "name"),
                        editedKeys: $editedKeys,
                        kind: .text,
                        placeholder: ar ? "اسم الجلسة" : "Session name",
                        font: .system(size: 13, weight: .semibold),
                        foregroundColor: HexTheme.text,
                        onCommit: { saveSession(weekIdx, sIdx, .name, $0) }
                    )
                    EditableField(
                        value: s.focus ?? "",
                        editKey: sessionEditKey(weekIdx, sIdx, "focus"),
                        editedKeys: $editedKeys,
                        kind: .text,
                        placeholder: ar ? "أضف وصفاً…" : "Add focus…",
                        font: .system(size: 11),
                        foregroundColor: HexTheme.dim,
                        muteColor: HexTheme.mute,
                        onCommit: { saveSession(weekIdx, sIdx, .focus, $0) }
                    )
                }
                Spacer()
            } else {
                Text(ar ? "راحة" : "Rest")
                    .font(.system(size: 13))
                    .foregroundColor(HexTheme.mute)
                Spacer()
            }
        }
        .padding(.vertical, 10)
        .overlay(
            Rectangle().fill(HexTheme.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Session card

    private func sessionCard(session: ProgrammeSession,
                             keyPrefix: String,
                             isToday: Bool,
                             weekIdx: Int,
                             sessionIdx: Int) -> some View {
        let isExpanded = expanded.contains(keyPrefix) || isToday
        return VStack(spacing: 0) {
            // Header (tap to expand/collapse)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if expanded.contains(keyPrefix) {
                        expanded.remove(keyPrefix)
                    } else {
                        expanded.insert(keyPrefix)
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(String(session.name.prefix(1)))
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(isToday ? .black : HexTheme.dim)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isToday ? HexTheme.accent : HexTheme.surface)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(HexTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        Text(sessionSubtitle(session: session))
                            .font(.system(size: 11))
                            .foregroundColor(HexTheme.mute)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Day-management menu — three-dot button. Move, toggle
                    // rest, delete. Placed before the expand chevron so
                    // it's reachable without expanding the card first.
                    dayMenu(session: session, weekIdx: weekIdx, sessionIdx: sessionIdx)
                        .padding(.top, 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(HexTheme.mute)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)

            // Exercises (when expanded)
            if isExpanded {
                Divider().background(HexTheme.border)
                VStack(spacing: 0) {
                    Text(ar
                         ? "اضغط على أي حقل للتعديل"
                         : "TAP ANY FIELD TO EDIT")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(ar ? 0 : 0.5)
                        .foregroundColor(HexTheme.mute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)

                    ForEach(Array(session.exercises.enumerated()), id: \.offset) { exIdx, ex in
                        exerciseRow(ex,
                                    weekIdx: weekIdx,
                                    sessionIdx: sessionIdx,
                                    exerciseIdx: exIdx)
                            // Long-press anywhere on the exercise row
                            // surfaces a Delete option. Kept out of
                            // the visible UI so the row stays compact
                            // and the swap chevron is the discoverable
                            // affordance for the common case.
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task {
                                        await app.deleteExercise(
                                            weekIdx: weekIdx,
                                            sessionIdx: sessionIdx,
                                            exerciseIdx: exIdx
                                        )
                                    }
                                } label: {
                                    Label(
                                        ar ? "حذف التمرين" : "Delete exercise",
                                        systemImage: "trash"
                                    )
                                }
                            }
                    }

                    // "+ Add exercise" button. Tapping opens the same
                    // ExercisePickerSheet used for swaps, with no
                    // current-name pre-fill. The picker's selection
                    // appends a new exercise to this session via
                    // AppState.addExercise.
                    Button {
                        addContext = AddContext(
                            weekIdx: weekIdx,
                            sessionIdx: sessionIdx
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                            Text(ar ? "إضافة تمرين" : "Add exercise")
                                .font(.system(size: 13, weight: .heavy))
                            Spacer()
                        }
                        .foregroundColor(HexTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    HexTheme.accent.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 1.25, dash: [4, 3])
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HexTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isToday ? HexTheme.accent : HexTheme.border, lineWidth: 1.5)
        )
    }

    private func sessionSubtitle(session: ProgrammeSession) -> String {
        let n = session.exercises.count
        let minutes = n * 6
        if ar {
            return "\(n) تمارين · ~\(minutes) د"
        }
        return "\(n) exercises · ~\(minutes) min"
    }

    // MARK: - Exercise row

    private func exerciseRow(_ ex: Exercise,
                             weekIdx: Int,
                             sessionIdx: Int,
                             exerciseIdx: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name row — tapping anywhere on it opens the swap picker.
            Button {
                swapContext = SwapContext(
                    weekIdx: weekIdx,
                    sessionIdx: sessionIdx,
                    exerciseIdx: exerciseIdx,
                    currentName: ex.name
                )
            } label: {
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                        .lineLimit(1)
                        .underlineDashed()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(HexTheme.mute)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // Sets · Reps · Weight · RPE — each cell tap-to-edits inline.
            HStack(spacing: 14) {
                editableCell(label: ar ? "مج" : "Sets",
                             value: "\(ex.sets)",
                             kind: .number,
                             editKey: editKey(weekIdx, sessionIdx, exerciseIdx, "sets")) {
                    save(weekIdx, sessionIdx, exerciseIdx, .sets, $0)
                }

                editableCell(label: ar ? "عد" : "Reps",
                             value: ex.reps,
                             kind: .text,
                             editKey: editKey(weekIdx, sessionIdx, exerciseIdx, "reps")) {
                    save(weekIdx, sessionIdx, exerciseIdx, .reps, $0)
                }

                // Weight cell — always rendered now, regardless of the
                // exercise's tag. Bodyweight moves show "BW" with the
                // kg suffix hidden, so users can flip an exercise from
                // BW → loaded (by typing a number) or back to BW (by
                // clearing the field). Earlier builds gated this on
                // `if let w = ex.weight, w > 0`, which meant exercises
                // like Leg Press / Leg Extension imported with a
                // missing weight column had no way to set one — the
                // cell never appeared.
                let hasWeight = (ex.weight ?? 0) > 0
                editableCell(
                    label: ar ? "وزن" : "Weight",
                    value: hasWeight
                        ? formatWeight(ex.weight!)
                        : (ar ? "وزن الجسم" : "BW"),
                    kind: .number,
                    placeholder: ar ? "وزن الجسم" : "BW",
                    suffix: hasWeight ? "kg" : nil,
                    valueColor: hasWeight ? HexTheme.accent : HexTheme.mute,
                    editKey: editKey(weekIdx, sessionIdx, exerciseIdx, "weight")
                ) {
                    save(weekIdx, sessionIdx, exerciseIdx, .weight, $0)
                }

                editableCell(label: "RPE",
                             value: ex.rpe ?? "",
                             kind: .text,
                             placeholder: "—",
                             valueColor: HexTheme.dim,
                             editKey: editKey(weekIdx, sessionIdx, exerciseIdx, "rpe")) {
                    save(weekIdx, sessionIdx, exerciseIdx, .rpe, $0)
                }

                Spacer()
            }

            // Notes — tap to edit; placeholder when empty.
            EditableField(
                value: ex.notes ?? "",
                editKey: editKey(weekIdx, sessionIdx, exerciseIdx, "notes"),
                editedKeys: $editedKeys,
                kind: .text,
                placeholder: ar ? "أضف ملاحظات…" : "Add notes…",
                font: .system(size: 11).italic(),
                foregroundColor: HexTheme.mute,
                muteColor: HexTheme.mute,
                onCommit: { save(weekIdx, sessionIdx, exerciseIdx, .notes, $0) }
            )

            // Rest timer presets — full React-parity row.
            restTimerRow(ex: ex,
                         weekIdx: weekIdx,
                         sessionIdx: sessionIdx,
                         exerciseIdx: exerciseIdx)
                .padding(.top, 4)
        }
        .padding(.vertical, 10)
        .overlay(
            Rectangle().fill(HexTheme.border).frame(height: 1),
            alignment: .bottom
        )
    }

    /// A "label  value" cell that swaps to an inline EditableField on tap.
    /// Used for the four pills under each exercise (Sets · Reps · Weight · RPE).
    private func editableCell(label: String,
                              value: String,
                              kind: EditableField.Kind,
                              placeholder: String = "—",
                              suffix: String? = nil,
                              valueColor: Color = HexTheme.text,
                              editKey: String,
                              onCommit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(HexTheme.mute)
            EditableField(
                value: value,
                editKey: editKey,
                editedKeys: $editedKeys,
                kind: kind,
                placeholder: placeholder,
                suffix: suffix,
                font: .system(size: 13, weight: .heavy),
                foregroundColor: valueColor,
                onCommit: onCommit
            )
        }
    }

    /// Per-exercise rest-timer block: title + pill row + (when Custom is
    /// active or the current seconds aren't in the preset set) a small
    /// numeric TextField. Mirrors React's RestTimer.jsx + the inline
    /// renderer in ProgrammePage.jsx (lines 185-258).
    private func restTimerRow(ex: Exercise,
                              weekIdx: Int,
                              sessionIdx: Int,
                              exerciseIdx: Int) -> some View {
        let baseKey   = editKey(weekIdx, sessionIdx, exerciseIdx, "restTimer")
        let effective = RestTimerPresets.effectiveSeconds(for: ex)
        let activePreset = RestTimerPresets.preset(for: effective)
        let customOpen = customRestKey == baseKey ||
                         (activePreset == nil && effective > 0)

        return VStack(alignment: .leading, spacing: 7) {
            Text(ar ? "مؤقت الراحة" : "REST TIMER")
                .font(.system(size: 10, weight: .heavy))
                .kerning(ar ? 0 : 0.7)
                .foregroundColor(HexTheme.mute)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(RestTimerPresets.all) { preset in
                        let isActive = preset.isCustom
                            ? customOpen
                            : (preset.seconds == effective)
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if preset.isCustom {
                                if customRestKey == baseKey {
                                    customRestKey = nil
                                } else {
                                    customRestKey = baseKey
                                    customRestDraft = effective > 0 ? "\(effective)" : ""
                                }
                            } else {
                                customRestKey = nil
                                save(weekIdx, sessionIdx, exerciseIdx,
                                     .restTimer, "\(preset.seconds ?? 0)")
                                editedKeys.insert(baseKey)
                            }
                        } label: {
                            Text(ar ? preset.arabicLabel : preset.label)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundColor(isActive ? .black : HexTheme.dim)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(isActive
                                                   ? HexTheme.accent
                                                   : HexTheme.surface)
                                )
                                .overlay(
                                    Capsule().stroke(
                                        isActive ? HexTheme.accent : HexTheme.border,
                                        lineWidth: 1.5
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 2)
            }

            // Custom seconds input — visible when the user taps "Custom"
            // OR when the persisted value isn't one of the fixed presets.
            if customOpen {
                HStack(spacing: 8) {
                    TextField(ar ? "ثواني" : "seconds",
                              text: $customRestDraft)
                        .keyboardType(.numberPad)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(HexTheme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(HexTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(HexTheme.border, lineWidth: 1)
                        )
                        .frame(maxWidth: 120)
                        .onAppear {
                            if customRestDraft.isEmpty && effective > 0 {
                                customRestDraft = "\(effective)"
                            }
                        }

                    Button {
                        let trimmed = customRestDraft.trimmingCharacters(in: .whitespaces)
                        if let n = Int(trimmed), n >= 0 {
                            save(weekIdx, sessionIdx, exerciseIdx,
                                 .restTimer, "\(n)")
                            editedKeys.insert(baseKey)
                        }
                        customRestKey = nil
                    } label: {
                        Text(ar ? "حفظ" : "Save")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(HexTheme.accentFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(Int(customRestDraft.trimmingCharacters(in: .whitespaces)) == nil)
                }
                .padding(.top, 2)
            }
        }
    }

    /// Build a stable identifier for an exercise field — appears in
    /// `editedKeys` and drives the accent underline + edit dot.
    private func editKey(_ weekIdx: Int, _ sessionIdx: Int,
                         _ exerciseIdx: Int, _ field: String) -> String {
        "w\(weekIdx)_s\(sessionIdx)_e\(exerciseIdx)_\(field)"
    }

    /// Hand a save off to AppState in a detached Task so the UI thread
    /// doesn't block on the network round-trip.
    private func save(_ weekIdx: Int, _ sessionIdx: Int, _ exerciseIdx: Int,
                      _ field: AppState.ExerciseField,
                      _ value: String) {
        Task {
            await app.updateExerciseField(
                weekIdx: weekIdx,
                sessionIdx: sessionIdx,
                exerciseIdx: exerciseIdx,
                field: field,
                value: value
            )
        }
    }

    /// Session-header save (name / focus / block). Used by both the
    /// DAY OVERVIEW rows and the session-card header.
    private func saveSession(_ weekIdx: Int, _ sessionIdx: Int,
                             _ field: AppState.SessionField,
                             _ value: String) {
        Task {
            await app.updateSessionField(
                weekIdx: weekIdx,
                sessionIdx: sessionIdx,
                field: field,
                value: value
            )
        }
    }

    /// Stable identifier for a session header field (name/focus/block).
    private func sessionEditKey(_ weekIdx: Int, _ sessionIdx: Int,
                                _ field: String) -> String {
        "w\(weekIdx)_s\(sessionIdx)_\(field)"
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(w))
            : String(format: "%.1f", w)
    }

    private func arabicNumber(_ n: Int) -> String {
        // ASCII digit → Eastern Arabic numeral
        let map: [Character: Character] = [
            "0":"٠","1":"١","2":"٢","3":"٣","4":"٤",
            "5":"٥","6":"٦","7":"٧","8":"٨","9":"٩",
        ]
        return String(String(n).map { map[$0] ?? $0 })
    }

    // MARK: - Day management UI

    /// Mon→Sun ordering used to render menu items in calendar order
    /// (the underlying session array also keeps this order — see
    /// AppState.dayOrder). dayLabel(_:) already exists at line ~380
    /// — reused here for the menu rows.
    private static let weekdayKeys: [String] = ["mon","tue","wed","thu","fri","sat","sun"]

    /// Weekdays NOT currently in `week.sessions` — feeds the
    /// "Add training day" menu so the user can only pick empty slots.
    private func availableDays(in week: ProgrammeWeek) -> [String] {
        let taken = Set(week.sessions.map { $0.day.lowercased() })
        return ProgrammePage.weekdayKeys.filter { !taken.contains($0) }
    }

    /// Three-dot menu on each session card. Lets the user move the
    /// session to another weekday (swaps if occupied), toggle rest,
    /// or delete the day entirely. Held inside its own button so
    /// tapping the dots doesn't also trigger the expand/collapse on
    /// the outer card.
    @ViewBuilder
    private func dayMenu(session: ProgrammeSession,
                         weekIdx: Int,
                         sessionIdx: Int) -> some View {
        Menu {
            // Move to: every weekday OTHER than this session's current
            // day. Tapping an occupied day will swap the two sessions.
            Section(ar ? "نقل إلى" : "Move to") {
                ForEach(ProgrammePage.weekdayKeys, id: \.self) { key in
                    if key != session.day.lowercased() {
                        Button(dayLabel(key)) {
                            Task {
                                await app.setSessionDay(
                                    weekIdx: weekIdx,
                                    sessionIdx: sessionIdx,
                                    newDay: key
                                )
                            }
                        }
                    }
                }
            }

            // Convert rest ⇄ training.
            Button {
                Task {
                    await app.toggleSessionRest(
                        weekIdx: weekIdx,
                        sessionIdx: sessionIdx
                    )
                }
            } label: {
                if session.isRest {
                    Label(ar ? "تحويل إلى يوم تدريب" : "Convert to training day",
                          systemImage: "figure.strengthtraining.traditional")
                } else {
                    Label(ar ? "تحويل إلى يوم راحة" : "Convert to rest day",
                          systemImage: "moon.fill")
                }
            }

            // Delete entirely. Destructive role so iOS renders the row
            // in red and adds a slight haptic on confirm.
            Button(role: .destructive) {
                Task {
                    await app.deleteSession(
                        weekIdx: weekIdx,
                        sessionIdx: sessionIdx
                    )
                }
            } label: {
                Label(ar ? "حذف اليوم" : "Delete day",
                      systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .heavy))
                .foregroundColor(HexTheme.mute)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "+ Add training day" CTA at the bottom of the sessions list.
    /// Wraps a Menu of available weekdays — tapping one creates an
    /// empty session for that day (user can then expand it to add
    /// exercises via the existing swap flow).
    @ViewBuilder
    private func addDayButton(weekIdx: Int, week: ProgrammeWeek) -> some View {
        Menu {
            ForEach(availableDays(in: week), id: \.self) { key in
                Button(dayLabel(key)) {
                    Task {
                        await app.addSession(weekIdx: weekIdx, day: key)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(ar ? "إضافة يوم تدريب" : "Add training day")
                    .font(.system(size: 14, weight: .heavy))
                Spacer()
            }
            .foregroundColor(HexTheme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(HexTheme.accent.opacity(0.45),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
        }
    }
}

// MARK: - Dashed underline modifier

/// Renders a subtle dashed underline beneath any view — matches the React
/// "tap to edit" affordance. Visual only; the page is read-only for now.
private struct DashedUnderline: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.top, 1),
                alignment: .bottom
            )
    }
}
private extension View {
    func underlineDashed() -> some View { modifier(DashedUnderline()) }
}
