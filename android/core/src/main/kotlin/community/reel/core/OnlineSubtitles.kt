package community.reel.core

/**
 * Subtitles from OpenSubtitles through its public Stremio addon, which needs no account or key.
 * Used when a file carries nothing in the reader's language.
 */
object OnlineSubtitles {
    const val BASE = "https://opensubtitles-v3.strem.io"

    data class Result(val id: String, val url: String, /** ISO 639-2, e.g. "eng" */ val language: String)

    suspend fun search(kind: MediaKind, videoID: String, filename: String?, size: Double?): List<Result> {
        val extras = mutableListOf<String>()
        if (!filename.isNullOrEmpty()) extras += "filename=${HTTP.pathValue(filename)}"
        if (size != null && size > 0) extras += "videoSize=${size.toLong()}"
        val extra = if (extras.isEmpty()) "" else "/" + extras.joinToString("&")
        val json = HTTP.getJson("$BASE/subtitles/${kind.raw}/${HTTP.idValue(videoID)}$extra.json")
        val seen = mutableSetOf<String>()
        return json["subtitles"].objects().mapNotNull { raw ->
            val url = raw["url"].string() ?: return@mapNotNull null
            val lang = raw["lang"].string() ?: return@mapNotNull null
            if (!seen.add(url)) null else Result(raw["id"].string() ?: url, url, lang.lowercase())
        }
    }
}

/**
 * The Movie Database, for what Cinemeta doesn't have: photos and biographies of cast and crew.
 * Optional: it needs a free key of the user's own (an API key or a read access token).
 */
object TMDB {
    data class Person(
        val id: Int, val name: String, val photo: String?, val department: String?,
        val biography: String? = null, val birthday: String? = null, val birthplace: String? = null,
    )

    private val people = mutableMapOf<String, Person?>()
    private const val ACCOUNT = "tmdb.key"

    val key: String get() = Platform.secrets.read(ACCOUNT) ?: ""
    val isConfigured: Boolean get() = key.isNotBlank()
    fun setKey(value: String) = Platform.secrets.write(value.trim(), ACCOUNT)

    /** The person best matching a name, with a photo; null without a key or a match. */
    suspend fun person(name: String, details: Boolean = false): Person? {
        val cacheKey = name.lowercase()
        synchronized(people) {
            if (people.containsKey(cacheKey)) {
                val cached = people[cacheKey]
                if (!details || cached?.biography != null || cached == null) return cached
            }
        }
        if (!isConfigured) return null
        val search = runCatching { get("search/person", mapOf("query" to name, "include_adult" to "false")) }.getOrNull()
        val results = search["results"].objects()
        val best = results.firstOrNull { it["name"].string()?.equals(name, ignoreCase = true) == true } ?: results.firstOrNull()
        val id = best["id"].int()
        if (best == null || id == null) {
            synchronized(people) { people[cacheKey] = null }
            return null
        }
        var person = Person(id, best["name"].string() ?: name, best["profile_path"].string()?.let { "https://image.tmdb.org/t/p/w342$it" },
            best["known_for_department"].string())
        if (details) {
            runCatching { get("person/$id", emptyMap()) }.getOrNull()?.let { info ->
                person = person.copy(biography = info["biography"].string()?.ifEmpty { null }, birthday = info["birthday"].string(),
                    birthplace = info["place_of_birth"].string())
            }
        }
        synchronized(people) { people[cacheKey] = person }
        return person
    }

    /** Checks a key, for Settings. */
    suspend fun test(key: String): Boolean = runCatching { get("configuration", emptyMap(), key) }.isSuccess

    /** A v3 API key goes in the query; a v4 read access token (a long JWT) as a bearer token. */
    private suspend fun get(path: String, query: Map<String, String>, key: String = this.key): kotlinx.serialization.json.JsonElement? {
        val trimmed = key.trim()
        val isToken = trimmed.length > 40
        val items = query.map { "${it.key}=${HTTP.queryValue(it.value)}" } + if (isToken) emptyList() else listOf("api_key=${HTTP.queryValue(trimmed)}")
        val url = "https://api.themoviedb.org/3/$path" + if (items.isEmpty()) "" else "?" + items.joinToString("&")
        val request = okhttp3.Request.Builder().url(url).apply { if (isToken) header("Authorization", "Bearer $trimmed") }.build()
        val answer = HTTP.send(request)
        if (!answer.ok) throw HttpStatusException(answer.status, url)
        return parseJson(answer.body)
    }
}
