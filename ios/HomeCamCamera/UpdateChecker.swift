import Foundation
import UIKit

/// 可用更新信息
struct UpdateInfo: Identifiable {
    let id = UUID()
    let build: Int
    let version: String
    let notes: String
    let ipaUrl: String
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
            return "已唤起 LiveContainer 安装，装完后重新打开 App 即可"
        }
        UIApplication.shared.open(ipa)
        return "未检测到 LiveContainer，已在浏览器打开下载链接；请用 LiveContainer 导入"
    }
}
