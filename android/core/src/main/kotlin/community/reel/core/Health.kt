package community.reel.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import okhttp3.CacheControl
import okhttp3.Request
import java.io.IOException
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Checks the key the way playback will use it, without changing the account: the service's own
 * account page says whether the key is accepted and when the plan ends, and a Torrentio search with
 * the key must come back with instant releases. Nothing is resolved, so no torrent is added.
 */
object DebridCheck {
    data class Pass(val summary: String, val account: DebridAccountInfo?)

    suspend fun run(base: TorrentioConfig): Result<Pass> = try {
        val config = base.copy(cachedOnly = true)
        val account = if (DebridAccount.supports(config.service)) DebridAccount.info(config.service, config.key) else null
        val sources = Torrentio.streams(MediaKind.MOVIE, "tt0111161", config)
        if (sources.none { it.isCached && it.isPlayable }) {
            Result.failure(IOException("No instant sources came back. The key may be wrong, or the service may be down."))
        } else {
            var summary = "Working"
            account?.daysLeft?.let { days -> summary += if (days <= 0) ", plan ends today" else ", $days day${if (days == 1) "" else "s"} left" }
            Result.success(Pass(summary, account))
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }
}

/** One line of the Status page: what was checked, how it went, and what to do about it. */
data class HealthCheck(
    val id: String,
    val title: String,
    val icon: String,
    val level: Level,
    val detail: String,
    val advice: String? = null,
    val fix: Fix? = null,
    val fixTitle: String? = null,
) {
    enum class Level(val label: String) { OK("OK"), NOT_SET("Not set"), WARNING("WARN"), PROBLEM("FAIL") }

    /** Where the fix lives. */
    sealed class Fix {
        data class Settings(val page: String) : Fix()
        data object SettingsHome : Fix()
        data object Setup : Fix()
        data object Downloads : Fix()
        data class Link(val url: String) : Fix()
    }
}

/** Runs every check at once, each with its own time limit, so one slow service never holds up the page. */
class HealthModel : Observed() {
    var checks: List<HealthCheck> = emptyList(); private set
    var isRunning = false; private set
    var ranAt: Instant? = null; private set

    val worst: HealthCheck.Level get() = checks.maxOfOrNull { it.level } ?: HealthCheck.Level.OK
    val problemCount get() = checks.count { it.level == HealthCheck.Level.PROBLEM }
    val warningCount get() = checks.count { it.level == HealthCheck.Level.WARNING }

    val summary: String
        get() {
            if (isRunning && checks.isEmpty()) return "Checking…"
            val p = problemCount
            val w = warningCount
            return when {
                p == 0 && w == 0 -> "Everything is working"
                p == 0 -> if (w == 1) "1 thing to look at" else "$w things to look at"
                w == 0 -> if (p == 1) "1 problem" else "$p problems"
                else -> "$p problem${if (p == 1) "" else "s"}, $w to look at"
            }
        }

    /** Plain text for sharing, one check per line, like a command-line doctor. */
    val report: String
        get() {
            val format = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(ZoneId.systemDefault())
            val lines = mutableListOf("${AppConfig.NAME} status, ${format.format(now())}", "Version ${AppConfig.version} (Android)", "")
            for (check in checks) {
                lines += "[${check.level.label}] ${check.title}: ${Redact.text(check.detail)}"
                if (check.advice != null && check.level != HealthCheck.Level.OK) lines += "       Fix: ${check.advice}"
            }
            val log = AppLog.entries.take(20)
            if (log.isNotEmpty()) {
                lines += ""
                lines += "Recent errors:"
                for (entry in log) lines += "  ${format.format(entry.date)} ${entry.area}: ${entry.message}"
            }
            return lines.joinToString("\n")
        }

    private fun replace(check: HealthCheck) {
        val index = checks.indexOfFirst { it.id == check.id }
        checks = if (index >= 0) checks.toMutableList().apply { set(index, check) } else checks + check
        changed()
    }

    suspend fun run(settings: AppSettings, trakt: TraktStore, downloads: DownloadStore, memory: SourceMemory) {
        if (isRunning) return
        isRunning = true
        changed()
        try {
            // Instant checks first, so the page fills straight away.
            val instant = mutableListOf(streamingCheck(settings), rulesCheck(settings), historyCheck(memory), traktCheck(trakt))
            // Offline copies are an extra; their checks only appear once there are some.
            if (downloads.items.isNotEmpty()) instant += listOf(downloadsCheck(downloads), storageCheck(downloads))
            if (!settings.setupFinished) instant.add(0, HealthCheck("setup", "Setup", "setup", HealthCheck.Level.NOT_SET,
                "Setup was not finished.", "Run setup to choose how titles play.", HealthCheck.Fix.Setup, "Run Setup"))
            val config = settings.torrentio
            val addons = settings.addons.filter { it.enabled }
            checks = instant + pendingNetworkChecks(config, addons)
            changed()

            val torrentioURL = "${config.serverBase}/manifest.json"
            coroutineScope {
                launch { debridCheck(config, settings)?.let(::replace) }
                settings.secondaryTorrentio?.let { second -> launch { debridCheck(second, settings, primary = false)?.let(::replace) } }
                launch { replace(reachCheck("cinemeta", "Catalogue", "catalogue", "https://v3-cinemeta.strem.io/manifest.json", "Cinemeta")) }
                launch { replace(reachCheck("torrentio", "Torrentio", "search", torrentioURL, "Torrentio")) }
                // Each row is filled in as its check finishes, not when the slowest one does.
                for (addon in addons) launch { replace(addonCheck(addon)) }
            }
        } finally {
            isRunning = false
            ranAt = now()
            changed()
        }
    }

