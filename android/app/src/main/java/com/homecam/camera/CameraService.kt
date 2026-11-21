package com.homecam.camera

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import io.socket.client.IO
import io.socket.client.Socket
import org.json.JSONArray
import org.json.JSONObject
import org.webrtc.IceCandidate
import java.net.URI

/** 常驻前台服务：只保信令，相机/麦克风在 watch:start 后按需创建。 */
class CameraService : Service() {
    companion object {
        const val ACTION_CONNECT = "com.homecam.camera.CONNECT"
        const val ACTION_CAPTURE = "com.homecam.camera.CAPTURE_PHOTO"
        const val ACTION_PAIR_CAPTURE = "com.homecam.camera.PAIR_CAPTURE"
        const val ACTION_UNPAIR = "com.homecam.camera.UNPAIR"
        const val ACTION_UNPAIRED = "com.homecam.camera.UNPAIRED"
        private const val CHANNEL = "homecam_status"
        private const val NOTIFICATION = 7
        private const val IDLE_TEXT = "待命中：摄像头和麦克风未启用"
    }

    private val prefs: SharedPreferences by lazy { getSharedPreferences("homecam", MODE_PRIVATE) }
    private val handler = Handler(Looper.getMainLooper())
    private val photoUploader by lazy { PhotoUploader(this) }
    private val streamer: WebRtcStreamer by lazy {
        WebRtcStreamer(this, object : WebRtcStreamer.Callbacks {
            override fun onState(state: WebRtcStreamer.State) {
                when (state) {
                    WebRtcStreamer.State.IDLE -> {
                        sendState("idle")
                        updateNotification(IDLE_TEXT)
                    }
                    WebRtcStreamer.State.CONNECTING -> {
                        sendState("connecting")
                        updateNotification("正在建立观看连接…")
                    }
                    WebRtcStreamer.State.STREAMING -> {
                        sendState("streaming")
                        updateNotification("正在直播")
                    }
                }
            }

            override fun onDiagnostic(message: String) = diag(message)

            override fun onLocalOffer(sdp: String) {
                sendSignal(JSONObject().put("type", "offer").put("sdp", sdp))
            }

            override fun onPeerUnstable(reason: String) {
                diag("peer unstable: $reason，请求恢复会话")
                handler.postDelayed({
                    emit("watch:resume", JSONObject().put("deviceId", prefs.getString("deviceId", "")))
                }, 1500)
            }
        })
    }

