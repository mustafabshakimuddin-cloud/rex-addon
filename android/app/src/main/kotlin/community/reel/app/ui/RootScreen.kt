package community.reel.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.VideoLibrary
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import community.reel.app.player.PlayerScreen
import community.reel.app.system.Notifier
import community.reel.app.system.Widgets
import community.reel.core.AppAlert
import community.reel.core.UpcomingStore
import kotlinx.coroutines.delay

fun tabIcon(tab: AppTab): ImageVector = when (tab) {
    AppTab.HOME -> Icons.Rounded.Home
    AppTab.EXPLORE -> Icons.Rounded.Explore
    AppTab.CALENDAR -> Icons.Rounded.CalendarMonth
    AppTab.LIBRARY -> Icons.Rounded.VideoLibrary
    AppTab.SEARCH -> Icons.Rounded.Search
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RootScreen() {
    val stores = Env.stores
    val router = Env.router
    val context = LocalContext.current
    val settings = stores.settings.observe()
    val library = stores.library.observe()
    val trakt = stores.trakt.observe()
    val upcoming = stores.upcoming.observe()
    val playback = stores.playback.observe()
    val attention = Attention(settings, library, trakt, upcoming)
    val wide = LocalConfiguration.current.screenWidthDp >= 600

    BackHandler(enabled = playback.session == null && !router.showingSetup) { if (!router.back()) (context as? android.app.Activity)?.moveTaskToBack(true) }

    LaunchedEffect(Unit) {
        if (!ScreenshotTour.isActive && !settings.setupFinished) {
            // First launch: walk through setup before anything else.
            delay(400)
            router.showingSetup = true
        }
    }
    LaunchedEffect(UpcomingStore.followedSeries(library).map { it.id }) {
        upcoming.refresh(library)
        if (settings.notifyNewEpisodes) Notifier.scheduleEpisodes(context, upcoming.upcoming)
        Widgets.publish(context, stores)
    }
    LaunchedEffect(trakt.syncError) {
        trakt.syncError?.let { stores.alerts.post("Trakt sync stopped".tr(), it, AppAlert.Level.WARNING, AppAlert.Action.OPEN_TRAKT) }
    }

    Backdrop {
        if (wide) {
            Row(Modifier.fillMaxSize()) {
                NavigationRail(Modifier.statusBarsPadding(), containerColor = Theme.background.copy(alpha = 0.6f)) {
                    Spacer(Modifier.weight(1f))
                    for (tab in AppTab.entries) {
                        NavigationRailItem(router.tab == tab, { router.select(tab) }, icon = { TabIcon(tab, attention) }, label = { Text(tab.title.tr()) })
                    }
                    Spacer(Modifier.weight(1f))
                }
                Box(Modifier.weight(1f)) { TabContent(router.tab) }
            }
        } else {
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f)) { TabContent(router.tab) }
                NavigationBar(containerColor = Theme.background.copy(alpha = 0.92f)) {
                    for (tab in AppTab.entries) {
                        NavigationBarItem(router.tab == tab, { router.select(tab) }, icon = { TabIcon(tab, attention) }, label = { Text(tab.title.tr()) },
                            colors = NavigationBarItemDefaults.colors(selectedIconColor = Theme.accent, selectedTextColor = Theme.accent, indicatorColor = Theme.accent.copy(alpha = 0.16f)))
                    }
                }
            }
        }
        PreparingHUD(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = if (wide) 24.dp else 90.dp))
        AlertToast(Modifier.align(Alignment.TopCenter))
    }

    if (router.showingSettings) FullScreen { SettingsRoot() }
    if (router.showingSetup) FullScreen { SetupScreen() }
    playback.choosingSource?.let { target ->
        ModalBottomSheet(onDismissRequest = { playback.choosingSource = null }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
            containerColor = androidx.compose.ui.graphics.Color(0.08f, 0.08f, 0.11f)) {
            SourcesSheet(target)
        }
    }
    playback.session?.let { session -> FullScreen(dark = true) { PlayerScreen(session) } }
    LaunchedEffect(playback.session) { if (playback.session == null) playback.playerDismissed() }

    playback.errorMessage?.let { message ->
        AlertDialog(onDismissRequest = { playback.errorMessage = null }, title = { Text("Couldn't play".tr()) }, text = { Text(message) },
            confirmButton = { TextButton({ playback.errorMessage = null }) { Text("OK".tr()) } })
    }
    if (playback.needsDebridSetup) {
        AlertDialog(onDismissRequest = { playback.needsDebridSetup = false }, title = { Text("Add a debrid service".tr()) },
            text = { Text("Streams play through a debrid service such as Real-Debrid, or through a Stremio addon you add.".tr()) },
            confirmButton = { TextButton({ playback.needsDebridSetup = false; router.openSetup() }) { Text("Set Up".tr()) } },
            dismissButton = {
                Row {
                    TextButton({ playback.needsDebridSetup = false; router.openSettings() }) { Text("Open Settings".tr()) }
                    TextButton({ playback.needsDebridSetup = false }) { Text("Not now".tr()) }
                }
            })
    }
}

