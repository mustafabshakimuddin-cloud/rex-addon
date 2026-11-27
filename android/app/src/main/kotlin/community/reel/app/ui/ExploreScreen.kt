package community.reel.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Inbox
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.TableRows
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import community.reel.core.AddonCatalog
import community.reel.core.Addons
import community.reel.core.Cinemeta
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.Platform
import community.reel.core.StreamAddon
import kotlinx.coroutines.launch

/** How a grid orders what it has loaded. */
enum class GridOrder(val title: String) {
    LIST("List order"), NEWEST("Newest first"), RATING("Highest rated");

    fun apply(items: List<MediaItem>): List<MediaItem> = when (this) {
        LIST -> items
        NEWEST -> items.sortedByDescending { it.year ?: "" }
        RATING -> items.sortedByDescending { it.rating?.toDoubleOrNull() ?: 0.0 }
    }
}

/** One catalogue list, a page at a time. */
class BrowseModel {
    val items = mutableStateListOf<MediaItem>()
    var isLoading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    private var page = 0
    private var exhausted = false
    private var key = ""

    suspend fun reset(kind: MediaKind, catalog: Cinemeta.Catalog, genre: String?) {
        val newKey = "${kind.raw}|${catalog.raw}|${genre ?: ""}"
        if (newKey == key && items.isNotEmpty()) return
        key = newKey
        items.clear()
        page = 0
        exhausted = false
        loadMore(kind, catalog, genre)
    }

    suspend fun loadMore(kind: MediaKind, catalog: Cinemeta.Catalog, genre: String?) {
        if (isLoading || exhausted) return
        isLoading = true
        val requestKey = key
        try {
            val next = Cinemeta.catalog(kind, catalog, genre, page)
            if (requestKey != key) return
            val known = items.map { it.id }.toSet()
            items += next.filter { it.id !in known }
            page += 1
            exhausted = next.isEmpty()
            error = null
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
        } finally {
            isLoading = false
        }
    }
}

enum class ExploreLayout(val raw: String, val title: String) { ROWS("rows", "Rows"), GRID("grid", "Grid") }

/**
 * Films and series in one place. Rows shows a shelf per list and genre to scroll through; Grid
 * shows one list at a time with its filters, loading more as you go.
 */
@Composable
fun ExploreScreen() {
    val stores = Env.stores
    val router = Env.router
    val settings = stores.settings.observe()
    var layout by remember { mutableStateOf(if (Platform.defaults.string("explore.layout") == "grid") ExploreLayout.GRID else ExploreLayout.ROWS) }
    var menu by remember { mutableStateOf(false) }
    Page("Explore", large = true, actions = {
        Box {
            RoundIconButton(if (layout == ExploreLayout.ROWS) Icons.Rounded.TableRows else Icons.Rounded.GridView, "Layout") { menu = true }
            DropdownMenu(menu, { menu = false }) {
                for (option in ExploreLayout.entries) DropdownMenuItem({ Text(option.title.tr()) }, {
                    layout = option; Platform.defaults.putString("explore.layout", option.raw); menu = false
                }, leadingIcon = { Icon(if (option == ExploreLayout.ROWS) Icons.Rounded.TableRows else Icons.Rounded.GridView, null) })
                DropdownMenuItem({ Text("Hide Watched Films".tr()) }, { settings.hideWatched = !settings.hideWatched },
                    leadingIcon = { Icon(Icons.Rounded.VisibilityOff, null) }, trailingIcon = { Switch(settings.hideWatched, { settings.hideWatched = it }) })
            }
        }
        RoundIconButton(Icons.Rounded.Settings, "Settings") { router.openSettings() }
    }) {
        val kindPicker = @Composable {
            SingleChoiceSegmentedButtonRow(Modifier.padding(horizontal = 20.dp).widthIn(max = 360.dp).fillMaxWidth()) {
                MediaKind.entries.forEachIndexed { index, kind ->
                    SegmentedButton(router.exploreKind == kind, { router.exploreKind = kind }, SegmentedButtonDefaults.itemShape(index, 2)) { Text(kind.title.tr()) }
                }
            }
        }
        when (layout) {
            ExploreLayout.ROWS -> ExploreRows(router.exploreKind, kindPicker)
            ExploreLayout.GRID -> ExploreGrid(router.exploreKind, kindPicker)
        }
    }
}

private data class Shelf(val title: String, val catalog: Cinemeta.Catalog, val genre: String?)

