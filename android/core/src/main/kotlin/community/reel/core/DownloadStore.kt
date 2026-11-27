package community.reel.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.time.Duration
import java.time.Instant
import java.util.concurrent.TimeUnit

/** One title saved for offline viewing. */
@Serializable
data class DownloadItem(
    val target: PlaybackTarget,
    val source: StreamSource,
    val remoteURL: String,
    val state: State,
    val written: Long = 0,
    val expected: Long = 0,
    val fileName: String? = null,
    val createdAt: Date = now(),
    /** Subtitle files saved beside the video, by file name. */
    val subtitleFiles: List<String>? = null,
    /** Whether the transfer may use mobile data. */
    val allowsCellular: Boolean? = null,
    /** The last HTTP status the server answered, when it refused the transfer. */
    val refusedStatus: Int? = null,
    /** Languages whose subtitles are saved beside the file once it is down. */
    val subtitleLanguages: List<String>? = null,
) {
    @Serializable
    sealed class State {
        @Serializable @kotlinx.serialization.SerialName("downloading") data object Downloading : State()
        @Serializable @kotlinx.serialization.SerialName("paused") data object Paused : State()
        @Serializable @kotlinx.serialization.SerialName("finished") data object Finished : State()
        @Serializable @kotlinx.serialization.SerialName("failed") data class Failed(val message: String) : State()
    }

    val id: String get() = target.videoID
    val fraction: Double get() = if (expected > 0) minOf(1.0, written.toDouble() / expected) else 0.0
    val isFinished: Boolean get() = state == State.Finished
}

class NoSpaceException(val needed: Long, val free: Long) :
    IOException("This release needs ${formatBytes(needed)} but only ${formatBytes(free)} is free. Delete downloads you've watched, or pick a smaller source.")

/**
 * Downloads into the app's own storage, a range request at a time, so a transfer that stops
 * carries on from where it was. The app keeps a foreground service running while anything is
 * downloading, so a film keeps coming down with the app closed.
 */
class DownloadStore(private val folder: File = File(Platform.folder, "Downloads")) : Observed() {
    /** What a download does beyond the file itself, read from the settings when it starts. */
    data class Options(val allowsCellular: Boolean = false, val subtitleLanguages: List<String> = emptyList()) {
        companion object {
            fun from(settings: AppSettings) = Options(
                settings.downloadsOverCellular,
                if (settings.downloadSubtitles) Languages.codes(settings.preferredSubtitleLanguage) else emptyList(),
            )
        }
    }

    sealed class Event {
        data class Finished(val item: DownloadItem) : Event()
        data class Failed(val item: DownloadItem, val message: String) : Event()
    }

    var items: Map<String, DownloadItem> = emptyMap(); private set
    /** Bytes a second for each running download, measured between progress reports. */
    var speeds: Map<String, Double> = emptyMap(); private set
    /** Bytes the finished and partial files take. */
    var usedBytes: Long = 0; private set

    /** Told when a download finishes or fails, so the app can say so. */
    var onEvent: ((Event) -> Unit)? = null
    /** Told as a download moves, about once a second, with its speed: the progress notification. */
    var onProgress: ((DownloadItem, Double?) -> Unit)? = null
    /** Asked before and during a transfer whether the network in use is allowed (mobile data). */
    var networkAllowed: (DownloadItem) -> Boolean = { true }

    private val indexFile = JSONFile.file("downloads.json")
    private val writer = SnapshotWriter(indexFile)
    private val jobs = mutableMapOf<String, Job>()
    private val lastPublished = mutableMapOf<String, Instant>()
    private val client by lazy { HTTP.client.newBuilder().readTimeout(60, TimeUnit.SECONDS).build() }

    init {
        folder.mkdirs()
        items = JSONFile.read(indexFile) { it.lossyMap<DownloadItem>() } ?: emptyMap()
        // After a relaunch: anything the index says is downloading was interrupted, and can be
        // resumed by hand.
        items = items.mapValues { (_, item) -> if (item.state == DownloadItem.State.Downloading) item.copy(state = DownloadItem.State.Paused) else item }
        recountBytes()
    }

    val ordered: List<DownloadItem> get() = items.values.sortedByDescending { it.createdAt }
    fun item(target: PlaybackTarget) = items[target.videoID]

    data class LocalCopy(val file: File, val source: StreamSource, val subtitles: List<File>)

    /** The local copy of a title, when one has finished downloading, with its subtitle files. */
    fun completedFile(target: PlaybackTarget): LocalCopy? {
        val item = items[target.videoID] ?: return null
        val name = item.fileName ?: return null
        if (!item.isFinished) return null
        val file = File(folder, name)
        if (!file.exists()) return null
        val subtitles = (item.subtitleFiles ?: emptyList()).map { File(folder, it) }.filter { it.exists() }
        return LocalCopy(file, item.source, subtitles)
    }

