import AVFoundation
import WebRTC

enum StreamState { case idle, connecting, streaming
    var label: String { switch self { case .idle: return "待命中：摄像头和麦克风未启用"; case .connecting: return "正在建立直播连接…"; case .streaming: return "正在直播" } }
}

final class WebRTCStreamer: NSObject, RTCPeerConnectionDelegate {
    var onStateChanged: ((StreamState) -> Void)?
    var onLocalCandidate: ((CandidateMessage) -> Void)?
    var onDiagnostic: ((String) -> Void)?   // 上报连接细节，便于远程排障

    private let factory: RTCPeerConnectionFactory
    private var peer: RTCPeerConnection?
    private var capturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var cameraPosition: AVCaptureDevice.Position = .front   // 默认前置
    private var pendingAnswerCompletion: ((String) -> Void)?
    private var answerSdpBase = ""                 // setLocalDescription 时的 SDP（不含 candidate）
    private struct CandidateEntry { let line: String; let mLineIndex: Int32 }
    private var gatheredCandidates: [CandidateEntry] = []  // 收集全部 candidate（localDescription 不自动更新）
    private var answerTimer: DispatchWorkItem?
    private var isStopping = false
    private var currentViewerID: String?
    private var currentIceServers: [IceServerConfiguration] = []
    private var restartWork: DispatchWorkItem?
    private var restartCount = 0
    private var isAudioOnly = false
    private let maxRestarts = 3
    var isActive: Bool { peer != nil }
    var audioOnlyActive: Bool { isAudioOnly }

    override init() {
        RTCInitializeSSL(); RTCPeerConnectionFactory.initialize()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
    }

