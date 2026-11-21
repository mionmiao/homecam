import Foundation

/// 运行时配置：由服务端 /api/config 下发，改配置即时生效，无需重装 App。
/// 本地留有缓存：App 启动先用缓存，再异步拉取最新。
final class RuntimeConfig {
    static let shared = RuntimeConfig()
    private let cacheKey = "homecam.runtimeConfig"
    private let cacheTimeKey = "homecam.runtimeConfig.updatedAt"
    private let defaults = UserDefaults.standard

    struct Features: Codable {
        var photos: Bool?
        var burst: Bool?
        var screenLockCapture: Bool?
        var cameraSwitch: Bool?
        var photoUpload: Bool?
    }
    struct PhotoSettings: Codable {
        var burstCount: Int?
        var intervalMs: Int?
        var order: [String]?
    }
    private struct Payload: Codable {
        var schemaVersion: Int?
        var iceServers: [IceServerConfiguration]?
        var features: Features?
        var photoSettings: PhotoSettings?
        var captureThresholdSeconds: Double?
        var ui: [String: String]?
    }

    // 生效中的配置（默认值兜底）
    private(set) var iceServers: [IceServerConfiguration]?
    private(set) var enablePhotos = true
    private(set) var enableBurst = true
    private(set) var enableScreenLockCapture = true
    private(set) var enableCameraSwitch = true
    private(set) var enablePhotoUpload = true
    private(set) var burstCount = 5
    private(set) var burstIntervalMs = 300
    private(set) var burstOrder = ["front", "back"]
    private(set) var captureThresholdSeconds: Double = 10
    private(set) var uiText: [String: String] = [:]
    /// 最近一次成功拉取的时间（用于界面显示）
    private(set) var lastUpdatedAt: Date?
    /// 最近一次拉取结果说明
    private(set) var lastStatus: String = "未同步（使用内置默认值）"

    /// 界面显示用的一行摘要
    var summary: String {
        let when = lastUpdatedAt.map { Self.formatter.string(from: $0) } ?? "--"
        return "运行时配置：\(lastStatus) · 更新于 \(when)"
    }
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private init() { loadCache() }

    /// 从本地缓存恢复上次生效的配置
    private func loadCache() {
        guard let data = defaults.data(forKey: cacheKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        apply(payload)
        lastUpdatedAt = defaults.object(forKey: cacheTimeKey) as? Date
        lastStatus = "已加载本地缓存"
    }

    /// 异步拉取服务端最新配置；失败时保留当前值
    func refresh(from serverURL: URL, onDone: ((String) -> Void)? = nil) {
        guard let url = URL(string: "api/config", relativeTo: serverURL) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.lastStatus = "拉取失败（沿用上次）"; onDone?(self.lastStatus); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                self.lastStatus = "响应无效（沿用上次）"; onDone?(self.lastStatus); return
            }
            self.apply(payload)
            self.saveCache(payload)
            self.lastUpdatedAt = Date()
            self.lastStatus = "已同步"
            onDone?(self.summary)
        }.resume()
    }

    private func apply(_ p: Payload) {
        // 服务端不再公开静态 TURN 凭据，返回空数组时回退到信令下发的 ICE
        if let s = p.iceServers { iceServers = s.isEmpty ? nil : s }
        if let f = p.features {
            if let v = f.photos { enablePhotos = v }
            if let v = f.burst { enableBurst = v }
            if let v = f.screenLockCapture { enableScreenLockCapture = v }
            if let v = f.cameraSwitch { enableCameraSwitch = v }
            if let v = f.photoUpload { enablePhotoUpload = v }
        }
        if let s = p.photoSettings {
            if let v = s.burstCount { burstCount = max(1, min(20, v)) }
            if let v = s.intervalMs { burstIntervalMs = max(0, min(5000, v)) }
            if let v = s.order { burstOrder = v.filter { $0 == "front" || $0 == "back" } }
            if burstOrder.isEmpty { burstOrder = ["front", "back"] }
        }
        if let v = p.captureThresholdSeconds { captureThresholdSeconds = max(0, min(600, v)) }
        if let v = p.ui { uiText = v }
    }

    private func saveCache(_ p: Payload) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        defaults.set(data, forKey: cacheKey)
        defaults.set(Date(), forKey: cacheTimeKey)
    }
}
