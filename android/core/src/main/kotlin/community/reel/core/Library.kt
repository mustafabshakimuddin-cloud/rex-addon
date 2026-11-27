package community.reel.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import java.io.File
import java.time.Instant

@Serializable
data class PlaybackProgress(
    val item: MediaItem,
    val episode: Episode? = null,
    val position: Double,
    val duration: Double,
    val updatedAt: Date,
    /** Marked as watched by hand rather than played: its duration is a stand-in. */
    val marked: Boolean? = null,
    /** Not played yet: the episode after the last one you finished, offered in Continue Watching. */
    val upNext: Boolean? = null,
) {
    val id: String get() = episode?.id ?: item.id
    val fraction: Double get() = if (duration > 0) (position / duration).coerceIn(0.0, 1.0) else 0.0
    val isFinished: Boolean get() = fraction >= Library.FINISHED_FRACTION
    val isUpNext: Boolean get() = upNext == true
    val target: PlaybackTarget get() = PlaybackTarget(item, episode)
}

private fun episodeOrder(a: Episode, b: Episode) = compareValuesBy(a, b, { it.season }, { it.number })

/**
 * Watchlist and playback positions, kept in a JSON file.
 *
 * Changes publish once per user action. Positions recorded while the player is open are kept
 * without publishing, so the screens behind the player don't redraw every ten seconds; they are
 * published when the player closes (`commitLive`).
 */
class Library(private var file: File = JSONFile.file("library.json")) : Observed() {
    companion object {
        const val FINISHED_FRACTION = 0.92
        const val MINIMUM_RESUME = 30.0
        /** Positions kept on disk; the oldest go first. */
        const val MAXIMUM_ENTRIES = 1500
        private const val FILE_VERSION = 2
    }

    var watchlist: List<MediaItem> = emptyList(); private set
    var progressMap: Map<String, PlaybackProgress> = emptyMap(); private set
    /** Watched on another device, as Trakt reports it, less those marked unwatched here since. */
    var externalWatched: Set<String> = emptySet(); private set
    private var unwatchedOverrides: Map<String, Instant> = emptyMap()
    private var traktWatchlist: Set<String>? = null
    private var upNext: Map<String, PlaybackProgress> = emptyMap()
    private var dismissedUpNext: Map<String, String> = emptyMap()
    private var knownEpisodes: Map<String, List<Episode>> = emptyMap()
    private var rawExternalWatched: Set<String> = emptySet()

    /** Bumped on every change, published or not; derived lists are cached against it. */
    var revision = 0L; private set

    /** Told about each watchlist change the user makes here, so Trakt can follow. */
    var onWatchlistChange: ((MediaItem, Boolean) -> Unit)? = null
    /** Told when titles are marked watched (true) or unwatched (false) by hand. */
    var onWatchedChange: ((List<PlaybackTarget>, Boolean) -> Unit)? = null

    private var writer = SnapshotWriter(file)
    /** Only family and animation titles in lists and rows: a kids profile. */
    var kidsOnly = false
        set(value) { field = value; publish() }

    private data class Cache(
        val revision: Long = -1,
        var history: List<PlaybackProgress>? = null,
        var continueWatching: List<PlaybackProgress>? = null,
        var furthest: Map<String, Pair<Int, Int>>? = null,
    )
    private var cache = Cache()

    init {
        read(file)?.let(::apply)
    }

    private fun touch() { revision += 1 }
    private fun publish() { touch(); changed() }

    /** Switches to another profile's library: what was here is saved first. */
    fun load(file: File) {
        saveNow()
        writer.waitUntilWritten()
        this.file = file
        writer = SnapshotWriter(file)
        knownEpisodes = emptyMap()
        apply(read(file) ?: Saved())
        publish()
    }

    private fun apply(saved: Saved) {
        watchlist = saved.watchlist
        progressMap = saved.progress
        rawExternalWatched = saved.externalWatched
        unwatchedOverrides = saved.unwatchedOverrides
        traktWatchlist = saved.traktWatchlist
        upNext = saved.upNext
        dismissedUpNext = saved.dismissedUpNext
        externalWatched = rawExternalWatched - unwatchedOverrides.keys
        touch()
    }

    // Watchlist

