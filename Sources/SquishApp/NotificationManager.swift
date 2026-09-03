import Foundation
@preconcurrency import UserNotifications
import AppKit

/// Posts a completion notification. Tries UNUserNotificationCenter first (the
/// modern, better-looking route) and falls back to `osascript -e 'display
/// notification'` if that's unavailable - ad-hoc signed / unbundled dev builds
/// often can't get a valid notification center. Must never crash the app.
enum NotificationManager {

    static func notify(title: String, body: String) {
        guard isProperAppBundle else {
            fallback(title: title, body: body)
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted, error == nil else {
                fallback(title: title, body: body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request) { addError in
                if addError != nil {
                    fallback(title: title, body: body)
                }
            }
        }
    }

    // MARK: - Permission surface
    //
    // Notifications are the *only* system permission Squish needs. It has no
    // sandbox, reads and writes only the files the user hands it, and never touches
    // the accessibility, input-monitoring or screen-recording APIs.

    enum Permission {
        /// Not running from a real .app bundle, or the notification centre refused
        /// to hand us settings - an ad-hoc signature can do this. The osascript
        /// fallback still works, so this is a degraded state, not a broken one.
        case unavailable
        case notDetermined
        case granted
        case denied

        var summary: String {
            switch self {
            case .unavailable: return "Unavailable"
            case .notDetermined: return "Not yet asked"
            case .granted: return "Allowed"
            case .denied: return "Denied"
            }
        }
    }

    static func currentPermission() async -> Permission {
        guard isProperAppBundle else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .granted
        @unknown default: return .unavailable
        }
    }

    /// Only ever called from a state where the prompt can actually appear
    /// (`.notDetermined`), so the user is never shown a request that cannot succeed.
    static func requestPermission() async -> Permission {
        guard isProperAppBundle else { return .unavailable }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            return granted ? .granted : .denied
        } catch {
            return .unavailable
        }
    }

    /// UNUserNotificationCenter reliably throws/crashes when the process isn't
    /// running from a properly-formed, code-signed .app bundle (e.g. bare
    /// `swift run`). Gate on that instead of catching, since the failure mode
    /// there is an uncatchable Objective-C exception, not a Swift error.
    private static var isProperAppBundle: Bool {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return false }
        let infoPlist = bundlePath + "/Contents/Info.plist"
        return FileManager.default.fileExists(atPath: infoPlist)
    }

    private static func fallback(title: String, body: String) {
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        // Best effort. If even this fails, degrade silently per spec.
        do {
            try task.run()
        } catch {
            // Nothing more we can do - never crash the app over a notification.
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Bounces the Dock icon once (informational request) to draw attention
    /// after a batch completes, in addition to the notification.
    @MainActor
    static func bounceDockIcon() {
        NSApp.requestUserAttention(.informationalRequest)
    }
}
