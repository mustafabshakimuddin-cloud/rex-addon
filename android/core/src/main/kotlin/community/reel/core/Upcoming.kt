package community.reel.core

import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** One episode on the calendar. */
data class CalendarEpisode(val item: MediaItem, val episode: Episode, val date: Instant) {
    val id: String get() = episode.id
    val target: PlaybackTarget get() = PlaybackTarget(item, episode)
    val hasAired: Boolean get() = !date.isAfter(now())
}

/**
 * New and upcoming episodes of the series you follow: those in My List and those you have watched
 * lately. One Cinemeta request covers them all, and the answer is reused for half an hour.
 */
class UpcomingStore : Observed() {
    var episodes: List<CalendarEpisode> = emptyList()
        private set(value) { field = value; newCache = null }
    private var newCache: Pair<Long, Map<String, List<CalendarEpisode>>>? = null
    var isLoading = false; private set
    var error: String? = null; private set
    var loadedAt: Instant? = null; private set
    private var loadedFor: List<String> = emptyList()

    companion object {
        private val LIFETIME = Duration.ofMinutes(30)
        val LOOK_BACK: Duration = Duration.ofDays(30)
        val LOOK_AHEAD: Duration = Duration.ofDays(180)
        /** How long an aired, unwatched episode counts as new. */
        val NEW_WINDOW: Duration = Duration.ofDays(14)

        /** Series in My List first, then those watched in the last three months, newest first. */
        fun followedSeries(library: Library): List<MediaItem> {
            val recentCutoff = now().minus(Duration.ofDays(90))
            val seen = mutableSetOf<String>()
            val listed = library.watchlist.filter { it.kind == MediaKind.SERIES }
            val watched = library.history.filter { it.item.kind == MediaKind.SERIES && it.updatedAt.isAfter(recentCutoff) }.map { it.item }
            return (listed + watched).filter { seen.add(it.id) }.take(80)
        }
    }

    suspend fun refresh(library: Library, force: Boolean = false) {
        val followed = followedSeries(library)
        val ids = followed.map { it.id }
        val loaded = loadedAt
        if (!force && ids == loadedFor && loaded != null && Duration.between(loaded, now()) < LIFETIME) return
        if (isLoading) return
        if (ids.isEmpty()) {
            episodes = emptyList(); loadedFor = emptyList(); loadedAt = now(); error = null
            changed()
            return
        }
        isLoading = true
        changed()
        try {
            val details = Cinemeta.calendar(ids)
            // Keep the library's own copy of each title: it has the artwork the lists showed.
            val known = followed.associateBy { it.id }
            val time = now()
            episodes = details.flatMap { detail ->
                val item = known[detail.item.id] ?: detail.item
                detail.episodes.mapNotNull { episode ->
                    val date = episode.released ?: return@mapNotNull null
                    if (episode.season <= 0 || !date.isAfter(time.minus(LOOK_BACK)) || !date.isBefore(time.plus(LOOK_AHEAD))) null
                    else CalendarEpisode(item, episode, date)
                }
            }.sortedWith(compareBy({ it.date }, { it.item.name }, { it.episode.number }))
            loadedFor = ids
            loadedAt = now()
            error = null
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.readable()
        } finally {
            isLoading = false
            changed()
        }
    }

    /**
     * Episodes aired in the last two weeks that come after the furthest one you have watched or
     * started in that series, grouped by series, each in episode order.
     */
    fun unwatchedNew(library: Library): Map<String, List<CalendarEpisode>> {
        newCache?.let { if (it.first == library.revision) return it.second }
        val cutoff = now().minus(NEW_WINDOW)
        val recent = episodes.filter { it.hasAired && it.date.isAfter(cutoff) }
        val bySeries = mutableMapOf<String, List<CalendarEpisode>>()
        for ((seriesID, entries) in recent.groupBy { it.item.id }) {
            val reached = library.furthestEpisode(seriesID)
            val ahead = entries.filter { entry ->
                if (reached != null && compareValuesBy(entry.episode.season to entry.episode.number, reached, { it.first }, { it.second }) <= 0) return@filter false
                !library.isWatched(entry.target) && library.progress(entry.target) == null
            }
            if (ahead.isNotEmpty()) bySeries[seriesID] = ahead.sortedWith(compareBy({ it.episode.season }, { it.episode.number }))
        }
        newCache = library.revision to bySeries
        return bySeries
    }

