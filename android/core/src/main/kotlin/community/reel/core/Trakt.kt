package community.reel.core

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.Request
import java.io.IOException
import java.time.Instant

/**
 * The parts of the Trakt API the app uses: device sign-in, scrobbling, the watchlist, playback
 * progress and watched history.
 */
object Trakt {
    const val BASE = "https://api.trakt.tv"
    const val REDIRECT = "urn:ietf:wg:oauth:2.0:oob"

    @Serializable
    data class Credentials(val clientID: String, val clientSecret: String)

    @Serializable
    data class Token(val accessToken: String, val refreshToken: String, val expiresAt: Date) {
        val isExpiring: Boolean get() = expiresAt.epochSecond - now().epochSecond < 24 * 3600
    }

    data class DeviceCode(val deviceCode: String, val userCode: String, val verificationURL: String, val expiresIn: Int, val interval: Int)

    sealed class PollResult {
        data object Pending : PollResult()
        data object SlowDown : PollResult()
        data class Success(val token: Token) : PollResult()
        data class Failed(val message: String) : PollResult()
    }

    class TraktException(val code: Int) : IOException(
        if (code == 401) "Trakt signed this app out. Connect again in Settings." else "Trakt answered $code.",
    )

    // Sign-in

    suspend fun deviceCode(credentials: Credentials): DeviceCode {
        val json = parseJson(post("/oauth/device/code", buildJsonObject { put("client_id", credentials.clientID) }, credentials, null))
        return DeviceCode(
            deviceCode = json["device_code"].string() ?: throw IOException("Trakt's answer couldn't be read."),
            userCode = json["user_code"].string() ?: "",
            verificationURL = json["verification_url"].string() ?: "https://trakt.tv/activate",
            expiresIn = json["expires_in"].int() ?: 600,
            interval = json["interval"].int() ?: 5,
        )
    }

