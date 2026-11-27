package community.reel.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.IOException
import java.time.Duration
import java.time.Instant
import java.util.UUID

/** What the player opens with: a resolved, directly playable address. */
data class PlayerSession(
    val target: PlaybackTarget,
    val url: String,
    val source: StreamSource,
    val startAt: Double?,
    /** What to try next, in order, if this source fails before its first picture. Empty for a hand-picked source. */
    val alternates: List<StreamSource> = emptyList(),
    val isLocal: Boolean = false,
    /** Downloaded subtitle files to add as tracks, for offline copies. */
    val localSubtitles: List<String> = emptyList(),
    /** A file from the debrid account's own list: no history, resume point or scrobble. */
    val isCloud: Boolean = false,
    val id: String = UUID.randomUUID().toString(),
)

class NoSourcesException(val any: Boolean) : IOException(
    if (any) "Releases were found, but none can stream right now. Try the Sources list or relax the filters in Settings."
    else "No releases were found for this title yet.",
)

object PlaybackErrors {
    /** What to tell the user, with the network named when it is the cause, and no key in sight. */
    fun describe(error: Throwable): String =
        if (HTTP.isOffline(error)) "You seem to be offline. Check your connection and try again." else error.readable()
}

/**
 * Turns "play this" into a running player: find sources across Torrentio and the user's addons,
 * rank them by what has actually played before, resolve the best through the debrid service
 * (falling back to the next if one fails, before or after the player opens), and present it.
 */
class PlaybackCenter(val memory: SourceMemory, val downloads: DownloadStore) : Observed() {
    var session: PlayerSession? = null
        set(value) { field = value; changed() }
    var preparing: PlaybackTarget? = null; private set
    var errorMessage: String? = null
        set(value) { field = value; changed() }
    var needsDebridSetup = false
        set(value) { field = value; changed() }
    /** Set to show the source list for a title. */
    var choosingSource: PlaybackTarget? = null
        set(value) { field = value; changed() }
    /** Shown briefly over the player while a failed source is being replaced. */
    var fallbackNotice: String? = null; private set
    /** Whether the source picked from that list should start over rather than resume. */
    var chooseFromStart = false; private set

    /** Fetches the first bytes of a likely pick, so Play starts at once. The player supplies it. */
    var prewarm: (suspend (String) -> Unit)? = null
    /** Opens a file and reads its real format. The player supplies it. */
    var verifier: (suspend (String) -> SourceVerification)? = null

    private var work: Job? = null
    private val prefetchJobs = mutableMapOf<String, Job>()
    private data class CachedSources(val query: SourceQuery, val sources: List<StreamSource>, val at: Instant)
    private val sourceCache = mutableMapOf<String, CachedSources>()
    private val resolvedCache = mutableMapOf<String, Pair<String, Instant>>()
    /** Run once the player has finished closing, instead of guessing how long that takes. */
    private var afterDismiss: (() -> Unit)? = null
    private val scope get() = Platform.scope

    companion object {
        private const val MAX_ATTEMPTS = 3
        private val SOURCE_LIFETIME = Duration.ofMinutes(10)
        private val RESOLVED_LIFETIME = Duration.ofMinutes(30)
    }

    private fun setPreparing(value: PlaybackTarget?) { preparing = value; changed() }
    private fun setNotice(value: String?) { fallbackNotice = value; changed() }

    // Sources

    /** Every source for a title, from a ten-minute cache when the same search ran recently. */
    suspend fun sources(target: PlaybackTarget, query: SourceQuery, refresh: Boolean = false): List<StreamSource> {
        if (!refresh) cachedSources(target, query)?.let { return it }
        val found = SourceFinder.find(target.item.kind, target.videoID, query)
        sourceCache[target.videoID] = CachedSources(query, found, now())
        if (sourceCache.size > 40) sourceCache.minByOrNull { it.value.at }?.key?.let { sourceCache.remove(it) }
        return found
    }

    fun cachedSources(target: PlaybackTarget, query: SourceQuery): List<StreamSource>? {
        val cached = sourceCache[target.videoID] ?: return null
        if (cached.query != query || Duration.between(cached.at, now()) >= SOURCE_LIFETIME) return null
        return cached.sources
    }

    /**
     * The final address of a source, reused for half an hour on the same debrid account: resolving
     * twice adds the same torrent to the account twice.
     */
    suspend fun resolve(source: StreamSource, account: String, fresh: Boolean = false): String {
        val key = account + "|" + source.fileKey
        val hit = resolvedCache[key]
        if (!fresh && hit != null && Duration.between(hit.second, now()) < RESOLVED_LIFETIME) return hit.first
        val url = Torrentio.resolve(source)
        resolvedCache[key] = url to now()
        return url
    }

    private fun forgetResolved(source: StreamSource) {
        resolvedCache.keys.filter { it.endsWith("|" + source.fileKey) }.forEach { resolvedCache.remove(it) }
    }