    /** One card per series: the next new episode to watch, most recently aired series first. */
    fun newEpisodes(library: Library): List<CalendarEpisode> {
        val latest = mutableMapOf<String, Instant>()
        for (entry in episodes) if (entry.hasAired) latest[entry.item.id] = maxOf(latest[entry.item.id] ?: Instant.MIN, entry.date)
        return unwatchedNew(library).values.mapNotNull { it.firstOrNull() }.sortedByDescending { latest[it.item.id] ?: it.date }
    }

    fun newEpisodeCount(library: Library) = unwatchedNew(library).values.sumOf { it.size }

    val upcoming: List<CalendarEpisode> get() = episodes.filter { !it.hasAired }
    val recent: List<CalendarEpisode> get() = episodes.filter { it.hasAired }.reversed()
    val airingToday: List<CalendarEpisode> get() = episodes.filter { LocalDate.ofInstant(it.date, ZoneId.systemDefault()) == LocalDate.now() }
}

/** When to announce an episode. */
object EpisodeTiming {
    /**
     * Cinemeta gives many air dates as midnight UTC, which isn't when anything is out; those are
     * announced at 9 in the morning, local time, on that day.
     */
    fun fireTime(date: Instant, zone: ZoneId = ZoneId.systemDefault()): Instant {
        val utc = date.atZone(ZoneOffset.UTC)
        if (utc.hour == 0 && utc.minute == 0) return LocalDateTime.of(utc.toLocalDate(), java.time.LocalTime.of(9, 0)).atZone(zone).toInstant()
        return date
    }
}

/** Upcoming episodes as an iCalendar file, for any calendar app. */
object CalendarExport {
    private val stampFormat = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC)
    private val dayFormat = DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneOffset.UTC)

    fun ics(episodes: List<CalendarEpisode>, now: Instant = community.reel.core.now()): String {
        val stamp = stampFormat.format(now)
        val lines = mutableListOf("BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//${AppConfig.NAME}//Upcoming episodes//EN", "CALSCALE:GREGORIAN")
        for (entry in episodes) {
            lines += listOf(
                "BEGIN:VEVENT",
                "UID:${entry.id}@${AppConfig.NAME.lowercase()}.app",
                "DTSTAMP:$stamp",
                // A whole-day event: air times in the catalogue are rarely the real hour.
                "DTSTART;VALUE=DATE:${dayFormat.format(entry.date)}",
                "DTEND;VALUE=DATE:${dayFormat.format(entry.date.plus(Duration.ofDays(1)))}",
                "SUMMARY:${escape("${entry.item.name} ${entry.episode.code}")}",
                "DESCRIPTION:${escape(entry.episode.title)}",
                "URL:reel://title/${entry.item.id}?type=series",
                "END:VEVENT",
            )
        }
        lines += "END:VCALENDAR"
        return lines.joinToString("\r\n") + "\r\n"
    }

    private fun escape(text: String) = text.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")
}

/** One file holding everything worth keeping that isn't a credential. */
object Backup {
    @kotlinx.serialization.Serializable
    private data class File(
        val app: String,
        val version: Int,
        val createdAt: Date,
        /** The library file's own JSON, as text. */
        val library: String,
        val sources: SourceMemory.Saved,
        val lists: List<CustomList>? = null,
        /** The settings, as key and text value. */
        val settings: Map<String, String>,
    )

    fun data(library: Library, memory: SourceMemory, lists: ListsStore?): String {
        val settings = Platform.defaults.all().filterKeys { key -> AppSettings.backupPrefixes.any { key.startsWith(it) } }
        val file = File(AppConfig.NAME, 1, now(), library.exportData(), memory.snapshot, lists?.lists, settings)
        return ReelJson.encodeToString(File.serializer(), file)
    }

    /** Restores a backup made here. Settings take effect after the app is opened again. */
    fun restore(text: String, library: Library, memory: SourceMemory, lists: ListsStore?) {
        val file = ReelJson.decodeFromString(File.serializer(), text)
        library.importData(file.library)
        memory.restore(file.sources)
        file.lists?.let { lists?.replaceAll(it) }
        for ((key, value) in file.settings) if (AppSettings.backupPrefixes.any { key.startsWith(it) }) Platform.defaults.putString(key, value)
    }

    fun fileName(): String = "${AppConfig.NAME} Backup ${LocalDate.now()}.json"
}
