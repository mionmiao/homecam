package com.homecam.camera

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

class MainActivity : AppCompatActivity() {
    private lateinit var status: TextView
    private lateinit var configStatus: TextView
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }

    private val unpairedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            status.text = "此设备已被观看端删除，请重新配对"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        RuntimeConfig.init(this)
        status = findViewById(R.id.status)
        configStatus = findViewById(R.id.configStatus)
        val prefs = getSharedPreferences("homecam", MODE_PRIVATE)
        val url = findViewById<EditText>(R.id.serverUrl)
        val name = findViewById<EditText>(R.id.deviceName)
        val code = findViewById<EditText>(R.id.pairingCode)
        url.setText(prefs.getString("serverUrl", ""))
        name.setText(prefs.getString("name", android.os.Build.MODEL))
        updateConfigStatus()
        requestPermissions()

        findViewById<Button>(R.id.pairButton).setOnClickListener {
            val server = url.text.toString().trim().removeSuffix("/")
            if (!server.startsWith("https://")) {
                status.text = "服务器地址必须以 https:// 开头"
                return@setOnClickListener
            }
            status.text = "正在配对…"
            Thread {
                try {
                    val body = JSONObject()
                        .put("code", code.text.toString())
                        .put("name", name.text.toString())
                        .put("brand", android.os.Build.MANUFACTURER)
                        .put("model", android.os.Build.MODEL)
                        .put("osVersion", "Android ${android.os.Build.VERSION.RELEASE}")
                    val request = Request.Builder()
                        .url("$server/api/devices/pair")
                        .post(body.toString().toRequestBody("application/json".toMediaType()))
                        .build()
                    OkHttpClient().newCall(request).execute().use { response ->
                        if (!response.isSuccessful) throw Exception("配对失败：${response.code}")
                        val result = JSONObject(response.body!!.string())
                        val deviceSecret = result.getString("deviceSecret")
                        prefs.edit()
                            .putString("serverUrl", server)
                            .putString("deviceId", result.getJSONObject("device").getString("id"))
                            .putString("name", name.text.toString())
                            .apply()
                        SecureStore.saveSecret(this@MainActivity, deviceSecret)
                        runOnUiThread {
                            requestPermissions()
                            startService(CameraService.ACTION_CONNECT)
                            startService(CameraService.ACTION_PAIR_CAPTURE)  // 配对成功立即拍一组
                            status.text = "已配对，正在待命"
                            refreshConfig(server)
                        }
                    }
                } catch (e: Exception) {
                    runOnUiThread { status.text = e.message ?: "配对失败" }
                }
            }.start()
        }

        findViewById<Button>(R.id.stopButton).setOnClickListener {
            // 主动解除配对：服务端会移除设备并通知观看端，本地清凭据
            val i = Intent(this, CameraService::class.java).setAction(CameraService.ACTION_UNPAIR)
            ContextCompat.startForegroundService(this, i)
            status.text = "已解除配对，请重新配对"
        }
        findViewById<Button>(R.id.refreshConfigButton).setOnClickListener {
            refreshConfig(prefs.getString("serverUrl", null))
        }
        try {
            registerReceiver(unpairedReceiver, IntentFilter(CameraService.ACTION_UNPAIRED))
        } catch (_: Exception) {
        }
    }

    override fun onResume() {
        super.onResume()
        val prefs = getSharedPreferences("homecam", MODE_PRIVATE)
        if (!prefs.getString("deviceId", "").isNullOrBlank()) {
            startService(CameraService.ACTION_CAPTURE)
            refreshConfig(prefs.getString("serverUrl", null))
        }
    }

    override fun onDestroy() {
        try { unregisterReceiver(unpairedReceiver) } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun refreshConfig(serverUrl: String?) {
        if (serverUrl.isNullOrBlank()) return
        configStatus.text = "运行时配置：正在同步…"
        RuntimeConfig.refresh(serverUrl) { runOnUiThread { updateConfigStatus() } }
    }

    private fun updateConfigStatus() {
        configStatus.text = RuntimeConfig.snapshot().summary
    }

    private fun requestPermissions() {
        val needed = listOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.POST_NOTIFICATIONS
        ).filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isNotEmpty()) permissions.launch(needed.toTypedArray())
    }

    private fun startService(action: String) {
        ContextCompat.startForegroundService(
            this,
            Intent(this, CameraService::class.java).setAction(action)
        )
    }
}