    private fun pendingNetworkChecks(config: TorrentioConfig, addons: List<StreamAddon>): List<HealthCheck> {
        val pending = mutableListOf(
            HealthCheck("cinemeta", "Catalogue", "catalogue", HealthCheck.Level.OK, "Checking…"),
            HealthCheck("torrentio", "Torrentio", "search", HealthCheck.Level.OK, "Checking…"),
        )
        if (config.hasDebrid) pending += HealthCheck("debrid", config.service.title, "key", HealthCheck.Level.OK, "Checking…")
        pending += addons.map { HealthCheck("addon:${it.id}", it.name, "addon", HealthCheck.Level.OK, "Checking…") }
        return pending
    }

    private fun streamingCheck(settings: AppSettings): HealthCheck {
        val addons = settings.addons.count { it.enabled }
        if (!settings.canFindSources) return HealthCheck("streaming", "Streaming", "play", HealthCheck.Level.PROBLEM,
            "Nothing can play yet: there is no debrid service and no addon.",
            "Add a debrid service such as Real-Debrid, or a Stremio addon that gives direct links.", HealthCheck.Fix.Setup, "Set Up")
        val parts = mutableListOf<String>()
        if (settings.isDebridConfigured) parts += settings.debridService.title
        if (addons > 0) parts += if (addons == 1) "1 addon" else "$addons addons"
        return HealthCheck("streaming", "Streaming", "play", HealthCheck.Level.OK, "Plays through ${parts.joinToString(" and ")}.")
    }

    /** What decides which release plays, in a line. Warns when Play may pick an uncached release. */
    private fun rulesCheck(settings: AppSettings): HealthCheck {
        val parts = mutableListOf(if (settings.autoPlayBest) "Play starts the best source" else "Play lists sources to pick from")
        if (settings.maxSizeGB > 0) parts += "up to ${settings.maxSizeGB} GB"
        if (settings.excludedQualities.isNotEmpty()) parts += "hides " + settings.excludedQualities.joinToString(", ") { qualityLabel(it) }
        if (settings.isDebridConfigured && !settings.cachedOnly) return HealthCheck("rules", "Pick rules", "rules", HealthCheck.Level.WARNING,
            "Instant only is off, so the list includes releases ${settings.debridService.title} hasn't cached. Those don't stream until the service has fetched them.",
            "Turn on Instant sources only for streams that start straight away.", HealthCheck.Fix.Settings("pickRules"), "Pick Rules")
        return HealthCheck("rules", "Pick rules", "rules", HealthCheck.Level.OK,
            (if (settings.isDebridConfigured) "Instant only; " else "") + parts.joinToString(", ") + ".", fix = HealthCheck.Fix.Settings("pickRules"), fixTitle = "Pick Rules")
    }

    private suspend fun debridCheck(config: TorrentioConfig, settings: AppSettings, primary: Boolean = true): HealthCheck? {
        if (!config.hasDebrid) return null
        val id = if (primary) "debrid" else "debrid2"
        return DebridCheck.run(config).fold(
            onSuccess = { pass ->
                if (primary) settings.debridAccount = pass.account
                var detail = "Key accepted; instant sources found."
                pass.account?.expires?.let { detail += " Plan ends ${DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault()).format(it)}." }
                val days = pass.account?.daysLeft
                if (days != null && days <= 7) HealthCheck(id, config.service.title, "key", HealthCheck.Level.WARNING, detail,
                    "Renew the plan, or streams stop when it ends.", config.service.accountPage?.let { HealthCheck.Fix.Link(it) }, "Renew")
                else HealthCheck(id, config.service.title, "key", HealthCheck.Level.OK, detail)
            },
            onFailure = { error ->
                HealthCheck(id, config.service.title, "key", HealthCheck.Level.PROBLEM, error.readable(),
                    "Check the API key in Settings. If it is right, the service may be down or your plan may have ended.",
                    config.service.keyPage?.let { HealthCheck.Fix.Link(it) } ?: HealthCheck.Fix.SettingsHome,
                    if (config.service.keyPage == null) "Settings" else "Get Key")
            },
        )
    }