    val freeBytes: Long? get() = folder.usableSpace.takeIf { it > 0 }

    /** Refuses a release that wouldn't fit, leaving a little room for the system. */
    fun checkSpace(source: StreamSource?) {
        if (source == null || source.sizeBytes <= 0) return
        val free = freeBytes ?: return
        val needed = source.sizeBytes.toLong()
        if (needed + (1L shl 30) > free) throw NoSpaceException(needed, free)
    }

    fun start(target: PlaybackTarget, source: StreamSource, url: String, options: Options = Options()) {
        val existing = items[target.videoID]
        if (existing?.state == DownloadItem.State.Downloading) return
        // Checked before anything is deleted: a copy already here stays if the new one won't fit.
        checkSpace(source)
        existing?.let(::removeFiles)
        val item = DownloadItem(target, source, url, DownloadItem.State.Downloading, allowsCellular = options.allowsCellular,
            subtitleLanguages = options.subtitleLanguages)
        items = items + (item.id to item)
        save()
        begin(item.id)
    }

    /** Starts again from a fresh link, after the old one expired or was refused. */
    fun restart(item: DownloadItem, url: String) {
        partFile(item.id).delete()
        update(item.id) { it.copy(remoteURL = url, state = DownloadItem.State.Downloading, written = 0, refusedStatus = null) }
        begin(item.id)
    }

    fun pause(item: DownloadItem) {
        // Marked paused at once: progress reports already on their way must not flip it back.
        update(item.id) { it.copy(state = DownloadItem.State.Paused) }
        jobs.remove(item.id)?.cancel()
        speeds = speeds - item.id
        lastPublished.remove(item.id)
        changed()
    }

    /** Whether Retry can carry on where the transfer stopped, rather than needing a fresh link. */
    fun canResumeInPlace(item: DownloadItem): Boolean {
        if (item.refusedStatus != null) return false
        if (partFile(item.id).exists()) return true
        return item.state !is DownloadItem.State.Failed
    }

    fun resume(item: DownloadItem) {
        update(item.id) { it.copy(state = DownloadItem.State.Downloading) }
        begin(item.id)
    }

    fun delete(item: DownloadItem) {
        jobs.remove(item.id)?.cancel()
        removeFiles(item)
        items = items - item.id
        speeds = speeds - item.id
        save()
        recountBytes()
        changed()
    }

    val active get() = ordered.filter { it.state == DownloadItem.State.Downloading }
    val paused get() = ordered.filter { it.state == DownloadItem.State.Paused }
    val finished get() = ordered.filter { it.isFinished }
    val problems get() = ordered.filter { it.state is DownloadItem.State.Failed }

    fun pauseAll() = active.forEach(::pause)

    /** Seconds left at the current speed, when there is one to go by. */
    fun remainingSeconds(item: DownloadItem): Double? {
        val speed = speeds[item.id] ?: return null
        if (item.state != DownloadItem.State.Downloading || item.expected <= 0 || speed <= 0) return null
        return (item.expected - item.written) / speed
    }

    /** Deletes finished copies watched more than `days` ago. */
    fun pruneWatched(days: Int, watchedAt: (PlaybackTarget) -> Instant?) {
        if (days <= 0) return
        val cutoff = now().minus(Duration.ofDays(days.toLong()))
        for (item in finished) watchedAt(item.target)?.let { if (it.isBefore(cutoff)) delete(item) }
    }

    // The transfer

    private fun partFile(id: String) = File(folder, ".${safeName(id)}.part")

    private fun begin(id: String) {
        jobs.remove(id)?.cancel()
        jobs[id] = Platform.scope.launch { transfer(id) }
        changed()
    }

    private suspend fun transfer(id: String) {
        val item = items[id] ?: return
        val part = partFile(id)
        try {
            while (!networkAllowed(items[id] ?: return)) delay(5000)
            val offset = if (part.exists()) part.length() else 0L
            val request = Request.Builder().url(HTTP.parse(item.remoteURL)).header("User-Agent", HTTP.userAgent)
                .apply { if (offset > 0) header("Range", "bytes=$offset-") }.build()
            val response = client.newCall(request).await()
            response.use {
                val status = response.code
                if (status !in 200..299) {
                    val message = if (status in listOf(403, 404, 410)) "The link expired. Retry fetches a fresh one." else "The server answered $status."
                    failed(id, message, canResume = false, status = status)
                    return
                }
                // A server that ignored the range sends the whole file again: start over.
                val resuming = status == 206 && offset > 0
                val total = response.body.contentLength().let { if (it > 0) it + (if (resuming) offset else 0) else 0 }
                withContext(Dispatchers.IO) {
                    RandomAccessFile(part, "rw").use { out ->
                        if (!resuming) out.setLength(0)
                        out.seek(if (resuming) offset else 0)
                        var written = if (resuming) offset else 0L
                        val buffer = ByteArray(256 * 1024)
                        var lastHop = 0L
                        response.body.byteStream().use { input ->
                            while (true) {
                                ensureActive()
                                val read = input.read(buffer)
                                if (read < 0) break
                                out.write(buffer, 0, read)
                                written += read
                                val clock = System.nanoTime()
                                if (clock - lastHop > 500_000_000L) {
                                    lastHop = clock
                                    val bytes = written
                                    withContext(Platform.main) { progressed(id, bytes, total) }
                                }
                            }
                        }
                    }
                }
            }
            finishedTransfer(id, item)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A dropped connection keeps the bytes already saved; Retry carries on from there.
            failed(id, e.readable(), canResume = part.exists() && part.length() > 0)
        }
    }

