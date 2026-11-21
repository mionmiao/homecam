package com.homecam.camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoCapturer
import org.webrtc.VideoSource

/** WebRTC offerer：non-trickle，等 ICE 收集完成后把 candidate 内嵌进 SDP 一次性发出。 */
class WebRtcStreamer(private val context: Context, private val callbacks: Callbacks) {
    enum class State { IDLE, CONNECTING, STREAMING }

    interface Callbacks {
        fun onState(state: State)
        fun onDiagnostic(message: String)
        fun onLocalOffer(sdp: String)
        fun onPeerUnstable(reason: String)
    }

    private data class CandidateEntry(val sdp: String, val mLineIndex: Int)

    private val handler = Handler(Looper.getMainLooper())
    private var factory: PeerConnectionFactory? = null
    private var egl: EglBase? = null
    private var peer: PeerConnection? = null
    private var capturer: VideoCapturer? = null
    private var videoSource: VideoSource? = null
    private var audioSource: org.webrtc.AudioSource? = null
    private var helper: SurfaceTextureHelper? = null
    private var frontCamera = true
    private var state = State.IDLE
    private var stopping = false

    private var baseSdp = ""
    private var sendingOffer = false
    private var sendRunnable: Runnable? = null
    private val localCandidates = mutableListOf<CandidateEntry>()
    private val remoteCandidates = mutableListOf<IceCandidate>()
    private var remoteReady = false

    val isActive: Boolean get() = peer != null