@Composable
private fun ExploreRows(kind: MediaKind, header: @Composable () -> Unit) {
    val settings = Env.stores.settings
    val year = Cinemeta.recentYears.first()
    val shelves = listOf(Shelf("Popular", Cinemeta.Catalog.POPULAR, null), Shelf("New in %s".tr(year), Cinemeta.Catalog.NEWEST, year),
        Shelf("Top Rated", Cinemeta.Catalog.TOP_RATED, null)) + Cinemeta.genres(kind).map { Shelf(it, Cinemeta.Catalog.POPULAR, it) }
    val addonShelves = settings.addons.filter { it.enabled }.flatMap { addon -> (addon.catalogs ?: emptyList()).filter { it.kind == kind }.map { addon to it } }
    val list = rememberLazyListState()
    ScrollToTop(AppTab.EXPLORE, list)
    LazyColumn(state = list, contentPadding = PaddingValues(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(30.dp)) {
        item { header() }
        items(shelves, key = { "${kind.raw}|${it.title}" }) { LazyShelf(it.title, kind, it.catalog, it.genre) }
        items(addonShelves, key = { "${it.first.id}|${it.second.type}|${it.second.id}" }) { (addon, catalog) -> AddonShelf(addon, catalog) }
    }
}

/** A catalogue shelf that fetches its titles the first time it appears. */
@Composable
fun LazyShelf(title: String, kind: MediaKind, catalog: Cinemeta.Catalog, genre: String?) {
    val stores = Env.stores
    val router = Env.router
    val library = stores.library.observe()
    val settings = stores.settings.observe()
    val metrics = CardMetrics.current()
    var loaded by remember(kind, catalog, genre) { mutableStateOf<List<MediaItem>>(emptyList()) }
    var failed by remember(kind, catalog, genre) { mutableStateOf(false) }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(kind, catalog, genre, attempt) {
        failed = false
        runCatching { Cinemeta.catalog(kind, catalog, genre).take(20) }.onSuccess { loaded = it }.onFailure { if (it !is kotlinx.coroutines.CancellationException) failed = true }
    }
    val items = library.shown(loaded, settings.hideWatched)
    if (items.isNotEmpty()) {
        ShelfRow(title, items, key = { it.id }, onSeeAll = { router.push(Route.Grid("$title ${kind.title.tr()}", kind, catalog, genre)) }) { PosterLink(it, metrics.poster) }
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionHeader(title, Modifier.padding(horizontal = 20.dp))
        when {
            failed -> Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Couldn't load this row.".tr(), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText)
                TextButton({ attempt += 1 }) { Text("Retry".tr()) }
            }
            loaded.isNotEmpty() -> Text("You've watched everything here.".tr(), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText,
                modifier = Modifier.padding(horizontal = 20.dp))
            else -> LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), userScrollEnabled = false) {
                items(6) { Box(Modifier.width(metrics.poster).height(metrics.poster * 1.5f).clip(RoundedCornerShape(14.dp)).background(Theme.surface)) }
            }
        }
    }
}

/** One of an addon's catalogues as a shelf, with See All paging through the rest. */
@Composable
fun AddonShelf(addon: StreamAddon, catalog: AddonCatalog) {
    val stores = Env.stores
    val router = Env.router
    val library = stores.library.observe()
    val metrics = CardMetrics.current()
    var loaded by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(addon.id + catalog.id) {
        runCatching { Addons.catalog(catalog, addon).take(20) }.onSuccess { loaded = it }.onFailure { if (it !is kotlinx.coroutines.CancellationException) failed = true }
    }
    val items = library.shown(loaded, stores.settings.hideWatched)
    when {
        items.isNotEmpty() -> ShelfRow(catalog.name, items, key = { it.id }, subtitle = addon.name, onSeeAll = { router.push(Route.AddonGrid(addon, catalog)) }) {
            PosterLink(it, metrics.poster)
        }
        failed -> {}
        else -> SectionHeader(catalog.name, Modifier.padding(horizontal = 20.dp), addon.name)
    }
}

/** One list at a time: Popular, New or Top Rated, narrowed by genre (or year, for New). */
@Composable
private fun ExploreGrid(kind: MediaKind, header: @Composable () -> Unit) {
    var catalog by remember { mutableStateOf(Cinemeta.Catalog.entries.firstOrNull { it.raw == Platform.defaults.string("explore.catalog") } ?: Cinemeta.Catalog.POPULAR) }
    var genre by remember { mutableStateOf<String?>(null) }
    var year by remember { mutableStateOf(Cinemeta.recentYears.first()) }
    var order by remember { mutableStateOf(GridOrder.LIST) }
    var orderMenu by remember { mutableStateOf(false) }
    CatalogGrid(kind, catalog, if (catalog.filtersByYear) year else genre, order, tab = AppTab.EXPLORE) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                header()
                SingleChoiceSegmentedButtonRow(Modifier.padding(horizontal = 20.dp).widthIn(max = 360.dp).fillMaxWidth()) {
                    Cinemeta.Catalog.entries.forEachIndexed { index, value ->
                        SegmentedButton(catalog == value, { catalog = value; Platform.defaults.putString("explore.catalog", value.raw) },
                            SegmentedButtonDefaults.itemShape(index, Cinemeta.Catalog.entries.size)) { Text(value.title.tr()) }
                    }
                }
                LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (catalog.filtersByYear) items(Cinemeta.recentYears) { value -> Chip(value, selected = year == value) { year = value } }
                    else {
                        item { Chip("All", selected = genre == null) { genre = null } }
                        items(Cinemeta.genres(kind)) { value -> Chip(value, selected = genre == value) { genre = value } }
                    }
                }
                Box(Modifier.padding(horizontal = 14.dp)) {
                    TextButton({ orderMenu = true }) { Text(order.title.tr()) }
                    DropdownMenu(orderMenu, { orderMenu = false }) {
                        for (value in GridOrder.entries) DropdownMenuItem({ Text(value.title.tr()) }, { order = value; orderMenu = false })
                    }
                }
            }
        }
    }
}

