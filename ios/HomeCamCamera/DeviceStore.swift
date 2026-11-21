import Foundation
import UIKit

struct DeviceCredentials: Codable {
    let serverURL: URL; let deviceID: String; let deviceSecret: String; let name: String
    var iceServers: [IceServerConfiguration]?
}

final class DeviceStore {
    private let key = "homecam-device-credentials"
    func load() -> DeviceCredentials? { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(DeviceCredentials.self, from: $0) } }
    func save(_ credentials: DeviceCredentials) { UserDefaults.standard.set(try? JSONEncoder().encode(credentials), forKey: key) }
    func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

enum PairingAPI {
    static func pair(serverURL: URL, name: String, code: String) async throws -> DeviceCredentials {
        let endpoint = serverURL.appending(path: "api/devices/pair")
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let device = UIDevice.current
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "code": code,
            "brand": "Apple", "model": DeviceInfo.modelName, "osVersion": "iOS \(device.systemVersion)"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PairingError.failed }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let device = object?["device"] as? [String: Any], let id = device["id"] as? String, let secret = object?["deviceSecret"] as? String else { throw PairingError.failed }
        // ICE 配置随配对响应下发并持久化，避免依赖 Socket.IO 的 NSArray 桥接
        let servers = (object?["iceServers"] as? [[String: Any]] ?? []).compactMap { item -> IceServerConfiguration? in
            guard let urls = item["urls"] as? [String], !urls.isEmpty else { return nil }
            return IceServerConfiguration(urls: urls, username: item["username"] as? String ?? "", credential: item["credential"] as? String ?? "")
        }
        return DeviceCredentials(serverURL: serverURL, deviceID: id, deviceSecret: secret, name: name, iceServers: servers)
    }
}
enum PairingError: LocalizedError { case failed; var errorDescription: String? { "配对码无效、已过期，或服务器暂时不可用。" } }
