import Foundation
import SocketIO

struct IceServerConfiguration { let urls: [String]; let username: String; let credential: String }
struct CandidateMessage { let sdp: String; let sdpMid: String; let sdpMLineIndex: Int32 }
struct SignalingMessage {
    enum Kind { case offer, answer, candidate }
    let kind: Kind; let sdp: String?; let candidate: CandidateMessage?
}

final class SignalingClient {
    var onConnected: (() -> Void)?; var onReconnected: (() -> Void)?
    var onWatchStart: ((String, [IceServerConfiguration]) -> Void)?
    var onWatchStop: (() -> Void)?; var onSignal: ((SignalingMessage) -> Void)?; var onError: ((String) -> Void)?
    var onRemoved: (() -> Void)?
    var onSwitchCamera: (() -> Void)?
    private let credentials: DeviceCredentials; private let manager: SocketManager; private let socket: SocketIOClient
    private var viewerID: String?
    private var pendingCandidates: [CandidateMessage] = []
    private var hasConnectedOnce = false

    init(credentials: DeviceCredentials) {
        self.credentials = credentials
        manager = SocketManager(socketURL: credentials.serverURL, config: [.log(false), .compress, .connectParams(["deviceId": credentials.deviceID, "deviceSecret": credentials.deviceSecret])])
        socket = manager.defaultSocket
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            if self.hasConnectedOnce {
                // A reconnect gets a new Socket.IO id, so any previous viewer session is stale.
                self.viewerID = nil
                self.pendingCandidates.removeAll()
                self.onReconnected?()
            } else {
                self.hasConnectedOnce = true
                self.onConnected?()
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            guard let self else { return }
            self.viewerID = nil
            self.pendingCandidates.removeAll()
            self.onWatchStop?()
        }
        socket.on(clientEvent: .error) { [weak self] data, _ in self?.onError?(data.first.map { "连接错误：\($0)" } ?? "无法连接服务器") }
        socket.on("watch:start") { [weak self] data, _ in self?.handleWatchStart(data) }
        socket.on("watch:stop") { [weak self] _, _ in
            guard let self else { return }
            self.viewerID = nil
            self.pendingCandidates.removeAll()
            self.onWatchStop?()
        }
        socket.on("signal") { [weak self] data, _ in self?.handleSignal(data) }
        socket.on("device:removed") { [weak self] _, _ in self?.onRemoved?() }
        socket.on("camera:switch") { [weak self] _, _ in self?.onSwitchCamera?() }
    }
    func connect() { socket.connect() }
    func disconnect() { socket.disconnect() }
    func acceptWatch(viewerID: String) {
        self.viewerID = viewerID
        socket.emit("watch:accepted", ["viewerId": viewerID])
        // ICE gathering starts as soon as the peer connection is created, which can be
        // before acceptWatch sets viewerID. Flush anything collected in the meantime.
        let buffered = pendingCandidates
        pendingCandidates.removeAll()
        for candidate in buffered { sendCandidate(candidate) }
    }
    func sendStopped() { socket.emit("stream:state", ["state": "idle"]) }
    func sendState(_ state: String) { socket.emit("stream:state", ["state": state]) }
    func sendDiagnostic(_ message: String) { socket.emit("device:diagnostic", ["deviceId": credentials.deviceID, "message": message]) }
    func sendAnswer(_ sdp: String) { send(data: ["type": "answer", "sdp": sdp]) }
    func sendCandidate(_ candidate: CandidateMessage) {
        guard viewerID != nil else { pendingCandidates.append(candidate); return }
        send(data: ["type": "candidate", "candidate": ["sdpMid": candidate.sdpMid, "sdpMLineIndex": candidate.sdpMLineIndex, "candidate": candidate.sdp]])
    }

    private func send(data: [String: Any]) { guard let viewerID else { return }; socket.emit("signal", ["targetId": viewerID, "data": data]) }
    private func handleWatchStart(_ values: [Any]) {
        guard let message = values.first as? [String: Any], let viewerID = message["viewerId"] as? String else { return }
        let ice = (message["iceServers"] as? [[String: Any]] ?? []).compactMap { item -> IceServerConfiguration? in
            let urls = (item["urls"] as? [String]) ?? (item["urls"] as? String).map { [$0] } ?? []
            return urls.isEmpty ? nil : IceServerConfiguration(urls: urls, username: item["username"] as? String ?? "", credential: item["credential"] as? String ?? "")
        }
        onWatchStart?(viewerID, ice)
    }
    private func handleSignal(_ values: [Any]) {
        guard let envelope = values.first as? [String: Any], let payload = envelope["data"] as? [String: Any], let type = payload["type"] as? String else { return }
        if type == "offer", let sdp = payload["sdp"] as? String { onSignal?(SignalingMessage(kind: .offer, sdp: sdp, candidate: nil)) }
        if type == "candidate", let item = payload["candidate"] as? [String: Any], let sdp = item["candidate"] as? String {
            onSignal?(SignalingMessage(kind: .candidate, sdp: nil, candidate: CandidateMessage(sdp: sdp, sdpMid: item["sdpMid"] as? String ?? "0", sdpMLineIndex: Int32(item["sdpMLineIndex"] as? Int ?? 0))))
        }
    }
}
