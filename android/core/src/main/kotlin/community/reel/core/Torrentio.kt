package community.reel.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import okhttp3.Request
import java.io.IOException

@Serializable
enum class DebridService(val raw: String, val title: String) {
    @SerialName("none") NONE("none", "None"),
    @SerialName("realdebrid") REALDEBRID("realdebrid", "Real-Debrid"),
    @SerialName("alldebrid") ALLDEBRID("alldebrid", "AllDebrid"),
    @SerialName("premiumize") PREMIUMIZE("premiumize", "Premiumize"),
    @SerialName("torbox") TORBOX("torbox", "TorBox"),
    @SerialName("debridlink") DEBRIDLINK("debridlink", "Debrid-Link"),
    @SerialName("easydebrid") EASYDEBRID("easydebrid", "EasyDebrid"),
    @SerialName("offcloud") OFFCLOUD("offcloud", "Offcloud"),
    @SerialName("putio") PUTIO("putio", "Put.io");

    /** The account page, to renew a plan. */
    val accountPage: String?
        get() = when (this) {
            NONE -> null
            REALDEBRID -> "https://real-debrid.com/premium"
            ALLDEBRID -> "https://alldebrid.com/offer/"
            PREMIUMIZE -> "https://www.premiumize.me/premium"
            TORBOX -> "https://torbox.app/pricing"
            DEBRIDLINK -> "https://debrid-link.com/premium"
            else -> keyPage
        }

    /** Where the user finds their API key. */
    val keyPage: String?
        get() = when (this) {
            NONE -> null
            REALDEBRID -> "https://real-debrid.com/apitoken"
            ALLDEBRID -> "https://alldebrid.com/apikeys"
            PREMIUMIZE -> "https://www.premiumize.me/account"
            TORBOX -> "https://torbox.app/settings"
            DEBRIDLINK -> "https://debrid-link.com/webapp/apikey"
            EASYDEBRID -> "https://paradise-cloud.com/products/easydebrid"
            OFFCLOUD -> "https://offcloud.com/#/account"
            PUTIO -> "https://app.put.io/oauth"
        }

    companion object {
        fun of(raw: String?): DebridService? = entries.firstOrNull { it.raw == raw }
    }
}

enum class TorrentioSort(val raw: String, val title: String) {
    QUALITY("quality", "Quality, then seeders"),
    QUALITY_SIZE("qualitysize", "Quality, then size"),
    SEEDERS("seeders", "Seeders"),
    SIZE("size", "Size");

    companion object {
        fun of(raw: String?): TorrentioSort? = entries.firstOrNull { it.raw == raw }
    }
}

/** The options Torrentio reads from the first path segment of its URLs: `key=value|key=value`. */
data class TorrentioConfig(
    val service: DebridService = DebridService.NONE,
    val key: String = "",
    val providers: List<String> = emptyList(),
    val excludedQualities: List<String> = emptyList(),
    val sort: TorrentioSort = TorrentioSort.QUALITY,
    val maxSizeGB: Int = 0,
    val cachedOnly: Boolean = true,
    /** Torrentio's address; a self-hosted instance can stand in for the public one. */
    val server: String = Torrentio.BASE,
    /** Torrentio's `language=` priority, e.g. ["french"]: those releases are listed first. */
    val priorityLanguages: List<String> = emptyList(),
    /** Torrentio's `limit=`: results per quality; 0 for all. */
    val perQualityLimit: Int = 0,
    /** Releases with fewer seeders are hidden (applied here; uncached torrents only). */
    val minSeeders: Int = 0,
) {
    val hasDebrid: Boolean get() = service != DebridService.NONE && key.trim().isNotEmpty()

    /**
     * Identifies the debrid account in memory caches, so links resolved through one account are
     * never reused after switching to another. Never stored.
     */
    val accountFingerprint: String get() = if (hasDebrid) "${service.raw}:${key.trim().hashCode()}" else "none"

    /** The server address without a trailing slash, or the public instance when it isn't usable. */
    val serverBase: String
        get() {
            var text = server.trim()
            while (text.endsWith("/")) text = text.dropLast(1)
            if (text.endsWith("/manifest.json")) text = text.dropLast("/manifest.json".length)
            val uri = runCatching { java.net.URI(text) }.getOrNull()
            if (uri?.scheme?.startsWith("http") != true || uri.host == null) return Torrentio.BASE
            return text
        }

    val pathSegment: String
        get() {
            val pairs = mutableListOf<String>()
            if (providers.isNotEmpty()) pairs += "providers=${providers.joinToString(",")}"
            if (sort != TorrentioSort.QUALITY) pairs += "sort=${sort.raw}"
            if (excludedQualities.isNotEmpty()) pairs += "qualityfilter=${excludedQualities.joinToString(",")}"
            if (maxSizeGB > 0) pairs += "sizefilter=${maxSizeGB}GB"
            if (priorityLanguages.isNotEmpty()) pairs += "language=${priorityLanguages.joinToString(",")}"
            if (perQualityLimit > 0) pairs += "limit=$perQualityLimit"
            if (hasDebrid) {
                if (cachedOnly) pairs += "debridoptions=nodownloadlinks"
                val cleanKey = key.trim().filter { it != '|' && it != '=' }
                pairs += "${service.raw}=$cleanKey"
            }
            return pairs.joinToString("|")
        }

    companion object {
        val allProviders = listOf(
            "yts", "eztv", "rarbg", "1337x", "thepiratebay", "kickasstorrents", "torrentgalaxy", "magnetdl",
            "horriblesubs", "nyaasi", "tokyotosho", "anidex", "rutor", "rutracker", "comando", "bludv",
            "torrent9", "ilcorsaronero", "mejortorrent", "wolfmax4k", "cinecalidad",
        )
        /** The language names Torrentio's `language=` option takes. */
        val languageOptions = listOf(
            "english", "japanese", "russian", "italian", "portuguese", "spanish", "latino", "korean", "chinese", "taiwanese",
            "french", "german", "dutch", "hindi", "telugu", "tamil", "polish", "lithuanian", "latvian", "estonian", "czech",
            "slovakian", "slovenian", "hungarian", "romanian", "bulgarian", "serbian", "croatian", "ukrainian", "greek",
            "danish", "finnish", "swedish", "norwegian", "turkish", "arabic", "persian", "hebrew", "vietnamese", "indonesian",
            "malay", "thai",
        )
        val qualityOptions = listOf("4k", "1080p", "720p", "480p", "scr", "cam", "unknown", "dolbyvision", "hdrall", "threed")
    }
}

