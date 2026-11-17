package com.homecam.camera

import android.app.*
import android.content.*
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.socket.client.IO
import io.socket.client.Socket
import org.json.JSONObject
import org.webrtc.*
import java.net.URI

/** Keeps only a signaling socket while idle. Camera/audio are created exclusively after watch:start. */
class CameraService : Service() {
    companion object { const val ACTION_CONNECT = "com.homecam.camera.CONNECT"; private const val CHANNEL = "homecam_status"; private const val NOTIFICATION = 7 }
    private lateinit var socket: Socket; private var viewerId: String? = null
    private var factory: PeerConnectionFactory? = null; private var peer: PeerConnection? = null; private var capturer: VideoCapturer? = null; private var videoSource: VideoSource? = null; private var audioSource: AudioSource? = null; private var egl: EglBase? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int { createChannel(); startForeground(NOTIFICATION, notification("待命中：摄像头和麦克风未启用")); if (intent?.action == ACTION_CONNECT) connect(); return START_STICKY }
    private fun connect() { if (::socket.isInitialized && socket.connected()) return; val p = getSharedPreferences("homecam", MODE_PRIVATE); val url = p.getString("serverUrl", null) ?: return; val id = p.getString("deviceId", null) ?: return; val secret = p.getString("deviceSecret", null) ?: return
        socket = IO.socket(URI(url), IO.Options().apply { auth = mapOf("deviceId" to id, "deviceSecret" to secret); reconnection = true })
        socket.on(Socket.EVENT_CONNECT) { socket.emit("stream:state", JSONObject().put("state", "idle")); update("待命中：摄像头和麦克风未启用") }
        socket.on("watch:start") { args -> val msg = args.firstOrNull() as? JSONObject ?: return@on; viewerId = msg.optString("viewerId"); socket.emit("watch:accepted", JSONObject().put("viewerId", viewerId)); startCapture(msg.optJSONArray("iceServers")) }
        socket.on("watch:stop") { stopCapture(); update("待命中：摄像头和麦克风未启用") }
        socket.on("signal") { args -> (args.firstOrNull() as? JSONObject)?.let { receiveSignal(it) } }
        socket.connect()
    }
    private fun startCapture(iceConfig: org.json.JSONArray?) { if (peer != null) return; try {
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(this).createInitializationOptions()); egl = EglBase.create(); factory = PeerConnectionFactory.builder().setVideoEncoderFactory(DefaultVideoEncoderFactory(egl!!.eglBaseContext, true, true)).setVideoDecoderFactory(DefaultVideoDecoderFactory(egl!!.eglBaseContext)).createPeerConnectionFactory()
        val ice = (0 until (iceConfig?.length() ?: 0)).mapNotNull { index -> iceConfig?.optJSONObject(index)?.let { config ->
            val url = config.optJSONArray("urls")?.optString(0) ?: config.optString("urls")
            if (url.isBlank()) null else PeerConnection.IceServer.builder(url).setUsername(config.optString("username")).setPassword(config.optString("credential")).createIceServer()
        } }.ifEmpty { listOf(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer()) }
        peer = factory!!.createPeerConnection(PeerConnection.RTCConfiguration(ice), object : PeerConnection.Observer {
            override fun onIceCandidate(c: IceCandidate) { sendSignal(JSONObject().put("type", "candidate").put("candidate", JSONObject().put("sdpMid", c.sdpMid).put("sdpMLineIndex", c.sdpMLineIndex).put("candidate", c.sdp))) }
            override fun onConnectionChange(s: PeerConnection.PeerConnectionState) { if (s == PeerConnection.PeerConnectionState.CONNECTED) { socket.emit("stream:state", JSONObject().put("state", "streaming")); update("正在直播") } }
            override fun onSignalingChange(s: PeerConnection.SignalingState) {} ; override fun onIceConnectionChange(s: PeerConnection.IceConnectionState) {} ; override fun onIceConnectionReceivingChange(b: Boolean) {} ; override fun onIceGatheringChange(s: PeerConnection.IceGatheringState) {} ; override fun onIceCandidatesRemoved(c: Array<IceCandidate>) {} ; override fun onAddStream(s: MediaStream) {} ; override fun onRemoveStream(s: MediaStream) {} ; override fun onDataChannel(c: DataChannel) {} ; override fun onRenegotiationNeeded() {} ; override fun onAddTrack(r: RtpReceiver, m: Array<MediaStream>) {}
        })
        val enumerator = Camera2Enumerator(this); val camera = (enumerator.deviceNames.firstOrNull { enumerator.isBackFacing(it) } ?: enumerator.deviceNames.first()); capturer = enumerator.createCapturer(camera, null) ?: error("无法打开摄像头")
        val helper = SurfaceTextureHelper.create("HomeCamCapture", egl!!.eglBaseContext); videoSource = factory!!.createVideoSource(false); capturer!!.initialize(helper, this, videoSource!!.capturerObserver); capturer!!.startCapture(640, 480, 12)
        val videoTrack = factory!!.createVideoTrack("video", videoSource); videoTrack.setEnabled(true); peer!!.addTrack(videoTrack)
        audioSource = factory!!.createAudioSource(MediaConstraints()); peer!!.addTrack(factory!!.createAudioTrack("audio", audioSource))
        socket.emit("stream:state", JSONObject().put("state", "connecting")); update("正在建立观看连接…")
    } catch (e: Exception) { stopCapture(); socket.emit("stream:state", JSONObject().put("state", "idle")); update("无法开启摄像头：${e.message}") } }
    private fun receiveSignal(envelope: JSONObject) { val data = envelope.optJSONObject("data") ?: return; when (data.optString("type")) { "offer" -> { val description = SessionDescription(SessionDescription.Type.OFFER, data.optString("sdp")); peer?.setRemoteDescription(object : SdpObserver { override fun onSetSuccess() { peer?.createAnswer(object : SdpObserver { override fun onCreateSuccess(answer: SessionDescription) { peer?.setLocalDescription(object : SdpObserver { override fun onSetSuccess() { sendSignal(JSONObject().put("type", "answer").put("sdp", answer.description)) }; override fun onSetFailure(s: String) {} }, answer) }; override fun onCreateFailure(s: String) {}; override fun onSetSuccess() {}; override fun onSetFailure(s: String) {} }, MediaConstraints()) }; override fun onSetFailure(s: String) {}; override fun onCreateSuccess(p0: SessionDescription) {}; override fun onCreateFailure(s: String) {} }, description) }; "candidate" -> data.optJSONObject("candidate")?.let { peer?.addIceCandidate(IceCandidate(it.optString("sdpMid"), it.optInt("sdpMLineIndex"), it.optString("candidate"))) } } }
    private fun sendSignal(data: JSONObject) { viewerId?.let { socket.emit("signal", JSONObject().put("targetId", it).put("data", data)) } }
    private fun stopCapture() { socket.emit("stream:state", JSONObject().put("state", "idle")); try { capturer?.stopCapture() } catch (_: Exception) {}; capturer?.dispose(); capturer = null; videoSource?.dispose(); videoSource = null; audioSource?.dispose(); audioSource = null; peer?.close(); peer?.dispose(); peer = null; factory?.dispose(); factory = null; egl?.release(); egl = null; viewerId = null }
    private fun createChannel() { (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(NotificationChannel(CHANNEL, "HomeCam 状态", NotificationManager.IMPORTANCE_LOW)) }
    private fun notification(text: String) = NotificationCompat.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.presence_video_online).setContentTitle("HomeCam 摄像头端").setContentText(text).setOngoing(true).build()
    private fun update(text: String) { (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification(text)) }
    override fun onDestroy() { stopCapture(); if (::socket.isInitialized) socket.disconnect(); super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null
}
