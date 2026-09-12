import Foundation
import BrainioPenCore
import UserNotifications

/// macOS notification centre. Only works when running from an app bundle; the caller falls back
/// to `OSAScriptNotifier` otherwise.
final class UserNotifier: Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Log.warn("notification permission: \(error.localizedDescription)") }
            if !granted { Log.warn("notifications not permitted; problems will only be logged") }
        }
    }

    func post(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: notice.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.warn("notification failed: \(error.localizedDescription)") }
        }
    }
}
