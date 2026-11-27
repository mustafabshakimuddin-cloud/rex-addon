package community.reel.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import java.io.IOException
import kotlin.math.pow

/**
 * One playable release from Torrentio or another Stremio addon, with the facts its free-text
 * fields carry pulled apart.
 */
@Serializable
data class StreamSource(
    val id: String,
    val addon: String,                 // "Torrentio", "Comet", …
    val addonHost: String? = null,     // the addon's own host: links on it redirect to the file
    val quality: String,               // "4K", "1080p", …
    val tags: List<String> = emptyList(), // "DV", "HDR", "HDR10+", "Atmos", …
    val release: String,               // torrent name
    val file: String? = null,          // file inside a pack, when different
    val size: String? = null,
    val sizeBytes: Double = 0.0,
    val seeders: Int? = null,
    val provider: String? = null,
    val languages: String? = null,
    val debridTag: String? = null,     // "RD+", "RD⚡", "RD download", …
    val cached: Boolean = false,
    val url: String? = null,           // debrid resolve link or direct file
    val infoHash: String? = null,
    val fileIndex: Int? = null,
    val bingeGroup: String? = null,
) {
    val isCached: Boolean get() = cached
    val isPlayable: Boolean get() = url != null
    val qualityRank: Int get() = QUALITY_ORDER.indexOf(quality).let { if (it < 0) QUALITY_ORDER.size else it }

    /** Identifies the same file across addons and sessions: the torrent and the file in it. */
    val fileKey: String
        get() = infoHash?.let { "${it.lowercase()}:${fileIndex?.toString() ?: file ?: ""}" } ?: url ?: id

    /** The scene group that made the release ("FLUX" in "Movie.2024.2160p.WEB-DL.DV-FLUX.mkv"). */
    val releaseGroup: String?
        get() {
            val name = Patterns.videoExtensionAtEnd.replace(file ?: release, "")
            val group = Patterns.releaseGroup.find(name)?.groupValues?.getOrNull(1)
            return group?.takeIf { it.isNotEmpty() }?.uppercase()
        }

    val hasDolbyVision: Boolean get() = "DV" in tags
    val hasHDR: Boolean get() = tags.any { it in setOf("HDR", "HDR10", "HDR10+", "DV", "HLG") }

    /**
     * A link on the addon's own host (or a Torrentio /resolve/ link) answers with a redirect to
     * the real file; anything else already is the file.
     */
    val needsResolve: Boolean
        get() {
            val url = url ?: return false
            val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return false
            if (uri.path?.contains("/resolve/") == true) return true
            if (addonHost != null && uri.host == addonHost) return true
            return false
        }

    companion object {
        val QUALITY_ORDER = listOf("4K", "1080p", "720p", "480p")
    }
}

/**
 * Reads a Stremio `/stream/` response. Torrentio, Comet, MediaFusion and most other addons share
 * the wire format but each writes its own `name`/`title` text, so the parsing is heuristic and only
 * ever adds facts: a field it cannot read stays empty.
 */
object StremioStreams {
    suspend fun fetch(url: String, addon: String): List<StreamSource> {
        val json = HTTP.getJson(url)
        val host = hostOf(url).ifEmpty { null }
        return json["streams"].objects().mapIndexedNotNull { index, raw -> source(RawStream.from(raw), index, addon, host) }
    }

    data class RawStream(
        var name: String? = null,
        var title: String? = null,
        var description: String? = null,
        var url: String? = null,
        var infoHash: String? = null,
        var fileIdx: Int? = null,
        var filename: String? = null,
        var bingeGroup: String? = null,
        var videoSize: Double? = null,
    ) {
        companion object {
            fun from(json: JsonObject) = RawStream(
                name = json["name"].string(),
                title = json["title"].string(),
                description = json["description"].string(),
                url = json["url"].string(),
                infoHash = json["infoHash"].string(),
                fileIdx = json["fileIdx"].int(),
                filename = json["behaviorHints", "filename"].string(),
                bingeGroup = json["behaviorHints", "bingeGroup"].string(),
                videoSize = json["behaviorHints", "videoSize"].double(),
            )
        }
    }

