package community.reel.app.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import community.reel.core.AppAlert
import community.reel.core.HealthCheck
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.Trakt

enum class AppTab(val title: String) { HOME("Home"), EXPLORE("Explore"), CALENDAR("Calendar"), LIBRARY("Library"), SEARCH("Search") }

/** Pages inside Settings that other screens can open directly (a Status fix, an alert). */
enum class SettingsPage(val raw: String) {
    STATUS("status"), PICK_RULES("pickRules"), ADDONS("addons"), TRAKT("trakt"), APPEARANCE("appearance"),
    HOME_SCREEN("homeScreen"), OFFLINE("offline"), BACKUP("backup"), PROFILES("profiles");
    companion object { fun of(raw: String) = entries.firstOrNull { it.raw == raw } }
}

sealed interface ListRoute {
    data class Custom(val id: String) : ListRoute
    data class TraktList(val list: Trakt.TraktList) : ListRoute
}

/** Everything a tab's stack can show above its first screen. */
sealed interface Route {
    data class Title(val item: MediaItem) : Route
    data class Person(val name: String) : Route
    data class Lists(val route: ListRoute) : Route
    data object Downloads : Route
    data object History : Route
    data object Cloud : Route
    /** "See All" on a shelf: a grid of the whole catalogue. */
    data class Grid(val title: String, val kind: MediaKind, val catalog: community.reel.core.Cinemeta.Catalog, val genre: String?) : Route
    data class AddonGrid(val addon: community.reel.core.StreamAddon, val catalog: community.reel.core.AddonCatalog) : Route
    data class Settings(val page: SettingsPage) : Route
}

/** App-wide navigation requests that aren't owned by one screen. */
class AppRouter {
    var tab by mutableStateOf(AppTab.HOME)
    private val stacks = AppTab.entries.associateWith { mutableStateListOf<Route>() }
    fun stack(tab: AppTab): SnapshotStateList<Route> = stacks.getValue(tab)

    var showingSettings by mutableStateOf(false)
    val settingsStack = mutableStateListOf<Route>()
    var showingSetup by mutableStateOf(false)
    var exploreKind by mutableStateOf(MediaKind.MOVIE)
    /** Raised when the current tab is chosen again: its screen scrolls back to the top. */
    var scrollToTop by mutableStateOf<AppTab?>(null)
    /** Words for Search to look up, from a shortcut; Search takes them when it appears. */
    var pendingSearch by mutableStateOf<String?>(null)

    /** The tab bar: choosing the tab already showing goes back to its first screen, then to the top. */
    fun select(chosen: AppTab) {
        if (chosen == tab) popToRoot(chosen) else tab = chosen
    }

    fun popToRoot(tab: AppTab) {
        val stack = stack(tab)
        if (stack.isEmpty()) scrollToTop = tab else stack.clear()
    }

    fun push(route: Route) {
        if (showingSettings) settingsStack.add(route) else stack(tab).add(route)
    }

    /** Back: the top screen of what is showing. Returns false when there was nothing to go back from. */
    fun back(): Boolean {
        if (showingSettings) {
            if (settingsStack.isNotEmpty()) settingsStack.removeAt(settingsStack.lastIndex) else showingSettings = false
            return true
        }
        val stack = stack(tab)
        if (stack.isNotEmpty()) { stack.removeAt(stack.lastIndex); return true }
        if (tab != AppTab.HOME) { tab = AppTab.HOME; return true }
        return false
    }

    fun search(text: String) {
        showingSettings = false
        stack(AppTab.SEARCH).clear()
        tab = AppTab.SEARCH
        pendingSearch = text
    }

    /** Opens a title from a link or a shortcut, on the Home tab. */
    fun open(item: MediaItem) {
        showingSettings = false
        tab = AppTab.HOME
        stack(AppTab.HOME).clear()
        stack(AppTab.HOME).add(Route.Title(item))
    }

    fun openSettings(page: SettingsPage? = null) {
        settingsStack.clear()
        page?.let { settingsStack.add(Route.Settings(it)) }
        showingSettings = true
    }

    fun openLibrary(page: Route) {
        showingSettings = false
        tab = AppTab.LIBRARY
        stack(AppTab.LIBRARY).clear()
        stack(AppTab.LIBRARY).add(page)
    }

    fun openSetup() {
        showingSettings = false
        showingSetup = true
    }

    fun perform(action: AppAlert.Action) = when (action) {
        AppAlert.Action.OPEN_DOWNLOADS -> openLibrary(Route.Downloads)
        AppAlert.Action.OPEN_STATUS -> openSettings(SettingsPage.STATUS)
        AppAlert.Action.OPEN_TRAKT -> openSettings(SettingsPage.TRAKT)
        AppAlert.Action.OPEN_SETUP -> openSetup()
    }

    fun perform(fix: HealthCheck.Fix, openUrl: (String) -> Unit) = when (fix) {
        is HealthCheck.Fix.Settings -> openSettings(SettingsPage.of(fix.page))
        HealthCheck.Fix.SettingsHome -> openSettings()
        HealthCheck.Fix.Setup -> openSetup()
        HealthCheck.Fix.Downloads -> openLibrary(Route.Downloads)
        is HealthCheck.Fix.Link -> openUrl(fix.url)
    }
}
