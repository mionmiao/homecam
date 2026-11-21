package com.homecam.camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlin.coroutines.resume

/** 解锁/回前台时用前后置摄像头连拍并上传。直播中不调用，避免相机占用冲突。 */
class PhotoUploader(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val client = OkHttpClient()
    private var busy = false

    private data class Credentials(val serverUrl: String, val deviceId: String, val deviceSecret: String)

    fun capture(onLog: (String) -> Unit) {
        if (busy) {
            onLog("拍照进行中，跳过")
            return
        }
        val prefs = context.getSharedPreferences("homecam", Context.MODE_PRIVATE)
        val serverUrl = prefs.getString("serverUrl", null)
        val deviceId = prefs.getString("deviceId", null)
        val deviceSecret = SecureStore.getSecret(context)
        if (serverUrl.isNullOrBlank() || deviceId.isNullOrBlank() || deviceSecret.isNullOrBlank()) {
            onLog("未配对，跳过拍照")
            return
        }
        if (!serverUrl.startsWith("https://")) { onLog("服务器地址必须使用 HTTPS，请重新配对"); return }
        val cfg = RuntimeConfig.snapshot()
        if (!cfg.photoUpload || !cfg.photos) {
            onLog("配置已关闭照片上传")
            return
        }
        if (!cfg.screenLockCapture) {
            onLog("配置已关闭解锁拍照")
            return
        }
        busy = true
        val credentials = Credentials(serverUrl, deviceId, deviceSecret)
        scope.launch {
            try {
                val order = if (cfg.burst) cfg.burstOrder else listOf("back")
                val count = if (cfg.burst) cfg.burstCount else 1
                for (camera in order) {
                    var uploaded = 0
                    for (i in 0 until count) {
                        if (i > 0) delay(cfg.burstIntervalMs.toLong())
                        val jpeg = captureJpeg(camera)
                        if (jpeg == null) {
                            onLog("$camera[${i + 1}] 拍照失败")
                            continue
                        }
                        if (upload(jpeg, camera, credentials)) uploaded++
                    }
                    onLog("$camera 连拍上传 $uploaded/$count")
                }
            } catch (e: Exception) {
                onLog("拍照失败：${e.message}")
            } finally {
                busy = false
            }
        }
    }

    private fun pickCameraId(camera: String): String? = try {
        cameraManager.cameraIdList.firstOrNull { id ->
            val chars = cameraManager.getCameraCharacteristics(id)
            val facing = chars[android.hardware.camera2.CameraCharacteristics.LENS_FACING]
            if (camera == "front") {
                facing == android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT
            } else {
                facing == android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK
            }
        }
    } catch (_: Exception) {
        null
    }

    private suspend fun captureJpeg(camera: String): ByteArray? = withContext(Dispatchers.IO) {
        val cameraId = pickCameraId(camera) ?: return@withContext null
        suspendCancellableCoroutine { cont ->
            val thread = HandlerThread("homecam-photo").apply { start() }
            val handler = Handler(thread.looper)
            val reader = ImageReader.newInstance(1920, 1080, android.graphics.ImageFormat.JPEG, 2)
            var device: CameraDevice? = null
            var session: CameraCaptureSession? = null
            var cleanup: (() -> Unit)? = null
            val timeout = Runnable {
                if (cont.isActive) cont.resume(null)
                cleanup?.invoke()
            }
            cleanup = {
                handler.removeCallbacks(timeout)
                try { session?.close() } catch (_: Exception) {}
                try { device?.close() } catch (_: Exception) {}
                try { reader.close() } catch (_: Exception) {}
                thread.quitSafely()
            }
            handler.postDelayed(timeout, 8000)

            reader.setOnImageAvailableListener({ r ->
                val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    if (cont.isActive) {
                        cont.resume(compress(bytes))
                        cleanup?.invoke()
                    }
                } catch (e: Exception) {
                    Log.w("HomeCam", "photo capture error", e)
                    if (cont.isActive) cont.resume(null)
                } finally {
                    image.close()
                }
            }, handler)

            try {
                cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                    override fun onOpened(c: CameraDevice) {
                        device = c
                        val request = c.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                            addTarget(reader.surface)
                            set(CaptureRequest.JPEG_QUALITY, 85.toByte())
                            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                        }
                        c.createCaptureSession(listOf(reader.surface), object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(s: CameraCaptureSession) {
                                session = s
                                try {
                                    s.capture(request.build(), object : CameraCaptureSession.CaptureCallback() {}, handler)
                                } catch (e: Exception) {
                                    if (cont.isActive) cont.resume(null)
                                    cleanup?.invoke()
                                }
                            }

                            override fun onConfigureFailed(s: CameraCaptureSession) {
                                if (cont.isActive) cont.resume(null)
                                cleanup?.invoke()
                            }
                        }, handler)
                    }

                    override fun onDisconnected(c: CameraDevice) {
                        if (cont.isActive) cont.resume(null)
                        cleanup?.invoke()
                    }

                    override fun onError(c: CameraDevice, error: Int) {
                        if (cont.isActive) cont.resume(null)
                        cleanup?.invoke()
                    }
                }, handler)
            } catch (_: Exception) {
                if (cont.isActive) cont.resume(null)
                cleanup?.invoke()
            }
        }
    }

    private fun compress(jpeg: ByteArray): ByteArray {
        val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return jpeg
        val scale = minOf(1f, 1280f / maxOf(bitmap.width, bitmap.height))
        val scaled = Bitmap.createScaledBitmap(
            bitmap,
            maxOf(1, (bitmap.width * scale).toInt()),
            maxOf(1, (bitmap.height * scale).toInt()),
            true
        )
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 70, out)
        bitmap.recycle()
        scaled.recycle()
        return out.toByteArray()
    }

    private suspend fun upload(jpeg: ByteArray, camera: String, creds: Credentials): Boolean = withContext(Dispatchers.IO) {
        try {
            val body = jpeg.toRequestBody("image/jpeg".toMediaType())
            val request = Request.Builder()
                .url(creds.serverUrl.trim().removeSuffix("/") + "/api/photos")
                .header("Content-Type", "image/jpeg")
                .header("X-Device-Id", creds.deviceId)
                .header("X-Device-Secret", creds.deviceSecret)
                .header("X-Camera", camera)
                .post(body)
                .build()
            client.newCall(request).execute().use { it.code == 201 }
        } catch (_: IOException) {
            false
        } catch (_: Exception) {
            false
        }
    }
}
