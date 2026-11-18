import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 生成有辨识度的默认设备名。UIDevice.current.name 在未自定义时只是 "iPhone"/"iPad"，
/// 此时退回硬件型号（uname 的 hw.machine），映射成友好机型名。
enum DeviceInfo {
    /// 用于配对表单的预填名称
    static var defaultName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || isGeneric(name) { return modelName }
        return name
    }

    /// 友好机型名，如 iPhone 14 Pro；映射不到时返回原始标识符如 iPhone18,1
    static var modelName: String {
        let identifier = machineIdentifier()
        guard !identifier.isEmpty else { return UIDevice.current.model }
        return Self.models[identifier] ?? identifier
    }

    private static func isGeneric(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["iphone", "ipad", "ipod", "ipod touch", "ipad air", "ipad pro", "iphone 手机"].contains(n)
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "" }
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MEMNAMELEN)) { chars in
                String(cString: chars)
            }
        }
    }

    private static let models: [String: String] = [
        // iPhone
        "iPhone7,1": "iPhone 6 Plus", "iPhone7,2": "iPhone 6",
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,3": "iPhone 7", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,3": "iPhone 8", "iPhone10,4": "iPhone X", "iPhone10,5": "iPhone 8 Plus",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE 2",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE 3", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone15,6": "iPhone 15 Pro", "iPhone15,7": "iPhone 15 Pro Max",
        "iPhone16,1": "iPhone 16", "iPhone16,2": "iPhone 16 Plus", "iPhone16,3": "iPhone 16 Pro", "iPhone16,4": "iPhone 16 Pro Max",
        "iPhone17,1": "iPhone 16e",
        "iPhone17,2": "iPhone 17 Pro", "iPhone17,3": "iPhone 17 Pro Max", "iPhone17,4": "iPhone 17", "iPhone17,5": "iPhone Air",
        "iPhone18,1": "iPhone 17e", "iPhone18,2": "iPhone 18 Pro", "iPhone18,3": "iPhone 18 Pro Max", "iPhone18,4": "iPhone 18",
        // iPad
        "iPad6,11": "iPad Pro 12.9", "iPad8,1": "iPad Pro 11", "iPad11,1": "iPad mini 5",
        "iPad13,1": "iPad Air 4", "iPad14,1": "iPad mini 6", "iPad14,3": "iPad Pro 11"
    ]
}
