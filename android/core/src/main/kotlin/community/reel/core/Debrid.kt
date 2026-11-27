package community.reel.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import okhttp3.CacheControl
import okhttp3.Request
import java.io.IOException
import java.time.Duration
import java.time.Instant

/** What a debrid service says about the account behind an API key. */
@Serializable
data class DebridAccountInfo(
    val username: String? = null,
    val premium: Boolean? = null,
    val expires: Date? = null,
    val checkedAt: Date = now(),
) {
    val daysLeft: Int? get() = expires?.let { Duration.between(now(), it).toDays().toInt() }
}

class DebridAccountException(message: String) : IOException(message) {
    companion object {
        val refused get() = DebridAccountException("The debrid service refused the API key. Check it in Settings.")
        val expired get() = DebridAccountException("The debrid account's premium plan has ended. Renew it to stream.")
        val unsupported get() = DebridAccountException("")
    }
}

/**
 * Reads the account behind an API key from the service's own API. Unlike resolving a release, this
 * changes nothing on the account.
 */
object DebridAccount {
    fun supports(service: DebridService) = request(service, "x") != null

    suspend fun info(service: DebridService, rawKey: String): DebridAccountInfo {
        val key = rawKey.trim()
        val request = request(service, key) ?: throw DebridAccountException.unsupported
        val answer = HTTP.send(request)
        if (answer.status == 401 || answer.status == 403) throw DebridAccountException.refused
        if (!answer.ok) throw HttpStatusException(answer.status, request.url.toString())
        val info = parse(service, parseJson(answer.body))
        if (info.premium == false || info.expires?.isBefore(now()) == true) throw DebridAccountException.expired
        return info
    }

    fun request(service: DebridService, key: String): Request? {
        fun make(address: String, bearer: Boolean) = Request.Builder().url(address).cacheControl(CacheControl.FORCE_NETWORK)
            .apply { if (bearer) header("Authorization", "Bearer $key") }.build()
        val encoded = HTTP.queryValue(key)
        return when (service) {
            DebridService.REALDEBRID -> make("https://api.real-debrid.com/rest/1.0/user", true)
            DebridService.ALLDEBRID -> make("https://api.alldebrid.com/v4/user?agent=${AppConfig.NAME}&apikey=$encoded", true)
            DebridService.PREMIUMIZE -> make("https://www.premiumize.me/api/account/info?apikey=$encoded", false)
            DebridService.TORBOX -> make("https://api.torbox.app/v1/api/user/me", true)
            DebridService.DEBRIDLINK -> make("https://debrid-link.com/api/v2/account/infos", true)
            DebridService.PUTIO -> make("https://api.put.io/v2/account/info", true)
            DebridService.NONE, DebridService.EASYDEBRID, DebridService.OFFCLOUD -> null
        }
    }

    /** Each service shapes its answer differently; only what is there is read. */
    fun parse(service: DebridService, json: JsonElement?): DebridAccountInfo {
        // Seconds since 1970 when a number, an ISO date when text.
        fun date(value: JsonElement?): Instant? {
            val p = value as? kotlinx.serialization.json.JsonPrimitive ?: return null
            if (p is kotlinx.serialization.json.JsonNull) return null
            if (!p.isString) return p.double()?.takeIf { it > 0 }?.let { Instant.ofEpochSecond(it.toLong()) }
            return DateParsing.parse(p.content) ?: DateParsing.parseDay(p.content)
        }
        fun failed(ok: Boolean) { if (!ok) throw DebridAccountException.refused }
        return when (service) {
            DebridService.REALDEBRID -> DebridAccountInfo(json["username"].string(), json["type"].string()?.let { it == "premium" }, date(json["expiration"]))
            DebridService.ALLDEBRID -> {
                failed(json["status"].string() != "error")
                val user = json["data", "user"]
                DebridAccountInfo(user["username"].string(), user["isPremium"].bool(), date(user["premiumUntil"]))
            }
            DebridService.PREMIUMIZE -> {
                failed(json["status"].string() != "error")
                DebridAccountInfo(json["customer_id"].string(), null, date(json["premium_until"]))
            }
            DebridService.TORBOX -> {
                failed(json["success"].bool() != false)
                val data = json["data"]
                DebridAccountInfo(data["email"].string(), data["plan"].int()?.let { it > 0 }, date(data["premium_expires_at"]))
            }
            DebridService.DEBRIDLINK -> {
                failed(json["success"].bool() != false)
                val left = json["value", "premiumLeft"].double()
                DebridAccountInfo(json["value", "pseudo"].string(), left?.let { it > 0 },
                    left?.takeIf { it > 0 }?.let { now().plusSeconds(it.toLong()) })
            }
            DebridService.PUTIO -> DebridAccountInfo(json["info", "username"].string(), null, date(json["info", "plan_expiration_date"]))
            else -> throw DebridAccountException.unsupported
        }
    }
}

