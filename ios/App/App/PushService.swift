import Foundation
import UIKit
import UserNotifications

/// Central coordinator for push notifications.
///
/// Responsibilities:
///   1. Ask for permission at the right moment (not first launch — after
///      the user finishes their first session, when they're bought in).
///   2. Forward the APNs device token from AppDelegate up to Supabase
///      (upsert into push_devices, keyed by token).
///   3. Route notification taps to the right tab via AppState.
///
/// Designed as a singleton so AppDelegate's UIKit callbacks have something
/// stable to call into. The SwiftUI layer reaches it via
/// `PushService.shared` — never via `@StateObject` since UIKit owns the
/// callback lifecycle.
@MainActor
final class PushService {

    static let shared = PushService()
    private init() {}

    /// Reference to AppState injected at app startup. Used for tab
    /// routing after taps and to know who the current user is when
    /// uploading the device token. Set from HEXApp's onAppear.
    weak var app: AppState?

    /// Cached token from the most recent registration. Lets us re-upload
    /// on sign-in if a user signs out and back in with the same device.
    private var lastKnownToken: String?

    // MARK: - Permission

    /// Whether we've already asked the user. Persists across launches so
    /// we don't re-prompt every time. Apple only shows the system dialog
    /// the FIRST time anyway — subsequent calls return the previous
    /// answer silently — but tracking this locally lets us decide whether
    /// to register for remote notifications at all.
    var didRequestPermission: Bool {
        get { UserDefaults.standard.bool(forKey: "push_permission_requested") }
        set { UserDefaults.standard.set(newValue, forKey: "push_permission_requested") }
    }

    /// Ask iOS for notification permission. Called from AppState after
    /// the user completes their first session — not on app launch (where
    /// the dialog gets declined ~50% of the time). After permission grant,
    /// register with APNs to get a device token.
    func requestPermissionIfNeeded() async {
        // Don't re-prompt if we've already asked. (iOS would auto-return
        // the previous answer anyway, but skipping the call also avoids
        // re-registering for remote notifications unnecessarily.)
        if didRequestPermission { return }

        let centre = UNUserNotificationCenter.current()
        do {
            let granted = try await centre.requestAuthorization(options: [.alert, .badge, .sound])
            didRequestPermission = true
            print("[PushService] permission granted: \(granted)")
            if granted {
                await registerForRemoteNotifications()
            }
        } catch {
            print("[PushService] permission request failed:", error)
        }
    }

    /// Trigger UIApplication.registerForRemoteNotifications. Apple will
    /// asynchronously call back to AppDelegate's `didRegisterForRemote-
    /// NotificationsWithDeviceToken`, which forwards to handleNewToken.
    private func registerForRemoteNotifications() async {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called by AppDelegate when iOS fails to hand back a token.
    /// Logged for console diagnostics; not surfaced to the user.
    func handleRegistrationFailure(_ error: Error) {
        print("[PushService] APNs registration failed:", error)
    }

    /// Current notification authorization status — drives the Settings
    /// "Enable Notifications" row UI.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Driven by the Settings "Enable Notifications" button. Does the
    /// right thing for the current status and returns the resulting
    /// status so the caller can update its UI / deep-link to Settings:
    ///   • .notDetermined → show the system permission dialog, then
    ///     register for a token on grant.
    ///   • .authorized/.provisional → already on; just (re)register so
    ///     a token lands in push_devices even if the original grant
    ///     didn't upload one (the bug that left the table empty).
    ///   • .denied → can't re-prompt; caller should deep-link the user
    ///     to iOS Settings → HEX → Notifications.
    @discardableResult
    func enableNotifications() async -> UNAuthorizationStatus {
        let centre = UNUserNotificationCenter.current()
        let status = await centre.notificationSettings().authorizationStatus

        switch status {
        case .notDetermined:
            let granted = (try? await centre.requestAuthorization(
                options: [.alert, .badge, .sound]
            )) ?? false
            didRequestPermission = true
            if granted {
                await registerForRemoteNotifications()
                return .authorized
            }
            return .denied
        case .authorized, .provisional, .ephemeral:
            // Already granted — force a re-register so the token gets
            // (re)uploaded. This is the recovery path for users whose
            // permission was granted before token upload worked.
            await registerForRemoteNotifications()
            return status
        case .denied:
            return .denied
        @unknown default:
            return status
        }
    }

    /// Called from AppState.restoreSession / signIn after the user has
    /// a valid auth session. If the user previously granted permission
    /// on this device, re-register so we re-upload the token (handles
    /// reinstalls, token rotation, sign-in on a new account, etc.).
    func reregisterIfPermitted() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
              || settings.authorizationStatus == .provisional else {
            return
        }
        await registerForRemoteNotifications()
    }

    // MARK: - Token upload

    /// Hand-off from AppDelegate. Upserts the token into push_devices.
    /// Token is the lowercase hex string — what Apple expects when we
    /// post back to api.push.apple.com.
    func handleNewToken(_ tokenHex: String) async {
        lastKnownToken = tokenHex
        // Persist locally too so signOut can find it and call
        // deletePushDevice to release this phone's slot.
        UserDefaults.standard.set(tokenHex, forKey: "last_apns_token")
        // Only upload once we have a signed-in user. If the token
        // arrives before sign-in (rare — usually after restoreSession),
        // AppState's onSignedIn callback will call this again.
        guard SupabaseManager.shared.currentUser?.id != nil else {
            print("[PushService] token received but no user yet — will replay on sign-in")
            return
        }
        do {
            try await SupabaseManager.shared.upsertPushDevice(token: tokenHex)
            print("[PushService] token uploaded to push_devices")
        } catch {
            print("[PushService] token upload failed:", error)
        }
    }

    /// Called from AppState after the user signs in. Re-uploads the last
    /// known token if we have one in memory (covers the "token arrived
    /// before sign-in completed" race condition).
    func uploadCachedTokenIfAny() async {
        if let token = lastKnownToken {
            await handleNewToken(token)
        }
    }

    // MARK: - Tap routing

    /// Called from AppDelegate when the user taps a notification banner.
    /// Switches to the appropriate tab so the user lands somewhere
    /// meaningful instead of wherever they last were.
    func handleTap(category: String, payload: [AnyHashable: Any]) {
        guard let app else { return }
        switch category {
        case "friend_request", "friend_accepted", "friend_session", "friend_badge":
            app.activeTab = .bros
        case "league_invite":
            app.activeTab = .bros        // leagues live inside Bros tab
        case "monthly_leaderboard":
            app.activeTab = .profile
        default:
            break
        }
    }
}
