import Foundation
import UserNotifications
import UIKit

/// 本地通知代理：让 App 在前台时也能显示通知横幅（默认前台通知不弹出）。
final class NoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoticeDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// 点通知横幅时把 App 切到前台（系统默认行为），无需额外处理。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
