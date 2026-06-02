import SwiftUI
import PhotosUI
import Supabase
import UserNotifications

/// Profile tab — visual port of src/components/ProfileTab.jsx.
/// Avatar header with name + username + camera button, then Account /
/// Preferences / Privacy sections with rows, then sign-out CTA.
/// Also exposes a "Talk to PT" link to PTChatView (in React, PT was
/// surfaced via the account view, not a top-level tab).
struct AccountView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var liveActivitiesEnabled = LiveActivityService.shared.isEnabled
    @State private var showSignOutConfirm    = false
    @State private var showDeleteConfirm     = false
    @State private var showResetConfirm      = false
    @State private var resetting             = false
    @State private var deleting              = false

    // Avatar picker state
    @State private var avatarPick: PhotosPickerItem? = nil
    @State private var uploadingAvatar = false

    // Name edit state — the pencil on the Name row opens this sheet.
    @State private var editingName = false
    @State private var nameDraft   = ""

    // Notification toggles — loaded on view appear, written back to
    // profiles.notification_prefs on each flip. Missing keys are
    // treated as "ON" by the Edge Function, so the toggles default
    // to the on position for a brand-new user.
    @State private var notifPrefs: [String: Bool] = [:]

    // System notification permission status — drives the "Enable
    // Notifications" banner. .notDetermined until we check on appear.
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var sendingTestPush = false

    private var ar: Bool { app.language == "ar" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Avatar header ────────────────────────────────
                avatarHeader.padding(.bottom, 24)

                // ── Account section ──────────────────────────────
                sectionTitle(ar ? "الحساب" : "ACCOUNT").padding(.bottom, 10)
                accountSection.padding(.bottom, 24)

                // ── Preferences section ──────────────────────────
                sectionTitle(ar ? "التفضيلات" : "PREFERENCES").padding(.bottom, 10)
                preferencesSection.padding(.bottom, 24)

                // ── Notifications section ────────────────────────
                sectionTitle(ar ? "الإشعارات" : "NOTIFICATIONS").padding(.bottom, 10)
                notificationsSection.padding(.bottom, 24)

                // ── PT shortcut ──────────────────────────────────
                sectionTitle(ar ? "المدرب" : "COACHING").padding(.bottom, 10)
                ptShortcut.padding(.bottom, 24)

                // ── Programme actions ────────────────────────────
                sectionTitle(ar ? "البرنامج" : "PROGRAMME").padding(.bottom, 10)
                VStack(spacing: 10) {
                    buildProgrammeRow
                    manualBuilderRow
                    importProgrammeRow
                    if app.activeProgramme != nil {
                        editProgrammeRow
                    }
                    calendarRow
                }
                .padding(.bottom, 24)

                // ── Sign out / delete ────────────────────────────
                dangerSection

                Spacer(minLength: 100) // room for floating tab bar
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        .background(HexTheme.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            // Load notification toggles from the DB on first appear.
            // If the column is unset / null, we get an empty dict —
            // which the toggle bindings treat as "all on" (default).
            if let prefs = try? await SupabaseManager.shared.fetchNotificationPrefs() {
                notifPrefs = prefs
            }
            notifAuthStatus = await PushService.shared.authorizationStatus()
        }
        // Re-check permission whenever the app foregrounds — the user
        // may have just toggled it in iOS Settings via the deep-link.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { notifAuthStatus = await PushService.shared.authorizationStatus() }
            }
        }
        .confirmationDialog(ar ? "تسجيل الخروج؟" : "Sign out?",
                            isPresented: $showSignOutConfirm,
                            titleVisibility: .visible) {
            Button(ar ? "تسجيل الخروج" : "Sign out", role: .destructive) {
                Task { await app.signOut() }
            }
            Button(ar ? "إلغاء" : "Cancel", role: .cancel) {}
        }
    }

    // MARK: - Avatar header

    private var avatarHeader: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let url = app.currentProfile?.avatarURL {
                        // Data URLs (the React-compatible format we
                        // write from handleAvatarPick) decode locally;
                        // http URLs go through AsyncImage as before.
                        if let dataImg = decodeDataURLImage(url) {
                            Image(uiImage: dataImg)
                                .resizable()
                                .scaledToFill()
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
                            .clipShape(Circle())
                        } else {
                            avatarFallback
                        }
                    } else {
                        avatarFallback
                    }
                }
                .frame(width: 72, height: 72)
                .overlay(
                    Circle().stroke(HexTheme.border, lineWidth: 2)
                )

                // Camera button bottom-right — opens PhotosPicker, uploads to
                // Supabase Storage, updates profile.avatar_url.
                PhotosPicker(selection: $avatarPick,
                             matching: .images,
                             photoLibrary: .shared()) {
                    Image(systemName: uploadingAvatar ? "arrow.triangle.2.circlepath" : "camera.fill")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.black)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(HexTheme.accentFill))
                        .overlay(
                            Circle().stroke(HexTheme.bg, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .onChange(of: avatarPick) { newItem in
                    guard let item = newItem else { return }
                    Task { await handleAvatarPick(item) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.currentProfile?.name ?? (ar ? "رياضي" : "Athlete"))
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                if let u = app.currentProfile?.username {
                    Text("@\(u)")
                        .font(.system(size: 13))
                        .foregroundColor(HexTheme.dim)
                }
            }
            Spacer()
        }
    }

    // MARK: - Account section

    private var accountSection: some View {
        VStack(spacing: 0) {
            // Name row is tap-to-edit (pencil now actually does something).
            // Username and email stay read-only — username is signup-only
            // per the project rule; email is managed by Supabase auth.
            Button {
                nameDraft = app.currentProfile?.name ?? ""
                editingName = true
            } label: {
                infoRow(icon: "person",
                        iconAccent: true,
                        label: ar ? "الاسم" : "Name",
                        value: app.currentProfile?.name,
                        last: false)
            }
            .buttonStyle(.plain)

            divider
            infoRow(icon: "at",
                    iconAccent: false,
                    label: ar ? "اسم المستخدم" : "Username",
                    value: app.currentProfile?.username.map { "@\($0)" },
                    last: false)
            divider
            infoRow(icon: "envelope",
                    iconAccent: false,
                    label: ar ? "البريد الإلكتروني" : "Email",
                    value: app.currentProfile?.email,
                    last: true)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HexTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HexTheme.border, lineWidth: 1)
        )
        .sheet(isPresented: $editingName) {
            NameEditSheet(
                initial: nameDraft,
                onSave: { newName in
                    Task { await app.updateOwnName(newName) }
                    editingName = false
                },
                onCancel: { editingName = false }
            )
            .environmentObject(app)
            .presentationDetents([.height(220)])
        }
    }

    // MARK: - Notifications section

    /// 5 toggles for the notification categories. Each writes back to
    /// profiles.notification_prefs immediately on flip — no save button.
    /// Missing keys default to "ON" (matches the Edge Function's logic).
    private var notificationsSection: some View {
        VStack(spacing: 0) {
            // Permission banner — shown unless already authorized. This
            // is the entry point that actually registers a device token
            // (the previous build only asked after finishing a session,
            // which left most users with no token at all).
            if notifAuthStatus != .authorized {
                permissionBanner
                Divider().background(HexTheme.border).padding(.leading, 64)
            } else {
                // Authorized — offer a one-tap self-test so the user can
                // confirm the whole pipe works end to end.
                testPushRow
                Divider().background(HexTheme.border).padding(.leading, 64)
            }
            notificationToggleRow(
                key:      .friends,
                icon:     "person.2.fill",
                title:    ar ? "طلبات الأصدقاء والقبول" : "Friend requests & accepts",
                subtitle: ar
                    ? "عندما يرسل شخص طلب أو يقبل طلبك"
                    : "When someone sends or accepts a request"
            )
            Divider().background(HexTheme.border).padding(.leading, 64)
            notificationToggleRow(
                key:      .leagues,
                icon:     "trophy.fill",
                title:    ar ? "دعوات الدوريات" : "League invites",
                subtitle: ar
                    ? "عندما يدعوك صديق لدوريه"
                    : "When a friend invites you to their league"
            )
            Divider().background(HexTheme.border).padding(.leading, 64)
            notificationToggleRow(
                key:      .friend_sessions,
                icon:     "figure.strengthtraining.traditional",
                title:    ar ? "جلسات الأصدقاء" : "Friend sessions",
                subtitle: ar
                    ? "عندما يكمل صديق جلسة تدريب"
                    : "When a bro completes a workout"
            )
            Divider().background(HexTheme.border).padding(.leading, 64)
            notificationToggleRow(
                key:      .friend_badges,
                icon:     "star.fill",
                title:    ar ? "شارات الأصدقاء" : "Friend badges",
                subtitle: ar
                    ? "عندما يحصل صديق على شارة جديدة"
                    : "When a bro earns a new badge"
            )
            Divider().background(HexTheme.border).padding(.leading, 64)
            notificationToggleRow(
                key:      .monthly_leaderboard,
                icon:     "chart.bar.fill",
                title:    ar ? "نتيجة الشهر" : "Monthly result",
                subtitle: ar
                    ? "ترتيبك في نهاية كل شهر"
                    : "Your rank at the end of each month",
                isLast:   true
            )
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

    /// Single toggle row — icon box + title/subtitle + Toggle. The
    /// binding writes through to Supabase on flip; UI updates
    /// optimistically so toggles feel responsive even on slow networks.
    @ViewBuilder
    private func notificationToggleRow(
        key: SupabaseManager.NotificationPrefKey,
        icon: String,
        title: String,
        subtitle: String,
        isLast: Bool = false
    ) -> some View {
        let isOn = Binding<Bool>(
            // Missing key = ON. Explicit false = OFF.
            get: { notifPrefs[key.rawValue] != false },
            set: { newValue in
                notifPrefs[key.rawValue] = newValue
                Task {
                    try? await SupabaseManager.shared.setNotificationPref(key, enabled: newValue)
                }
            }
        )
        HStack(spacing: 14) {
            iconBox(name: icon, accent: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HexTheme.text)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(HexTheme.mute)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(HexTheme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// "Enable Notifications" call-to-action. Tapping requests the
    /// system permission (if never asked) which registers a device
    /// token, or — if the user previously denied — deep-links to iOS
    /// Settings → HEX so they can flip it on. Either way the scenePhase
    /// .active handler re-checks status when they come back.
    private var permissionBanner: some View {
        Button {
            Task { @MainActor in
                let result = await PushService.shared.enableNotifications()
                notifAuthStatus = result
                if result == .denied {
                    // Previously denied — can't re-prompt; open Settings.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        await UIApplication.shared.open(url)
                    }
                } else if result == .authorized {
                    app.toast = ar ? "تم تفعيل الإشعارات ✓" : "Notifications enabled ✓"
                }
            }
        } label: {
            HStack(spacing: 14) {
                iconBox(name: "bell.badge.fill", accent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "تفعيل الإشعارات" : "Enable notifications")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(HexTheme.accent)
                    Text(notifAuthStatus == .denied
                         ? (ar ? "مرفوضة — اضغط لفتح الإعدادات" : "Denied — tap to open Settings")
                         : (ar ? "لتصلك طلبات الأصدقاء والتذكيرات" : "For friend requests & reminders"))
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Self-test row — shown once notifications are authorized. Fires a
    /// push to the current user via the send-push Edge Function so they
    /// can confirm delivery without needing a second account.
    private var testPushRow: some View {
        Button {
            guard let uid = app.currentProfile?.id else { return }
            sendingTestPush = true
            Task { @MainActor in
                await SupabaseManager.shared.sendPush(
                    toUserIds: [uid],
                    category:  "friend_request",   // any always-on category
                    title:     ar ? "HEX يعمل ✓" : "HEX works ✓",
                    body:      ar
                        ? "إشعارات HEX مفعّلة بنجاح."
                        : "Your HEX notifications are working."
                )
                sendingTestPush = false
                app.toast = ar
                    ? "أُرسل إشعار تجريبي — اقفل الشاشة لرؤيته"
                    : "Test sent — lock your screen to see it"
            }
        } label: {
            HStack(spacing: 14) {
                iconBox(name: "paperplane.fill", accent: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "إرسال إشعار تجريبي" : "Send a test notification")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                    Text(ar ? "للتأكد أن الإشعارات تصلك" : "Confirm delivery works")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                }
                Spacer()
                if sendingTestPush {
                    ProgressView().scaleEffect(0.7).tint(HexTheme.mute)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sendingTestPush)
    }

    // MARK: - Preferences section

    private var preferencesSection: some View {
        VStack(spacing: 0) {
            // Language row
            HStack(spacing: 14) {
                iconBox(name: "globe", accent: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "اللغة" : "Language")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                    Text(ar ? "العربية" : "English")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                }
                Spacer()
                // Intercept the picker write so the choice is persisted to
                // `profiles.language` instead of staying in-memory only. The
                // binding mirrors the AppState publish so the UI flips on tap.
                Picker("", selection: Binding(
                    get: { app.language },
                    set: { newLang in Task { await app.setLanguage(newLang) } }
                )) {
                    Text("EN").tag("en")
                    Text("AR").tag("ar")
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            divider

            // Accent colour swatches
            accentColorRow

            divider

            // Accent material picker (matte / glossy / metal / neon)
            accentMaterialRow

            divider

            // Live activities toggle
            Toggle(isOn: $liveActivitiesEnabled) {
                HStack(spacing: 14) {
                    iconBox(name: "bolt", accent: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ar ? "الأنشطة المباشرة" : "Live Activities")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(HexTheme.text)
                        Text(ar
                             ? "اعرض جلستك على شاشة القفل"
                             : "Show your session on the lock screen")
                            .font(.system(size: 11))
                            .foregroundColor(HexTheme.mute)
                    }
                }
            }
            .tint(HexTheme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

    /// Five-swatch picker for the app's signature accent colour. Tapping
    /// a circle updates `AppState.accentChoice` which:
    ///   • persists the raw value to App Group UserDefaults (so the
    ///     WorkoutWidget extension picks it up on the next LA render);
    ///   • re-publishes, forcing every view observing AppState to
    ///     re-evaluate its body and pull the new `HexTheme.accent`;
    ///   • pushes a no-op `Activity.update` so the Lock Screen card
    ///     recolours immediately rather than waiting for a set toggle.
    private var accentColorRow: some View {
        // Layout switched from a single-line HStack to a top-aligned
        // HStack with a wrapping grid for the swatches. With 8
        // colours, the old single-line approach forced the swatches
        // off the right edge of the screen and dragged the whole
        // settings card into a horizontal overflow — visible as the
        // weirdly-clipped row in the user's screenshot.
        //
        // LazyVGrid with `.adaptive(minimum: 30)` lets SwiftUI fit
        // as many 30pt swatches per row as the available width
        // allows, then wraps the rest to the next row. Works at any
        // device width without hard-coding a column count.
        HStack(alignment: .top, spacing: 14) {
            iconBox(name: "paintpalette.fill", accent: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(ar ? "اللون المميز" : "Accent Color")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HexTheme.text)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 38, maximum: 44),
                                       spacing: 10,
                                       alignment: .leading)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(AccentChoice.allCases) { choice in
                        accentSwatch(choice)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func accentSwatch(_ choice: AccentChoice) -> some View {
        let selected = app.accentChoice == choice.rawValue
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            app.setAccentChoice(choice)
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hexString: choice.hex))
                    .frame(width: 28, height: 28)
                Circle()
                    .stroke(HexTheme.text, lineWidth: selected ? 2.5 : 0)
                    .frame(width: 28, height: 28)
                // Subtle white ring for the lighter shades that would
                // otherwise vanish against the surface.
                Circle()
                    .stroke(HexTheme.border, lineWidth: selected ? 0 : 1)
                    .frame(width: 28, height: 28)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(swatchCheckmarkColor(choice))
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(choice.label))
    }

    /// Pick the checkmark contrast colour for each swatch so the
    /// tick is always readable. Light backgrounds (lime / cream /
    /// electric / gold) get a black mark; darker / more saturated
    /// backgrounds (magenta / orange / crimson / royal) get white.
    private func swatchCheckmarkColor(_ choice: AccentChoice) -> Color {
        switch choice {
        case .lime, .cream, .electric, .gold:        return .black
        case .magenta, .orange, .crimson, .royal:    return .white
        }
    }

    /// Four-option material picker — matte / glossy / metal / neon —
    /// each rendered as a small rounded tile previewing the same
    /// material the user would see applied to set buttons, the
    /// primary CTA, weight pills, etc. The tile uses the CURRENT
    /// `HexTheme.accent` colour so flipping the colour swatch above
    /// automatically updates the material previews too.
    private var accentMaterialRow: some View {
        HStack(spacing: 14) {
            iconBox(name: "sparkles", accent: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(ar ? "ملمس اللون" : "Accent Material")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HexTheme.text)
                HStack(spacing: 8) {
                    ForEach(AccentMaterial.allCases) { material in
                        materialTile(material)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func materialTile(_ material: AccentMaterial) -> some View {
        let selected = app.accentMaterial == material.rawValue
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            app.setAccentMaterial(material)
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(previewFill(for: material))
                    .frame(width: 44, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(selected ? HexTheme.text : HexTheme.border,
                                    lineWidth: selected ? 2 : 1)
                    )
                Text(material.label)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(selected ? HexTheme.text : HexTheme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(material.label))
    }

    /// Build the same gradient the chosen material renders elsewhere,
    /// scoped to the small preview tile so the user can see at a
    /// glance what each material looks like before committing.
    private func previewFill(for material: AccentMaterial) -> AnyShapeStyle {
        let base = HexTheme.accent
        switch material {
        case .matte:
            return AnyShapeStyle(base)
        case .glossy:
            return AnyShapeStyle(LinearGradient(
                colors: [base.blendWhite(0.40), base, base.blendBlack(0.15)],
                startPoint: .top, endPoint: .bottom
            ))
        case .metal:
            return AnyShapeStyle(LinearGradient(
                colors: [
                    base.blendBlack(0.18), base.blendWhite(0.30),
                    base.blendBlack(0.25), base.blendWhite(0.15),
                    base.blendBlack(0.10)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
    }

    // MARK: - PT shortcut

    private var ptShortcut: some View {
        NavigationLink {
            PTChatView()
        } label: {
            HStack(spacing: 14) {
                iconBox(name: "message.fill", accent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "اسأل المدرب" : "Ask PT")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                    Text(ar
                         ? "تدريب ذكي · تعديلات البرنامج"
                         : "AI coaching · programme adjustments")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                }
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
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
        .buttonStyle(.plain)
    }

    // MARK: - Build programme shortcut (onboarding)

    private var buildProgrammeRow: some View {
        NavigationLink {
            OnboardingView { profile in
                // Generate the starter programme via ProgrammeBuilder (port of
                // src/lib/programme.js), persist it, and mark it the active
                // programme. Mirrors enterApp() in src/App.jsx.
                Task { await app.enterApp(profile: profile,
                                          weights: profile.startingWeights) }
            }
        } label: {
            HStack(spacing: 14) {
                iconBox(name: "sparkles", accent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "ابنِ برنامجي" : "Build my programme")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                    Text(ar
                         ? "٧ خطوات · مولّد تلقائياً"
                         : "7-step setup · auto-generated")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                }
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
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
        .buttonStyle(.plain)
    }

    // MARK: - Manual builder shortcut

    private var manualBuilderRow: some View {
        NavigationLink {
            ManualProgrammeBuilder()
                .environmentObject(app)
        } label: {
            HStack(spacing: 14) {
                iconBox(name: "pencil.line", accent: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "بناء يدوي" : "Build manually")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                    Text(ar
                         ? "٦ خطوات · قابل للتخصيص"
                         : "6-step wizard · fully customisable")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                }
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
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
        .buttonStyle(.plain)
    }

    // MARK: - Edit programme shortcut

    private var editProgrammeRow: some View {
        NavigationLink {
            ProgrammePage()
                .environmentObject(app)
        } label: {
            HStack(spacing: 14) {
                iconBox(name: "list.bullet.rectangle", accent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "تعديل برنامجك" : "Edit programme")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                    Text(ar
                         ? "اعرض وعدّل كل الجلسات"
                         : "View and edit every session")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                }
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
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
        .buttonStyle(.plain)
    }

    // MARK: - Calendar shortcut

    private var calendarRow: some View {
        NavigationLink {
            CalendarView()
        } label: {
            HStack(spacing: 14) {
                iconBox(name: "calendar", accent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "تقويم التمارين" : "Workout calendar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                    Text(ar
                         ? "اعرض شهرك في لمحة"
                         : "See your month at a glance")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                }
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
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
        .buttonStyle(.plain)
    }

    // MARK: - Import programme shortcut

    private var importProgrammeRow: some View {
        NavigationLink {
            ImportView()
        } label: {
            HStack(spacing: 14) {
                iconBox(name: "tray.and.arrow.down.fill", accent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ar ? "استيراد برنامج" : "Import a programme")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(HexTheme.text)
                    Text(ar
                         ? "الصق JSON · دعم متعدد الأسابيع"
                         : "Paste JSON · multi-week support")
                        .font(.system(size: 11))
                        .foregroundColor(HexTheme.mute)
                }
                Spacer()
                Image(systemName: ar ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
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
        .buttonStyle(.plain)
    }

    // MARK: - Danger zone

    private var dangerSection: some View {
        VStack(spacing: 10) {
            // Sign out
            dangerButton(
                icon: "rectangle.portrait.and.arrow.right",
                title: ar ? "تسجيل الخروج" : "Sign out",
                loading: false
            ) { showSignOutConfirm = true }

            // Reset all data
            dangerButton(
                icon: "arrow.counterclockwise",
                title: resetting
                    ? (ar ? "جارٍ إعادة التعيين…" : "Resetting…")
                    : (ar ? "إعادة تعيين كل البيانات" : "Reset all data"),
                loading: resetting
            ) { showResetConfirm = true }

            // Delete account
            dangerButton(
                icon: "trash",
                title: deleting
                    ? (ar ? "جارٍ الحذف…" : "Deleting…")
                    : (ar ? "حذف الحساب" : "Delete account"),
                loading: deleting,
                stronger: true
            ) { showDeleteConfirm = true }
        }
        .confirmationDialog(
            ar ? "إعادة تعيين كل البيانات؟" : "Reset all data?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(ar ? "نعم، احذف كل شيء" : "Yes, wipe everything",
                   role: .destructive) {
                Task { await runReset() }
            }
            Button(ar ? "إلغاء" : "Cancel", role: .cancel) {}
        } message: {
            Text(ar
                 ? "سيتم حذف برنامجك وكل جلساتك ومجموعاتك وأوزانك. لا يمكن التراجع."
                 : "Deletes your programme, all sessions, sets, weights, friends, and activity. Cannot be undone.")
        }
        .confirmationDialog(
            ar ? "حذف الحساب؟" : "Delete account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(ar ? "نعم، احذف حسابي" : "Yes, delete my account",
                   role: .destructive) {
                Task { await runDelete() }
            }
            Button(ar ? "إلغاء" : "Cancel", role: .cancel) {}
        } message: {
            Text(ar
                 ? "سيتم حذف ملفك الشخصي وكل بياناتك وسيتم تسجيل خروجك. للحذف النهائي للحساب من خوادمنا، راسل الدعم."
                 : "Deletes your profile + all data and signs you out. For full removal from our servers, contact support after.")
        }
    }

    @ViewBuilder
    private func dangerButton(
        icon: String,
        title: String,
        loading: Bool,
        stronger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if loading {
                    ProgressView().tint(HexTheme.danger).scaleEffect(0.75)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .heavy))
                }
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
            }
            .foregroundColor(HexTheme.danger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(HexTheme.danger.opacity(stronger ? 0.16 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(HexTheme.danger.opacity(stronger ? 0.45 : 0.30),
                            lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    @MainActor
    private func runReset() async {
        resetting = true
        defer { resetting = false }
        do {
            try await SupabaseManager.shared.resetUserData()
            // Refresh in-memory state so the UI reflects the wipe.
            app.activeProgramme = nil
            app.currentSession = nil
            app.workoutHistory = []
            app.friends = []
            app.pendingRequests = []
            app.activityFeed = []
            app.leaderboard = []
            app.workingWeights = [:]
            app.customExercises = []
            app.toast = ar ? "تم مسح بياناتك ✓" : "All data wiped ✓"
        } catch {
            print("[AccountView] resetUserData failed:", error)
            app.toast = ar ? "تعذّر مسح البيانات" : "Couldn't reset data"
        }
    }

    @MainActor
    private func runDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await SupabaseManager.shared.deleteOwnAccount()
            // signOut inside deleteOwnAccount already cleared the session;
            // mirror it in AppState so ContentView swings back to login.
            app.currentProfile = nil
            app.activeProgramme = nil
            app.currentSession = nil
            app.workoutHistory = []
            app.friends = []
            app.pendingRequests = []
            app.activityFeed = []
            app.leaderboard = []
            app.workingWeights = [:]
            app.customExercises = []
            app.authPhase = .signedOut
            app.toast = ar ? "تم حذف الحساب" : "Account deleted"
        } catch {
            print("[AccountView] deleteOwnAccount failed:", error)
            app.toast = ar ? "تعذّر حذف الحساب" : "Couldn't delete account"
        }
    }

    // MARK: - Row helpers

    private var divider: some View {
        Rectangle()
            .fill(HexTheme.border)
            .frame(height: 1)
            .padding(.leading, 60)
    }

    private func iconBox(name: String, accent: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent ? HexTheme.accent.opacity(0.10) : HexTheme.surface)
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(accent ? HexTheme.accent : HexTheme.dim)
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private func infoRow(icon: String,
                         iconAccent: Bool,
                         label: String,
                         value: String?,
                         last: Bool) -> some View {
        HStack(spacing: 14) {
            iconBox(name: icon, accent: iconAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(HexTheme.mute)
                Text(value ?? "—")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(value == nil ? HexTheme.mute : HexTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(HexTheme.mute)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .kerning(ar ? 0 : 0.8)
            .foregroundColor(HexTheme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Initial

    private var initial: String {
        let s = app.currentProfile?.name ?? app.currentProfile?.username ?? "?"
        return String(s.prefix(1)).uppercased()
    }

    // MARK: - Avatar fallback (initial on tinted circle)

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(HexTheme.accent.opacity(0.12))
            Text(initial)
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(HexTheme.accent)
        }
    }

    // MARK: - Avatar upload

    /// Read the picked photo, downscale to ≤ 1024px, upload as a new file
    /// in the `avatars` Supabase Storage bucket, then update
    /// `profile.avatar_url` and refresh the in-memory profile.
    @MainActor
    /// Pick + persist an avatar, matching React's exact pipeline so the
    /// web and iOS clients are 1:1 interoperable.
    ///
    /// React (src/components/ProfileTab.jsx:13-35):
    ///   • scale = min(220/w, 220/h, 1) — never upscales
    ///   • circular clip via canvas.arc + ctx.clip()
    ///   • canvas.toDataURL('image/jpeg', 0.80)
    ///   • result stored DIRECTLY in profiles.avatar_url as a
    ///     "data:image/jpeg;base64,…" string. No Supabase Storage.
    ///
    /// Previously the iOS path uploaded to a `avatars` Storage bucket
    /// that was never set up server-side — explained why uploads kept
    /// failing while the React app "just worked." Matching React's
    /// approach means zero Supabase config to maintain and both
    /// platforms see each other's avatars immediately.
    private func handleAvatarPick(_ item: PhotosPickerItem) async {
        guard let uid = SupabaseManager.shared.currentUser?.id else { return }
        uploadingAvatar = true
        defer { uploadingAvatar = false }

        do {
            // 1) Load raw image data
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: raw) else {
                app.toast = ar ? "تعذّر قراءة الصورة" : "Couldn't read image"
                return
            }

            // 2) Downscale to ≤ 220px on longest side AND circle-crop.
            //    Matches React's compressImage scale + clip step.
            let scaled = scaleAndCircleCrop(img, maxPx: 220)

            // 3) JPEG @ 0.80 quality (mirrors canvas.toDataURL second arg)
            guard let jpeg = scaled.jpegData(compressionQuality: 0.80) else {
                app.toast = ar ? "تعذّر ضغط الصورة" : "Couldn't compress image"
                return
            }

            // 4) Build the data URL string the way browsers do for
            //    canvas.toDataURL — "data:image/jpeg;base64,<bytes>".
            //    A few KB per profile row at 220×220 / 0.80, which is
            //    what React has been doing all along.
            let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"

            // 5) Persist on the profile row + refresh local state.
            //    No Storage call, no bucket needed.
            var profile = app.currentProfile ?? Profile(
                id: uid,
                name: nil, username: nil, email: nil, language: nil,
                trackedLifts: nil, trackedMuscles: nil,
                avatarURL: nil, createdAt: nil
            )
            profile.avatarURL = dataURL
            try await SupabaseManager.shared.upsertOwnProfile(profile)
            await app.loadOwnProfile()
            app.toast = ar ? "تم تحديث الصورة ✓" : "Avatar updated ✓"
        } catch {
            print("[AccountView] avatar save failed:", error)
            app.toast = ar ? "تعذّر حفظ الصورة" : "Photo upload failed"
        }
        avatarPick = nil
    }

    /// Scale to ≤ maxPx on the longest side AND apply a circular clip
    /// mask. Mirrors React's canvas pipeline (scale → ctx.arc → ctx.clip
    /// → drawImage). UIImage doesn't expose canvas-style clipping
    /// directly, but `UIBezierPath(ovalIn:).addClip()` inside a graphics
    /// context gives the same effect: pixels outside the circle never
    /// get drawn, so the JPEG encoder leaves them transparent-on-black
    /// which renders as a clean circle when displayed.
    private func scaleAndCircleCrop(_ img: UIImage, maxPx: CGFloat) -> UIImage {
        let w = img.size.width, h = img.size.height
        let scale: CGFloat = Swift.min(maxPx / w, maxPx / h, 1.0)
        let target = CGSize(width: round(w * scale), height: round(h * scale))

        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { ctx in
            // Background fill — JPEG has no alpha channel, so anywhere
            // outside the circle gets the underlying fill colour.
            // Black matches the app's HexTheme.bg so the avatar still
            // reads as a clean circle on any dark UI background.
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))

            // Clip to a circle, then draw the source image inside.
            let circle = UIBezierPath(ovalIn: CGRect(origin: .zero, size: target))
            circle.addClip()
            img.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - Name edit sheet

/// Small modal for editing the display name. Wired from `AccountView`'s
/// Name row — the pencil icon now opens this. Username is intentionally
/// not edited here (signup-only field per project rule).
private struct NameEditSheet: View {
    let initial: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @EnvironmentObject var app: AppState
    @State private var draft: String = ""

    private var ar: Bool { app.language == "ar" }
    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(ar ? "تعديل الاسم" : "Edit name")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(HexTheme.text)
                Spacer()
                Button(ar ? "إلغاء" : "Cancel", action: onCancel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HexTheme.mute)
            }

            TextField(ar ? "اسمك" : "Your name", text: $draft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(HexTheme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(HexTheme.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(HexTheme.border, lineWidth: 1)
                )

            Button {
                onSave(trimmed)
            } label: {
                Text(ar ? "حفظ" : "Save")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(trimmed.isEmpty ? HexTheme.border : HexTheme.accent)
                    )
            }
            .disabled(trimmed.isEmpty)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .background(HexTheme.bg.ignoresSafeArea())
        .onAppear { draft = initial }
    }
}
