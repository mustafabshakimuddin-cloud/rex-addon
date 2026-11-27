package community.reel.core

import kotlinx.coroutines.launch

/**
 * The app's long-lived stores, built in dependency order once. The Android app adds what only it
 * can do (notifications, the download service, widgets) through the hooks here.
 */
class AppStores {
    val settings = AppSettings()
    val library = Library()
    val memory = SourceMemory()
    val downloads = DownloadStore()
    val trakt = TraktStore()
    val alerts = AlertCenter()
    val upcoming = UpcomingStore()
    val lists = ListsStore()
    val profiles = ProfileStore()
    val playback = PlaybackCenter(memory, downloads)
    val health = HealthModel()

    /** Platform hooks. */
    var onDownloadFinished: ((DownloadItem) -> Unit)? = null
    var onDownloadEnded: ((DownloadItem, Boolean) -> Unit)? = null

    init {
        // The profile in use is settled before Trakt syncs, so its account fills its library.
        if (!profiles.current.isDefault) switchProfile(profiles.current)
        trakt.attach(library)
        downloads.onEvent = { event ->
            when (event) {
                is DownloadStore.Event.Finished -> {
                    onDownloadEnded?.invoke(event.item, true)
                    alerts.post("Downloaded", event.item.target.displayTitle, AppAlert.Level.SUCCESS, AppAlert.Action.OPEN_DOWNLOADS)
                    if (settings.notifyDownloads) onDownloadFinished?.invoke(event.item)
                }
                is DownloadStore.Event.Failed -> {
                    onDownloadEnded?.invoke(event.item, false)
                    alerts.post("Download failed", "${event.item.target.displayTitle}: ${event.message}", AppAlert.Level.PROBLEM, AppAlert.Action.OPEN_DOWNLOADS)
                }
            }
        }
        if (JSONFile.unreadableFiles.isNotEmpty()) {
            alerts.post("Some saved data couldn't be read",
                "It was kept aside, not deleted. Restore a backup in Settings if anything is missing.",
                AppAlert.Level.WARNING, AppAlert.Action.OPEN_STATUS)
        }
        current = this
    }

    /** Becomes someone else: their library, lists, player choices and Trakt account. */
    fun switchProfile(profile: Profile) {
        playback.session = null
        playback.cancel()
        profiles.select(profile)
        library.load(profile.file("library"))
        library.kidsOnly = profile.isKids
        lists.load(profile.file("lists"))
        trakt.switchProfile(profile)
    }

    /** Back in the foreground: sync, tidy downloads, and look at the debrid plan once a day. */
    fun becameActive() {
        Platform.scope.launch { trakt.sync() }
        downloads.pruneWatched(settings.deleteWatchedDownloadsAfterDays) { target ->
            library.progress(target)?.takeIf { it.isFinished }?.updatedAt
        }
        refreshDebridAccount()
    }

    fun wentToBackground() {
        library.saveNow()
        lists.saveNow()
        memory.saveNow()
    }

    private fun refreshDebridAccount() {
        val config = settings.torrentio
        if (!config.hasDebrid || !DebridAccount.supports(config.service)) return
        val checked = settings.debridAccount?.checkedAt
        if (checked != null && java.time.Duration.between(checked, now()).toHours() < 24) return
        Platform.scope.launch {
            runCatching { DebridAccount.info(config.service, config.key) }.onSuccess { settings.debridAccount = it }
        }
    }

    /** Opens what a link names: `reel://title/tt0111161?type=movie`, an IMDb title link, or `reel://resume/<video id>`. */
    fun open(url: String, router: (MediaItem) -> Unit, resume: (PlaybackProgress) -> Unit) {
        if (url.startsWith("reel://resume/")) {
            val videoID = java.net.URLDecoder.decode(url.removePrefix("reel://resume/").substringBefore('?'), "UTF-8")
            library.continueWatching.firstOrNull { it.id == videoID }?.let { resume(it); return }
        }
        val (id, kind) = title(url) ?: return
        router(MediaItem.placeholder(id, kind))
    }

    companion object {
        @Volatile var current: AppStores? = null

        fun title(url: String): Pair<String, MediaKind>? {
            val id = Regex("tt\\d{5,10}").find(url)?.value ?: return null
            val type = Regex("[?&]type=([a-z]+)").find(url)?.groupValues?.get(1)
            val kind = MediaKind.of(type) ?: if (url.contains("/series/") || url.contains("/tv/")) MediaKind.SERIES else MediaKind.MOVIE
            return id to kind
        }
    }
}
