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
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var pendingAnswerCompletion: ((String) -> Void)?
    private var answerSdpBase = ""                 // setLocalDescription 时的 SDP（不含 candidate）
    private var gatheredCandidates: [String] = []  // 自己收集的全部 candidate（localDescription 不会自动更新）
    private var answerTimer: DispatchWorkItem?
    private var isStopping = false

    override init() {
        RTCInitializeSSL(); RTCPeerConnectionFactory.initialize()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
    }

    func start(viewerID: String, iceServers: [IceServerConfiguration]) throws {
        guard peer == nil else { return }
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        onDiagnostic?("RTCIceServer built: count=\(configuration.iceServers.count), users=\(iceServers.map { $0.username.isEmpty ? "EMPTY" : "set(\($0.username.count))" }.joined(separator: ",")), creds=\(iceServers.map { $0.credential.isEmpty ? "EMPTY" : "set(\($0.credential.count))" }.joined(separator: ","))")
        peer = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        guard let peer else { throw StreamerError.unavailable }
        let source = factory.videoSource(); let camera = RTCCameraVideoCapturer(delegate: source)
        guard let device = preferredDevice() else { throw StreamerError.unavailable }
        guard let format = Self.bestFormat(for: device) else { throw StreamerError.unavailable }
        let maxFps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 12
        camera.startCapture(with: device, format: format, fps: min(Int(maxFps), 12))
        videoSource = source; capturer = camera
        peer.add(factory.videoTrack(with: source, trackId: "video"), streamIds: ["homecam"])
        peer.add(factory.audioTrack(with: factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)), trackId: "audio"), streamIds: ["homecam"])
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

    // MARK: - 信令：non-trickle ICE
    // 等 ICE 收集完成后再回 answer，candidate 直接内嵌 SDP，避免逐条转发的时序问题。
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
        var sdp = answerSdpBase
        // 把收集到的 candidate 插到第一个 media section 的 a= 行里。
        // 放在 m= 行之前不合法，追加到末尾（SDP 末尾）浏览器也能解析为 session-level candidate。
        if !gatheredCandidates.isEmpty {
            if !sdp.hasSuffix("\n") { sdp += "\r\n" }
            sdp += gatheredCandidates.joined(separator: "\r\n") + "\r\n"
        }
        onDiagnostic?("sending answer, sdp chars=\(sdp.count), candidates=\(gatheredCandidates.count), base=\(answerSdpBase.count)")
        completion(sdp)
    }

    // 仍兼容逐条 candidate（若对端先走 trickle）
    func receive(candidate: CandidateMessage) {
        peer?.add(RTCIceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid))
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        capturer?.stopCapture(); capturer = nil; videoSource = nil
        peer?.close(); peer = nil
        pendingAnswerCompletion = nil; answerSdpBase = ""; gatheredCandidates.removeAll()
        answerTimer?.cancel(); answerTimer = nil
        onStateChanged?(.idle)
        isStopping = false
    }

    // MARK: - RTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let typ = candidate.sdp.components(separatedBy: " typ ").last ?? "?"
        onDiagnostic?("local candidate: \(typ)")
        gatheredCandidates.append("a=" + candidate.sdp)
        // 每收到一个候选就顺延发送，等 TURN relay/srflx 到齐（stasel 的 gathering 会过早 complete）
        if pendingAnswerCompletion != nil { scheduleAnswerSend(delay: 3) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onDiagnostic?("peer state: \(newState.rawValue)")
        if newState == .connected { onStateChanged?(.streaming) }
        if newState == .failed || newState == .closed { stop() }
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
