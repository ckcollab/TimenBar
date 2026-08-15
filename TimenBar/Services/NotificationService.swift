import Foundation
import UserNotifications

actor NotificationService {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func notifyIdle(minutes: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "TimenBar noticed inactivity"
        content.body = "You have been idle for at least \(minutes) minutes. Open TimenBar to keep, remove, or continue the timer."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "idle-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