@Composable
private fun TabIcon(tab: AppTab, attention: Attention) {
    if (tab == AppTab.HOME && attention.badgeCount > 0) BadgedBox(badge = { Badge(containerColor = Theme.attention) { Text("${attention.badgeCount}") } }) { Icon(tabIcon(tab), null) }
    else Icon(tabIcon(tab), null)
}

/** A tab: its first screen, or the page on top of its stack. */
@Composable
fun TabContent(tab: AppTab) {
    val router = Env.router
    val top = router.stack(tab).lastOrNull()
    if (top != null) { RouteScreen(top); return }
    when (tab) {
        AppTab.HOME -> HomeScreen()
        AppTab.EXPLORE -> ExploreScreen()
        AppTab.CALENDAR -> CalendarScreen()
        AppTab.LIBRARY -> LibraryScreen()
        AppTab.SEARCH -> SearchScreen()
    }
}

/** The pages any tab can push: titles, people and the Library's own pages. */
@Composable
fun RouteScreen(route: Route) {
    androidx.compose.runtime.key(route) {
        when (route) {
            is Route.Title -> DetailScreen(route.item)
            is Route.Person -> PersonScreen(route.name)
            is Route.Lists -> ListDetailScreen(route.route)
            Route.Downloads -> DownloadsScreen()
            Route.History -> HistoryScreen()
            Route.Cloud -> DebridCloudScreen()
            is Route.Grid -> CatalogGridScreen(route)
            is Route.AddonGrid -> AddonCatalogGridScreen(route)
            is Route.Settings -> SettingsPageScreen(route.page)
        }
    }
}

/** A layer over the whole app: Settings, Setup, the player. */
@Composable
fun FullScreen(dark: Boolean = false, content: @Composable () -> Unit) {
    if (dark) Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) { content() }
    else Backdrop { content() }
}

@Composable
private fun PreparingHUD(modifier: Modifier) {
    val playback = Env.stores.playback.observe()
    AnimatedVisibility(playback.preparing != null, modifier, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
        val target = playback.preparing ?: return@AnimatedVisibility
        Row(Modifier.padding(horizontal = 16.dp).widthIn(max = 460.dp).fillMaxWidth().glass(RoundedCornerShape(24.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(22.dp), color = androidx.compose.ui.graphics.Color.White, strokeWidth = 2.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text((if (playback.fallbackNotice == null) "Preparing stream" else "Trying the next source").tr(), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                Text(target.displayTitle, style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 1)
            }
            TextButton({ playback.cancel() }) { Text("Cancel".tr()) }
        }
    }
}

/** The pop-up for the newest alert, under the status bar. Tap its button to go where it points. */
@Composable
fun AlertToast(modifier: Modifier = Modifier) {
    val stores = Env.stores
    val router = Env.router
    val alerts = stores.alerts.observe()
    AnimatedVisibility(alerts.current != null, modifier.statusBarsPadding(), enter = slideInVertically { -it } + fadeIn(), exit = slideOutVertically { -it } + fadeOut()) {
        val alert = alerts.current ?: return@AnimatedVisibility
        Row(Modifier.padding(horizontal = 16.dp, vertical = 6.dp).widthIn(max = 520.dp).fillMaxWidth().glass(RoundedCornerShape(22.dp))
            .focusCard(RoundedCornerShape(22.dp), { alerts.dismissCurrent() }).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            val (icon, tint) = when (alert.level) {
                AppAlert.Level.INFO -> Icons.Rounded.Info to Theme.accent
                AppAlert.Level.SUCCESS -> Icons.Rounded.CheckCircle to Theme.cached
                AppAlert.Level.WARNING -> Icons.Rounded.Warning to Theme.warning
                AppAlert.Level.PROBLEM -> Icons.Rounded.Error to Theme.problem
            }
            Icon(icon, null, tint = tint)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(alert.title.tr(), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 1)
                alert.message?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 2) }
            }
            val action = alert.action
            val title = alert.actionTitle
            if (action != null && title != null) TextButton({ alerts.dismissCurrent(); router.perform(action) }) { Text(title.tr()) }
        }
    }
}
