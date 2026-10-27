import Foundation
import UserNotifications

final class NotificationService {
    private var notified: [String: Set<Int>] = [:]
    private var authorizationRequested = false

    func evaluate(_ devices: [MouseDevice], enabled: Bool) {
        let activeIDs = Set(devices.map(\.id))
        for id in notified.keys where !activeIDs.contains(id) {
            notified.removeValue(forKey: id)
        }
        guard enabled else {
            notified.removeAll()
            return
        }

        for device in devices {
            guard !device.isStale, let battery = device.battery else { continue }
            if device.charging == true || battery > 25 {
                notified.removeValue(forKey: device.id)
                continue
            }
            var state = notified[device.id] ?? []
            if battery <= 10 {
                if !state.contains(10) {
                    state.insert(10)
                    state.insert(20)
                    notified[device.id] = state
                    deliver(
                        title: "鼠标电量仅剩 \(battery)%",
                        body: "\(device.name) 快没电了，建议立即充电。",
                        identifier: "low-\(device.id)-10"
                    )
                }
            } else if battery <= 20 {
                if !state.contains(20) {
                    state.insert(20)
                    notified[device.id] = state
                    deliver(
                        title: "鼠标电量偏低（\(battery)%）",
                        body: "\(device.name) 建议尽快充电，避免使用中断。",
                        identifier: "low-\(device.id)-20"
                    )
                }
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
