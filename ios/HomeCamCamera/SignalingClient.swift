import Foundation
import Network
import SocketIO

struct IceServerConfiguration: Codable { let urls: [String]; let username: String; let credential: String }
struct CandidateMessage { let sdp: String; let sdpMid: String; let sdpMLineIndex: Int32 }
struct SignalingMessage {
    enum Kind { case offer, answer, candidate }
    let kind: Kind; let sdp: String?; let candidate: CandidateMessage?
}

final class SignalingClient {
    var onConnected: (() -> Void)?; var onReconnected: (() -> Void)?
    var onWatchStart: ((String, [IceServerConfiguration]) -> Void)?
    var onWatchStop: (() -> Void)?; var onSignal: ((SignalingMessage) -> Void)?; var onError: ((String) -> Void)?
    var onSocketLost: (() -> Void)?   // socket 断开（网络切换），与"服务端要求停止"区分
    var onRemoved: (() -> Void)?
    var onSwitchCamera: (() -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private let credentials: DeviceCredentials; private let manager: SocketManager; private let socket: SocketIOClient
    private var viewerID: String?
    private var pendingCandidates: [CandidateMessage] = []
    private var hasConnectedOnce = false
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "homecam.net.monitor")
    private var lastInterfaces: Set<String> = []

    init(credentials: DeviceCredentials) {
        self.credentials = credentials
        manager = SocketManager(socketURL: credentials.serverURL, config: [.log(false), .compress, .connectParams(["deviceId": credentials.deviceID, "deviceSecret": credentials.deviceSecret]),
                                                               .reconnects(true), .reconnectAttempts(-1), .reconnectWait(1), .reconnectWaitMax(3)])
        socket = manager.defaultSocket
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            if self.hasConnectedOnce {
                // A reconnect gets a new Socket.IO id, so any previous viewer session is stale.
                self.pendingCandidates.removeAll()
                self.onReconnected?()
            } else {
                self.hasConnectedOnce = true
                self.onConnected?()
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            guard let self else { return }
            // 网络切换（WiFi↔蜂窝）会短暂断线：保留 viewerID 与会话，等重连后恢复。
            // 这里不能走 onWatchStop，否则会上报 idle 让服务端释放会话。
            self.pendingCandidates.removeAll()
            self.onSocketLost?()
        }
        socket.on(clientEvent: .error) { [weak self] data, _ in self?.onError?(data.first.map { "连接错误：\($0)" } ?? "无法连接服务器") }
        socket.on("watch:start") { [weak self] data, _ in self?.handleWatchStart(data) }
        socket.on("watch:stop") { [weak self] _, _ in
            guard let self else { return }
            self.viewerID = nil
            self.pendingCandidates.removeAll()
            self.onWatchStop?()
        }
        socket.on("watch:resumed") { [weak self] data, _ in self?.handleWatchResumed(data) }
        socket.on("signal") { [weak self] data, _ in self?.handleSignal(data) }
        socket.on("device:removed") { [weak self] _, _ in self?.onRemoved?() }
        socket.on("camera:switch") { [weak self] _, _ in self?.onSwitchCamera?() }
        // 网络接口变化（WiFi↔蜂窝）时立即重连信令，不等 Socket.IO 心跳超时（约 45 秒）
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = Set(path.availableInterfaces.map(\.name))
            let changed = !self.lastInterfaces.isEmpty && interfaces != self.lastInterfaces
            self.lastInterfaces = interfaces
            guard changed else { return }
            DispatchQueue.main.async { self.forceReconnect() }
        }
        pathMonitor.start(queue: monitorQueue)
    }
    /// 强制断开并重连（网络接口已变，旧的 TCP 连接多半已失效）
    private func forceReconnect() {
        guard socket.status == .connected || socket.status == .connecting else { return }
        onDiagnostic?("网络接口变化，重连信令")
        socket.disconnect()
        socket.connect()
    }
    func connect() { socket.connect() }
    func disconnect() { socket.disconnect() }
    func acceptWatch(viewerID: String) {
        self.viewerID = viewerID
        emit("watch:accepted", ["viewerId": viewerID])
        // ICE gathering starts as soon as the peer connection is created, which can be
        // before acceptWatch sets viewerID. Flush anything collected in the meantime.
        let buffered = pendingCandidates
        pendingCandidates.removeAll()
        for candidate in buffered { sendCandidate(candidate) }
    }
    func sendStopped() { emit("stream:state", ["state": "idle"]) }
    func sendState(_ state: String) { emit("stream:state", ["state": state]) }
    func sendDiagnostic(_ message: String) {
        emit("device:diagnostic", ["deviceId": credentials.deviceID, "message": message])
    }
    /// socket 重连后请求恢复当前观看会话（网络切换导致）
    func requestResume() {
        onDiagnostic?("请求恢复会话")
        emit("watch:resume", ["deviceId": credentials.deviceID])
    }
    func sendOffer(_ sdp: String) { onDiagnostic?("sending offer, sdp chars=\(sdp.count)"); send(data: ["type": "offer", "sdp": sdp]) }
    func sendAnswer(_ sdp: String) { send(data: ["type": "answer", "sdp": sdp]) }
    func sendCandidate(_ candidate: CandidateMessage) {
        guard viewerID != nil else { pendingCandidates.append(candidate); return }
        send(data: ["type": "candidate", "candidate": ["sdpMid": candidate.sdpMid, "sdpMLineIndex": candidate.sdpMLineIndex, "candidate": candidate.sdp]])
    }

    /// 未连接时 emit 会抛错，统一拦截
    private func emit(_ event: String, _ data: [String: Any]) {
        guard socket.status == .connected else { return }
        socket.emit(event, data)
    }
    private func send(data: [String: Any]) { guard let viewerID else { return }; emit("signal", ["targetId": viewerID, "data": data]) }
    private func handleWatchStart(_ values: [Any]) {
        guard let message = values.first as? [String: Any], let viewerID = message["viewerId"] as? String else { return }
        // Socket.IO Swift 反序列化可能是 NSArray/NSDictionary 桥接，直接 as? [String] 或
        // as? [[String: Any]] 会失败导致 TURN 配置丢失。逐层兼容解析。
        // 优先用配对响应持久化下来的配置（JSONSerialization 解析，类型可靠）；
        // watch:start 里带的作为老版本兜底。
        var ice = credentials.iceServers ?? []
        if ice.isEmpty {
            let rawServers = Self.anyArray(message["iceServers"])
            ice = rawServers.compactMap { item -> IceServerConfiguration? in
                guard let dict = item as? [String: Any] ?? (item as? NSDictionary) as? [String: Any] else { return nil }
                let urls = Self.stringArray(dict["urls"])
                guard !urls.isEmpty else { return nil }
                return IceServerConfiguration(urls: urls,
                                              username: dict["username"] as? String ?? "",
                                              credential: dict["credential"] as? String ?? "")
            }
        }
        onDiagnostic?("ICE parsed: \(ice.count) servers, urls=\(ice.map { $0.urls.joined(separator: ",") }.joined(separator: " | "))")
        onWatchStart?(viewerID, ice)
    }
    /// 服务端确认会话可恢复：重建流并重新协商
    private func handleWatchResumed(_ values: [Any]) {
        guard let message = values.first as? [String: Any], let viewerID = message["viewerId"] as? String else { return }
        self.viewerID = viewerID
        onDiagnostic?("会话已恢复，重新协商")
        let ice = credentials.iceServers ?? []
        onWatchStart?(viewerID, ice)
    }
    private static func anyArray(_ value: Any?) -> [Any] {        if let arr = value as? [Any] { return arr }
        if let arr = value as? NSArray { return arr as? [Any] ?? [] }
        return []
    }
    private static func stringArray(_ value: Any?) -> [String] {
        if let str = value as? String { return [str] }
        if let arr = value as? [String] { return arr }
        if let arr = value as? [Any] { return arr.compactMap { $0 as? String } }
        if let arr = value as? NSArray { return arr.compactMap { $0 as? String } }
        return []
    }
    private func handleSignal(_ values: [Any]) {
        guard let envelope = values.first as? [String: Any], let payload = envelope["data"] as? [String: Any], let type = payload["type"] as? String else { return }
        if type == "offer", let sdp = payload["sdp"] as? String { onSignal?(SignalingMessage(kind: .offer, sdp: sdp, candidate: nil)) }
        if type == "answer", let sdp = payload["sdp"] as? String { onSignal?(SignalingMessage(kind: .answer, sdp: sdp, candidate: nil)) }
        if type == "candidate", let item = payload["candidate"] as? [String: Any], let sdp = item["candidate"] as? String {
            onSignal?(SignalingMessage(kind: .candidate, sdp: nil, candidate: CandidateMessage(sdp: sdp, sdpMid: item["sdpMid"] as? String ?? "0", sdpMLineIndex: Int32(item["sdpMLineIndex"] as? Int ?? 0))))
        }
    }
}
