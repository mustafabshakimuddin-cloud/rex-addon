package community.reel.core

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.time.Year

/**
 * Stremio's public metadata catalogue: popular and top-rated lists, search, and title details with
 * episode lists. No key needed. Ids are IMDb ids, which is what Torrentio looks up.
 */
object Cinemeta {
    enum class Catalog(val raw: String, val title: String) {
        POPULAR("top", "Popular"),
        NEWEST("year", "New"),
        TOP_RATED("imdbRating", "Top Rated");

        /** The "year" list needs a year where the others take a genre. */
        val filtersByYear: Boolean get() = this == NEWEST
    }

    /** Years the New list offers, newest first. */
    val recentYears: List<String> get() {
        val year = Year.now().value
        return (0 until 12).map { (year - it).toString() }
    }

    const val PAGE_SIZE = 50
    val genres = listOf(
        "Action", "Adventure", "Animation", "Biography", "Comedy", "Crime", "Documentary", "Drama", "Family",
        "Fantasy", "History", "Horror", "Mystery", "Romance", "Sci-Fi", "Sport", "Thriller", "War", "Western",
    )

    /** The genres Cinemeta lists for films or for series; series add the television ones. */
    fun genres(kind: MediaKind): List<String> =
        if (kind == MediaKind.MOVIE) genres else (genres + listOf("Reality-TV", "Talk-Show", "Game-Show")).sorted()

    private const val CATALOG_BASE = "https://cinemeta-catalogs.strem.io"
    private const val API_BASE = "https://v3-cinemeta.strem.io"

    suspend fun catalog(kind: MediaKind, catalog: Catalog = Catalog.POPULAR, genre: String? = null, page: Int = 0): List<MediaItem> {
        val extras = mutableListOf<String>()
        var chosen = genre
        if (catalog.filtersByYear && chosen?.toIntOrNull() == null) chosen = recentYears.first()
        if (!chosen.isNullOrEmpty()) extras += "genre=${HTTP.pathValue(chosen)}"
        if (page > 0) extras += "skip=${page * PAGE_SIZE}"
        val extra = if (extras.isEmpty()) "" else "/" + extras.joinToString("&")
        val url = "$CATALOG_BASE/${catalog.raw}/catalog/${kind.raw}/${catalog.raw}$extra.json"
        val items = metas(HTTP.getJson(url)["metas"]).mapNotNull { item(it, kind) }
        // Early in January this year's list is nearly empty: follow it with last year's.
        val year = chosen?.toIntOrNull()
        if (catalog == Catalog.NEWEST && page == 0 && items.size < 20 && year == Year.now().value) {
            val previous = runCatching { catalog(kind, Catalog.NEWEST, (year - 1).toString()) }.getOrNull()
            if (previous != null) {
                val known = items.map { it.id }.toSet()
                return items + previous.filter { it.id !in known }
            }
        }
        return items
    }

    /** Titles from any Stremio catalogue address: Cinemeta's own, or an addon's. */
    suspend fun items(url: String, fallbackKind: MediaKind): List<MediaItem> =
        metas(HTTP.getJson(url)["metas"]).mapNotNull { item(it, fallbackKind) }