    private val markers = listOf("👤", "💾", "⚙️", "🔎")
    private fun isStats(line: String) = markers.any { line.contains(it) }

    private fun isDecoration(line: String): Boolean =
        line.startsWith("🇬") || line.startsWith("🌐") || line.codePoints().allMatch { !Character.isLetterOrDigit(it) }

    fun source(raw: RawStream, index: Int, addon: String, addonHost: String?): StreamSource? {
        // Torrentio: name "[RD+] Torrentio\n4k DV | HDR", title "Release\nfile.mkv\n👤 12 💾 4.1 GB ⚙️ YTS\n🇬🇧"
        // Comet:     name "[RD⚡] Comet 2160p", description "Release\n💾 15.3 GB 🔎 Provider"
        val name = raw.name ?: ""
        val text = raw.title ?: raw.description ?: ""
        val nameLines = name.split("\n")
        val head = nameLines.firstOrNull() ?: ""
        val debridTag = Regex("\\[([^\\]]+)\\]").find(head)?.groupValues?.get(1)
        val cached = (debridTag?.endsWith("+") ?: false) || name.contains("⚡") || name.contains("cached", ignoreCase = true)

        val lines = text.split("\n").map { it.trim() }.filter { it.isNotEmpty() }
        val statsIndex = lines.indexOfFirst { isStats(it) }.takeIf { it >= 0 }
        val textLines = (statsIndex?.let { lines.subList(0, it) } ?: lines).filter { !isDecoration(it) }
        // The stats run over the lines that carry their markers; what follows (Torrentio's language
        // flags) is separate, or the provider would read "YTS 🇬🇧 / 🇫🇷".
        val statsLines = statsIndex?.let { start -> lines.drop(start).takeWhile { isStats(it) } } ?: emptyList()
        val stats = statsLines.joinToString(" ")
        val afterStats = statsIndex?.let { lines.drop(it + statsLines.size) } ?: emptyList()

        val release = textLines.firstOrNull() ?: raw.filename ?: "Unknown release"
        val file = if (textLines.size > 1) textLines.last() else raw.filename?.takeIf { it != release }
        val haystack = listOf(name, release, file ?: "", raw.filename ?: "").joinToString(" ")

        val size = Patterns.size.find(stats)?.groupValues?.get(1)
        val sizeBytes = size?.let(::bytes) ?: raw.videoSize ?: 0.0
        val shownSize = size ?: if (sizeBytes > 0) formatBytes(sizeBytes.toLong()) else null
        val provider = (Patterns.providerGear.find(stats) ?: Patterns.providerSearch.find(stats))?.groupValues?.get(1)?.trim()

        return StreamSource(
            id = "$addon-$index-${raw.infoHash ?: raw.url ?: name}",
            addon = addon,
            addonHost = addonHost,
            quality = quality(nameLines, haystack),
            tags = tags(haystack),
            release = release,
            file = file,
            size = shownSize,
            sizeBytes = sizeBytes,
            seeders = Patterns.seeders.find(stats)?.groupValues?.get(1)?.toIntOrNull(),
            provider = provider,
            languages = if (afterStats.isEmpty()) null else afterStats.joinToString(" "),
            debridTag = debridTag,
            cached = cached,
            url = raw.url,
            infoHash = raw.infoHash?.lowercase(),
            fileIndex = raw.fileIdx,
            bingeGroup = raw.bingeGroup,
        )
    }

    fun quality(nameLines: List<String>, haystack: String): String {
        // Torrentio puts the resolution first on the name's second line.
        if (nameLines.size > 1) {
            val first = nameLines[1].split(' ', '|').firstOrNull { it.isNotEmpty() }
            if (first != null) {
                val token = first.lowercase()
                if (token == "4k") return "4K"
                if (token in listOf("1080p", "720p", "480p")) return token
            }
        }
        // A ".ts" extension is a container, not a telesync.
        val lower = Patterns.videoExtension.replace(haystack.lowercase(), " ")
        if (Patterns.uhd.containsMatchIn(lower)) return "4K"
        for (value in listOf("1080p", "720p", "480p")) if (lower.contains(value)) return value
        if (Patterns.cam.containsMatchIn(lower)) return "CAM"
        return "Other"
    }

