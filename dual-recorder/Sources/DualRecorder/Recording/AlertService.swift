import AppKit
import UserNotifications

/// Sounds and notifications for sensor dropouts. Sounds play even when Zwift is full screen.
final class AlertService: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter crashes in a process without a bundle (e.g. `swift run`).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Something needs attention now: repeated warning sound plus a notification.
    func warn(title: String, body: String) {
        playSound(named: "Basso", times: 3)
        post(title: title, body: body)
    }

    /// Good news, e.g. a sensor is back.
    func inform(title: String, body: String) {
        playSound(named: "Glass", times: 1)
        post(title: title, body: body)
    }

    private func playSound(named name: String, times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(i)) {
                // A fresh instance each time: one NSSound can't overlap with itself.
                let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound
                sound?.play()
            }
        }
    }

    private func post(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while Dual Recorder is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
