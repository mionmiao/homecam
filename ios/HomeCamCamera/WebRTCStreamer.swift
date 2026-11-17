import AVFoundation
import WebRTC

enum StreamState { case idle, connecting, streaming
    var label: String { switch self { case .idle: return "待命中：摄像头和麦克风未启用"; case .connecting: return "正在建立直播连接…"; case .streaming: return "正在直播" } }
}

final class WebRTCStreamer: NSObject, RTCPeerConnectionDelegate {
    var onStateChanged: ((StreamState) -> Void)?; var onLocalCandidate: ((CandidateMessage) -> Void)?
    private let factory: RTCPeerConnectionFactory
    private var peer: RTCPeerConnection?; private var capturer: RTCCameraVideoCapturer?; private var videoSource: RTCVideoSource?

    override init() {
        RTCInitializeSSL(); RTCPeerConnectionFactory.initialize()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
    }
    func start(viewerID: String, iceServers: [IceServerConfiguration]) throws {
        guard peer == nil else { return }
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        peer = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        guard let peer else { throw StreamerError.unavailable }
        let source = factory.videoSource(); let camera = RTCCameraVideoCapturer(delegate: source)
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .back }) ?? RTCCameraVideoCapturer.captureDevices().first else { throw StreamerError.unavailable }
        guard let format = RTCCameraVideoCapturer.supportedFormats(for: device).max(by: { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width }) else { throw StreamerError.unavailable }
        let maxFps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 12
        camera.startCapture(with: device, format: format, fps: min(Int(maxFps), 12))
        videoSource = source; capturer = camera
        peer.add(factory.videoTrack(with: source, trackId: "video"), streamIds: ["homecam"])
        peer.add(factory.audioTrack(with: factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)), trackId: "audio"), streamIds: ["homecam"])
        onStateChanged?(.connecting)
    }
    func receiveOffer(_ sdp: String, completion: @escaping (String) -> Void) {
        let offer = RTCSessionDescription(type: .offer, sdp: sdp)
        peer?.setRemoteDescription(offer) { [weak self] error in
            guard error == nil, let self, let peer = self.peer else { return }
            peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                guard let answer, error == nil else { return }
                peer.setLocalDescription(answer) { error in if error == nil { completion(answer.sdp) } }
            }
        }
    }
    func receive(candidate: CandidateMessage) { peer?.add(RTCIceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)) }
    func stop() { capturer?.stopCapture(); capturer = nil; videoSource = nil; peer?.close(); peer = nil; onStateChanged?(.idle) }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { onLocalCandidate?(CandidateMessage(sdp: candidate.sdp, sdpMid: candidate.sdpMid ?? "0", sdpMLineIndex: candidate.sdpMLineIndex)) }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) { if newState == .connected { onStateChanged?(.streaming) }; if newState == .failed || newState == .closed { stop() } }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {} ; func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {} ; func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {} ; func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {} ; func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {} ; func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {} ; func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {} ; func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
enum StreamerError: LocalizedError { case unavailable; var errorDescription: String? { "无法打开此设备的摄像头。" } }
