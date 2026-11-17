package com.homecam.camera
import android.content.*
import androidx.core.content.ContextCompat
class BootReceiver : BroadcastReceiver() { override fun onReceive(context: Context, intent: Intent) { val p = context.getSharedPreferences("homecam", Context.MODE_PRIVATE); if (!p.getString("deviceId", "").isNullOrBlank()) ContextCompat.startForegroundService(context, Intent(context, CameraService::class.java).setAction(CameraService.ACTION_CONNECT)) } }
