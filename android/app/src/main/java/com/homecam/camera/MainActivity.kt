package com.homecam.camera

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import okhttp3.*
import org.json.JSONObject

class MainActivity : AppCompatActivity() {
    private lateinit var status: TextView
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); setContentView(R.layout.activity_main)
        status = findViewById(R.id.status); val prefs = getSharedPreferences("homecam", MODE_PRIVATE)
        val url = findViewById<EditText>(R.id.serverUrl); val name = findViewById<EditText>(R.id.deviceName); val code = findViewById<EditText>(R.id.pairingCode)
        url.setText(prefs.getString("serverUrl", "")); name.setText(prefs.getString("name", android.os.Build.MODEL))
        findViewById<Button>(R.id.pairButton).setOnClickListener {
            val server = url.text.toString().trim().removeSuffix("/"); if (!server.startsWith("https://") && !server.startsWith("http://")) { status.text = "服务器地址必须以 https:// 开头"; return@setOnClickListener }
            status.text = "正在配对…"; Thread {
                try { val body = JSONObject().put("code", code.text.toString()).put("name", name.text.toString()); val request = Request.Builder().url("$server/api/devices/pair").post(body.toString().toRequestBody("application/json".toMediaType())).build()
                    OkHttpClient().newCall(request).execute().use { response -> if (!response.isSuccessful) throw Exception("配对失败：${response.code}"); val result = JSONObject(response.body!!.string()); prefs.edit().putString("serverUrl", server).putString("deviceId", result.getJSONObject("device").getString("id")).putString("deviceSecret", result.getString("deviceSecret")).putString("name", name.text.toString()).apply(); runOnUiThread { requestPermissions(); startService(); status.text = "已配对，正在待命" } }
                } catch (e: Exception) { runOnUiThread { status.text = e.message ?: "配对失败" } }
            }.start()
        }
        findViewById<Button>(R.id.stopButton).setOnClickListener { stopService(Intent(this, CameraService::class.java)); status.text = "已停止待命" }
    }
    private fun requestPermissions() { val needed = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS).filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }; if (needed.isNotEmpty()) permissions.launch(needed.toTypedArray()) }
    private fun startService() { ContextCompat.startForegroundService(this, Intent(this, CameraService::class.java).setAction(CameraService.ACTION_CONNECT)) }
}
