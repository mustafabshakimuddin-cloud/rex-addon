package community.reel.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Interceptor
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.time.Duration

/**
 * The `mock` launch option: every request the app makes is answered here, from fixed data, so CI
 * screenshots show the same titles, sources and pictures on every run. Not used otherwise.
 */
object MockServer : Interceptor {
    /** Draws the placeholder picture for an address; the app supplies it (a soft gradient). */
    var picture: (String) -> ByteArray = { ByteArray(0) }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        // The player tour plays Apple's public test stream for real, as on iOS.
        if (request.url.host == "devstreaming-cdn.apple.com") return chain.proceed(request)
        val (status, type, body) = answer(request.url.toString())
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("Mock")
            .header("Content-Type", type).header("Cache-Control", "no-store")
            .body(body.toResponseBody(okhttp3.MediaType.Companion.run { type.toMediaTypeOrNull() })).build()
    }

    fun answer(url: String): Triple<Int, String, ByteArray> {
        val uri = runCatching { java.net.URI(url) }.getOrNull()
        val host = uri?.host ?: ""
        val path = uri?.rawPath ?: ""
        if (host.contains("metahub") || host.contains("image.tmdb") || path.endsWith(".jpg") || path.endsWith(".png")) {
            return Triple(200, "image/png", picture(url))
        }
        if (path.contains("/catalog/") && path.contains("calendar-videos")) return json(buildJsonObject { put("metasDetailed", JsonArray(listOf(seriesMeta()))) })
        if (path.contains("/catalog/")) return json(buildJsonObject { put("metas", JsonArray(catalog(path.contains("/series/")))) })
        if (path.contains("/meta/")) return json(buildJsonObject { put("meta", if (path.contains("/series/")) seriesMeta() else filmMeta()) })
        if (path.contains("/stream/")) return json(buildJsonObject { put("streams", streams) })
        if (path.contains("/subtitles/")) return json(buildJsonObject { put("subtitles", JsonArray(emptyList())) })
        if (path.endsWith("manifest.json")) return json(buildJsonObject {
            put("id", "mock"); put("name", "Mock")
            put("resources", buildJsonArray { add("stream") }); put("types", buildJsonArray { add("movie"); add("series") })
        })
        return Triple(404, "application/json", "{}".toByteArray())
    }

    private fun json(value: JsonElement) = Triple(200, "application/json", value.toString().toByteArray())

    private val genres = listOf(listOf("Drama", "Mystery"), listOf("Comedy", "Family"), listOf("Action", "Sci-Fi"), listOf("Animation", "Family"), listOf("Crime", "Thriller"))

    private fun strings(list: List<String>) = JsonArray(list.map { JsonPrimitive(it) })

    fun catalog(series: Boolean): List<JsonObject> = (1..12).map { index ->
        val id = "tt99%05d".format(index + if (series) 500 else 0)
        buildJsonObject {
            put("id", id); put("imdb_id", id); put("type", if (series) "series" else "movie")
            put("name", if (series) "Sample Series $index" else "Sample Film $index")
            put("poster", "https://images.metahub.space/poster/small/$id/img")
            put("background", "https://images.metahub.space/background/medium/$id/img")
            put("releaseInfo", if (series) "${2015 + index % 10}–" else "${2010 + index}")
            put("imdbRating", String.format(java.util.Locale.ROOT, "%.1f", 6.0 + (index % 4) * 0.8))
            put("genres", strings(genres[index % genres.size]))
            put("description", "A placeholder title for screenshots. Nothing here is real.")
        }
    }

    private fun filmMeta() = JsonObject(catalog(false)[0] + mapOf(
        "runtime" to JsonPrimitive("1h 52min"),
        "cast" to strings(listOf("Alex Example", "Sam Sample", "Jo Placeholder")),
        "director" to strings(listOf("Dee Rector")),
    ))

    /** Any series id gets this, episodes dated around today. */
    private fun seriesMeta(): JsonObject {
        val videos = (1..2).flatMap { season ->
            (1..8).map { number ->
                val offset = Duration.ofDays(((season - 1) * 8 + number - 12) * 7L)
                buildJsonObject {
                    put("id", "tt0903747:$season:$number"); put("season", season); put("episode", number)
                    put("name", "Chapter $number"); put("overview", "An episode description for screenshots.")
                    put("thumbnail", "https://images.metahub.space/background/small/ep$season$number/img")
                    put("released", now().plus(offset).toString())
                }
            }
        }
        return buildJsonObject {
            put("id", "tt0903747"); put("type", "series"); put("name", "Breaking Bad")
            put("poster", "https://images.metahub.space/poster/medium/tt0903747/img")
            put("background", "https://images.metahub.space/background/large/tt0903747/img")
            put("releaseInfo", "2008–2013"); put("imdbRating", "9.5"); put("genres", strings(listOf("Crime", "Drama")))
            put("description", "A placeholder series for screenshots."); put("runtime", "49 min")
            put("cast", strings(listOf("Alex Example", "Sam Sample"))); put("director", JsonArray(emptyList()))
            put("videos", JsonArray(videos))
        }
    }

    private val streams: JsonArray
        get() = JsonArray(listOf(
            Triple("[RD+] Torrentio\n4k DV | HDR", "Sample.2160p.WEB-DL.DV.HDR.Atmos-GRP\n👤 120 💾 18.2 GB ⚙️ Mock\n🇬🇧", "aaaa" to "4k"),
            Triple("[RD+] Torrentio\n1080p", "Sample.1080p.BluRay.x265-GRP\n👤 340 💾 4.1 GB ⚙️ Mock\n🇬🇧", "bbbb" to "1080"),
            Triple("[RD download] Torrentio\n720p", "Sample.720p.WEB-DL-GRP\n👤 55 💾 1.2 GB ⚙️ Mock", "cccc" to "720"),
        ).map { (name, title, extra) ->
            buildJsonObject {
                put("name", name); put("title", title); put("url", "https://example.invalid/${extra.second}.mkv")
                put("infoHash", extra.first); put("fileIdx", 0)
            }
        })
}
