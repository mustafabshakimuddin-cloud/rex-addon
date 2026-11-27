package community.reel.app.ui

import community.reel.core.AppStores
import community.reel.core.Episode
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.PlaybackTarget
import community.reel.core.PlayerSession
import community.reel.core.Platform
import community.reel.core.StreamSource
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Opens one screen at launch when CI passes `--es ReelShot <screen>`, so the emulator job can
 * screenshot every screen, as the iOS tour does on the simulators. Does nothing otherwise.
 */
object ScreenshotTour {
    var isActive = false
        private set

    fun start(screen: String, router: AppRouter, stores: AppStores) {
        isActive = true
        val series = MediaItem("tt0903747", MediaKind.SERIES, "Breaking Bad",
            poster = "https://images.metahub.space/poster/medium/tt0903747/img",
            background = "https://images.metahub.space/background/medium/tt0903747/img",
            logo = "https://images.metahub.space/logo/medium/tt0903747/img",
            year = "2008", rating = "9.5", genres = listOf("Crime", "Drama"),
            overview = "A chemistry teacher diagnosed with cancer turns to making methamphetamine.")
        val target = PlaybackTarget(series, Episode("tt0903747:1:1", 1, 1, "Pilot"))
        Platform.scope.launch {
            delay(1500)
            when (screen) {
                "movies", "explore" -> { router.exploreKind = MediaKind.MOVIE; router.tab = AppTab.EXPLORE }
                "series" -> { router.exploreKind = MediaKind.SERIES; router.tab = AppTab.EXPLORE }
                "calendar" -> router.tab = AppTab.CALENDAR
                "library" -> router.tab = AppTab.LIBRARY
                "downloads" -> router.openLibrary(Route.Downloads)
                "history" -> router.openLibrary(Route.History)
                "search" -> router.tab = AppTab.SEARCH
                "settings" -> router.openSettings()
                "status" -> router.openSettings(SettingsPage.STATUS)
                "appearance" -> router.openSettings(SettingsPage.APPEARANCE)
                "setup" -> router.showingSetup = true
                "person" -> router.stack(AppTab.HOME).add(Route.Person("Bryan Cranston"))
                "detail" -> router.stack(AppTab.HOME).add(Route.Title(series))
                "sources" -> {
                    router.stack(AppTab.HOME).add(Route.Title(series))
                    delay(1000)
                    stores.playback.chooseSource(target)
                }
                "player" -> {
                    val source = StreamSource(id = "tour", addon = "Torrentio", quality = "1080p", tags = listOf("HDR"), release = "Sample stream",
                        size = "1.2 GB", sizeBytes = 1_288_490_188.0, cached = true)
                    stores.playback.session = PlayerSession(target,
                        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8", source, null)
                }
            }
        }
    }
}