    private fun progressed(id: String, written: Long, expected: Long) {
        // A report that was already on its way when the user paused doesn't count.
        if (items[id]?.state != DownloadItem.State.Downloading) return
        val time = now()
        val last = lastPublished[id]
        if (last != null && Duration.between(last, time).toMillis() < 800) return
        val previous = items[id]?.written ?: 0
        if (last != null && written > previous) {
            val seconds = Duration.between(last, time).toMillis() / 1000.0
            val instant = (written - previous) / seconds
            // Smoothed, so the figure doesn't jump about with every report.
            speeds = speeds + (id to (speeds[id]?.let { it * 0.7 + instant * 0.3 } ?: instant))
        }
        lastPublished[id] = time
        update(id, persist = false) { it.copy(written = written, expected = if (expected > 0) expected else it.expected) }
        items[id]?.let { onProgress?.invoke(it, speeds[id]) }
    }

    private fun finishedTransfer(id: String, item: DownloadItem) {
        var ext = item.remoteURL.substringBefore('?').substringAfterLast('.', "").lowercase()
        if (ext !in listOf("mkv", "mp4", "m4v", "avi", "ts", "webm", "mov")) ext = "mkv"
        val name = "${safeName(id)}.$ext"
        val destination = File(folder, name)
        destination.delete()
        if (!partFile(id).renameTo(destination)) {
            failed(id, "The file couldn't be saved.", canResume = false)
            return
        }
        jobs.remove(id)
        update(id) { it.copy(fileName = name, state = DownloadItem.State.Finished, written = maxOf(it.written, it.expected)) }
        speeds = speeds - id
        lastPublished.remove(id)
        recountBytes()
        items[id]?.let {
            onEvent?.invoke(Event.Finished(it))
            fetchSubtitles(it)
        }
    }

    private fun failed(id: String, message: String, canResume: Boolean, status: Int? = null) {
        if (items[id] == null) return
        jobs.remove(id)
        update(id) { it.copy(state = if (canResume) DownloadItem.State.Paused else DownloadItem.State.Failed(message), refusedStatus = status) }
        speeds = speeds - id
        lastPublished.remove(id)
        if (!canResume) items[id]?.let {
            onEvent?.invoke(Event.Failed(it, message))
            AppLog.record("Download ${it.target.displayTitle}", message)
        }
    }

    /** Saves subtitles in the preferred language beside the video, so they work offline too. */
    private fun fetchSubtitles(item: DownloadItem) {
        val languages = item.subtitleLanguages ?: emptyList()
        if (languages.isEmpty()) return
        Platform.scope.launch {
            val results = runCatching {
                OnlineSubtitles.search(item.target.item.kind, item.target.videoID, item.source.file ?: item.source.release, item.source.sizeBytes)
            }.getOrNull() ?: return@launch
            val pick = results.firstOrNull { it.language in languages } ?: return@launch
            val text = runCatching { HTTP.getText(pick.url) }.getOrNull()?.takeIf { it.isNotEmpty() } ?: return@launch
            val name = "${safeName(item.id)}.${pick.language}.srt"
            val saved = runCatching { withContext(Dispatchers.IO) { File(folder, name).writeText(text) } }.isSuccess
            if (saved) update(item.id) { it.copy(subtitleFiles = listOf(name)) }
        }
    }

    private fun removeFiles(item: DownloadItem) {
        item.fileName?.let { File(folder, it).delete() }
        item.subtitleFiles?.forEach { File(folder, it).delete() }
        partFile(item.id).delete()
    }

    private fun recountBytes() {
        usedBytes = folder.listFiles()?.sumOf { it.length() } ?: 0
        changed()
    }

    private fun update(id: String, persist: Boolean = true, change: (DownloadItem) -> DownloadItem) {
        val item = items[id] ?: return
        items = items + (id to change(item))
        changed()
        if (persist) save()
    }

    private fun save() {
        val snapshot = items
        writer.schedule(0.3) { ReelJson.encodeToString(snapshot) }
    }

    companion object {
        fun safeName(id: String) = id.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")
    }
}

