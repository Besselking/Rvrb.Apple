import Foundation
import os
import UserNotifications

/// Shows a system notification when someone mentions, whispers to or answers the user while the app isn't in front.
/// Local notifications only, so on iOS just while the app still runs in the background; tapping one opens the app.
final class MentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var asked = false

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks once, the first time a notification is due (not at launch, out of the blue).
    private func authorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined where !asked:
            asked = true
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    func notify(_ message: ChatMessage, in channel: String) {
        Task {
            guard await authorized() else { return }

            let content = UNMutableNotificationContent()
            content.title = message.kind == .whisper ? "\(message.name) whispered" : message.name
            content.subtitle = channel
            content.body = message.body.summary.isEmpty ? "Sent an image" : message.body.summary
            content.sound = .default
            content.threadIdentifier = channel

            // One per message: repeats replace rather than pile up.
            let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                Log.app.error("Could not show a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Back in the app: the notifications about this chat are no longer news.
    func clearDelivered() {
        center.removeAllDeliveredNotifications()
    }

    // Only while the app is in the background: in front, the chat already shows (and highlights) the message.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        []
    }
}