    fun tags(haystack: String): List<String> {
        val tags = mutableListOf<String>()
        fun add(tag: String) { if (tag !in tags) tags += tag }
        val lower = haystack.lowercase()
        if (Patterns.dolbyVision.containsMatchIn(lower)) add("DV")
        if (Patterns.hdr10Plus.containsMatchIn(lower)) add("HDR10+") else if (Patterns.hdr.containsMatchIn(lower)) add("HDR")
        if (Patterns.hlg.containsMatchIn(lower)) add("HLG")
        if (lower.contains("atmos")) add("Atmos")
        if (Patterns.remux.containsMatchIn(lower)) add("Remux")
        if (Patterns.hevc.containsMatchIn(lower)) add("HEVC") else if (Patterns.av1.containsMatchIn(lower)) add("AV1")
        if (Patterns.threeD.containsMatchIn(lower)) add("3D")
        return tags
    }

    fun bytes(size: String): Double {
        val parts = size.replace(",", ".").split(" ").filter { it.isNotEmpty() }
        val number: Double
        var unit: String
        if (parts.size > 1) {
            number = parts[0].toDoubleOrNull() ?: 0.0
            unit = parts[1]
        } else {
            val text = parts.firstOrNull() ?: ""
            val digits = text.takeWhile { it.isDigit() || it == '.' }
            number = digits.toDoubleOrNull() ?: 0.0
            unit = text.drop(digits.length)
        }
        val powers = mapOf("B" to 0, "KB" to 1, "MB" to 2, "GB" to 3, "TB" to 4)
        return number * 1024.0.pow(powers[unit.uppercase()] ?: 0)
    }
}

