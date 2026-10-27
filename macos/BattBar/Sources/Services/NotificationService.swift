import Foundation
import UserNotifications

/// Decides *when* to notify (the Rust core) and delivers the notification (this
/// file). Titles and bodies live here because they belong to the UI language.
final class NotificationService {
    private let alerts = CoreAlertManager()

    /// Ask the core which devices crossed a threshold, then deliver those.
    func evaluate(_ devices: [MouseDevice], enabled: Bool) {
        for alert in alerts.evaluate(devices, enabled: enabled) {
            guard let device = devices.first(where: { $0.id == alert.deviceID }) else { continue }
            switch alert.kind {
            case .critical:
                deliver(
                    title: "鼠标电量仅剩 \(alert.battery)%",
                    body: "\(device.name) 快没电了，建议立即充电。",
                    identifier: "low-\(alert.deviceID)-10"
                )
            case .low:
                deliver(
                    title: "鼠标电量偏低（\(alert.battery)%）",
                    body: "\(device.name) 建议尽快充电，避免使用中断。",
                    identifier: "low-\(alert.deviceID)-20"
                )
            }
        }
    }

    func requestAuthorizationIfNeeded(completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { completion?(true) }
            case .denied:
                DispatchQueue.main.async { completion?(false) }
            default:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async { completion?(granted) }
                }
            }
        }
    }

    func sendTest(completion: @escaping (Bool) -> Void) {
        requestAuthorizationIfNeeded { granted in
            guard granted else {
                completion(false)
                return
            }
            self.deliver(
                title: "通知工作正常",
                body: "电量栏会在电量低于 20% 和 10% 时提醒你。",
                identifier: "test-\(UUID().uuidString)"
            ) { success in
                completion(success)
            }
        }
    }

    private func deliver(
        title: String,
        body: String,
        identifier: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        requestAuthorizationIfNeeded { granted in
            guard granted else {
                completion?(false)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            )
            UNUserNotificationCenter.current().add(request) { error in
                DispatchQueue.main.async { completion?(error == nil) }
            }
        }
    }
}
