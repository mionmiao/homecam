import AVFoundation
import Foundation
import SwiftUI
import UIKit

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
    private let photoUploader = PhotoUploader()
    private var isActive = true
    private var needsForegroundCapture = true  // 冷启动/真正从后台回来时拍一次
    private var backgroundStopWork: DispatchWorkItem?
    private var resignActiveAt: Date?           // 失去活跃的时间，用于判断是否锁屏/切后台
    private let captureDelayThreshold: TimeInterval = 10  // 离开超过 10 秒才算锁屏/切后台

    init() {
        if let credentials = store.load() { configure(credentials) }
        // 锁屏/解锁不一定会经过 scenePhase .background，用通知更可靠：
        // 失去活跃时记时间，重新活跃时若离开超过阈值（锁屏、切后台）则拍照。
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resignActiveAt = Date()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            guard let at = self.resignActiveAt else { return }
            self.resignActiveAt = nil
            let away = Date().timeIntervalSince(at)
            guard away > self.captureDelayThreshold else { return }   // 下拉状态栏等短暂失焦不拍
            self.needsForegroundCapture = true
            self.capturePhotosIfNeeded()
        }
        stream.signalingSendOffer = { [weak self] sdp, _ in
            Task { @MainActor in self?.signaling?.sendOffer(sdp) }
        }
        stream.signalingRequestResume = { [weak self] in
            Task { @MainActor in self?.signaling?.requestResume() }
        }
        stream.onStateChanged = { [weak self] state in Task { @MainActor in
            guard let self else { return }
            self.isStreaming = state == .streaming
            self.statusText = state.label
            // 把采集端状态实时上报，观看端可据此判断卡在哪一步
            self.signaling?.sendState(state == .streaming ? "streaming" : state == .connecting ? "connecting" : "idle")
        }}
        stream.onLocalCandidate = { [weak self] candidate in Task { @MainActor in self?.signaling?.sendCandidate(candidate) } }
        stream.onDiagnostic = { [weak self] message in Task { @MainActor in self?.signaling?.sendDiagnostic(message) } }
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
        stream.stop("disconnect"); signaling?.disconnect(); signaling = nil; store.clear()
        isPaired = false; statusText = "未配对"; isStreaming = false
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            // 回到前台：取消待执行的后台停止（下拉状态栏/快速切换不会杀直播）
            backgroundStopWork?.cancel(); backgroundStopWork = nil
            // 只在冷启动或真正从后台回来时拍照；.inactive 往返（下拉状态栏）不拍
            capturePhotosIfNeeded()
        case .inactive:
            // 下拉状态栏、控制中心、来电等短暂失焦：仅标记，不停止直播，也不拍照
            isActive = false
        case .background:
            isActive = false
            needsForegroundCapture = true  // 真正进后台，下次回前台要拍
            // 真正切后台：给几秒宽限，期间回前台则取消；持续后台才停止采集
            guard isStreaming, backgroundStopWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isActive else { return }
                self.applicationMovedToBackground()
            }
            backgroundStopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        @unknown default:
            break
        }
    }

    /// 冷启动（onAppear）或真正从后台回前台（scenePhase .active）时调一次；内部去重。
    func capturePhotosIfNeeded() {
        guard needsForegroundCapture, isActive else { return }
        needsForegroundCapture = false
        // 稍作延迟，等 App 完全回到前台，避免与界面恢复/直播抢占相机
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.photoUploader.captureAndUpload { [weak self] msg in
                Task { @MainActor in self?.signaling?.sendDiagnostic("拍照: " + msg) }
            }
        }
    }

    func applicationMovedToBackground() {
        backgroundStopWork?.cancel(); backgroundStopWork = nil
        guard isStreaming else { return }
        stream.stop("background"); signaling?.sendStopped(); statusText = "已进入后台，直播已停止"
    }

    private func configure(_ credentials: DeviceCredentials) {
        deviceName = credentials.name; serverURL = credentials.serverURL; isPaired = true; statusText = "正在连接待命服务…"
        let client = SignalingClient(credentials: credentials)
        client.onConnected = { [weak self] in Task { @MainActor in self?.statusText = "待命中：摄像头和麦克风未启用" } }
        client.onReconnected = { [weak self] in Task { @MainActor in
            guard let self, self.isPaired else { return }
            self.statusText = self.isStreaming ? "连接已恢复，正在直播" : "连接已恢复，待命中：摄像头和麦克风未启用"
            // 服务端在设备重连时会主动下发 watch:resumed 触发重新协商，此处无需重复请求
        }}
        client.onWatchStart = { [weak self] viewerID, iceServers in Task { @MainActor in self?.startStream(viewerID: viewerID, iceServers: iceServers) } }
        client.onSignal = { [weak self] signal in Task { @MainActor in self?.receive(signal: signal) } }
        client.onWatchStop = { [weak self] in Task { @MainActor in
            guard let self, self.isStreaming else { return }  // 已停止时不再 stop，避免 idle 上报死循环
            self.stream.stop("watch-stop")
        }}
        client.onSocketLost = { [weak self] in Task { @MainActor in
            // 网络断开（切换 WiFi/蜂窝）：停掉旧 peer 但不上报 idle，保留会话等待重连恢复
            guard let self, self.isStreaming else { return }
            self.stream.stop("socket-lost", notifyState: false)
            self.isStreaming = false
            self.statusText = "网络中断，正在重连…"
        }}
        client.onError = { [weak self] message in Task { @MainActor in self?.errorMessage = message } }
        client.onSwitchCamera = { [weak self] in Task { @MainActor in self?.stream.switchCamera() } }
        client.onDiagnostic = { [weak self] message in Task { @MainActor in self?.signaling?.sendDiagnostic(message) } }
        client.onRemoved = { [weak self] in Task { @MainActor in
            guard let self else { return }
            self.stream.stop("removed"); client.disconnect(); self.signaling = nil; self.store.clear()
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
                // 网络切换后重建：先停掉旧 peer（不上报 idle，避免服务端释放会话），再新建重新协商
                if self.stream.isActive { self.stream.stop("rebuild", notifyState: false) }
                try stream.start(viewerID: viewerID, iceServers: iceServers)
                // 手机做 offerer：先告诉观看端已接受，等 candidate 收齐后发 offer
                signaling?.acceptWatch(viewerID: viewerID)
                stream.createOffer { [weak self] sdp in self?.signaling?.sendOffer(sdp) }
            } catch { errorMessage = error.localizedDescription; signaling?.sendStopped() }
        }
    }

    private func receive(signal: SignalingMessage) {
        switch signal.kind {
        case .offer: stream.receiveOffer(signal.sdp ?? "") { [weak self] answer in self?.signaling?.sendAnswer(answer) }
        case .candidate: if let candidate = signal.candidate { stream.receive(candidate: candidate) }
        case .answer: stream.receiveAnswer(signal.sdp ?? "")
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