    suspend fun poll(code: DeviceCode, credentials: Credentials): PollResult = try {
        val body = buildJsonObject {
            put("code", code.deviceCode); put("client_id", credentials.clientID); put("client_secret", credentials.clientSecret)
        }
        PollResult.Success(decodeToken(post("/oauth/device/token", body, credentials, null)))
    } catch (e: TraktException) {
        when (e.code) {
            400 -> PollResult.Pending
            429 -> PollResult.SlowDown
            404 -> PollResult.Failed("Trakt didn't recognise the code. Start again.")
            409 -> PollResult.Failed("That code was already used. Start again.")
            410 -> PollResult.Failed("The code expired. Start again.")
            418 -> PollResult.Failed("The connection was declined on Trakt.")
            else -> PollResult.Failed("Trakt answered ${e.code}.")
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        PollResult.Failed(e.readable())
    }

    suspend fun refresh(token: Token, credentials: Credentials): Token {
        val body = buildJsonObject {
            put("refresh_token", token.refreshToken); put("client_id", credentials.clientID)
            put("client_secret", credentials.clientSecret); put("redirect_uri", REDIRECT); put("grant_type", "refresh_token")
        }
        return decodeToken(post("/oauth/token", body, credentials, null))
    }

    private fun decodeToken(text: String): Token {
        val json = parseJson(text)
        val created = json["created_at"].double() ?: throw IOException("Trakt's answer couldn't be read.")
        val expires = json["expires_in"].double() ?: 0.0
        return Token(
            accessToken = json["access_token"].string() ?: throw IOException("Trakt's answer couldn't be read."),
            refreshToken = json["refresh_token"].string() ?: "",
            expiresAt = Instant.ofEpochSecond((created + expires).toLong()),
        )
    }

    // Scrobbling

    enum class ScrobbleAction(val raw: String) { START("start"), PAUSE("pause"), STOP("stop") }

    suspend fun scrobble(action: ScrobbleAction, target: PlaybackTarget, progress: Double, credentials: Credentials, token: Token) {
        val body = JsonObject(identity(target) + ("progress" to JsonPrimitive(progress.coerceIn(0.0, 100.0))))
        post("/scrobble/${action.raw}", body, credentials, token)
    }

    private fun identity(target: PlaybackTarget): Map<String, JsonElement> {
        val episode = target.episode
        return if (episode != null) {
            mapOf(
                "show" to buildJsonObject { putJsonObject("ids") { put("imdb", target.item.id) } },
                "episode" to buildJsonObject { put("season", episode.season); put("number", episode.number) },
            )
        } else {
            mapOf("movie" to buildJsonObject { putJsonObject("ids") { put("imdb", target.item.id) } })
        }
    }

    // Watchlist

    suspend fun watchlist(credentials: Credentials, token: Token): List<MediaItem> = coroutineScope {
        val movies = async { get("/sync/watchlist/movies", credentials, token) }
        val shows = async { get("/sync/watchlist/shows", credentials, token) }
        (movies.await().objects() + shows.await().objects()).mapNotNull { entry ->
            entry["movie"].obj()?.let { work(it, MediaKind.MOVIE) } ?: entry["show"].obj()?.let { work(it, MediaKind.SERIES) }
        }
    }

    suspend fun setWatchlist(item: MediaItem, included: Boolean, credentials: Credentials, token: Token) {
        val key = if (item.kind == MediaKind.MOVIE) "movies" else "shows"
        val body = buildJsonObject { putJsonArray(key) { add(buildJsonObject { putJsonObject("ids") { put("imdb", item.id) } }) } }
        post(if (included) "/sync/watchlist" else "/sync/watchlist/remove", body, credentials, token)
    }

    // Progress and history

    data class Resume(val target: PlaybackTarget, val fraction: Double, val runtimeSeconds: Double, val pausedAt: Instant)

    suspend fun playback(credentials: Credentials, token: Token): List<Resume> =
        get("/sync/playback?extended=full", credentials, token).objects().mapNotNull(::resume)

    internal fun resume(entry: JsonObject): Resume? {
        val progress = entry["progress"].double() ?: return null
        // A stamp that can't be read counts as long ago, not as now: "now" would beat every
        // resume point recorded on this device.
        val pausedAt = entry["paused_at"].string()?.let(DateParsing::parse) ?: Instant.EPOCH
        val type = entry["type"].string()
        if (type == "movie") {
            val movie = entry["movie"].obj() ?: return null
            val item = work(movie, MediaKind.MOVIE) ?: return null
            return Resume(PlaybackTarget(item), progress / 100, (movie["runtime"].int() ?: 110) * 60.0, pausedAt)
        }
        if (type == "episode") {
            val show = entry["show"].obj() ?: return null
            val item = work(show, MediaKind.SERIES) ?: return null
            val ref = entry["episode"].obj() ?: return null
            val season = ref["season"].int() ?: return null
            val number = ref["number"].int() ?: return null
            val episode = Episode("${item.id}:$season:$number", season, number, ref["title"].string() ?: "Episode $number")
            val runtime = ref["runtime"].int() ?: show["runtime"].int() ?: 45
            return Resume(PlaybackTarget(item, episode), progress / 100, runtime * 60.0, pausedAt)
        }
        return null
    }

    /** Watched films by IMDb id, and watched episodes as Stremio video ids ("tt…:1:2"). */
    suspend fun watched(credentials: Credentials, token: Token): Pair<Set<String>, Set<String>> = coroutineScope {
        val movies = async { get("/sync/watched/movies", credentials, token) }
        val shows = async { get("/sync/watched/shows", credentials, token) }
        val movieIDs = movies.await().objects().mapNotNull { it["movie", "ids", "imdb"].string() }.toSet()
        val episodeIDs = mutableSetOf<String>()
        for (show in shows.await().objects()) {
            val imdb = show["show", "ids", "imdb"].string() ?: continue
            for (season in show["seasons"].objects()) {
                val number = season["number"].int() ?: continue
                for (episode in season["episodes"].objects()) {
                    episode["number"].int()?.let { episodeIDs += "$imdb:$number:$it" }
                }
            }
        }
        movieIDs to episodeIDs
    }

    /** Adds (with `watched_at`) or removes films and episodes from Trakt's watched history. */
    suspend fun history(targets: List<PlaybackTarget>, watched: Boolean, at: Instant, credentials: Credentials, token: Token) {
        val stamp = at.toString()
        val movies = mutableListOf<JsonObject>()
        val shows = linkedMapOf<String, java.util.TreeMap<Int, MutableList<JsonObject>>>()
        for (target in targets) {
            val episode = target.episode
            if (episode != null) {
                val entry = buildJsonObject { put("number", episode.number); if (watched) put("watched_at", stamp) }
                shows.getOrPut(target.item.id) { java.util.TreeMap() }.getOrPut(episode.season) { mutableListOf() } += entry
            } else {
                movies += buildJsonObject { putJsonObject("ids") { put("imdb", target.item.id) }; if (watched) put("watched_at", stamp) }
            }
        }
        if (movies.isEmpty() && shows.isEmpty()) return
        val body = buildJsonObject {
            if (movies.isNotEmpty()) put("movies", buildJsonArray { movies.forEach { add(it) } })
            if (shows.isNotEmpty()) put("shows", buildJsonArray {
                for ((imdb, seasons) in shows) add(buildJsonObject {
                    putJsonObject("ids") { put("imdb", imdb) }
                    put("seasons", buildJsonArray {
                        for ((number, episodes) in seasons) add(buildJsonObject {
                            put("number", number); put("episodes", buildJsonArray { episodes.forEach { add(it) } })
                        })
                    })
                })
            })
        }
        post(if (watched) "/sync/history" else "/sync/history/remove", body, credentials, token)
    }

    /** Rates a film or series from 1 to 10; 0 removes the rating. */
    suspend fun rate(item: MediaItem, rating: Int, credentials: Credentials, token: Token) {
        val key = if (item.kind == MediaKind.MOVIE) "movies" else "shows"
        val entry = buildJsonObject { putJsonObject("ids") { put("imdb", item.id) }; if (rating > 0) put("rating", rating) }
        post(if (rating > 0) "/sync/ratings" else "/sync/ratings/remove", buildJsonObject { putJsonArray(key) { add(entry) } }, credentials, token)
    }

    /** When each part of the account last changed, so a sync can skip what hasn't. */
    suspend fun lastActivities(credentials: Credentials, token: Token): Map<String, String> {
        val json = get("/sync/last_activities", credentials, token)
        fun stamp(group: String, field: String) = json[group, field].string() ?: ""
        return mapOf(
            "watched" to stamp("movies", "watched_at") + stamp("episodes", "watched_at"),
            "watchlist" to stamp("movies", "watchlisted_at") + stamp("shows", "watchlisted_at"),
            "playback" to stamp("movies", "paused_at") + stamp("episodes", "paused_at"),
        )
    }

    // Discovery

    enum class Discovery(val raw: String, val title: String) {
        TRENDING("trending", "Trending"),
        POPULAR("popular", "Popular on Trakt"),
        ANTICIPATED("anticipated", "Most Anticipated"),
        RECOMMENDED("recommended", "Recommended for You");

        val needsSignIn: Boolean get() = this == RECOMMENDED
    }

    /** Trending and anticipated wrap each title in an object; popular and recommended list them bare. */
    suspend fun discover(list: Discovery, kind: MediaKind, credentials: Credentials, token: Token?): List<MediaItem> {
        val type = if (kind == MediaKind.MOVIE) "movies" else "shows"
        val path = if (list == Discovery.RECOMMENDED) "/recommendations/$type?limit=30&ignore_collected=true" else "/$type/${list.raw}?limit=30"
        return parseWorks(get(path, credentials, if (list.needsSignIn) token else null), kind)
    }

    /** Titles Trakt's users watch alongside this one. */
    suspend fun related(item: MediaItem, credentials: Credentials): List<MediaItem> {
        val type = if (item.kind == MediaKind.MOVIE) "movies" else "shows"
        return parseWorks(get("/$type/${item.id}/related?limit=20", credentials, null), item.kind)
    }

    data class TraktList(val id: Int, val name: String, val itemCount: Int, val description: String?)

    suspend fun lists(credentials: Credentials, token: Token): List<TraktList> =
        get("/users/me/lists", credentials, token).objects().mapNotNull { entry ->
            val id = entry["ids", "trakt"].int() ?: return@mapNotNull null
            TraktList(id, entry["name"].string() ?: "List", entry["item_count"].int() ?: 0, entry["description"].string()?.ifEmpty { null })
        }

    suspend fun listItems(list: TraktList, credentials: Credentials, token: Token): List<MediaItem> =
        get("/users/me/lists/${list.id}/items/movie,show", credentials, token).objects().mapNotNull { entry ->
            entry["movie"].obj()?.let { work(it, MediaKind.MOVIE) } ?: entry["show"].obj()?.let { work(it, MediaKind.SERIES) }
        }

    private fun parseWorks(json: JsonElement?, kind: MediaKind): List<MediaItem> {
        val key = if (kind == MediaKind.MOVIE) "movie" else "show"
        return json.objects().mapNotNull { work(it[key].obj() ?: it, kind) }
    }

    /** A Trakt title with Cinemeta's artwork addresses, which are keyed by IMDb id. */
    fun work(work: JsonObject, kind: MediaKind): MediaItem? {
        val imdb = work["ids", "imdb"].string()?.takeIf { it.startsWith("tt") } ?: return null
        return item(imdb, kind, work["title"].string(), work["year"].int())
    }

    fun item(id: String, kind: MediaKind, title: String?, year: Int?) = MediaItem(
        id = id, kind = kind, name = title ?: id,
        poster = "https://images.metahub.space/poster/medium/$id/img",
        background = "https://images.metahub.space/background/medium/$id/img",
        logo = "https://images.metahub.space/logo/medium/$id/img",
        year = year?.toString(),
    )

    // Requests

    private fun request(path: String, credentials: Credentials, token: Token?) = Request.Builder()
        .url(BASE + path)
        .header("Content-Type", "application/json")
        .header("trakt-api-version", "2")
        .header("trakt-api-key", credentials.clientID)
        .apply { token?.let { header("Authorization", "Bearer ${it.accessToken}") } }

    private suspend fun get(path: String, credentials: Credentials, token: Token?): JsonElement? {
        val answer = HTTP.send(request(path, credentials, token).get().build())
        if (!answer.ok) throw TraktException(answer.status)
        return parseJson(answer.body)
    }

    private suspend fun post(path: String, body: JsonObject, credentials: Credentials, token: Token?): String {
        val answer = HTTP.send(request(path, credentials, token).post(jsonBody(body.toString())).build())
        if (!answer.ok) throw TraktException(answer.status)
        return answer.body
    }
}