    /**
     * Called by a title page: look up its sources now so Play and the source list don't wait.
     * With "Get streams ready" on, also resolve the likely pick and fetch its first bytes. A second
     * after the page opens, so flicking through titles doesn't search for each one.
     */
    fun prefetch(target: PlaybackTarget, settings: AppSettings, immediately: Boolean = false, prepare: Boolean? = null) {
        if (!settings.canFindSources) return
        val query = settings.sourceQuery
        val shouldPrepare = prepare ?: settings.prepareAhead
        val account = settings.torrentio.accountFingerprint
        val preferences = settings.sourcePreferences
        prefetchJobs.remove(target.videoID)?.cancel()
        prefetchJobs[target.videoID] = scope.launch {
            if (!immediately) delay(1000)
            val all = runCatching { sources(target, query) }.getOrNull() ?: return@launch
            if (!shouldPrepare) return@launch
            val top = SourceRanker.rank(all, memory, preferences = preferences).firstOrNull { it.isCached } ?: return@launch
            val url = runCatching { resolve(top, account) }.getOrNull() ?: return@launch
            runCatching { prewarm?.invoke(url) }
        }
    }

    /** The title page closed before its prefetch ran: don't search for it. */
    fun cancelPrefetch(target: PlaybackTarget) {
        prefetchJobs.remove(target.videoID)?.cancel()
    }

    /** Opens the file and reads its real format, then remembers the answer for the source list. */
    suspend fun verify(source: StreamSource, settings: AppSettings): SourceVerification {
        val verifier = verifier ?: throw IOException("Checking a file isn't available on this device.")
        val url = resolve(source, settings.torrentio.accountFingerprint)
        val verification = verifier(url)
        memory.store(verification, source)
        return verification
    }

    // Downloading

    /** Saves a title for offline viewing: the source given, or the one Play would have picked under the download size limit. */
    fun download(target: PlaybackTarget, settings: AppSettings, source: StreamSource? = null) {
        if (!settings.canFindSources) { needsDebridSetup = true; return }
        val query = settings.downloadQuery
        val account = settings.torrentio.accountFingerprint
        val preferences = settings.sourcePreferences
        val options = DownloadStore.Options.from(settings)
        scope.launch {
            try {
                val candidates = if (source != null) listOf(source) else
                    SourceRanker.rank(sources(target, query), memory, preferences = preferences).filter { it.isCached }
                downloads.checkSpace(candidates.firstOrNull())
                var lastError: Throwable = NoSourcesException(any = candidates.isNotEmpty())
                for (candidate in candidates.take(3)) {
                    try {
                        val url = resolve(candidate, account)
                        downloads.start(target, candidate, url, options)
                        return@launch
                    } catch (e: NoSpaceException) {
                        throw e
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        lastError = e
                    }
                }
                throw lastError
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.readable()
            }
        }
    }

    /** Downloads several episodes in order (a season, or the next few), skipping those saved. */
    fun download(episodes: List<Episode>, item: MediaItem, settings: AppSettings) {
        val targets = episodes.filter { it.hasAired }.map { PlaybackTarget(item, it) }.filter { downloads.item(it) == null }
        if (targets.isEmpty()) return
        scope.launch {
            for (target in targets) {
                download(target, settings)
                // One search at a time is kinder to Torrentio and the debrid service.
                delay(1500)
            }
        }
    }

    /** Retry from Downloads: carry on where it stopped, or resolve the same release again for a fresh link. */
    fun retryDownload(item: DownloadItem, settings: AppSettings) {
        if (downloads.canResumeInPlace(item)) {
            downloads.resume(item)
            return
        }
        val account = settings.torrentio.accountFingerprint
        scope.launch {
            try {
                forgetResolved(item.source)
                downloads.restart(item, resolve(item.source, account, fresh = true))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.readable()
            }
        }
    }

    // Playing

    fun play(target: PlaybackTarget, settings: AppSettings, library: Library, source: StreamSource? = null,
             fromStart: Boolean = false, automatic: Boolean = false, preferGroup: String? = null) {
        val startAt = if (fromStart) null else library.resumePosition(target)
        // A finished download plays from the device, with no network and no debrid service.
        if (source == null) downloads.completedFile(target)?.let { local ->
            errorMessage = null
            session = PlayerSession(target, local.file.toURI().toString(), local.source, startAt, isLocal = true,
                localSubtitles = local.subtitles.map { it.toURI().toString() })
            return
        }
        if (!settings.canFindSources) { needsDebridSetup = true; return }
        // Unless "play the best source automatically" is on, Play opens the source list.
        if (source == null && !settings.autoPlayBest && !automatic) {
            chooseSource(target, fromStart)
            return
        }
        work?.cancel()
        setPreparing(target)
        errorMessage = null
        val query = settings.sourceQuery
        val account = settings.torrentio.accountFingerprint
        val preferences = settings.sourcePreferences
        work = scope.launch {
            try {
                val candidates = if (source != null) listOf(source) else {
                    val all = sources(target, query)
                    SourceRanker.rank(all, memory, preferGroup, preferences).ifEmpty { throw NoSourcesException(any = all.isNotEmpty()) }
                }
                open(target, candidates, startAt, account, if (source == null) MAX_ATTEMPTS else 1, keepAlternates = source == null)
            } catch (e: CancellationException) {
                setPreparing(null)
                throw e
            } catch (e: Exception) {
                setPreparing(null)
                errorMessage = PlaybackErrors.describe(e)
                AppLog.record("Play ${target.displayTitle}", e)
            }
        }
    }

