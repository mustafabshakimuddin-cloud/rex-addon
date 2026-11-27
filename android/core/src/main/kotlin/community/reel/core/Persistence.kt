package community.reel.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import java.io.File
import java.time.format.DateTimeFormatter
import java.time.ZoneOffset
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * A store screens follow. Like the iOS stores' change counter: it moves once per change a view
 * should show, and views read the store's properties again when it does.
 */
abstract class Observed {
    private val _changes = MutableStateFlow(0L)
    val changes: StateFlow<Long> = _changes.asStateFlow()
    protected fun changed() = _changes.update { it + 1 }
}

/**
 * The app's JSON files. A file that exists but can't be decoded is moved aside rather than read as
 * empty: an empty store would overwrite it on its next save, and the user's library would be gone.
 */
object JSONFile {
    val folder: File get() = Platform.folder

    fun file(name: String) = File(folder, name)

    private val moved = mutableListOf<String>()

    /** Files moved aside this launch because they couldn't be read, by name. */
    val unreadableFiles: List<String> get() = synchronized(moved) { moved.toList() }

    /** The parsed file, or null when there is none. An unreadable file is renamed and kept. */
    fun <T> read(file: File, decode: (JsonElement) -> T): T? {
        if (!file.exists()) return null
        val text = runCatching { file.readText() }.getOrNull() ?: return null
        return try {
            val json = ReelJson.parseToJsonElement(text)
            decode(json)
        } catch (e: Exception) {
            quarantine(file)
            null
        }
    }

    fun quarantine(file: File) {
        val stamp = DateTimeFormatter.ISO_INSTANT.format(now()).replace(":", "-")
        val destination = File(file.parentFile, "${file.nameWithoutExtension}.unreadable-$stamp.json")
        file.renameTo(destination)
        synchronized(moved) { moved += file.name }
    }
}

/** Decodes what it can: one malformed element costs that element, not the whole list. */
inline fun <reified T> JsonElement?.lossyList(): List<T> =
    (this as? JsonArray)?.mapNotNull { runCatching { ReelJson.decodeFromJsonElement<T>(it) }.getOrNull() } ?: emptyList()

inline fun <reified T> JsonElement?.lossyMap(): Map<String, T> =
    (this as? JsonObject)?.mapNotNull { (key, value) ->
        runCatching { ReelJson.decodeFromJsonElement<T>(value) }.getOrNull()?.let { key to it }
    }?.toMap() ?: emptyMap()

inline fun <reified T> JsonElement?.decodeOrNull(): T? =
    this?.let { runCatching { ReelJson.decodeFromJsonElement<T>(it) }.getOrNull() }

/**
 * Writes a store's snapshot after a pause, so a burst of changes costs one write. Encoding and
 * writing happen on one background thread, in order; a snapshot overtaken by a newer one is
 * skipped. Writes go to a temporary file and are renamed into place.
 */
class SnapshotWriter(private val file: File) {
    private val lock = Any()
    private var generation = 0
    private var pending: ScheduledFuture<*>? = null

    fun schedule(afterSeconds: Double, encode: () -> String?) = enqueue((afterSeconds * 1000).toLong(), encode)

    fun flush(encode: () -> String?) = enqueue(0, encode)

    /** Blocks until every queued write has finished. For tests and profile switches. */
    fun waitUntilWritten() {
        executor.submit {}.get()
        // A delayed write may still be waiting: run the latest one now.
        val future = synchronized(lock) { pending }
        if (future != null && !future.isDone) {
            runCatching { future.get() }
        }
    }

    private fun enqueue(delayMs: Long, encode: () -> String?) {
        synchronized(lock) {
            generation += 1
            val mine = generation
            pending?.cancel(false)
            pending = executor.schedule({
                if (synchronized(lock) { mine == generation }) {
                    encode()?.let { write(it) }
                }
            }, delayMs, TimeUnit.MILLISECONDS)
        }
    }

    private fun write(text: String) {
        runCatching {
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, ".${file.name}.tmp")
            temp.writeText(text)
            if (!temp.renameTo(file)) { file.delete(); temp.renameTo(file) }
        }
    }

    companion object {
        private val executor = Executors.newSingleThreadScheduledExecutor { Thread(it, "reel-save").apply { isDaemon = true } }
    }
}

/** A short record of what went wrong recently, for Status. Lines are redacted before they are kept. */
object AppLog {
    @kotlinx.serialization.Serializable
    data class Entry(
        val id: String = java.util.UUID.randomUUID().toString(),
        val date: Date = now(),
        val area: String,
        val message: String,
    )

    private const val KEY = "log.entries"
    private const val KEEP = 80
    private var cached: List<Entry>? = null

    @Synchronized fun record(area: String, message: String) {
        val clean = Redact.text(message)
        val list = (listOf(Entry(area = area, message = clean)) + load()).take(KEEP)
        cached = list
        runCatching { Platform.defaults.putString(KEY, ReelJson.encodeToString(list)) }
    }

    fun record(area: String, error: Throwable) = record(area, error.readable())

    val entries: List<Entry> @Synchronized get() = load()

    @Synchronized fun clear() {
        cached = emptyList()
        Platform.defaults.remove(KEY)
    }

    private fun load(): List<Entry> {
        cached?.let { return it }
        val saved = runCatching { Platform.defaults.string(KEY)?.let { ReelJson.decodeFromString<List<Entry>>(it) } }.getOrNull() ?: emptyList()
        cached = saved
        return saved
    }
}

private val utc = ZoneOffset.UTC
