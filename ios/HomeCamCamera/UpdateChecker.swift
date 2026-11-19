import Foundation
import UIKit

/// 可用更新信息
struct UpdateInfo: Identifiable {
    let id = UUID()
    let build: Int
    let version: String
    let notes: String
    let ipaUrl: String
    /// 附加提示（例如上次未完成安装）
    var hint: String = ""
}

/// App 内提示类型：更新弹窗或普通消息
enum AppNotice {
    case update(UpdateInfo)
    case message(String)
}

/// App 更新检查：启动时与回前台时向服务端询问最新构建，
/// 若构建号高于本地则提示更新，并可通过 LiveContainer 一键安装（livecontainer://install?url=）。
enum UpdateChecker {
    struct Response: Decodable {
        let build: Int
        let version: String
        let notes: String
        let ipaUrl: String
        let ready: Bool
    }

    /// 本地构建号（CI 注入的 CURRENT_PROJECT_VERSION）
    static var localBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    static func check(serverURL: URL, onResult: @escaping (UpdateInfo?) -> Void) {
        guard let url = URL(string: "api/version", relativeTo: serverURL) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let res = try? JSONDecoder().decode(Response.self, from: data),
                  res.ready, res.build > localBuild, !res.ipaUrl.isEmpty else {
                onResult(nil); return
            }
            onResult(UpdateInfo(build: res.build, version: res.version, notes: res.notes, ipaUrl: res.ipaUrl))
        }.resume()
    }

    /// 唤起 LiveContainer 安装新包；未安装 LiveContainer 时降级为用 Safari 打开下载链接
    /// 返回给用户看的提示文案
    @discardableResult
    static func install(_ info: UpdateInfo) -> String {
        guard let ipa = URL(string: info.ipaUrl) else { return "下载地址无效" }
        var components = URLComponents()
        components.scheme = "livecontainer"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        if let installURL = components.url, UIApplication.shared.canOpenURL(installURL) {
            UIApplication.shared.open(installURL)
            // LiveContainer 会把安装任务排队，提示重启 LiveContainer——必须完全退出
            // LiveContainer 本身（多任务界面向上划掉它），只重启本 App 无效。
            return "已通知 LiveContainer 下载新版。请在多任务界面把 LiveContainer 整个划掉，再重新打开它完成安装；安装后从 LiveContainer 启动本 App"
        }
        UIApplication.shared.open(ipa)
        return "未检测到 LiveContainer，已在浏览器打开下载链接；请用 LiveContainer 的「+」导入"
    }
}
