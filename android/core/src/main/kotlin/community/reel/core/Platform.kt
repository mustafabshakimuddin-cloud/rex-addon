package community.reel.core

import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** Small settings, like UserDefaults: the app backs this with SharedPreferences. */
interface KeyValueStore {
    fun string(key: String): String?
    fun putString(key: String, value: String?)
    fun has(key: String): Boolean
    fun remove(key: String)
    /** Every key and its value as text, for backups. */
    fun all(): Map<String, String>

    fun bool(key: String): Boolean? = string(key)?.toBooleanStrictOrNull()
    fun int(key: String): Int? = string(key)?.toIntOrNull()
    fun double(key: String): Double? = string(key)?.toDoubleOrNull()
    fun strings(key: String): List<String>? = string(key)?.let { text ->
        runCatching { ReelJson.decodeFromString<List<String>>(text) }.getOrNull()
    }
    fun putBool(key: String, value: Boolean) = putString(key, value.toString())
    fun putInt(key: String, value: Int) = putString(key, value.toString())
    fun putDouble(key: String, value: Double) = putString(key, value.toString())
    fun putStrings(key: String, value: List<String>) = putString(key, ReelJson.encodeToString(value))
}

/** Credentials, like the Keychain: the app backs this with the Android Keystore. */
interface SecretStore {
    fun read(account: String): String?
    /** An empty value deletes. */
    fun write(value: String, account: String)
}

class MemoryKeyValueStore : KeyValueStore {
    private val map = ConcurrentHashMap<String, String>()
    override fun string(key: String) = map[key]
    override fun putString(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
    override fun has(key: String) = map.containsKey(key)
    override fun remove(key: String) { map.remove(key) }
    override fun all(): Map<String, String> = HashMap(map)
}

class MemorySecretStore : SecretStore {
    private val map = ConcurrentHashMap<String, String>()
    override fun read(account: String) = map[account]
    override fun write(value: String, account: String) { if (value.isEmpty()) map.remove(account) else map[account] = value }
}

/** What the app hands the core at launch. Tests set it up with memory stores and a temp folder. */
object Platform {
    lateinit var defaults: KeyValueStore
    lateinit var secrets: SecretStore
    lateinit var folder: File
    /** The thread stores live on: the main thread in the app, the caller's in tests. */
    var main: kotlin.coroutines.CoroutineContext = kotlinx.coroutines.Dispatchers.Unconfined
    /** Where stores run their timers and background work: the main thread in the app. */
    var scope: kotlinx.coroutines.CoroutineScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Default)
    /** What the screen and chip can do; filled in by the app at launch. */
    @Volatile var device = SourcePreferences.DeviceSupport.assumeAll
    /** The device's language, ISO 639-1. */
    @Volatile var languageCode: String = java.util.Locale.getDefault().language

    fun setUpForTests(folder: File) {
        defaults = MemoryKeyValueStore()
        secrets = MemorySecretStore()
        this.folder = folder
    }
}
