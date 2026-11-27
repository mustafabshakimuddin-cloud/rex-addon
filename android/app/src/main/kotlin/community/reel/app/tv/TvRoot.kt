package community.reel.app.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import androidx.tv.material3.DrawerValue
import androidx.tv.material3.Icon
import androidx.tv.material3.NavigationDrawer
import androidx.tv.material3.NavigationDrawerItem
import androidx.tv.material3.Text
import androidx.tv.material3.rememberDrawerState
import community.reel.app.ui.AlertToast
import community.reel.app.ui.AppTab
import community.reel.app.ui.Attention
import community.reel.app.ui.AttentionDot
import community.reel.app.ui.Backdrop
import community.reel.app.ui.Env
import community.reel.app.ui.PreparingHUD
import community.reel.app.ui.ProfileBadge
import community.reel.app.ui.RootEffects
import community.reel.app.ui.RootOverlays
import community.reel.app.ui.TabContent
import community.reel.app.ui.observe
import community.reel.app.ui.tabIcon
import community.reel.app.ui.tr

/**
 * Android TV: the same screens, steered by the remote. A navigation drawer on the left opens as
 * focus reaches it, as in Google TV's own apps; content keeps clear of the screen's overscan edge.
 * Every card and button takes focus, grows a little and gets a ring, and the player answers the
 * remote's centre, arrows and media keys.
 */
@Composable
fun TvRoot() {
    val stores = Env.stores
    val router = Env.router
    val settings = stores.settings.observe()
    val library = stores.library.observe()
    val trakt = stores.trakt.observe()
    val upcoming = stores.upcoming.observe()
    val alerts = stores.alerts.observe()
    val profiles = stores.profiles.observe()
    val attention = Attention(settings, library, trakt, upcoming)
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val content = remember { FocusRequester() }

    RootEffects()
    LaunchedEffect(Unit) { runCatching { content.requestFocus() } }

    Backdrop {
        NavigationDrawer(drawerState = drawer, drawerContent = { value ->
            Column(Modifier.fillMaxHeight().padding(vertical = 27.dp, horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                NavigationDrawerItem(selected = false, onClick = { router.openSettings(community.reel.app.ui.SettingsPage.PROFILES) },
                    leadingContent = { ProfileBadge(profiles.current, 28.dp) }) { Text(profiles.current.name) }
                Spacer(Modifier.height(18.dp))
                for (tab in AppTab.entries) {
                    NavigationDrawerItem(selected = router.tab == tab, onClick = { router.select(tab) },
                        leadingContent = {
                            Box {
                                Icon(tabIcon(tab), null)
                                if (tab == AppTab.HOME && attention.badgeCount > 0) Box(Modifier.align(Alignment.TopEnd)) { AttentionDot(7.dp) }
                            }
                        }) { Text(tab.title.tr()) }
                }
                Spacer(Modifier.weight(1f))
                NavigationDrawerItem(selected = false, onClick = { router.openSettings() }, leadingContent = {
                    Box {
                        Icon(Icons.Rounded.Settings, null)
                        if (Attention.settingsNeedAttention(settings, trakt, alerts)) Box(Modifier.align(Alignment.TopEnd)) { AttentionDot(7.dp) }
                    }
                }) { Text("Settings".tr()) }
            }
        }) {
            // TV screens can crop their edges: keep text and controls inside the safe area.
            Box(Modifier.fillMaxSize().padding(start = 8.dp, end = 48.dp, top = 27.dp, bottom = 27.dp).focusRequester(content)) {
                TabContent(router.tab)
            }
        }
        PreparingHUD(Modifier.align(Alignment.BottomCenter).padding(bottom = 32.dp))
        AlertToast(Modifier.align(Alignment.TopCenter))
    }
    RootOverlays()
}