object Torrentio {
    const val BASE = "https://torrentio.strem.fun"

    /** Encodes the config segment as iOS does: everything outside RFC 3986 path characters, and `/`. */
    internal fun encodeSegment(text: String): String {
        val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@"
        val out = StringBuilder()
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt().toChar()
            if (byte >= 0 && c in allowed) out.append(c) else out.append("%%%02X".format(byte.toInt() and 0xFF))
        }
        return out.toString()
    }

    suspend fun streams(kind: MediaKind, videoID: String, config: TorrentioConfig, label: String = "Torrentio"): List<StreamSource> {
        val segment = config.pathSegment
        val configPart = if (segment.isEmpty()) "" else "/" + encodeSegment(segment)
        val url = "${config.serverBase}$configPart/stream/${kind.raw}/${HTTP.idValue(videoID)}.json"
        return StremioStreams.fetch(url, addon = label)
    }

    /**
     * Torrentio's `/resolve/` links (and the playback links of other addons) make the debrid
     * service prepare the file, then redirect to it. Follow that one redirect here so the player
     * gets the final address, and turn Torrentio's "error videos" into readable errors. Only the
     * headers are read.
     */
    suspend fun resolve(source: StreamSource): String {
        val url = source.url ?: throw ResolveException(ResolveError.NotCached)
        if (!source.needsResolve) return url
        val request = Request.Builder().url(HTTP.parse(url)).header("User-Agent", HTTP.userAgent).build()
        HTTP.noRedirects.newCall(request).await().use { response ->
            val location = response.header("Location")
            if (location != null) {
                val target = runCatching { java.net.URI(url).resolve(location).toString() }.getOrNull() ?: location
                ResolveError.fromErrorVideo(target)?.let { throw ResolveException(it) }
                return target
            }
            if (response.isSuccessful) return url
            throw ResolveException(ResolveError.Unexpected("HTTP ${response.code}"))
        }
    }
}

sealed class ResolveError {
    data object AccessDenied : ResolveError()
    data object Downloading : ResolveError()
    data object Infringement : ResolveError()
    data object TooBig : ResolveError()
    data object Archive : ResolveError()
    data object NotCached : ResolveError()
    data object Limit : ResolveError()
    data class Unexpected(val detail: String) : ResolveError()

    val description: String
        get() = when (this) {
            AccessDenied -> "Your debrid service refused the API key. Check it in Settings."
            Downloading -> "This release isn't cached yet. Your debrid service is downloading it; try another source or come back later."
            Infringement -> "Your debrid service removed this file. Try another source."
            TooBig -> "This file is too big for your debrid service. Try a smaller source."
            Archive -> "This release is packed in an archive that can't be streamed. Try another source."
            NotCached -> "This source needs a debrid service. Add one in Settings."
            Limit -> "Your debrid service's limit was reached. Try again later."
            is Unexpected -> "Couldn't prepare this source ($detail)."
        }

    companion object {
        fun fromErrorVideo(url: String): ResolveError? {
            val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return null
            val path = uri.path ?: return null
            // Torrentio's explanatory clips live under /videos/ on its own host (or a self-hosted one).
            if (!path.contains("/videos/")) return null
            val name = path.substringAfterLast('/').substringBeforeLast('.')
            val known = listOf("failed_", "downloading").any { name.startsWith(it) } || name.contains("limit")
            if (uri.host?.contains("torrentio") != true && !known) return null
            return when {
                name.startsWith("failed_access") -> AccessDenied
                name.startsWith("downloading") -> Downloading
                name.startsWith("failed_infringement") -> Infringement
                name.startsWith("failed_too_big") -> TooBig
                name.startsWith("failed_rar") -> Archive
                name.contains("limit") -> Limit
                else -> Unexpected(name.replace("_", " "))
            }
        }
    }
}

class ResolveException(val error: ResolveError) : IOException(error.description)