    fun isInWatchlist(item: MediaItem) = watchlist.any { it.id == item.id }

    fun toggleWatchlist(item: MediaItem) {
        val index = watchlist.indexOfFirst { it.id == item.id }
        if (index >= 0) {
            watchlist = watchlist.toMutableList().apply { removeAt(index) }
            onWatchlistChange?.invoke(item, false)
        } else {
            watchlist = listOf(item) + watchlist
            onWatchlistChange?.invoke(item, true)
        }
        publish()
        scheduleSave()
    }

    /**
     * Brings the watchlist in line with Trakt's. Titles Trakt has and this one lacks are added;
     * titles Trakt had at the last sync and no longer has were removed elsewhere, so they go here
     * too. Changes made here and not yet sent to Trakt are left alone.
     */
    fun applyTraktWatchlist(items: List<MediaItem>, pendingAdds: Set<String> = emptySet(), pendingRemovals: Set<String> = emptySet()) {
        val remote = items.map { it.id }.toSet()
        var changedAny = false
        traktWatchlist?.let { previous ->
            val removedElsewhere = previous - remote - pendingAdds
            if (removedElsewhere.isNotEmpty()) {
                val before = watchlist.size
                watchlist = watchlist.filter { it.id !in removedElsewhere }
                changedAny = changedAny || watchlist.size != before
            }
        }
        val known = watchlist.map { it.id }.toSet()
        val added = items.filter { it.id !in known && it.id !in pendingRemovals }
        if (added.isNotEmpty()) {
            watchlist = watchlist + added
            changedAny = true
        }
        if (traktWatchlist != remote) { traktWatchlist = remote; changedAny = true }
        if (changedAny) { publish(); scheduleSave() }
    }

    /** A resume point from another device, kept only when it is newer than the one here. */
    fun importResume(target: PlaybackTarget, fraction: Double, runtime: Double, at: Instant) {
        val existing = progressMap[target.videoID]
        if (existing != null && !existing.updatedAt.isBefore(at)) return
        val duration = maxOf(runtime, 60.0)
        val item = existing?.item ?: target.item
        progressMap = progressMap + (target.videoID to PlaybackProgress(item, target.episode, duration * fraction, duration, at))
        publish()
        scheduleSave(2.0)
    }

    /**
     * Trakt's watched history. An id marked unwatched here stays unwatched while Trakt still lists
     * it (the removal may not have reached Trakt yet); once Trakt agrees, the override goes.
     */
    fun setExternalWatched(movies: Set<String>, episodes: Set<String>) {
        val all = movies + episodes
        unwatchedOverrides = unwatchedOverrides.filterKeys { it in all }
        if (all == rawExternalWatched && externalWatched == all - unwatchedOverrides.keys) return
        rawExternalWatched = all
        externalWatched = all - unwatchedOverrides.keys
        touch()
        refreshAllUpNext()
        publish()
        scheduleSave(2.0)
    }

    /** Forgets Trakt's state, when Trakt is disconnected. */
    fun forgetTraktState() {
        rawExternalWatched = emptySet()
        externalWatched = emptySet()
        unwatchedOverrides = emptyMap()
        traktWatchlist = null
        publish()
        scheduleSave()
    }

    // Progress

    private fun cached(): Cache {
        if (cache.revision != revision) cache = Cache(revision)
        return cache
    }

    /** The newest unfinished entry per title, most recent first, with the next episode of series whose latest episode you finished. */
    val continueWatching: List<PlaybackProgress>
        get() {
            val cache = cached()
            cache.continueWatching?.let { return it }
            val seen = mutableSetOf<String>()
            val started = progressMap.values.filter { !it.isFinished && it.position >= MINIMUM_RESUME }
            val next = upNext.values.filter { entry ->
                val episode = entry.episode ?: return@filter false
                progressMap[episode.id] == null && episode.id !in externalWatched
            }
            val list = (started + next).sortedByDescending { it.updatedAt }.filter { seen.add(it.item.id) }
            cache.continueWatching = list
            return list
        }

    fun progress(target: PlaybackTarget): PlaybackProgress? = progressMap[target.videoID]

