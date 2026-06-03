import UIKit
import UserNotifications

/// Bridges UIKit's UIApplicationDelegate callbacks into our SwiftUI
/// app — needed because pure SwiftUI doesn't expose
/// `didRegisterForRemoteNotificationsWithDeviceToken` / `…didFailToRegister`
/// without an AppDelegate. Wired via @UIApplicationDelegateAdaptor in HEXApp.
///
/// Responsibilities:
///   • Capture the APNs device token after iOS hands it to us, forward
///     to PushService for upload to push_devices.
///   • Forward foreground / tap callbacks to PushService for routing.
///   • Set itself as the UNUserNotificationCenter delegate so banners
///     can show even while the app is in the foreground.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Become the notification centre delegate so willPresent /
        // didReceive callbacks land here. PushService also subscribes
        // to a NotificationCenter post we publish from didReceive so
        // the SwiftUI layer can react to taps.
        UNUserNotificationCenter.current().delegate = self
        clearBadge()
        return true
    }

    // Clear the app-icon badge every time the app comes to the
    // foreground. Pushes arrive with badge:1, which iOS stamps on the
    // icon; without this it stays stuck forever because nothing ever
    // resets the count once the user has seen the notification.
    func applicationDidBecomeActive(_ application: UIApplication) {
        clearBadge()
    }

    private func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    // ─── Token receipt ───────────────────────────────────────────────────
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Apple gives us 32 raw bytes. APNs wants the lowercase hex
        // string of those bytes — that's the format push_devices.device_token
        // stores and the Edge Function passes back to apple.
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[AppDelegate] APNs token received: \(tokenHex.prefix(8))…")
        Task { await PushService.shared.handleNewToken(tokenHex) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Soft failure — most common cause is simulator (no APNs) or
        // network. Logged + surfaced to the Settings debug line so we
        // can distinguish "Apple never replied" from an upload failure.
        print("[AppDelegate] APNs registration failed:", error)
        Task { @MainActor in
            PushService.shared.handleRegistrationFailure(error)
        }
    }

    // ─── Foreground presentation ─────────────────────────────────────────
    //
    // When a push lands while the app is in the foreground, iOS asks
    // us what to do. Default would be "silence it". We choose to show
    // the banner + play the sound so the user notices a friend request
    // even if they're mid-session.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    // ─── Tap routing ─────────────────────────────────────────────────────
    //
    // User tapped a notification. The aps payload includes a "category"
    // field (set by the Edge Function) which PushService uses to route
    // to the appropriate tab — friend stuff → Bros, league stuff →
    // Bros's leagues section, monthly leaderboard → Profile.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let category = userInfo["category"] as? String ?? ""
        print("[AppDelegate] notification tap, category=\(category)")
        PushService.shared.handleTap(category: category, payload: userInfo)
        clearBadge()
        completionHandler()
    }
}
