import Foundation
import UserNotifications

/// 未接来电提醒：观看端发来的消息排队在服务端，App 回前台/启动时拉取并弹本地通知。
/// 免费 Apple ID 侧载没有 APNs 权限，无法做真后台即时推送，故采用「回前台补达」方案。
enum NoticeChecker {
    struct Notice: Decodable {
        let id: String
        let title: String
        let body: String
        let createdAt: Int64
    }
    private struct Response: Decodable { let notices: [Notice] }

    /// 申请通知权限（在 App 启动时调用一次）
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 从服务端拉取待通知并弹出。deviceId 为配对时生成的随机 UUID。
    static func fetchAndShow(serverURL: URL, deviceID: String) {
        var url = serverURL.appending(path: "api/notices")
        url.append(queryItems: [URLQueryItem(name: "deviceId", value: deviceID)])
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let res = try? JSONDecoder().decode(Response.self, from: data) else { return }
            for notice in res.notices { show(notice) }
        }.resume()
    }

    /// socket 实时收到通知时直接弹（App 在前台时有效）
    static func showRemote(_ notice: Notice) { show(notice) }

    private static func show(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "homecam-notice-\(notice.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