    suspend fun search(query: String, kind: MediaKind): List<MediaItem> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        val url = "$API_BASE/catalog/${kind.raw}/top/search=${HTTP.pathValue(trimmed)}.json"
        return metas(HTTP.getJson(url)["metas"]).mapNotNull { item(it, kind) }
    }

    data class Credits(val movies: List<MediaItem>, val series: List<MediaItem>, val directed: Set<String>)

    /**
     * Titles a person is in or directed. Cinemeta's search matches cast and directors as well as
     * names; results that don't credit the person are dropped unless nothing else is left.
     */
    suspend fun person(name: String): Credits = coroutineScope {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return@coroutineScope Credits(emptyList(), emptyList(), emptySet())
        suspend fun credits(kind: MediaKind): Pair<List<MediaItem>, Set<String>> {
            val url = "$API_BASE/catalog/${kind.raw}/top/search=${HTTP.pathValue(trimmed)}.json"
            val all = metas(HTTP.getJson(url)["metas"])
            val key = trimmed.lowercase()
            val credited = all.filter { meta -> (names(meta, "cast") + names(meta, "director")).any { it.lowercase() == key } }
            val chosen = credited.ifEmpty { all }
            val directed = chosen.filter { meta -> names(meta, "director").any { it.lowercase() == key } }
                .mapNotNull { item(it, kind)?.id }.toSet()
            return chosen.mapNotNull { item(it, kind) } to directed
        }
        val movies = async { credits(MediaKind.MOVIE) }
        val series = async { credits(MediaKind.SERIES) }
        val m = movies.await()
        val s = series.await()
        Credits(m.first, s.first, m.second + s.second)
    }

    private fun names(meta: JsonObject, key: String) = meta[key].strings()

    /**
     * The latest and next episodes of many series in one request, the way Stremio's calendar gets
     * them: each series comes back with about ten episodes around today.
     */
    suspend fun calendar(seriesIDs: List<String>): List<MediaDetail> = coroutineScope {
        val seen = mutableSetOf<String>()
        val ids = seriesIDs.filter { it.startsWith("tt") && seen.add(it) }
        if (ids.isEmpty()) return@coroutineScope emptyList()
        val chunks = ids.chunked(40)
        val details = mutableListOf<MediaDetail>()
        var firstError: Throwable? = null
        // Three requests at a time: quicker for a long list, still gentle on Cinemeta.
        for (batch in chunks.chunked(3)) {
            val results = batch.map { chunk ->
                async {
                    runCatching {
                        val url = "$API_BASE/catalog/series/calendar-videos/calendarVideosIds=${chunk.joinToString(",")}.json"
                        metas(HTTP.getJson(url)["metasDetailed"]).mapNotNull { detail(it, MediaKind.SERIES) }
                    }
                }
            }.awaitAll()
            for (result in results) {
                result.onSuccess { details += it }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it; if (firstError == null) firstError = it }
            }
        }
        if (details.isEmpty()) firstError?.let { throw it }
        details
    }

    suspend fun detail(kind: MediaKind, id: String): MediaDetail {
        val url = "$API_BASE/meta/${kind.raw}/${HTTP.pathValue(id)}.json"
        val meta = HTTP.getJson(url)["meta"].obj()
        return meta?.let { detail(it, kind) } ?: throw HttpStatusException(404, url)
    }

    // Wire format

    /** One malformed entry must not empty the whole row. */
    private fun metas(element: JsonElement?): List<JsonObject> = element.objects()

    fun item(meta: JsonObject, fallbackKind: MediaKind): MediaItem? {
        val imdb = listOf(meta["imdb_id"].string(), meta["id"].string()).firstOrNull { it?.startsWith("tt") == true } ?: return null
        val name = meta["name"].string()?.takeIf { it.isNotEmpty() } ?: return null
        val kind = MediaKind.of(meta["type"].string()) ?: fallbackKind
        val rating = meta["imdbRating"].string()?.toDoubleOrNull()?.let { String.format(java.util.Locale.ROOT, "%.1f", it) }
        var genres = meta["genres"].strings()
        if (genres.isEmpty()) genres = meta["genre"].strings()
        return MediaItem(
            id = imdb,
            kind = kind,
            name = name,
            poster = metahub(meta["poster"].string(), "medium"),
            background = metahub(meta["background"].string(), "large"),
            logo = metahub(meta["logo"].string(), "medium"),
            year = meta["releaseInfo"].string() ?: meta["year"].string(),
            rating = rating,
            genres = genres,
            overview = meta["description"].string(),
        )
    }

    fun detail(meta: JsonObject, fallbackKind: MediaKind): MediaDetail? {
        val item = item(meta, fallbackKind) ?: return null
        val episodes = meta["videos"].objects().mapNotNull { episode(it, item.id) }
        val trailers = meta["trailers"].objects()
            .filter { (it["type"].string() ?: "Trailer") == "Trailer" }
            .mapNotNull { it["source"].string() }
        return MediaDetail(
            item = item,
            runtime = meta["runtime"].string(),
            released = meta["released"].string()?.let(DateParsing::parse),
            cast = meta["cast"].strings().take(12),
            directors = meta["director"].strings(),
            episodes = episodes,
            trailerYouTubeID = trailers.firstOrNull(),
        )
    }

    fun episode(video: JsonObject, seriesID: String): Episode? {
        val season = video["season"].int() ?: return null
        val number = video["episode"].int() ?: video["number"].int() ?: return null
        if (season < 0 || number <= 0) return null
        val title = (video["name"].string() ?: video["title"].string())?.takeIf { it.isNotEmpty() }
        return Episode(
            id = video["id"].string() ?: "$seriesID:$season:$number",
            season = season,
            number = number,
            title = title ?: "Episode $number",
            overview = video["overview"].string() ?: video["description"].string(),
            thumbnail = video["thumbnail"].string()?.takeIf { it.isNotEmpty() },
            released = (video["released"].string() ?: video["firstAired"].string())?.let(DateParsing::parse),
        )
    }

    private val metahubSize = Regex("/(poster|background|logo)/(small|medium|large)/")

    /** Metahub serves several sizes behind the same path; pick a sharper one than the catalogue's. */
    fun metahub(url: String?, size: String): String? {
        if (url.isNullOrEmpty()) return null
        return metahubSize.replace(url, "/$1/$size/")
    }
}