/** "4.1 GB": decimal units, as file sizes are shown on Apple and Android alike. */
fun formatBytes(bytes: Long): String {
    if (bytes < 1000) return "$bytes bytes"
    val units = listOf("KB" to 0, "MB" to 1, "GB" to 2, "TB" to 2)
    var value = bytes / 1000.0
    var index = 0
    while (value >= 1000 && index < units.size - 1) { value /= 1000; index++ }
    val (unit, decimals) = units[index]
    var text = java.math.BigDecimal(value).setScale(decimals, java.math.RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()
    if (text.contains('E')) text = value.toLong().toString()
    return "$text $unit"
}

// Addons

/** One list an addon offers to browse ("Trending anime", "Netflix new releases"). */
@Serializable
data class AddonCatalog(val id: String, val type: String, val name: String) {
    val kind: MediaKind? get() = MediaKind.of(type)
}

/**
 * A Stremio addon the user added by its manifest address: its streams join Torrentio's, and its
 * catalogues appear in Explore.
 */
@Serializable
data class StreamAddon(
    val id: String,
    val name: String = id,
    val base: String,            // manifest address without "/manifest.json"
    val types: List<String> = emptyList(),
    val enabled: Boolean = true,
    /** null for addons saved before catalogues were read: those were stream addons. */
    val providesStreams: Boolean? = null,
    val catalogs: List<AddonCatalog>? = null,
) {
    val hasStreams: Boolean get() = providesStreams ?: true
    fun supports(kind: MediaKind) = types.isEmpty() || kind.raw in types
}

class AddonException(message: String) : IOException(message) {
    companion object {
        val invalidAddress get() = AddonException("That isn't an addon address. Paste the link that ends in manifest.json.")
        val noStreams get() = AddonException("This addon offers neither streams nor catalogues of films and series.")
    }
}

object Addons {
    /** Fetches the manifest at a pasted address (https://… or stremio://…) and describes the addon. */
    suspend fun install(text: String): StreamAddon {
        var address = text.trim()
        if (address.startsWith("stremio://")) address = "https://" + address.removePrefix("stremio://")
        if (address.endsWith("/")) address = address.dropLast(1)
        if (address.endsWith("/manifest.json")) address = address.dropLast("/manifest.json".length)
        val manifestURL = "$address/manifest.json"
        val uri = runCatching { java.net.URI(manifestURL) }.getOrNull()
        if (uri?.scheme?.startsWith("http") != true || uri.host == null) throw AddonException.invalidAddress
        val manifest = HTTP.getJson(manifestURL).obj() ?: throw AddonException.invalidAddress
        val parsed = Manifest.from(manifest)
        val catalogs = parsed.browsableCatalogs
        if (!parsed.providesStreams && catalogs.isEmpty()) throw AddonException.noStreams
        return StreamAddon(id = parsed.id, name = parsed.name, base = address, types = parsed.streamTypes,
            providesStreams = parsed.providesStreams, catalogs = catalogs)
    }

    /** A page of an addon's catalogue. Only titles with an IMDb id are kept. */
    suspend fun catalog(catalog: AddonCatalog, addon: StreamAddon, page: Int = 0): List<MediaItem> {
        val id = HTTP.pathValue(catalog.id)
        val skip = if (page > 0) "/skip=${page * 100}" else ""
        return Cinemeta.items("${addon.base}/catalog/${catalog.type}/$id$skip.json", catalog.kind ?: MediaKind.MOVIE)
    }

    suspend fun streams(addon: StreamAddon, kind: MediaKind, videoID: String): List<StreamSource> =
        StremioStreams.fetch("${addon.base}/stream/${kind.raw}/${HTTP.idValue(videoID)}.json", addon = addon.name)

    internal data class Manifest(
        val id: String,
        val name: String,
        val types: List<String>,
        val resources: List<Pair<String, List<String>?>>,
        val catalogs: List<JsonObject>,
    ) {
        val browsableCatalogs: List<AddonCatalog>
            get() = catalogs.mapNotNull { catalog ->
                val type = catalog["type"].string() ?: return@mapNotNull null
                val id = catalog["id"].string() ?: return@mapNotNull null
                // Listable without typing anything: no required search, genre or skip.
                val browsable = catalog["extra"].objects().none { it["isRequired"].bool() == true } &&
                    catalog["extraRequired"].strings().isEmpty()
                if (!browsable || MediaKind.of(type) == null) null
                else AddonCatalog(id = id, type = type, name = catalog["name"].string() ?: id)
            }

        val providesStreams: Boolean get() = resources.any { it.first == "stream" }
        val streamTypes: List<String> get() = resources.firstOrNull { it.first == "stream" }?.second ?: types

        companion object {
            fun from(json: JsonObject): Manifest {
                val resources = (json["resources"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { element ->
                    val single = (element as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content
                    if (single != null) single to null
                    else element.obj()?.let { o -> o["name"].string()?.let { it to o["types"].strings().ifEmpty { null } } }
                } ?: emptyList()
                return Manifest(
                    id = json["id"].string() ?: java.util.UUID.randomUUID().toString(),
                    name = json["name"].string() ?: "Addon",
                    types = json["types"].strings(),
                    resources = resources,
                    catalogs = json["catalogs"].objects(),
                )
            }
        }
    }
}

// Finding sources

/** What a source search needs from the settings, copied so it can run off the main thread. */
data class SourceQuery(
    val torrentio: TorrentioConfig,
    val addons: List<StreamAddon>,
    /** A second debrid service, searched alongside the first; it fills in what the first lacks. */
    val secondary: TorrentioConfig? = null,
)

class TimeoutError : IOException("The addon took too long to answer.")

object SourceFinder {
    /**
     * Torrentio and every enabled addon at once, merged. One addon failing or timing out never
     * hides the others' results; only when every one of them fails is that an error.
     */
    suspend fun find(kind: MediaKind, videoID: String, query: SourceQuery): List<StreamSource> = coroutineScope {
        val addons = query.addons.filter { it.enabled && it.hasStreams && it.supports(kind) }
        val jobs = mutableListOf<kotlinx.coroutines.Deferred<Result<List<StreamSource>>>>()
        jobs += async { runCatchingIO { Torrentio.streams(kind, videoID, query.torrentio) } }
        // The second service comes right after the first, ahead of the addons: the merge keeps the
        // first copy of a file, and a cached copy replaces one that isn't.
        val secondary = query.secondary
        if (secondary != null && secondary.hasDebrid) {
            jobs += async { runCatchingIO { Torrentio.streams(kind, videoID, secondary, "Torrentio · ${secondary.service.title}") } }
        }
        for (addon in addons) {
            jobs += async {
                runCatchingIO {
                    try {
                        withTimeout(20_000) { Addons.streams(addon, kind, videoID) }
                    } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                        throw TimeoutError()
                    }
                }
            }
        }
        val results = jobs.awaitAll()
        val lists = results.mapNotNull { it.getOrNull() }
        if (lists.isEmpty()) results.firstNotNullOfOrNull { it.exceptionOrNull() }?.let { throw it }
        merge(lists).filter { passes(it, query.torrentio) }
    }

    private suspend fun <T> runCatchingIO(work: suspend () -> T): Result<T> = try {
        Result.success(work())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }

    /**
     * Torrentio applies the quality, size and cache filters itself; other addons know nothing of
     * them, so the same rules are applied here to everything.
     */
    fun passes(source: StreamSource, config: TorrentioConfig): Boolean {
        val excluded = config.excludedQualities.toSet()
        when (source.quality) {
            "4K" -> if ("4k" in excluded) return false
            "1080p", "720p", "480p" -> if (source.quality in excluded) return false
            "CAM" -> if ("cam" in excluded || "scr" in excluded) return false
            "Other" -> if ("unknown" in excluded) return false
        }
        if ("dolbyvision" in excluded && source.hasDolbyVision) return false
        if ("hdrall" in excluded && source.hasHDR) return false
        if ("threed" in excluded && "3D" in source.tags) return false
        if (config.maxSizeGB > 0 && source.sizeBytes > config.maxSizeGB * 1_073_741_824.0) return false
        if (config.cachedOnly && config.hasDebrid && !source.isCached) return false
        val seeders = source.seeders
        if (config.minSeeders > 0 && !source.isCached && seeders != null && seeders < config.minSeeders) return false
        return true
    }

    /**
     * Keeps the first copy of each file (Torrentio's, then addons in the order they were added),
     * but a cached copy from a later addon replaces an uncached one.
     */
    fun merge(lists: List<List<StreamSource>>): List<StreamSource> {
        val order = mutableListOf<String>()
        val byKey = mutableMapOf<String, StreamSource>()
        for (list in lists) for (source in list) {
            val key = source.fileKey
            val existing = byKey[key]
            if (existing != null) {
                if (!existing.isCached && source.isCached && source.isPlayable) byKey[key] = source
            } else {
                byKey[key] = source
                order += key
            }
        }
        return order.mapNotNull { byKey[it] }
    }
}

/** The release-name patterns, compiled once: parsing a search runs them hundreds of times. */
object Patterns {
    private fun make(pattern: String, ignoreCase: Boolean = true) =
        Regex(pattern, if (ignoreCase) setOf(RegexOption.IGNORE_CASE) else emptySet())

    val videoExtensionAtEnd = make("\\.(mkv|mp4|avi|m4v|ts|webm)$")
    val videoExtension = make("\\.(mkv|mp4|avi|m4v|ts|m2ts|webm)\\b")
    val releaseGroup = make("-([A-Za-z0-9]{2,20})(?:\\[[^\\]]*\\])?$", ignoreCase = false)
    val size = make("💾\\s*([\\d.,]+\\s*[KMGT]?B)")
    val seeders = make("👤\\s*(\\d+)")
    val providerGear = make("⚙️\\s*([^💾👤🔎]+)")
    val providerSearch = make("🔎\\s*([^💾👤⚙️]+)")
    val uhd = make("\\b(2160p|4k|uhd)\\b")
    val cam = make("\\b(cam|camrip|hdcam|ts|hdts|tsrip|telesync)\\b")
    val dolbyVision = make("\\b(dv|dovi|dolby[ .]?vision)\\b")
    val hdr10Plus = make("hdr10(\\+|plus)")
    val hdr = make("\\bhdr(10)?\\b")
    val hlg = make("\\bhlg\\b")
    val remux = make("\\bremux\\b")
    val hevc = make("\\b(x265|hevc|h\\.?265)\\b")
    val av1 = make("\\bav1\\b")
    val threeD = make("\\b(3d|h-?sbs|half[ .-]?sbs|h-?ou|half[ .-]?ou)\\b")
}