/**
 * What is already in a debrid account, ready to stream: torrents (or items) and their video files.
 * Uses the same API key as Torrentio. Real-Debrid, AllDebrid, Premiumize and TorBox are read.
 */
object DebridCloud {
    data class Entry(
        val id: String, val name: String, val bytes: Long, val added: Instant?,
        /** Files already known from the listing; empty when they are fetched on opening. */
        val files: List<File>,
        /** Not finished on the service's side yet. */
        val ready: Boolean = true,
    )

    data class File(val id: String, val name: String, val bytes: Long, /** What the service needs to hand out a link. */ val handle: String)

    class CloudException(message: String) : IOException(message) {
        companion object {
            val unsupported get() = CloudException("This debrid service's files can't be listed here.")
            val refused get() = CloudException("The debrid service refused the API key.")
            val noLink get() = CloudException("The service didn't hand out a link for this file.")
        }
    }

    fun supports(service: DebridService) = service in setOf(DebridService.REALDEBRID, DebridService.ALLDEBRID, DebridService.PREMIUMIZE, DebridService.TORBOX)

    val videoExtensions = setOf("mkv", "mp4", "m4v", "avi", "ts", "m2ts", "webm", "mov", "wmv")
    fun isVideo(name: String) = name.substringAfterLast('.', "").lowercase() in videoExtensions

    suspend fun list(service: DebridService, key: String): List<Entry> = when (service) {
        DebridService.REALDEBRID -> json(request("https://api.real-debrid.com/rest/1.0/torrents?limit=200", key)).objects().mapNotNull { t ->
            val id = t["id"].string() ?: return@mapNotNull null
            Entry(id, t["filename"].string() ?: id, t["bytes"].long() ?: 0, t["added"].string()?.let(DateParsing::parse), emptyList(),
                ready = t["status"].string() == "downloaded" && t["links"].strings().isNotEmpty())
        }
        DebridService.TORBOX -> json(request("https://api.torbox.app/v1/api/torrents/mylist?bypass_cache=true", key))["data"].objects().mapNotNull { item ->
            val id = item["id"].string() ?: return@mapNotNull null
            val files = item["files"].objects().mapNotNull { f ->
                val fileID = f["id"].string() ?: return@mapNotNull null
                File(fileID, f["short_name"].string() ?: f["name"].string() ?: fileID, f["size"].long() ?: 0, "$id:$fileID")
            }
            Entry(id, item["name"].string() ?: id, item["size"].long() ?: 0, item["created_at"].string()?.let(DateParsing::parse), files,
                ready = item["download_finished"].bool() ?: true)
        }
        DebridService.PREMIUMIZE -> {
            val json = json(request("https://www.premiumize.me/api/item/listall?apikey=${enc(key)}", null))
            if (json["status"].string() == "error") throw CloudException.refused
            // Premiumize lists files, not transfers: group them by their folder.
            json["files"].objects().mapNotNull { f ->
                val id = f["id"].string() ?: return@mapNotNull null
                val name = f["name"].string() ?: return@mapNotNull null
                val path = f["path"].string() ?: name
                val folder = path.substringBeforeLast('/', "")
                (folder.ifEmpty { name }) to File(id, name, f["size"].long() ?: 0, id)
            }.groupBy({ it.first }, { it.second }).map { (folder, group) ->
                Entry(folder, folder.substringAfterLast('/'), group.sumOf { it.bytes }, null, group)
            }
        }
        DebridService.ALLDEBRID -> {
            val json = json(request("https://api.alldebrid.com/v4.1/magnet/status?agent=${AppConfig.NAME}&apikey=${enc(key)}", key, post = true))
            if (json["status"].string() == "error") throw CloudException.refused
            json["data", "magnets"].objects().mapNotNull { m ->
                val id = m["id"].string() ?: return@mapNotNull null
                Entry(id, m["filename"].string() ?: id, m["size"].long() ?: 0, m["uploadDate"].long()?.let { Instant.ofEpochSecond(it) },
                    emptyList(), ready = m["statusCode"].int()?.let { it == 4 } ?: true)
            }
        }
        else -> throw CloudException.unsupported
    }

