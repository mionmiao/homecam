import Foundation
import UIKit
import Security

struct DeviceCredentials: Codable {
    let serverURL: URL; let deviceID: String; let deviceSecret: String; let name: String
    var iceServers: [IceServerConfiguration]?
}

/// 配对凭据存 Keychain（ThisDeviceOnly，不进备份），不再明文写 UserDefaults。
/// 旧版本留在 UserDefaults 的凭据会在首次读取时自动迁移并清除。
final class DeviceStore {
    private let account = "homecam-device-credentials"
    private let legacyKey = "homecam-device-credentials"

    private var baseQuery: [String: Any] {
        let service = Bundle.main.bundleIdentifier ?? "com.homecam.camera"
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }

    private var lookupQuery: [String: Any] {
        var q = baseQuery
        q.removeValue(forKey: kSecAttrAccessible as String)
        return q
    }

    func load() -> DeviceCredentials? {
        var query = lookupQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let creds = try? JSONDecoder().decode(DeviceCredentials.self, from: data) {
            return creds
        }
        // 迁移旧 UserDefaults 明文凭据
        guard let legacy = UserDefaults.standard.data(forKey: legacyKey),
              let creds = try? JSONDecoder().decode(DeviceCredentials.self, from: legacy) else { return nil }
        save(creds)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        return creds
    }

    func save(_ credentials: DeviceCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(lookupQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    func clear() {
        SecItemDelete(lookupQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
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