    fun resumePosition(target: PlaybackTarget): Double? {
        val entry = progressMap[target.videoID] ?: return null
        if (entry.isFinished || entry.position < MINIMUM_RESUME) return null
        return entry.position
    }

    fun isWatched(episode: Episode): Boolean = progressMap[episode.id]?.isFinished ?: (episode.id in externalWatched)
    fun isWatched(target: PlaybackTarget): Boolean = progressMap[target.videoID]?.isFinished ?: (target.videoID in externalWatched)

    /** A position from the player. With `live`, nothing is published until `commitLive()`. */
    fun record(target: PlaybackTarget, position: Double, duration: Double, live: Boolean = false) {
        if (duration <= 0 || !position.isFinite() || !duration.isFinite()) return
        val wasFinished = progressMap[target.videoID]?.isFinished ?: false
        progressMap = progressMap + (target.videoID to PlaybackProgress(target.item, target.episode, position, duration, now()))
        trimOverflow()
        touch()
        if (progressMap[target.videoID]?.isFinished == true && !wasFinished) refreshUpNext(target.item.id, target.item)
        if (!live) changed()
        // While playing, positions arrive every 10 s; the file only needs the last of a burst.
        scheduleSave(5.0)
    }

    /** Publishes the positions recorded while the player was open. */
    fun commitLive() {
        publish()
        saveNow()
    }

    fun clearProgress(entry: PlaybackProgress) {
        val episode = entry.episode
        if (entry.isUpNext && episode != null) {
            upNext = upNext - entry.item.id
            dismissedUpNext = dismissedUpNext + (entry.item.id to episode.id)
        } else {
            progressMap = progressMap - entry.id
        }
        publish()
        scheduleSave()
    }

    /** Everything opened, most recent first: the History screen's timeline. */
    val history: List<PlaybackProgress>
        get() {
            val cache = cached()
            cache.history?.let { return it }
            val list = progressMap.values.sortedByDescending { it.updatedAt }
            cache.history = list
            return list
        }

    fun clearHistory() {
        progressMap = emptyMap()
        upNext = emptyMap()
        publish()
        scheduleSave()
    }

    /** Marks a film or episode as seen without playing it. */
    fun markWatched(target: PlaybackTarget) {
        val duration = maxOf(progressMap[target.videoID]?.duration ?: 0.0, 60.0)
        progressMap = progressMap + (target.videoID to PlaybackProgress(target.item, target.episode, duration, duration, now(), marked = true))
        unwatchedOverrides = unwatchedOverrides - target.videoID
        externalWatched = rawExternalWatched - unwatchedOverrides.keys
        touch()
        refreshUpNext(target.item.id, target.item)
        onWatchedChange?.invoke(listOf(target), true)
        publish()
        scheduleSave()
    }

    fun markUnwatched(target: PlaybackTarget) = markUnwatched(listOf(target))

    fun markWatched(episodes: List<Episode>, item: MediaItem) {
        val time = now()
        val aired = episodes.filter { it.hasAired }
        val next = progressMap.toMutableMap()
        val overrides = unwatchedOverrides.toMutableMap()
        aired.forEachIndexed { offset, episode ->
            val duration = maxOf(next[episode.id]?.duration ?: 0.0, 60.0)
            // A second apart, so the latest episode is also the most recent in History.
            next[episode.id] = PlaybackProgress(item, episode, duration, duration, time.plusSeconds((offset - aired.size).toLong()), marked = true)
            overrides.remove(episode.id)
        }
        progressMap = next
        unwatchedOverrides = overrides
        externalWatched = rawExternalWatched - unwatchedOverrides.keys
        touch()
        refreshUpNext(item.id, item)
        onWatchedChange?.invoke(aired.map { PlaybackTarget(item, it) }, true)
        publish()
        scheduleSave()
    }

    fun markUnwatched(episodes: List<Episode>, item: MediaItem) = markUnwatched(episodes.map { PlaybackTarget(item, it) })