    func start(viewerID: String, iceServers: [IceServerConfiguration], audioOnly: Bool = false) throws {
        guard peer == nil else { return }
        currentViewerID = viewerID; currentIceServers = iceServers; restartCount = 0
        isAudioOnly = audioOnly
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        onDiagnostic?("RTCIceServer built: count=\(configuration.iceServers.count), users=\(iceServers.map { $0.username.isEmpty ? "EMPTY" : "set(\($0.username.count))" }.joined(separator: ",")), creds=\(iceServers.map { $0.credential.isEmpty ? "EMPTY" : "set(\($0.credential.count))" }.joined(separator: ","))")
        peer = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        guard let peer else { throw StreamerError.unavailable }
        if audioOnly {
            onDiagnostic?("audio-only mode: microphone only, no camera")
            peer.add(factory.audioTrack(with: factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)), trackId: "audio"), streamIds: ["homecam"])
        } else {
            let source = factory.videoSource(); let camera = RTCCameraVideoCapturer(delegate: source)
            guard let device = preferredDevice() else { throw StreamerError.unavailable }
            guard let format = Self.bestFormat(for: device) else { throw StreamerError.unavailable }
            let maxFps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 12
            camera.startCapture(with: device, format: format, fps: min(Int(maxFps), 12))
            videoSource = source; capturer = camera
            peer.add(factory.videoTrack(with: source, trackId: "video"), streamIds: ["homecam"])
            peer.add(factory.audioTrack(with: factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)), trackId: "audio"), streamIds: ["homecam"])
        }
        onStateChanged?(.connecting)
        onDiagnostic?("peer created, capturing, gathering=\(Self.gatheringName(peer.iceGatheringState))")
    }

    // MARK: - 前后摄像头切换
    func switchCamera() {
        guard let capturer else { onDiagnostic?("switch skipped: no capturer"); return }
        let next: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == next }),
              let format = Self.bestFormat(for: device) else { onDiagnostic?("switch failed: no device"); return }
        let fps = min(Int(format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 12), 12)
        capturer.stopCapture { [weak self] in
            guard let self else { return }
            capturer.startCapture(with: device, format: format, fps: fps)
            self.cameraPosition = next
            self.onDiagnostic?("camera switched to \(next == .back ? "back" : "front")")
        }
    }

    private func preferredDevice() -> AVCaptureDevice? {
        RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == cameraPosition })
            ?? RTCCameraVideoCapturer.captureDevices().first
    }
    private static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        RTCCameraVideoCapturer.supportedFormats(for: device).max(by: { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width })
    }

    // MARK: - 网络切换后的重新协商
    // stasel WebRTC 的 ICE restart 在 non-trickle 下不可靠（offer 发出后对端不回 answer），
    // 改为请求服务端恢复会话 → 重建 peer 重新协商（更可靠）。
    func requestIceRestart(reason: String) {
        guard let viewerID = currentViewerID, peer != nil else { return }
        restartWork?.cancel()
        guard restartCount < maxRestarts else { onDiagnostic?("重连已达上限，停止"); stop("restart-limit"); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let peer = self.peer else { return }
            if peer.connectionState == .connected || peer.connectionState == .connecting { self.restartCount = 0; return }
            self.restartCount += 1
            self.onDiagnostic?("请求重建连接 #\(self.restartCount) (\(reason))")
            self.signalingRequestResume?()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    var signalingSendOffer: ((String, String) -> Void)?   // CameraAppModel 注入，避免循环依赖
    var signalingRequestResume: (() -> Void)?             // 请求服务端恢复会话

    // MARK: - 信令：non-trickle ICE（手机端做 offerer）
    // stasel WebRTC 在 answerer 角色下不会重新收集 TURN candidate；
    // 而在创建 peer 后（offerer）gathering 正常产生 srflx/relay。故改为手机发 offer。
    func createOffer(completion: @escaping (String) -> Void) {
        guard let peer else { onDiagnostic?("createOffer: no peer"); return }
        peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] offer, error in
            guard let self else { return }
            if let error { self.onDiagnostic?("createOffer error: \(error.localizedDescription)"); return }
            guard let offer else { self.onDiagnostic?("createOffer nil"); return }
            peer.setLocalDescription(offer) { [weak self] error in
                guard let self else { return }
                if let error { self.onDiagnostic?("setLocalOffer error: \(error.localizedDescription)"); return }
                self.answerSdpBase = offer.sdp
                self.pendingAnswerCompletion = completion
                self.onDiagnostic?("local offer set, gathered=\(self.gatheredCandidates.count)")
                self.scheduleAnswerSend(delay: 5)
            }
        }
    }

    /// 收到观看端的 answer（手机是 offerer）
    func receiveAnswer(_ sdp: String) {
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        peer?.setRemoteDescription(answer) { [weak self] error in
            guard let self else { return }
            if let error { self.onDiagnostic?("setRemoteAnswer error: \(error.localizedDescription)"); return }
            self.onDiagnostic?("remote answer set")
        }
    }

    // 保留：answerer 路径（当前不使用，防御性保留）
    func receiveOffer(_ sdp: String, completion: @escaping (String) -> Void) {
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        onDiagnostic?("offer received, setting remote description")
        peer?.setRemoteDescription(offer) { [weak self] error in
            guard let self else { return }
            if let error { self.onDiagnostic?("setRemoteDescription error: \(error.localizedDescription)"); return }
            guard let peer = self.peer else { self.onDiagnostic?("peer gone after offer"); return }
            self.onDiagnostic?("remote description set")
            peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] answer, error in
                guard let self else { return }
                if let error { self.onDiagnostic?("createAnswer error: \(error.localizedDescription)"); return }
                guard let answer else { self.onDiagnostic?("createAnswer nil"); return }
                peer.setLocalDescription(answer) { [weak self] error in
                    guard let self else { return }
                    if let error { self.onDiagnostic?("setLocalDescription error: \(error.localizedDescription)"); return }
                    self.onDiagnostic?("local description set, gathering=\(Self.gatheringName(peer.iceGatheringState))")
                    // localDescription.sdp 不含后续收集的 candidate，需自己组装
                    self.answerSdpBase = answer.sdp
                    self.pendingAnswerCompletion = completion
                    // answer 的 gathering 常被 stasel WebRTC 过早报 complete，TURN candidate
                    // 还没到齐。统一用可顺延的定时器：新 candidate 到达就再宽限几秒。
                    self.scheduleAnswerSend(delay: 5)
                }
            }
        }
    }

    /// 重置发送定时器：最后一次 candidate 后再等 delay 秒才发，保证 TURN candidate 到齐。
    private func scheduleAnswerSend(delay: Double) {
        guard pendingAnswerCompletion != nil else { return }
        answerTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendFullAnswer() }
        answerTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sendFullAnswer() {
        guard let completion = pendingAnswerCompletion else { return }
        pendingAnswerCompletion = nil
        answerTimer?.cancel(); answerTimer = nil
        // 把每个 candidate 插到它所属的 m= section 内（按 sdpMLineIndex），
        // 追加到 SDP 末尾属 session-level，Chrome 解析会失败。
        var lines = answerSdpBase.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let mPositions = lines.enumerated().compactMap { $0.element.hasPrefix("m=") ? $0.offset : nil }
        // 从后往前插入，避免前面的插入改变后面的行号
        for (section, mPos) in mPositions.enumerated().reversed() {
            let cands = gatheredCandidates.filter { Int($0.mLineIndex) == section || ($0.mLineIndex < 0 && section == 0) }.map { "a=" + $0.line }
            if !cands.isEmpty {
                let sectionEnd = mPositions.first(where: { $0 > mPos }) ?? lines.count
                lines.insert(contentsOf: cands, at: sectionEnd)
            }
        }
        let sdp = lines.joined(separator: "\r\n") + "\r\n"
        onDiagnostic?("sending sdp, chars=\(sdp.count), candidates=\(gatheredCandidates.count), base=\(answerSdpBase.count), mLines=\(mPositions.count)")
        completion(sdp)
    }

    // 仍兼容逐条 candidate（若对端先走 trickle）
    func receive(candidate: CandidateMessage) {
        peer?.add(RTCIceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid))
    }

    func stop(_ reason: String = "unknown", notifyState: Bool = true) {
        guard !isStopping else { return }
        onDiagnostic?("STOP reason=\(reason)")
        isStopping = true
        capturer?.stopCapture(); capturer = nil; videoSource = nil
        peer?.close(); peer = nil
        pendingAnswerCompletion = nil; answerSdpBase = ""; gatheredCandidates.removeAll()
        answerTimer?.cancel(); answerTimer = nil
        restartWork?.cancel(); restartWork = nil; restartCount = 0
        currentViewerID = nil
        if notifyState { onStateChanged?(.idle) }
        isStopping = false
    }

    // MARK: - RTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let typ = candidate.sdp.components(separatedBy: " typ ").last ?? "?"
        onDiagnostic?("local candidate: \(typ)")
        gatheredCandidates.append(CandidateEntry(line: candidate.sdp, mLineIndex: candidate.sdpMLineIndex))
        // 每收到一个候选就顺延发送，等 TURN relay/srflx 到齐（stasel 的 gathering 会过早 complete）
        if pendingAnswerCompletion != nil { scheduleAnswerSend(delay: 3) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onDiagnostic?("peer state: \(newState.rawValue)")
        switch newState {
        case .connected:
            restartCount = 0; restartWork?.cancel(); restartWork = nil
            onStateChanged?(.streaming)
        case .disconnected, .failed:
            // 网络切换（WiFi↔蜂窝）会导致短暂断开，尝试 ICE restart 恢复；超限才停
            requestIceRestart(reason: "peer-\(newState.rawValue)")
        case .closed:
            stop("peer-5")
        default:
            break
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceGatheringState) {
        onDiagnostic?("gathering state: \(Self.gatheringName(stateChanged))")
        if stateChanged == .complete { scheduleAnswerSend(delay: 3) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onDiagnostic?("ice state changed")
    }
    private static func gatheringName(_ state: RTCIceGatheringState) -> String {
        switch state { case .new: return "new"; case .gathering: return "gathering"; case .complete: return "complete"; @unknown default: return "?" }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
enum StreamerError: LocalizedError { case unavailable
    var errorDescription: String? { "无法打开此设备的摄像头。" }
}
