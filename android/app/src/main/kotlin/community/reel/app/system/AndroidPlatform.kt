package community.reel.app.system

import android.content.Context
import android.content.SharedPreferences
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.Display
import android.hardware.display.DisplayManager
import community.reel.core.KeyValueStore
import community.reel.core.SecretStore
import community.reel.core.SourcePreferences
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Settings in SharedPreferences, as text, like UserDefaults on iOS. */
class PreferencesStore(context: Context) : KeyValueStore {
    private val prefs: SharedPreferences = context.getSharedPreferences("reel", Context.MODE_PRIVATE)
    override fun string(key: String): String? = prefs.getString(key, null)
    override fun putString(key: String, value: String?) { prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply() }
    override fun has(key: String) = prefs.contains(key)
    override fun remove(key: String) { prefs.edit().remove(key).apply() }
    override fun all(): Map<String, String> = prefs.all.mapNotNull { (key, value) -> (value as? String)?.let { key to it } }.toMap()
}

/**
 * Credentials (debrid keys, Trakt tokens), encrypted with an AES key that never leaves the Android
 * Keystore, then kept in their own preferences file. The Keychain's counterpart.
 */
class KeystoreSecrets(context: Context) : SecretStore {
    private val prefs = context.getSharedPreferences("reel.secrets", Context.MODE_PRIVATE)
    private val alias = "community.reel.secrets"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return generator.generateKey()
    }

    override fun read(account: String): String? {
        val stored = prefs.getString(account, null) ?: return null
        return runCatching {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
            String(cipher.doFinal(bytes, 12, bytes.size - 12), Charsets.UTF_8)
        }.getOrNull()
    }

    override fun write(value: String, account: String) {
        if (value.isEmpty()) { prefs.edit().remove(account).apply(); return }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(account, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }
}

/** What this device's screen and decoders can do, read once at launch. */
object DeviceCapabilities {
    fun read(context: Context): SourcePreferences.DeviceSupport {
        val display = (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).getDisplay(Display.DEFAULT_DISPLAY)
        @Suppress("DEPRECATION")
        val types = display?.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)
        val hdr = types.isNotEmpty()
        val dolbyVision = Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in types && hasDecoder(MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION)
        val av1 = hasDecoder(MediaFormat.MIMETYPE_VIDEO_AV1, hardwareOnly = true)
        return SourcePreferences.DeviceSupport(hdr = hdr, dolbyVision = dolbyVision, av1 = av1)
    }

    private fun hasDecoder(mime: String, hardwareOnly: Boolean = false): Boolean =
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
                (!hardwareOnly || Build.VERSION.SDK_INT < 29 || info.isHardwareAccelerated)
        }
}