    private fun markUnwatched(targets: List<PlaybackTarget>) {
        if (targets.isEmpty()) return
        val time = now()
        val next = progressMap.toMutableMap()
        val overrides = unwatchedOverrides.toMutableMap()
        for (target in targets) {
            next.remove(target.videoID)
            if (target.videoID in rawExternalWatched) overrides[target.videoID] = time
        }
        progressMap = next
        unwatchedOverrides = overrides
        externalWatched = rawExternalWatched - unwatchedOverrides.keys
        touch()
        for (seriesID in targets.filter { it.episode != null }.map { it.item.id }.toSet()) {
            targets.firstOrNull { it.item.id == seriesID }?.item?.let { refreshUpNext(seriesID, it) }
        }
        onWatchedChange?.invoke(targets, false)
        publish()
        scheduleSave()
    }

    /**
     * The furthest regular episode of a series you've finished or started here, or that Trakt says
     * you watched, as (season, episode).
     */
    fun furthestEpisode(seriesID: String): Pair<Int, Int>? {
        val cache = cached()
        cache.furthest?.let { return it[seriesID] }
        // One pass over everything, for every series at once: New Episodes asks for each series.
        val furthest = mutableMapOf<String, Pair<Int, Int>>()
        fun consider(series: String, position: Pair<Int, Int>) {
            if (position.first <= 0) return  // specials don't move you along
            val current = furthest[series]
            if (current == null || compareValuesBy(position, current, { it.first }, { it.second }) > 0) furthest[series] = position
        }
        for (entry in progressMap.values) entry.episode?.let { consider(entry.item.id, it.season to it.number) }
        for (id in externalWatched) {
            val parts = id.split(":")
            val season = parts.getOrNull(1)?.toIntOrNull()
            val number = parts.getOrNull(2)?.toIntOrNull()
            if (parts.size == 3 && season != null && number != null) consider(parts[0], season to number)
        }
        cache.furthest = furthest
        return furthest[seriesID]
    }

    /**
     * The episode to offer next: the one after the latest watched, or the first. Episodes that
     * haven't aired are never offered; null means you're caught up (or nothing has aired).
     */
    fun nextEpisode(detail: MediaDetail): Episode? {
        val regular = detail.episodes.filter { it.season > 0 }.sortedWith(::episodeOrder)
        val latest = regular.indexOfLast { progressMap[it.id] != null || it.id in externalWatched }
        if (latest < 0) return regular.firstOrNull { it.hasAired }
        val current = regular[latest]
        val entry = progressMap[current.id]
        if (entry != null && !entry.isFinished && current.id !in externalWatched && current.hasAired) return current
        val next = regular.getOrNull(latest + 1) ?: return null
        return if (next.hasAired) next else null
    }

    /** The next episode still to air after the ones you've watched, when you're caught up. */
    fun caughtUp(detail: MediaDetail): Pair<Boolean, Episode?> {
        val regular = detail.episodes.filter { it.season > 0 }.sortedWith(::episodeOrder)
        if (regular.none { progressMap[it.id] != null || it.id in externalWatched } || nextEpisode(detail) != null) return false to null
        return true to regular.firstOrNull { !it.hasAired }
    }

    // Up next

    /** Remembers a series' episodes, so the episode after the one you finish can wait in Continue Watching. */
    fun learnEpisodes(detail: MediaDetail) {
        if (detail.item.kind != MediaKind.SERIES) return
        val regular = detail.episodes.filter { it.season > 0 }.sortedWith(::episodeOrder)
        if (knownEpisodes[detail.item.id] == regular) return
        knownEpisodes = knownEpisodes + (detail.item.id to regular)
        val item = progressMap.values.firstOrNull { it.item.id == detail.item.id }?.item ?: detail.item
        val before = upNext[detail.item.id]
        refreshUpNext(detail.item.id, item)
        if (upNext[detail.item.id] != before) {
            publish()
            scheduleSave()
        }
    }

    private fun refreshAllUpNext() {
        for (seriesID in knownEpisodes.keys) {
            val item = upNext[seriesID]?.item ?: progressMap.values.firstOrNull { it.item.id == seriesID }?.item
            if (item != null) refreshUpNext(seriesID, item)
        }
    }

