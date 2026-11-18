import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class CameraAppModel: ObservableObject {
    @Published private(set) var statusText = "未配对"
    @Published private(set) var isStreaming = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPaired = false
    @Published private(set) var deviceName = UIDevice.current.name
    @Published private(set) var serverURL = URL(string: "https://")!

    private let store = DeviceStore()
    private var signaling: SignalingClient?
    private let stream = WebRTCStreamer()
    private var isActive = true

    init() {
        if let credentials = store.load() { configure(credentials) }
        stream.onStateChanged = { [weak self] state in Task { @MainActor in
            self?.isStreaming = state == .streaming
            self?.statusText = state.label
        }}
        stream.onLocalCandidate = { [weak self] candidate in Task { @MainActor in self?.signaling?.sendCandidate(candidate) } }
    }

    func pair(serverURL rawURL: String, name: String, code: String) {
        guard let url = Self.normalizedURL(rawURL) else { errorMessage = "请输入有效的 HTTPS 地址"; return }
        isWorking = true; errorMessage = nil
        Task {
            do {
                let credentials = try await PairingAPI.pair(serverURL: url, name: name, code: code)
                store.save(credentials); configure(credentials)
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    func disconnect() {
        stream.stop(); signaling?.disconnect(); signaling = nil; store.clear()
        isPaired = false; statusText = "未配对"; isStreaming = false
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        isActive = phase == .active
        if !isActive { applicationMovedToBackground() }
    }

    func applicationMovedToBackground() {
        guard isStreaming else { return }
        stream.stop(); signaling?.sendStopped(); statusText = "已进入后台，直播已停止"
    }

    private func configure(_ credentials: DeviceCredentials) {
        deviceName = credentials.name; serverURL = credentials.serverURL; isPaired = true; statusText = "正在连接待命服务…"
        let client = SignalingClient(credentials: credentials)
        client.onConnected = { [weak self] in Task { @MainActor in self?.statusText = "待命中：摄像头和麦克风未启用" } }
        client.onReconnected = { [weak self] in Task { @MainActor in
            guard let self, self.isPaired else { return }
            self.statusText = self.isStreaming ? "连接已恢复，正在直播" : "连接已恢复，待命中：摄像头和麦克风未启用"
        }}
        client.onWatchStart = { [weak self] viewerID, iceServers in Task { @MainActor in self?.startStream(viewerID: viewerID, iceServers: iceServers) } }
        client.onSignal = { [weak self] signal in Task { @MainActor in self?.receive(signal: signal) } }
        client.onWatchStop = { [weak self] in Task { @MainActor in self?.stream.stop() } }
        client.onError = { [weak self] message in Task { @MainActor in self?.errorMessage = message } }
        client.onRemoved = { [weak self] in Task { @MainActor in
            guard let self else { return }
            self.stream.stop(); client.disconnect(); self.signaling = nil; self.store.clear()
            self.isPaired = false; self.isStreaming = false; self.statusText = "未配对"
            self.errorMessage = "此设备已被观看端删除，请重新配对。"
        }}
        signaling = client; client.connect()
    }

    private func startStream(viewerID: String, iceServers: [IceServerConfiguration]) {
        Task {
            do {
                // iOS cannot reliably capture in the background; decline instead of
                // leaving the viewer stuck in a "connecting" state.
                guard isActive else { signaling?.sendStopped(); return }
                try await requestCapturePermissions()
                try stream.start(viewerID: viewerID, iceServers: iceServers)
                signaling?.acceptWatch(viewerID: viewerID)
            } catch { errorMessage = error.localizedDescription; signaling?.sendStopped() }
        }
    }

    private func receive(signal: SignalingMessage) {
        switch signal.kind {
        case .offer: stream.receiveOffer(signal.sdp ?? "") { [weak self] answer in self?.signaling?.sendAnswer(answer) }
        case .candidate: if let candidate = signal.candidate { stream.receive(candidate: candidate) }
        case .answer: break
        }
    }

    private func requestCapturePermissions() async throws {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard camera && microphone else { throw CameraError.permissionDenied }
    }

    private static func normalizedURL(_ value: String) -> URL? {
        let candidate = value.hasPrefix("http") ? value : "https://\(value)"
        guard let url = URL(string: candidate), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

enum CameraError: LocalizedError { case permissionDenied
    var errorDescription: String? { "需要允许相机和麦克风权限后才能开始观看。" }
}