/** A grid of one catalogue list that loads the next page as the last poster appears. */
@Composable
fun CatalogGrid(kind: MediaKind, catalog: Cinemeta.Catalog, genre: String?, order: GridOrder = GridOrder.LIST, tab: AppTab? = null,
                header: LazyGridScope.() -> Unit = {}) {
    val stores = Env.stores
    val library = stores.library.observe()
    val settings = stores.settings.observe()
    val metrics = CardMetrics.current()
    val model = remember { BrowseModel() }
    val scope = rememberCoroutineScope()
    val state = rememberLazyGridState()
    LaunchedEffect(kind, catalog, genre) { model.reset(kind, catalog, genre) }
    // The next page as the end comes into view.
    LaunchedEffect(state, kind, catalog, genre) {
        snapshotFlow { state.layoutInfo.visibleItemsInfo.lastOrNull()?.index to state.layoutInfo.totalItemsCount }.collect { (last, total) ->
            if (last != null && total > 0 && last >= total - 4) model.loadMore(kind, catalog, genre)
        }
    }
    if (tab != null) {
        val router = Env.router
        LaunchedEffect(router.scrollToTop) { if (router.scrollToTop == tab) { state.animateScrollToItem(0); router.scrollToTop = null } }
    }
    val items = order.apply(library.shown(model.items, settings.hideWatched))
    LazyVerticalGrid(GridCells.Adaptive(metrics.poster), state = state, contentPadding = PaddingValues(vertical = 12.dp, horizontal = 0.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.fillMaxSize()) {
        header()
        items(items, key = { it.id }) { Box(Modifier.padding(horizontal = 6.dp), contentAlignment = Alignment.TopCenter) { PosterLink(it, metrics.poster) } }
        item(span = { GridItemSpan(maxLineSpan) }) {
            when {
                model.isLoading -> Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Theme.accent) }
                model.error != null && model.items.isEmpty() -> StateMessage("Couldn't load", model.error ?: "", actionTitle = "Retry") {
                    scope.launch { model.reset(kind, catalog, genre) }
                }
                model.error != null -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    TextButton({ scope.launch { model.loadMore(kind, catalog, genre) } }) { Icon(Icons.Rounded.Refresh, null); Text(" " + "Couldn't load more. Retry".tr()) }
                }
                model.items.isEmpty() -> StateMessage("Nothing here", "This list has no titles right now.", icon = Icons.Rounded.Inbox)
            }
        }
    }
}

/** "See All" from a shelf: that list as a full grid. */
@Composable
fun CatalogGridScreen(route: Route.Grid) = PushedPage(route.title) { CatalogGrid(route.kind, route.catalog, route.genre) }

/** An addon catalogue as a grid, loading the next page as the end comes into view. */
@Composable
fun AddonCatalogGridScreen(route: Route.AddonGrid) {
    val library = Env.stores.library.observe()
    val metrics = CardMetrics.current()
    val items = remember { mutableStateListOf<MediaItem>() }
    var page by remember { mutableIntStateOf(0) }
    var done by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    val state = rememberLazyGridState()
    suspend fun loadMore() {
        if (loading || done) return
        loading = true
        val next = runCatching { Addons.catalog(route.catalog, route.addon, page) }.getOrNull()
        if (next == null) { done = true; loading = false; return }
        val known = items.map { it.id }.toSet()
        val fresh = next.filter { it.id !in known }
        items += fresh
        page += 1
        done = fresh.isEmpty()
        loading = false
    }
    LaunchedEffect(Unit) { if (items.isEmpty()) loadMore() }
    LaunchedEffect(state) {
        snapshotFlow { state.layoutInfo.visibleItemsInfo.lastOrNull()?.index to state.layoutInfo.totalItemsCount }.collect { (last, total) ->
            if (last != null && total > 0 && last >= total - 4) loadMore()
        }
    }
    PushedPage(route.catalog.name) {
        LazyVerticalGrid(GridCells.Adaptive(metrics.poster), state = state, contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            items(library.shown(items.toList(), false), key = { it.id }) { PosterLink(it, metrics.poster) }
            if (loading) item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Theme.accent) } }
        }
    }
}