    private fun refreshUpNext(seriesID: String, item: MediaItem) {
        if (item.kind != MediaKind.SERIES) return
        val episodes = knownEpisodes[seriesID] ?: return
        val detail = MediaDetail(item, episodes = episodes)
        val entries = episodes.mapNotNull { progressMap[it.id] }
        val next = nextEpisode(detail)
        if (next == null || progressMap[next.id] != null || dismissedUpNext[seriesID] == next.id) {
            if (upNext[seriesID] != null) { upNext = upNext - seriesID; touch() }
            return
        }
        // Only once a previous episode was finished: an episode merely started shows itself.
        val index = episodes.indexOfFirst { it.id == next.id }
        if (index <= 0) {
            if (upNext[seriesID] != null) { upNext = upNext - seriesID; touch() }
            return
        }
        val finishedAt = entries.maxOfOrNull { it.updatedAt } ?: now()
        val entry = PlaybackProgress(item, next, 0.0, 0.0, finishedAt, upNext = true)
        if (upNext[seriesID] != entry) { upNext = upNext + (seriesID to entry); touch() }
    }

    // Persistence

    @Serializable
    data class Saved(
        val version: Int = FILE_VERSION,
        val watchlist: List<MediaItem> = emptyList(),
        val progress: Map<String, PlaybackProgress> = emptyMap(),
        val externalWatched: Set<String> = emptySet(),
        val unwatchedOverrides: Map<String, Date> = emptyMap(),
        val traktWatchlist: Set<String>? = null,
        val upNext: Map<String, PlaybackProgress> = emptyMap(),
        val dismissedUpNext: Map<String, String> = emptyMap(),
    ) {
        companion object {
            /** Older files lack the newer fields, and one malformed entry only costs that entry. */
            fun decode(json: JsonElement): Saved {
                // A file that has neither list isn't a library at all: refuse it so it is kept aside.
                if (json["watchlist"] == null && json["progress"] == null) error("Not a library file")
                return Saved(
                    version = json["version"].int() ?: 1,
                    watchlist = json["watchlist"].lossyList(),
                    progress = json["progress"].lossyMap(),
                    externalWatched = json["externalWatched"].strings().toSet(),
                    unwatchedOverrides = json["unwatchedOverrides"].lossyMap<Date>(),
                    traktWatchlist = json["traktWatchlist"]?.takeIf { it is kotlinx.serialization.json.JsonArray }?.strings()?.toSet(),
                    upNext = json["upNext"].lossyMap(),
                    dismissedUpNext = json["dismissedUpNext"].lossyMap(),
                )
            }
        }
    }

    private fun read(file: File) = JSONFile.read(file, Saved::decode)

    private val snapshot: Saved
        get() = Saved(FILE_VERSION, watchlist, progressMap, rawExternalWatched, unwatchedOverrides, traktWatchlist, upNext, dismissedUpNext)

    private fun trimOverflow() {
        if (progressMap.size <= MAXIMUM_ENTRIES) return
        val overflow = progressMap.values.sortedBy { it.updatedAt }.take(progressMap.size - MAXIMUM_ENTRIES).map { it.id }.toSet()
        progressMap = progressMap.filterKeys { it !in overflow }
    }

    private fun scheduleSave(afterSeconds: Double = 0.4) {
        val snapshot = snapshot
        writer.schedule(afterSeconds) { ReelJson.encodeToString(Saved.serializer(), snapshot) }
    }

    fun saveNow() {
        val snapshot = snapshot
        writer.flush { ReelJson.encodeToString(Saved.serializer(), snapshot) }
    }

    /** For tests: wait for queued writes to reach the disk. */
    fun waitForSave() = writer.waitUntilWritten()

    // Backup

    fun exportData(): String = ReelJson.encodeToString(Saved.serializer(), snapshot)

    /** Replaces the library with a backup's. Throws when the data isn't a library. */
    fun importData(text: String) {
        apply(Saved.decode(ReelJson.parseToJsonElement(text)))
        publish()
        saveNow()
    }

    /** The titles a list shows: all of them, or with films you've watched left out. */
    fun shown(items: List<MediaItem>, hidingWatched: Boolean): List<MediaItem> {
        var shown = items
        // A kids profile sees family and animation titles only.
        if (kidsOnly) shown = shown.filter { "Family" in it.genres || "Animation" in it.genres }
        if (!hidingWatched) return shown
        return shown.filter { it.kind != MediaKind.MOVIE || !isWatched(PlaybackTarget(it)) }
    }
}
