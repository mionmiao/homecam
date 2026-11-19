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

    /// 检查结果：latestBuild 用于版本行显示；update 仅在有新版时非空
    struct Result {
        let latestBuild: Int
        let update: UpdateInfo?
    }

    static func check(serverURL: URL, onResult: @escaping (Result?) -> Void) {
        guard let url = URL(string: "api/version", relativeTo: serverURL) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let res = try? JSONDecoder().decode(Response.self, from: data), res.ready else {
                onResult(nil); return
            }
            let update: UpdateInfo? = (res.build > localBuild && !res.ipaUrl.isEmpty)
                ? UpdateInfo(build: res.build, version: res.version, notes: res.notes, ipaUrl: res.ipaUrl)
                : nil
            onResult(Result(latestBuild: res.build, update: update))
        }.resume()
    }

    /// 复制安装链接到剪贴板，由用户在 LiveContainer 的「+」→ Install from URL 手动粘贴安装。
    /// 不再调用 livecontainer://install（它会把安装排队，需要重启 LiveContainer 才生效，容易误导）。
    @discardableResult
    static func copyInstallLink(url: String) -> String {
        guard URL(string: url) != nil else { return "下载地址无效" }
        UIPasteboard.general.string = url
        return "安装链接已复制。请打开 LiveContainer → 点「+」→ Install from URL → 粘贴链接安装，装完重启 LiveContainer 后从列表启动本 App"
    }
}