    private lateinit var socket: Socket
    private var viewerId: String? = null
    private var lastCaptureAt = 0L
    private var lastRebuildAt = 0L
    private var lastNetworkChange = 0L
    private var unlockReceiver: BroadcastReceiver? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onCreate() {
        super.onCreate()
        RuntimeConfig.init(this)
        createChannel()
        registerUnlockReceiver()
        registerNetworkCallback()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION, notification(IDLE_TEXT))
        when (intent?.action) {
            ACTION_CAPTURE -> capturePhotos("回前台")
            ACTION_PAIR_CAPTURE -> capturePhotos("配对成功", force = true)
            ACTION_UNPAIR -> unpairAndStop()
            else -> connect()
        }
        return START_STICKY
    }

    private fun connect() {
        if (::socket.isInitialized && socket.connected()) return
        val serverUrl = prefs.getString("serverUrl", null)?.trim()?.removeSuffix("/")
        val deviceId = prefs.getString("deviceId", null)
        val deviceSecret = prefs.getString("deviceSecret", null)
        if (serverUrl.isNullOrBlank() || deviceId.isNullOrBlank() || deviceSecret.isNullOrBlank()) return
        try {
            socket = IO.socket(URI(serverUrl), IO.Options().apply {
                auth = mapOf("deviceId" to deviceId, "deviceSecret" to deviceSecret)
                reconnection = true
                reconnectionDelay = 1000
                reconnectionDelayMax = 3000
                timeout = 10000
            })
        } catch (e: Exception) {
            updateNotification("服务器地址无效：${e.message}")
            return
        }
        bindEvents()
        socket.connect()
    }

    private fun bindEvents() {
        socket.on(Socket.EVENT_CONNECT) { args ->
            diag("socket connected")
            if (!streamer.isActive) updateNotification(IDLE_TEXT)
        }
        socket.on(Socket.EVENT_DISCONNECT) { args ->
            // 网络切换短暂断线：停旧 peer 但不上报 idle，会话由服务端保留至 watch:resumed
            diag("socket disconnected, hold session")
            if (streamer.isActive) {
                streamer.stop("socket-lost", notifyState = false)
                updateNotification("网络中断，正在重连…")
            }
        }
        socket.on(Socket.EVENT_CONNECT_ERROR) { args ->
            diag("connect error: ${args.firstOrNull()?.toString()?.take(120)}")
        }
        socket.on("watch:start") { args ->
            val message = args.firstOrNull() as? JSONObject ?: return@on
            val id = message.optString("viewerId")
            if (id.isBlank()) return@on
            diag("watch:start $id")
            viewerId = id
            startStream(id, message.optJSONArray("iceServers"))
        }
        socket.on("watch:resumed") { args ->
            val message = args.firstOrNull() as? JSONObject ?: return@on
            val id = message.optString("viewerId")
            if (id.isBlank()) return@on
            diag("watch:resumed $id")
            viewerId = id
            startStream(id, message.optJSONArray("iceServers"))
        }
        socket.on("watch:stop") { args ->
            if (streamer.isActive) streamer.stop("watch-stop")
            viewerId = null
        }
        socket.on("signal") { args ->
            val envelope = args.firstOrNull() as? JSONObject ?: return@on
            val data = envelope.optJSONObject("data") ?: return@on
            when (data.optString("type")) {
                "answer" -> data.optString("sdp").takeIf { it.isNotBlank() }?.let { streamer.receiveAnswer(it) }
                "candidate" -> {
                    val candidate = data.optJSONObject("candidate") ?: return@on
                    val sdp = candidate.optString("candidate")
                    if (sdp.isNotBlank()) {
                        streamer.receiveCandidate(
                            IceCandidate(candidate.optString("sdpMid"), candidate.optInt("sdpMLineIndex"), sdp)
                        )
                    }
                }
                "offer" -> diag("unexpected offer from viewer (android is offerer)")
            }
        }
        socket.on("camera:switch") { args ->
            if (RuntimeConfig.snapshot().cameraSwitch) streamer.switchCamera()
        }
        socket.on("device:removed") { args ->
            prefs.edit().remove("deviceId").remove("deviceSecret").apply()
            streamer.stop("removed", notifyState = false)
            viewerId = null
            sendBroadcast(Intent(ACTION_UNPAIRED))
            updateNotification("设备已被删除，请重新配对")
        }
    }

    private fun startStream(id: String, fallbackIce: JSONArray?) {
        if (streamer.isActive) streamer.stop("rebuild", notifyState = false)
        val now = System.currentTimeMillis()
        if (now - lastRebuildAt < 3000) {
            diag("重建去抖，忽略重复恢复通知")
            return
        }
        lastRebuildAt = now
        val effectiveIce = RuntimeConfig.snapshot().iceServers
            ?.map { IceServerSpec(it.urls, it.username, it.credential) }
            ?: parseIceServers(fallbackIce)
        try {
            streamer.start(effectiveIce)
            emit("watch:accepted", JSONObject().put("viewerId", id))
        } catch (e: Exception) {
            diag("start failed: ${e.message}")
            streamer.stop("start-failed", notifyState = false)
            sendState("idle")
            updateNotification("无法开启摄像头：${e.message}")
        }
    }

    private fun parseIceServers(array: JSONArray?): List<IceServerSpec> {
        val result = mutableListOf<IceServerSpec>()
        if (array == null) return result
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            val urls = mutableListOf<String>()
            val raw = item.opt("urls")
            if (raw is JSONArray) {
                for (j in 0 until raw.length()) {
                    val u = raw.optString(j)
                    if (u.isNotBlank()) urls.add(u)
                }
            } else if (raw is String && raw.isNotBlank()) {
                urls.add(raw)
            }
            if (urls.isNotEmpty()) result.add(IceServerSpec(urls, item.optString("username"), item.optString("credential")))
        }
        return result
    }

    /// 手机端主动停止配对：先通知服务端移除设备（观看端即时反馈），再清本地凭据停服务
    private fun unpairAndStop() {
        streamer.stop("unpair", notifyState = false)
        viewerId = null
        val payload = JSONObject().put("deviceId", prefs.getString("deviceId", ""))
        val finish = Runnable {
            emit("device:unpair", payload)   // 服务端从 socket 身份取设备，无需等待回执
            prefs.edit().remove("deviceId").remove("deviceSecret").apply()
            handler.postDelayed({ stopSelf() }, 300)  // 留时间给 emit 发出
        }
        if (!::socket.isInitialized || !socket.connected()) {
            // 服务未连接（被系统回收后重启）：先建连再发解绑
            connect()
            handler.postDelayed(finish, 800)
        } else finish.run()
    }

    private fun sendSignal(data: JSONObject) {
        val id = viewerId ?: return
        emit("signal", JSONObject().put("targetId", id).put("data", data))
    }

    private fun emit(event: String, data: JSONObject) {
        if (!::socket.isInitialized || !socket.connected()) return
        try { socket.emit(event, data) } catch (_: Exception) {}
    }

    private fun sendState(state: String) = emit("stream:state", JSONObject().put("state", state))

    private fun diag(message: String) = emit(
        "device:diagnostic",
        JSONObject()
            .put("deviceId", prefs.getString("deviceId", ""))
            .put("message", message.take(280))
    )

    private fun capturePhotos(reason: String, force: Boolean = false) {
        val config = RuntimeConfig.snapshot()
        if (!config.photoUpload || !config.photos) return
        if (!force && !config.screenLockCapture) return
        if (streamer.isActive) {
            diag("直播中跳过拍照（$reason）")
            return
        }
        val now = System.currentTimeMillis()
        if (!force && now - lastCaptureAt < (config.captureThresholdSeconds * 1000).toLong()) return
        lastCaptureAt = now
        photoUploader.capture { diag("$reason：$it") }
    }

    private fun registerUnlockReceiver() {
        unlockReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = capturePhotos("解锁")
        }
        try {
            registerReceiver(unlockReceiver, IntentFilter(Intent.ACTION_USER_PRESENT))
        } catch (_: Exception) {
            // 某些 ROM 会拦截该广播，回前台仍会触发拍照
        }
    }

    private fun registerNetworkCallback() {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build()
        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = forceReconnect("available")
            override fun onLost(network: Network) = forceReconnect("lost")
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) forceReconnect("changed")
            }
        }
        val callback = networkCallback ?: return
        try { manager.registerNetworkCallback(request, callback) } catch (_: Exception) {}
    }

    private fun forceReconnect(reason: String) {
        if (!::socket.isInitialized || !socket.connected()) return
        val now = System.currentTimeMillis()
        if (now - lastNetworkChange < 1500) return
        lastNetworkChange = now
        diag("网络变化（$reason），重连信令")
        try {
            socket.disconnect()
            socket.connect()
        } catch (_: Exception) {}
    }

    private fun createChannel() {
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
            NotificationChannel(CHANNEL, "HomeCam 状态", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun notification(text: String) = NotificationCompat.Builder(this, CHANNEL)
        .setSmallIcon(android.R.drawable.presence_video_online)
        .setContentTitle("HomeCam 摄像头端")
        .setContentText(text)
        .setOngoing(true)
        .build()

    private fun updateNotification(text: String) {
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification(text))
    }

    override fun onDestroy() {
        streamer.stop("service-destroy")
        if (::socket.isInitialized) {
            try { socket.disconnect() } catch (_: Exception) {}
        }
        unlockReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        networkCallback?.let { callback ->
            try {
                (getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).unregisterNetworkCallback(callback)
            } catch (_: Exception) {}
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