    /** Plays a file straight from the debrid account's list. */
    fun playCloudFile(name: String, size: Long, url: String) {
        val item = MediaItem(id = "cloud:${url.substringAfterLast('/')}", kind = MediaKind.MOVIE, name = name)
        val source = StreamSource(
            id = url, addon = "Debrid", quality = StremioStreams.quality(emptyList(), name), tags = StremioStreams.tags(name),
            release = name, size = if (size > 0) formatBytes(size) else null, sizeBytes = size.toDouble(), cached = true, url = url,
        )
        errorMessage = null
        session = PlayerSession(PlaybackTarget(item), url, source, null, isLocal = true, isCloud = true)
    }

    /** Resolves candidates in order until one gives an address, then presents the player. */
    private suspend fun open(target: PlaybackTarget, candidates: List<StreamSource>, startAt: Double?, account: String,
                             attempts: Int, keepAlternates: Boolean) {
        var lastError: Throwable? = null
        for ((index, candidate) in candidates.take(attempts).withIndex()) {
            try {
                val url = resolve(candidate, account)
                setPreparing(null)
                val rest = if (keepAlternates) candidates.drop(index + 1).take(4) else emptyList()
                session = PlayerSession(target, url, candidate, startAt, rest)
                return
            } catch (e: ResolveException) {
                if (e.error == ResolveError.AccessDenied) throw e  // every source will fail the same way
                memory.noteFailure(candidate, e.readable())
                AppLog.record("Resolve ${candidate.releaseGroup ?: candidate.addon}", e)
                lastError = e
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // No network: the source isn't at fault, and the next one won't fare better.
                if (HTTP.isOffline(e)) throw e
                memory.noteFailure(candidate, e.readable())
                AppLog.record("Resolve ${candidate.releaseGroup ?: candidate.addon}", e)
                lastError = e
            }
        }
        throw lastError ?: NoSourcesException(any = true)
    }

    /** The player reports its first picture: this source works. */
    fun playerStarted(session: PlayerSession) { if (!session.isLocal) memory.noteSuccess(session.source) }

    fun playerStalled(session: PlayerSession) { if (!session.isLocal) memory.noteStall(session.source) }

    /** The player has finished closing. */
    fun playerDismissed() {
        val next = afterDismiss
        afterDismiss = null
        next?.invoke()
    }

    /** Closes the player, then runs `next` once it is off screen. */
    private fun closePlayer(next: () -> Unit) {
        if (session == null) next() else { afterDismiss = next; session = null }
    }

    /**
     * The player could not open its source. Remember that, and when the source was picked
     * automatically, quietly move on to the next one. Returns whether a replacement is coming.
     */
    fun playerFailed(failed: PlayerSession, reason: String, position: Double?, offline: Boolean, settings: AppSettings): Boolean {
        if (failed.isLocal) return false
        forgetResolved(failed.source)
        if (!offline) memory.noteFailure(failed.source, reason)
        AppLog.record("Player ${failed.target.displayTitle}", reason)
        if (failed.alternates.isEmpty() || offline) return false
        setNotice("That source didn't open. Trying the next one…")
        val startAt = position?.takeIf { it > 5 } ?: failed.startAt
        val account = settings.torrentio.accountFingerprint
        work?.cancel()
        setPreparing(failed.target)
        closePlayer {
            work = scope.launch {
                try {
                    open(failed.target, failed.alternates, startAt, account, MAX_ATTEMPTS, keepAlternates = true)
                } catch (e: CancellationException) {
                    setPreparing(null)
                    throw e
                } catch (e: Exception) {
                    setPreparing(null)
                    errorMessage = PlaybackErrors.describe(e)
                } finally {
                    setNotice(null)
                }
            }
        }
        return true
    }

    /** The link of a source that was playing stopped working: resolve the same release again. */
    suspend fun reconnect(session: PlayerSession, settings: AppSettings): String {
        if (session.isLocal) return session.url
        forgetResolved(session.source)
        return resolve(session.source, settings.torrentio.accountFingerprint, fresh = true)
    }

    fun chooseSource(target: PlaybackTarget, fromStart: Boolean = false) {
        chooseFromStart = fromStart
        choosingSource = target
    }

    /** From the player: close it (its progress is saved on the way out), then offer the list. */
    fun switchSource(target: PlaybackTarget) = closePlayer { chooseSource(target) }

    /** Up Next: close this episode and start the next with the same kind of release. */
    fun playNext(target: PlaybackTarget, current: PlayerSession, settings: AppSettings, library: Library) = closePlayer {
        play(target, settings, library, fromStart = true, automatic = true, preferGroup = current.source.bingeGroup)
    }

    fun cancel() {
        work?.cancel()
        work = null
        preparing = null
        fallbackNotice = null
        changed()
    }
}