    /** The video files of one entry, fetched when it isn't in the listing already. */
    suspend fun files(entry: Entry, service: DebridService, key: String): List<File> {
        if (entry.files.isNotEmpty()) return entry.files.filter { isVideo(it.name) }
        return when (service) {
            DebridService.REALDEBRID -> {
                val info = json(request("https://api.real-debrid.com/rest/1.0/torrents/info/${entry.id}", key))
                // Links follow the selected files in order.
                val links = info["links"].strings()
                val selected = info["files"].objects().filter { it["selected"].int() == 1 }
                selected.zip(links).mapNotNull { (file, link) ->
                    val name = (file["path"].string() ?: "").substringAfterLast('/')
                    if (!isVideo(name)) null else File(file["id"].string() ?: link, name, file["bytes"].long() ?: 0, link)
                }
            }
            DebridService.ALLDEBRID -> {
                val json = json(request("https://api.alldebrid.com/v4/magnet/files?agent=${AppConfig.NAME}&apikey=${enc(key)}&id%5B%5D=${entry.id}", key, post = true))
                val found = mutableListOf<File>()
                // Files come as a tree: {n: name, s: size, l: link} or {n: folder, e: [children]}.
                fun walk(nodes: List<kotlinx.serialization.json.JsonObject>) {
                    for (node in nodes) {
                        val children = node["e"].objects()
                        if (node["e"] != null) { walk(children); continue }
                        val name = node["n"].string() ?: continue
                        val link = node["l"].string() ?: continue
                        if (isVideo(name)) found += File(link, name, node["s"].long() ?: 0, link)
                    }
                }
                for (magnet in json["data", "magnets"].objects()) walk(magnet["files"].objects())
                found
            }
            else -> emptyList()
        }
    }

    /** A direct, streamable address for a file. Unrestricting a link is a read; it adds nothing. */
    suspend fun link(file: File, service: DebridService, key: String): String = when (service) {
        DebridService.REALDEBRID -> {
            val request = request("https://api.real-debrid.com/rest/1.0/unrestrict/link", key).newBuilder()
                .post(formBody("link=${enc(file.handle)}")).build()
            json(request)["download"].string() ?: throw CloudException.noLink
        }
        DebridService.TORBOX -> {
            val parts = file.handle.split(":")
            if (parts.size != 2) throw CloudException.noLink
            json(request("https://api.torbox.app/v1/api/torrents/requestdl?token=${enc(key)}&torrent_id=${parts[0]}&file_id=${parts[1]}", key))["data"].string()
                ?: throw CloudException.noLink
        }
        DebridService.PREMIUMIZE -> {
            val json = json(request("https://www.premiumize.me/api/item/details?apikey=${enc(key)}&id=${enc(file.handle)}", null))
            json["link"].string() ?: json["stream_link"].string() ?: throw CloudException.noLink
        }
        DebridService.ALLDEBRID ->
            json(request("https://api.alldebrid.com/v4/link/unlock?agent=${AppConfig.NAME}&apikey=${enc(key)}&link=${enc(file.handle)}", key))["data", "link"].string()
                ?: throw CloudException.noLink
        else -> throw CloudException.unsupported
    }

    private fun request(address: String, key: String?, post: Boolean = false): Request = Request.Builder().url(address)
        .cacheControl(CacheControl.FORCE_NETWORK)
        .apply {
            key?.let { header("Authorization", "Bearer ${it.trim()}") }
            if (post) post(formBody(""))
        }.build()

    /** An account with nothing in it answers 204 with no body (Real-Debrid does): an empty list. */
    private suspend fun json(request: Request): JsonElement? {
        val answer = HTTP.send(request)
        if (answer.status == 401 || answer.status == 403) throw CloudException.refused
        if (!answer.ok) throw HttpStatusException(answer.status, request.url.toString())
        return parseJson(answer.body)
    }

    private fun enc(text: String) = HTTP.queryValue(text.trim())
}
