package com.homecam.camera

import android.content.Context
import android.content.SharedPreferences
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class IceServerSpec(val urls: List<String>, val username: String = "", val credential: String = "")

data class RuntimeConfigSnapshot(
    val iceServers: List<IceServerSpec>? = null,
    val photos: Boolean = true,
    val burst: Boolean = true,
    val screenLockCapture: Boolean = true,
    val cameraSwitch: Boolean = true,
    val photoUpload: Boolean = true,
    val burstCount: Int = 5,
    val burstIntervalMs: Int = 300,
    val burstOrder: List<String> = listOf("front", "back"),
    val captureThresholdSeconds: Double = 10.0,
    val ui: Map<String, String> = emptyMap(),
    val status: String = "未同步（使用内置默认值）",
    val updatedAt: Long = 0L
) {
    val summary: String
        get() {
            val whenText = if (updatedAt > 0) TIME_FORMAT.format(Date(updatedAt)) else "--"
            return "运行时配置：$status · 更新于 $whenText"
        }

    companion object {
        private val TIME_FORMAT = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
    }
}

/** 服务端 /api/config 下发的运行时配置，带本地缓存，改配置无需重装 App。 */
object RuntimeConfig {
    private const val PREFS = "homecam"
    private const val KEY_CACHE = "homecam.runtimeConfig"
    private var prefs: SharedPreferences? = null
    private var current = RuntimeConfigSnapshot()
    private val client = OkHttpClient()

    @Synchronized
    fun init(context: Context) {
        if (prefs != null) return
        prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs?.getString(KEY_CACHE, null)
        if (!raw.isNullOrBlank()) {
            try {
                val cached = JSONObject(raw)
                // 旧缓存里的静态 TURN 凭据已失效，清掉后回退到信令下发的临时凭据
                if (cached.has("iceServers")) {
                    cached.put("iceServers", JSONArray())
                    prefs?.edit()?.putString(KEY_CACHE, cached.toString())?.apply()
                }
                apply(cached, "已加载本地缓存", System.currentTimeMillis())
            } catch (_: Exception) {
                // 缓存损坏时用默认值
            }
        }
    }

    @Synchronized
    fun snapshot(): RuntimeConfigSnapshot = current

    /** 异步拉取；失败时保留当前值与状态不变。 */
    fun refresh(serverUrl: String, onDone: (String) -> Unit) {
        val url = serverUrl.trim().removeSuffix("/") + "/api/config"
        client.newCall(Request.Builder().url(url).get().build()).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                onDone("拉取失败（沿用上次）")
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    if (!it.isSuccessful) {
                        onDone("响应无效（沿用上次）")
                        return
                    }
                    try {
                        val json = JSONObject(it.body!!.string())
                        apply(json, "已同步", System.currentTimeMillis())
                        prefs?.edit()?.putString(KEY_CACHE, json.toString())?.apply()
                        onDone(snapshot().summary)
                    } catch (_: Exception) {
                        onDone("响应无效（沿用上次）")
                    }
                }
            }
        })
    }

    @Synchronized
    private fun apply(json: JSONObject, status: String, updatedAt: Long) {
        val base = RuntimeConfigSnapshot()
        var ice = base.iceServers
        json.optJSONArray("iceServers")?.let { arr ->
            val list = mutableListOf<IceServerSpec>()
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                val urls = mutableListOf<String>()
                val rawUrls = item.opt("urls")
                if (rawUrls is JSONArray) {
                    for (j in 0 until rawUrls.length()) {
                        val u = rawUrls.optString(j)
                        if (u.isNotBlank()) urls.add(u)
                    }
                } else if (rawUrls is String && rawUrls.isNotBlank()) {
                    urls.add(rawUrls)
                }
                if (urls.isNotEmpty()) {
                    list.add(IceServerSpec(urls, item.optString("username"), item.optString("credential")))
                }
            }
            if (list.isNotEmpty()) ice = list
        }

        val features = json.optJSONObject("features")
        val photos = features?.optBoolean("photos", base.photos) ?: base.photos
        val burst = features?.optBoolean("burst", base.burst) ?: base.burst
        val screenLock = features?.optBoolean("screenLockCapture", base.screenLockCapture) ?: base.screenLockCapture
        val cameraSwitch = features?.optBoolean("cameraSwitch", base.cameraSwitch) ?: base.cameraSwitch
        val photoUpload = features?.optBoolean("photoUpload", base.photoUpload) ?: base.photoUpload

        val photo = json.optJSONObject("photoSettings")
        val count = (photo?.optInt("burstCount", base.burstCount) ?: base.burstCount).coerceIn(1, 20)
        val interval = (photo?.optInt("intervalMs", base.burstIntervalMs) ?: base.burstIntervalMs).coerceIn(0, 5000)
        val order = mutableListOf<String>()
        photo?.optJSONArray("order")?.let { arr ->
            for (i in 0 until arr.length()) {
                val v = arr.optString(i)
                if (v == "front" || v == "back") order.add(v)
            }
        }
        if (order.isEmpty()) order.addAll(base.burstOrder)

        val threshold = json.optDouble("captureThresholdSeconds", base.captureThresholdSeconds)
            .coerceIn(0.0, 600.0)

        val ui = mutableMapOf<String, String>()
        json.optJSONObject("ui")?.let { obj ->
            for (key in obj.keys()) ui[key] = obj.optString(key)
        }

        current = RuntimeConfigSnapshot(
            iceServers = ice,
            photos = photos,
            burst = burst,
            screenLockCapture = screenLock,
            cameraSwitch = cameraSwitch,
            photoUpload = photoUpload,
            burstCount = count,
            burstIntervalMs = interval,
            burstOrder = order,
            captureThresholdSeconds = threshold,
            ui = ui,
            status = status,
            updatedAt = updatedAt
        )
    }
}