    private suspend fun reachCheck(id: String, title: String, icon: String, url: String, service: String): HealthCheck {
        val failure = reach(url) ?: return HealthCheck(id, title, icon, HealthCheck.Level.OK, "$service is answering.")
        return HealthCheck(id, title, icon, HealthCheck.Level.PROBLEM, "$service didn't answer: $failure",
            "Check your internet connection. If it works elsewhere, $service may be down for a while.")
    }

    private suspend fun addonCheck(addon: StreamAddon): HealthCheck {
        val started = System.currentTimeMillis()
        val failure = reach("${addon.base}/manifest.json")
        val id = "addon:${addon.id}"
        if (failure == null) {
            val ms = System.currentTimeMillis() - started
            return HealthCheck(id, addon.name, "addon", HealthCheck.Level.OK,
                "Answering at ${hostOf(addon.base).ifEmpty { "its address" }} in $ms ms." + if (addon.base.startsWith("http://")) " Its address isn't encrypted." else "")
        }
        return HealthCheck(id, addon.name, "addon", HealthCheck.Level.WARNING, "Didn't answer: ${Redact.text(failure)}",
            "Turn it off under Stremio Addons, or install it again from its configure page.", HealthCheck.Fix.Settings("addons"), "Addons")
    }

    private fun traktCheck(trakt: TraktStore): HealthCheck {
        if (!trakt.isConnected) return HealthCheck("trakt", "Trakt", "sync", HealthCheck.Level.NOT_SET, "Not connected.",
            "Connect Trakt to keep My List and resume points in step across apps.", HealthCheck.Fix.Settings("trakt"), "Connect")
        trakt.syncError?.let { return HealthCheck("trakt", "Trakt", "sync", HealthCheck.Level.WARNING, it,
            "Sync again, or connect Trakt again if the sign-in expired.", HealthCheck.Fix.Settings("trakt"), "Trakt") }
        val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())
        val whenText = trakt.lastSync?.let { "Last synced ${time.format(it)}." } ?: "Connected."
        return HealthCheck("trakt", "Trakt", "sync", HealthCheck.Level.OK, whenText)
    }

    private fun downloadsCheck(downloads: DownloadStore): HealthCheck {
        val failed = downloads.problems.size
        if (failed > 0) return HealthCheck("downloads", "Offline copies", "download", HealthCheck.Level.WARNING,
            if (failed == 1) "1 download failed." else "$failed downloads failed.",
            "Retry them in Downloads; a fresh link is fetched if the old one expired.", HealthCheck.Fix.Downloads, "Downloads")
        val parts = mutableListOf("${downloads.finished.size} saved")
        if (downloads.active.isNotEmpty()) parts += "${downloads.active.size} downloading"
        if (downloads.paused.isNotEmpty()) parts += "${downloads.paused.size} paused"
        return HealthCheck("downloads", "Offline copies", "download", HealthCheck.Level.OK, parts.joinToString(", ") + ".",
            fix = HealthCheck.Fix.Downloads, fixTitle = "Downloads")
    }

    private fun storageCheck(downloads: DownloadStore): HealthCheck {
        val used = formatBytes(downloads.usedBytes)
        val free = downloads.freeBytes ?: return HealthCheck("storage", "Storage", "storage", HealthCheck.Level.OK, "$used used by downloads.")
        if (free < 3L shl 30) return HealthCheck("storage", "Storage", "storage", HealthCheck.Level.WARNING,
            "Only ${formatBytes(free)} free on this device.",
            "Delete downloads you have watched, or free space in Android Settings, before saving more.", HealthCheck.Fix.Downloads, "Downloads")
        return HealthCheck("storage", "Storage", "storage", HealthCheck.Level.OK, "${formatBytes(free)} free; downloads use $used.")
    }

    private fun historyCheck(memory: SourceMemory): HealthCheck {
        val files = memory.records.keys.count { it.startsWith("file:") }
        val checked = memory.verified.size
        val detail = if (files == 0) "Nothing learned yet. Picks improve as you play."
        else "Learned from $files release${if (files == 1) "" else "s"}" + if (checked > 0) ", $checked checked for format." else "."
        return HealthCheck("memory", "Source ranking", "ranking", HealthCheck.Level.OK, detail)
    }

    companion object {
        /** null when the address answered, otherwise why not. */
        suspend fun reach(address: String): String? = try {
            withTimeout(15_000) {
                val request = Request.Builder().url(HTTP.parse(address)).cacheControl(CacheControl.FORCE_NETWORK).build()
                val status = HTTP.client.newCall(request).await().use { it.code }
                if (status in 200..399) null else "HTTP $status"
            }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            "no answer in 15 seconds"
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e.readable()
        }

        /** The label for an excluded-quality name Torrentio takes, as Settings shows it. */
        fun qualityLabel(raw: String) = mapOf("4k" to "4K", "scr" to "Screener", "cam" to "Cam", "unknown" to "Unknown",
            "dolbyvision" to "Dolby Vision", "hdrall" to "HDR", "threed" to "3D")[raw] ?: raw
    }
}