    private fun ensureFactory(): PeerConnectionFactory {
        factory?.let { return it }
        try {
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions()
            )
        } catch (_: IllegalStateException) {
            // 已经初始化过
        }
        egl = EglBase.create()
        val f = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl!!.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl!!.eglBaseContext))
            .createPeerConnectionFactory()
        factory = f
        return f
    }

    @Synchronized
    fun start(iceSpecs: List<IceServerSpec>) {
        if (peer != null) return
        stopping = false
        remoteReady = false
        localCandidates.clear()
        remoteCandidates.clear()
        baseSdp = ""
        sendingOffer = false
        val f = ensureFactory()

        val servers = iceSpecs.flatMap { spec ->
            spec.urls.mapNotNull { url ->
                if (url.isBlank()) null else {
                    val builder = PeerConnection.IceServer.builder(url)
                    if (spec.username.isNotBlank()) builder.setUsername(spec.username)
                    if (spec.credential.isNotBlank()) builder.setPassword(spec.credential)
                    builder.createIceServer()
                }
            }
        }
        callbacks.onDiagnostic("ICE servers built: ${servers.size} (${servers.flatMap { it.urls }.distinct().size} urls)")
        val config = PeerConnection.RTCConfiguration(servers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        }
        peer = f.createPeerConnection(config, object : PeerConnection.Observer {
            override fun onIceCandidate(candidate: IceCandidate) {
                val type = candidate.sdp.substringAfter(" typ ", "?")
                callbacks.onDiagnostic("local candidate: $type")
                localCandidates.add(CandidateEntry(candidate.sdp, candidate.sdpMLineIndex))
                if (sendingOffer) scheduleOfferSend(2000)
            }

            override fun onConnectionChange(state: PeerConnection.PeerConnectionState) {
                callbacks.onDiagnostic("peer state: ${state.name}")
                when (state) {
                    PeerConnection.PeerConnectionState.CONNECTED -> {
                        setState(State.STREAMING)
                    }
                    PeerConnection.PeerConnectionState.DISCONNECTED,
                    PeerConnection.PeerConnectionState.FAILED -> callbacks.onPeerUnstable(state.name)
                    else -> Unit
                }
            }

            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {
                callbacks.onDiagnostic("gathering: ${state.name}")
                if (state == PeerConnection.IceGatheringState.COMPLETE && sendingOffer) scheduleOfferSend(500)
            }

            override fun onSignalingChange(state: PeerConnection.SignalingState) {}
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {}
            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceCandidatesRemoved(candidates: Array<IceCandidate>) {}
            override fun onAddStream(stream: MediaStream) {}
            override fun onRemoveStream(stream: MediaStream) {}
            override fun onDataChannel(channel: DataChannel) {}
            override fun onRenegotiationNeeded() {}
            override fun onAddTrack(receiver: RtpReceiver, streams: Array<MediaStream>) {}
        })

        val enumerator = Camera2Enumerator(context)
        val names = enumerator.deviceNames
        val cameraName = names.firstOrNull {
            if (frontCamera) enumerator.isFrontFacing(it) else enumerator.isBackFacing(it)
        } ?: names.firstOrNull() ?: throw IllegalStateException("没有可用摄像头")
        capturer = enumerator.createCapturer(cameraName, null) ?: throw IllegalStateException("无法打开摄像头")
        helper = SurfaceTextureHelper.create("HomeCamCapture", egl!!.eglBaseContext)
        videoSource = f.createVideoSource(false)
        capturer!!.initialize(helper, context, videoSource!!.capturerObserver)
        capturer!!.startCapture(640, 480, 12)
        val videoTrack = f.createVideoTrack("video", videoSource)
        videoTrack.setEnabled(true)
        peer!!.addTrack(videoTrack, listOf("homecam"))
        audioSource = f.createAudioSource(MediaConstraints())
        peer!!.addTrack(f.createAudioTrack("audio", audioSource), listOf("homecam"))
        setState(State.CONNECTING)
        createOffer()
    }

    private fun createOffer() {
        val p = peer ?: return
        p.createOffer(object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription) {
                p.setLocalDescription(object : SdpObserver {
                    override fun onCreateSuccess(sdp: SessionDescription) {}
                    override fun onSetSuccess() {
                        baseSdp = sdp.description
                        sendingOffer = true
                        callbacks.onDiagnostic("local offer set: ${baseSdp.length} chars, gathered=${localCandidates.size}")
                        scheduleOfferSend(3000)
                    }
                    override fun onCreateFailure(error: String) {
                        callbacks.onDiagnostic("SDP error: $error")
                    }
                    override fun onSetFailure(error: String) {
                        callbacks.onDiagnostic("setLocalOffer failed: $error")
                    }
                }, sdp)
            }
            override fun onSetSuccess() {}
            override fun onCreateFailure(error: String) {
                callbacks.onDiagnostic("SDP error: $error")
            }
            override fun onSetFailure(error: String) {}
        }, MediaConstraints())
    }

    private fun scheduleOfferSend(delayMs: Long) {
        if (!sendingOffer) return
        sendRunnable?.let { handler.removeCallbacks(it) }
        val runnable = Runnable { sendOfferNow() }
        sendRunnable = runnable
        handler.postDelayed(runnable, delayMs)
    }

    private fun sendOfferNow() {
        if (!sendingOffer || baseSdp.isEmpty()) return
        sendingOffer = false
        sendRunnable?.let { handler.removeCallbacks(it) }
        sendRunnable = null
        val sdp = assembleSdp(baseSdp, localCandidates)
        callbacks.onDiagnostic("sending offer: ${sdp.length} chars, candidates=${localCandidates.size}")
        callbacks.onLocalOffer(sdp)
    }

    /** candidate 必须插入到所属 m= section 内，追加到 SDP 末尾属 session-level，Chrome 会解析失败。 */
    private fun assembleSdp(base: String, candidates: List<CandidateEntry>): String {
        val lines = base.split("\r\n").filter { it.isNotEmpty() }.toMutableList()
        val existing = lines.filter { it.startsWith("a=candidate:") }.toSet()
        val mPositions = lines.mapIndexedNotNull { index, line -> if (line.startsWith("m=")) index else null }
        for (section in mPositions.indices.reversed()) {
            val start = mPositions[section]
            val end = mPositions.getOrNull(section + 1) ?: lines.size
            val sectionCandidates = candidates
                .filter { if (it.mLineIndex >= 0) it.mLineIndex == section else section == 0 }
                .map { "a=${it.sdp}" }
                .filterNot { existing.contains(it) }
            if (sectionCandidates.isEmpty()) continue
            val endOfCandidates = (start until end).firstOrNull { lines[it] == "a=end-of-candidates" }
            lines.addAll(endOfCandidates ?: end, sectionCandidates)
        }
        return lines.joinToString(separator = "\r\n", postfix = "\r\n")
    }

    fun receiveAnswer(sdp: String) {
        peer?.setRemoteDescription(object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription) {}
            override fun onSetSuccess() {
                remoteReady = true
                callbacks.onDiagnostic("remote answer set")
                remoteCandidates.forEach { peer?.addIceCandidate(it) }
                remoteCandidates.clear()
            }
            override fun onCreateFailure(error: String) {
                callbacks.onDiagnostic("SDP error: $error")
            }
            override fun onSetFailure(error: String) {
                callbacks.onDiagnostic("setRemoteAnswer failed: $error")
            }
        }, SessionDescription(SessionDescription.Type.ANSWER, sdp))
    }

    fun receiveCandidate(candidate: IceCandidate) {
        if (remoteReady) peer?.addIceCandidate(candidate) else remoteCandidates.add(candidate)
    }

    fun switchCamera() {
        val old = capturer
        val source = videoSource
        if (old == null || source == null) {
            callbacks.onDiagnostic("switch skipped: no capturer")
            return
        }
        val enumerator = Camera2Enumerator(context)
        val names = enumerator.deviceNames
        val nextFront = !frontCamera
        val cameraName = names.firstOrNull {
            if (nextFront) enumerator.isFrontFacing(it) else enumerator.isBackFacing(it)
        }
        if (cameraName == null) {
            callbacks.onDiagnostic("switch failed: no such camera")
            return
        }
        val next = enumerator.createCapturer(cameraName, null) ?: return
        try { old.stopCapture() } catch (_: Exception) {}
        try { old.dispose() } catch (_: Exception) {}
        next.initialize(helper, context, source.capturerObserver)
        next.startCapture(640, 480, 12)
        capturer = next
        frontCamera = nextFront
        callbacks.onDiagnostic("camera switched to ${if (nextFront) "front" else "back"}")
    }

    @Synchronized
    fun stop(reason: String, notifyState: Boolean = true) {
        if (stopping) return
        callbacks.onDiagnostic("STOP reason=$reason")
        stopping = true
        sendRunnable?.let { handler.removeCallbacks(it) }
        sendRunnable = null
        sendingOffer = false
        try { capturer?.stopCapture() } catch (_: Exception) {}
        try { capturer?.dispose() } catch (_: Exception) {}
        capturer = null
        try { videoSource?.dispose() } catch (_: Exception) {}
        videoSource = null
        try { audioSource?.dispose() } catch (_: Exception) {}
        audioSource = null
        try { helper?.dispose() } catch (_: Exception) {}
        helper = null
        try { peer?.close() } catch (_: Exception) {}
        try { peer?.dispose() } catch (_: Exception) {}
        peer = null
        localCandidates.clear()
        remoteCandidates.clear()
        baseSdp = ""
        remoteReady = false
        stopping = false
        state = State.IDLE
        if (notifyState) callbacks.onState(State.IDLE)
    }

    private fun setState(next: State) {
        if (state == next) return
        state = next
        callbacks.onState(next)
    }
}
