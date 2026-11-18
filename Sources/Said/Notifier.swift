import UserNotifications

/// System notifications (silence, low disk space) with a "Stop recording" action.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private static let category = "SAID_RECORDING"
    nonisolated private static let stopAction = "STOP"

    /// Call at launch so taps on notification actions reach us.
    func setUp() {
        center.delegate = self
        let stop = UNNotificationAction(identifier: Self.stopAction, title: L("Stop recording"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [stop], intentIdentifiers: [])
        ])
    }

    /// Asks once (the first time a recording starts).
    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String, offerStop: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if offerStop { content.categoryIdentifier = Self.category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func clear(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.stopAction {
            Task { @MainActor in Recorder.shared.stop() }
        }
        completionHandler()
    }

    /// Said is a menu bar app, so show banners even while it is "active".
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
