package com.esp32hub.esp32_hub_app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small encrypted key/value store for secrets (device tokens, the Anthropic API key, MQTT passwords).
 * Values are encrypted with an AES-256-GCM key that lives in the Android Keystore (hardware-backed where the phone
 * has it) and can never be exported. Only the ciphertext is written to SharedPreferences.
 * No extra dependency: this uses the platform's javax.crypto + AndroidKeyStore.
 */
object SecureStore {
    private const val ALIAS = "esp32hub_secure_v1"
    private const val PREFS = "hub_secure"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    @Synchronized
    fun put(ctx: Context, name: String, value: String?) {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (value == null) { p.edit().remove(name).apply(); return }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val enc = c.doFinal(value.toByteArray(Charsets.UTF_8))
        val blob = Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(enc, Base64.NO_WRAP)
        p.edit().putString(name, blob).apply()
    }

    /** Returns null when missing or when it cannot be decrypted (for example after a backup restore on another phone). */
    @Synchronized
    fun get(ctx: Context, name: String): String? {
        val blob = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(name, null) ?: return null
        return try {
            val (iv, data) = blob.split(":")
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            String(c.doFinal(Base64.decode(data, Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    @Synchronized
    fun remove(ctx: Context, name: String) = put(ctx, name, null)
}
