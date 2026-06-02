import SwiftUI

/// 6-digit OTP verification — mirrors OtpView in src/components/AuthScreen.jsx.
struct OTPView: View {
    @EnvironmentObject var app: AppState

    let email: String

    @State private var digits: [String] = Array(repeating: "", count: 6)
    @State private var isLoading   = false
    @State private var isResending = false
    @State private var resentOk    = false
    @State private var errorMsg: String?
    @FocusState private var focusedIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Back button ───────────────────────────────────
                Button {
                    Task { await app.cancelOTP() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: app.language == "ar"
                              ? "arrow.right" : "arrow.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text(app.language == "ar" ? "رجوع" : "Back")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(HexTheme.dim)
                }
                .padding(.bottom, 32)

                // ── Logo (hides when keyboard is up) ──────────────
                if focusedIndex == nil {
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

                Text(app.language == "ar"
                     ? "تحقق من بريدك الإلكتروني"
                     : "Check your email")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(HexTheme.text)
                    .padding(.bottom, 8)

                (
                    Text(app.language == "ar"
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

                // ── 6 digit boxes ─────────────────────────────────
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        otpBox(at: i)
                    }
                }
                .padding(.bottom, 28)

                // ── Verify button ─────────────────────────────────
                Button(action: verify) {
                    if isLoading {
                        ProgressView().tint(HexTheme.mute)
                    } else {
                        Text(app.language == "ar" ? "تحقق" : "Verify")
                    }
                }
                .buttonStyle(HexPrimaryButton(
                    disabled: !filled || isLoading
                ))
                .disabled(!filled || isLoading)

                // ── Resend ────────────────────────────────────────
                VStack(spacing: 8) {
                    if resentOk {
                        Text(app.language == "ar" ? "تم إعادة الإرسال ✓" : "Code resent ✓")
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
                                Text(app.language == "ar" ? "جارٍ الإرسال…" : "Sending…")
                                    .foregroundStyle(HexTheme.mute)
                            } else {
                                Text(app.language == "ar" ? "إعادة إرسال الرمز" : "Resend code")
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
            .animation(.easeInOut(duration: 0.22), value: focusedIndex == nil)
        }
        .scrollDismissesKeyboard(.interactively)
        .hexAuthBackground()
        .navigationBarHidden(true)
        .onAppear { focusedIndex = 0 }
    }

    // MARK: - One digit box

    @ViewBuilder
    private func otpBox(at i: Int) -> some View {
        TextField("", text: Binding(
            get: { digits.indices.contains(i) ? digits[i] : "" },
            set: { newValue in
                // Guard the index defensively — digits is always size 6,
                // but never trust an out-of-range write.
                guard digits.indices.contains(i) else { return }
                let filtered = newValue.filter(\.isNumber)

                // Multiple digits arriving at once = paste or QuickType
                // auto-fill. Distribute them across the boxes from the
                // start. (count == 1 is the normal single keystroke;
                // count == 0 is a delete.)
                if filtered.count >= 2 {
                    var next = Array(repeating: "", count: 6)
                    for (j, ch) in filtered.prefix(6).enumerated() {
                        next[j] = String(ch)
                    }
                    digits = next
                    errorMsg = nil
                    let landed = min(filtered.count, 6)
                    // Defer focus change to the next runloop tick. Mutating
                    // @FocusState synchronously inside a TextField binding
                    // setter happens DURING SwiftUI's view update, which
                    // crashes / hangs on device. Deferring is the standard
                    // safe pattern.
                    DispatchQueue.main.async {
                        focusedIndex = landed >= 6 ? nil : landed
                    }
                    return
                }

                // Single digit or deletion.
                digits[i] = filtered
                errorMsg = nil
                let target: Int? = {
                    if !filtered.isEmpty && i < 5 { return i + 1 }
                    if filtered.isEmpty && i > 0 { return i - 1 }
                    return nil
                }()
                if let target {
                    DispatchQueue.main.async { focusedIndex = target }
                }
            }
        ))
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .multilineTextAlignment(.center)
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
        .focused($focusedIndex, equals: i)
    }

    private func borderColor(for i: Int) -> Color {
        if focusedIndex == i { return HexTheme.accent }
        let empty = digits.indices.contains(i) ? digits[i].isEmpty : true
        return empty ? HexTheme.border : HexTheme.accent
    }

    private var code: String { digits.joined() }
    private var filled: Bool { digits.allSatisfy { !$0.isEmpty } }

    // MARK: - Actions

    private func verify() {
        focusedIndex = nil
        Task {
            isLoading = true
            errorMsg  = nil
            defer { isLoading = false }
            do {
                try await app.verifyOTP(email: email, token: code)
            } catch {
                let lower = error.localizedDescription.lowercased()
                if lower.contains("expired") {
                    errorMsg = app.language == "ar"
                        ? "انتهت صلاحية الرمز. اضغط إعادة الإرسال."
                        : "Code expired. Tap Resend to get a new one."
                } else {
                    errorMsg = app.language == "ar"
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
                digits = Array(repeating: "", count: 6)
                focusedIndex = 0
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }
}
