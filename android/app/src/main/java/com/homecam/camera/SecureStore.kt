package com.homecam.camera

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** 设备密钥存 Android Keystore，SharedPreferences 只存密文。自动迁移旧明文值。 */
object SecureStore {
    private const val PREFS = "homecam"
    private const val ENC_KEY = "deviceSecretEnc"
    private const val LEGACY_KEY = "deviceSecret"
    private const val ALIAS = "homecam_device_secret"
    private const val KEYSTORE = "AndroidKeyStore"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        gen.init(KeyGenParameterSpec.Builder(ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return gen.generateKey()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val blob = cipher.iv + cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(blob, Base64.DEFAULT)
    }

    private fun decrypt(encoded: String): String? = try {
        val blob = Base64.decode(encoded, Base64.DEFAULT)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob.copyOfRange(0, 12)))
        String(cipher.doFinal(blob.copyOfRange(12, blob.size)), Charsets.UTF_8)
    } catch (_: Exception) { null }

    fun getSecret(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(ENC_KEY, null)?.let { decrypt(it)?.let { s -> if (s.isNotBlank()) return s } }
        val legacy = prefs.getString(LEGACY_KEY, null)
        if (!legacy.isNullOrBlank()) {
            saveSecret(context, legacy)
            return legacy
        }
        return null
    }

    fun saveSecret(context: Context, secret: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(ENC_KEY, encrypt(secret)).remove(LEGACY_KEY).apply()
    }

    fun clearSecret(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove(ENC_KEY).remove(LEGACY_KEY).apply()
    }
}
