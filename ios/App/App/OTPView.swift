import SwiftUI

/// 6-digit OTP verification — mirrors OtpView in src/components/AuthScreen.jsx.
///
/// Input model: a SINGLE hidden text field holds the whole code, and the
/// six boxes are a read-only visual rendering on top of it. The earlier
/// design used six separate `TextField`s and hopped `@FocusState` from
/// one to the next on each keystroke — but the focus hop was deferred to
/// the next runloop tick, so fast typing landed the 2nd/3rd digit in the
/// still-focused first box and the re-entrant setter glitched. One field
/// = no focus juggling, and `.oneTimeCode` autofill lands cleanly because
/// only one field claims it.
struct OTPView: View {
    @EnvironmentObject var app: AppState

    let email: String

    @State private var code: String = ""
    @State private var isLoading   = false
    @State private var isResending = false
    @State private var resentOk    = false
    @State private var errorMsg: String?
    @FocusState private var focused: Bool

    private var ar: Bool { app.language == "ar" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Back button ───────────────────────────────────
                Button {
                    Task { await app.cancelOTP() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: ar ? "arrow.right" : "arrow.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text(ar ? "رجوع" : "Back")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(HexTheme.dim)
                }
                .padding(.bottom, 32)

                // ── Logo (hides when keyboard is up) ──────────────
                if !focused {
                    HStack {
                        Spacer()
                        Image("LoginLogo")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(HexTheme.accent)
                            .frame(height: 160)
                        Spacer()
                    }
                    .padding(.bottom, 32)
                    .transition(.opacity)
                }

                Text(ar ? "تحقق من بريدك الإلكتروني" : "Check your email")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(HexTheme.text)
                    .padding(.bottom, 8)

                (
                    Text(ar
                         ? "أدخل الرمز المكوّن من ٦ أرقام المُرسَل إلى "
                         : "Enter the 6-digit code sent to ")
                        .foregroundColor(HexTheme.dim)
                    + Text(email)
                        .foregroundColor(HexTheme.text)
                        .fontWeight(.heavy)
                )
                .font(.system(size: 14))
                .lineSpacing(4)
                .padding(.bottom, 28)

                if let err = errorMsg {
                    HexErrorBanner(msg: err)
                        .padding(.bottom, 16)
                }

                // ── 6 digit boxes over one hidden field ───────────
                ZStack {
                    // The real input. Text + caret are clear so it's
                    // invisible; it sits behind the boxes and captures
                    // every keystroke / the autofilled code.
                    TextField("", text: codeBinding)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)

                    HStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { i in
                            otpBox(at: i)
                        }
                    }
                    // Taps fall through to the full-width field behind,
                    // which focuses natively — so tapping anywhere on the
                    // row opens the keyboard.
                    .allowsHitTesting(false)
                }
                .padding(.bottom, 28)

                // ── Verify button ─────────────────────────────────
                Button(action: verify) {
                    if isLoading {
                        ProgressView().tint(HexTheme.mute)
                    } else {
                        Text(ar ? "تحقق" : "Verify")
                    }
                }
                .buttonStyle(HexPrimaryButton(
                    disabled: !filled || isLoading
                ))
                .disabled(!filled || isLoading)

                // ── Resend ────────────────────────────────────────
                VStack(spacing: 8) {
                    if resentOk {
                        Text(ar ? "تم إعادة الإرسال ✓" : "Code resent ✓")
                            .font(.system(size: 12))
                            .foregroundStyle(HexTheme.success)
                            .transition(.opacity)
                    }
                    Button(action: resend) {
                        HStack(spacing: 6) {
                            if isResending {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(HexTheme.mute)
                                Text(ar ? "جارٍ الإرسال…" : "Sending…")
                                    .foregroundStyle(HexTheme.mute)
                            } else {
                                Text(ar ? "إعادة إرسال الرمز" : "Resend code")
                                    .foregroundStyle(HexTheme.accent)
                            }
                        }
                        .font(.system(size: 13, weight: .heavy))
                    }
                    .disabled(isResending)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .animation(.easeInOut(duration: 0.2), value: resentOk)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.22), value: focused)
        }
        .scrollDismissesKeyboard(.interactively)
        .hexAuthBackground()
        .navigationBarHidden(true)
        .onAppear { focused = true }
    }

    // MARK: - Input binding

    /// Sanitises input to at most 6 digits. Single source of truth — no
    /// per-box state, no focus hopping. When the 6th digit lands we drop
    /// focus (deferred, never mutate @FocusState inside the setter) so
    /// the keyboard clears and the Verify button is reachable.
    private var codeBinding: Binding<String> {
        Binding(
            get: { code },
            set: { newValue in
                let filtered = String(newValue.filter(\.isNumber).prefix(6))
                guard filtered != code else { return }
                code = filtered
                errorMsg = nil
                if filtered.count == 6 {
                    DispatchQueue.main.async { focused = false }
                }
            }
        )
    }

    // MARK: - One digit box (display only)

    @ViewBuilder
    private func otpBox(at i: Int) -> some View {
        let chars = Array(code)
        let ch = i < chars.count ? String(chars[i]) : ""
        Text(ch)
            .font(.system(size: 24, weight: .heavy).monospacedDigit())
            .foregroundStyle(HexTheme.text)
            .frame(maxWidth: 52)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: HexTheme.cornerInput, style: .continuous)
                    .fill(HexTheme.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HexTheme.cornerInput, style: .continuous)
                    .stroke(borderColor(for: i), lineWidth: 1.5)
            )
    }

    /// Accent on filled boxes and on the next box to fill (when focused);
    /// neutral border otherwise.
    private func borderColor(for i: Int) -> Color {
        let count = code.count
        if i < count { return HexTheme.accent }            // already typed
        if focused && i == count { return HexTheme.accent } // cursor here
        return HexTheme.border
    }

    private var filled: Bool { code.count == 6 }

    // MARK: - Actions

    private func verify() {
        focused = false
        Task {
            isLoading = true
            errorMsg  = nil
            defer { isLoading = false }
            do {
                try await app.verifyOTP(email: email, token: code)
            } catch {
                let lower = error.localizedDescription.lowercased()
                if lower.contains("expired") {
                    errorMsg = ar
                        ? "انتهت صلاحية الرمز. اضغط إعادة الإرسال."
                        : "Code expired. Tap Resend to get a new one."
                } else {
                    errorMsg = ar
                        ? "رمز غير صالح. يرجى المحاولة مجدداً."
                        : "Invalid code. Please try again."
                }
            }
        }
    }

    private func resend() {
        Task {
            isResending = true
            resentOk    = false
            errorMsg    = nil
            defer { isResending = false }
            do {
                try await app.resendOTP(email: email)
                resentOk = true
                code = ""
                focused = true
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }
}
