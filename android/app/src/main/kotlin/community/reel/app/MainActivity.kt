package community.reel.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import community.reel.app.tv.TvRoot
import community.reel.app.ui.AppRouter
import community.reel.app.ui.LocalCardScale
import community.reel.app.ui.LocalRouter
import community.reel.app.ui.LocalShowsRatings
import community.reel.app.ui.LocalStores
import community.reel.app.ui.LocalTelevision
import community.reel.app.ui.ReelTheme
import community.reel.app.ui.RootScreen
import community.reel.app.ui.Route
import community.reel.app.ui.ScreenshotTour
import community.reel.app.ui.Strings
import community.reel.app.ui.observe

class MainActivity : ComponentActivity() {
    private val router = AppRouter()

    override fun onCreate(savedInstanceState: Bundle?) {
        // CI launches with `--ez ReelMock true --es ReelShot <screen>`, as iOS takes -ReelMock -ReelShot.
        if (intent.getBooleanExtra("ReelMock", false)) ReelApplication.instance.useMockData()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(0), navigationBarStyle = SystemBarStyle.dark(0))
        Strings.load(this)
        val app = ReelApplication.instance
        val stores = app.stores
        val television = app.isTelevision
        handle(intent)
        intent.getStringExtra("ReelShot")?.let { ScreenshotTour.start(it, router, stores) }
        setContent {
            val settings = stores.settings.observe()
            ReelTheme(settings.accent) {
                CompositionLocalProvider(
                    LocalStores provides stores,
                    LocalRouter provides router,
                    LocalTelevision provides television,
                    LocalCardScale provides settings.posterSize.scale,
                    LocalShowsRatings provides settings.showRatings,
                ) {
                    if (television) TvRoot() else RootScreen()
                }
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        community.reel.app.player.PipState.active = isInPictureInPictureMode
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** `reel://title/tt…`, `reel://resume/<video id>`, IMDb links and text shared from other apps. */
    private fun handle(intent: Intent?) {
        val stores = ReelApplication.instance.stores
        val link = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        } ?: return
        if (link == "reel://downloads") { router.openLibrary(Route.Downloads); return }
        if (link == "reel://continue") {
            // The shortcut: resume the newest entry of Continue Watching.
            stores.library.continueWatching.firstOrNull()?.let { stores.playback.play(it.target, stores.settings, stores.library, automatic = true) }
            return
        }
        if (link.startsWith("reel://search/")) { router.search(android.net.Uri.decode(link.removePrefix("reel://search/"))); return }
        stores.open(link, router = { router.open(it) }, resume = { entry ->
            router.tab = community.reel.app.ui.AppTab.HOME
            stores.playback.play(entry.target, stores.settings, stores.library, automatic = true)
        })
    }
}
