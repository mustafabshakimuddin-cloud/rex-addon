package community.reel.app.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.List
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Cloud
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.DownloadDone
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Event
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.RemoveCircleOutline
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.core.DebridCloud
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.PlaybackProgress
import community.reel.core.PlaybackTarget
import community.reel.core.Platform
import community.reel.core.Trakt
import community.reel.core.now
import java.time.Duration
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

enum class LibraryDisplay(val raw: String, val title: String, val icon: ImageVector) {
    POSTERS("posters", "Posters", Icons.Rounded.Bookmark), ROWS("rows", "Rows", Icons.AutoMirrored.Rounded.List),
    BANNERS("banners", "Banners", Icons.Rounded.Movie), OVERVIEW("overview", "Overview", Icons.Rounded.Event)
}
enum class LibraryFilter(val raw: String, val title: String) { ALL("all", "All"), MOVIES("movies", "Movies"), SERIES("series", "Series"), UNWATCHED("unwatched", "Not Watched") }
enum class LibrarySort(val raw: String, val title: String) { ADDED("added", "Recently Added"), TITLE("title", "Title"), YEAR("year", "Year"), RATING("rating", "Rating") }

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun LibraryScreen() {
    val stores = Env.stores
    val router = Env.router
    val library = stores.library.observe()
    val settings = stores.settings.observe()
    val downloads = stores.downloads.observe()
    val upcoming = stores.upcoming.observe()
    stores.lists.observe()
    val metrics = CardMetrics.current()
    val defaults = Platform.defaults
    var display by remember { mutableStateOf(LibraryDisplay.entries.firstOrNull { it.raw == defaults.string("library.display") } ?: LibraryDisplay.POSTERS) }
    var filter by remember { mutableStateOf(LibraryFilter.entries.firstOrNull { it.raw == defaults.string("library.filter") } ?: LibraryFilter.ALL) }
    var sort by remember { mutableStateOf(LibrarySort.entries.firstOrNull { it.raw == defaults.string("library.sort") } ?: LibrarySort.ADDED) }
    var filterMenu by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    ScrollToTop(AppTab.LIBRARY, list)

    val filtered = library.watchlist.filter { item ->
        when (filter) {
            LibraryFilter.ALL -> true
            LibraryFilter.MOVIES -> item.kind == MediaKind.MOVIE
            LibraryFilter.SERIES -> item.kind == MediaKind.SERIES
            LibraryFilter.UNWATCHED -> item.kind == MediaKind.SERIES || !library.isWatched(PlaybackTarget(item))
        }
    }
    val shown = when (sort) {
        LibrarySort.ADDED -> filtered
        LibrarySort.TITLE -> filtered.sortedBy { it.name.lowercase() }
        LibrarySort.YEAR -> filtered.sortedByDescending { it.year ?: "" }
        LibrarySort.RATING -> filtered.sortedByDescending { it.rating?.toDoubleOrNull() ?: 0.0 }
    }

    Page("Library", large = true, actions = { RoundIconButton(Icons.Rounded.Settings, "Settings") { router.openSettings() } }) {
        LazyColumn(state = list, contentPadding = PaddingValues(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(30.dp)) {
            item { QuickLinks() }
            if (library.continueWatching.isNotEmpty()) item {
                ShelfRow("Continue Watching", library.continueWatching, key = { it.id }) { entry ->
                    ContinueCard(entry, metrics.landscape) { stores.playback.play(entry.target, settings, library) }
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.Bottom) {
                        Text("My List".tr(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                        Spacer(Modifier.width(8.dp))
                        Text("${library.watchlist.size}", color = Theme.secondaryText)
                        Spacer(Modifier.weight(1f))
                        if (display != LibraryDisplay.OVERVIEW) Box {
                            Chip(if (filter == LibraryFilter.ALL) "Filter" else filter.title, icon = Icons.Rounded.FilterList) { filterMenu = true }
                            DropdownMenu(filterMenu, { filterMenu = false }) {
                                for (value in LibraryFilter.entries) DropdownMenuItem({ Text(value.title.tr()) }, { filter = value; defaults.putString("library.filter", value.raw); filterMenu = false },
                                    trailingIcon = { if (filter == value) Icon(Icons.Rounded.CheckCircle, null, tint = Theme.accent) })
                                HorizontalDivider()
                                for (value in LibrarySort.entries) DropdownMenuItem({ Text(value.title.tr()) }, { sort = value; defaults.putString("library.sort", value.raw); filterMenu = false },
                                    trailingIcon = { if (sort == value) Icon(Icons.Rounded.CheckCircle, null, tint = Theme.accent) })
                            }
                        }
                    }
                    SingleChoiceSegmentedButtonRow(Modifier.padding(horizontal = 20.dp).widthIn(max = 460.dp).fillMaxWidth()) {
                        LibraryDisplay.entries.forEachIndexed { index, value ->
                            SegmentedButton(display == value, { display = value; defaults.putString("library.display", value.raw) },
                                SegmentedButtonDefaults.itemShape(index, LibraryDisplay.entries.size)) { Text(value.title.tr(), fontSize = 12.sp, maxLines = 1) }
                        }
                    }
                    when {
                        library.watchlist.isEmpty() && display != LibraryDisplay.OVERVIEW ->
                            StateMessage("Nothing in My List", "Tap + on any title to keep it here. Its new episodes appear on Calendar.", icon = Icons.Rounded.Bookmark,
                                actionTitle = "Explore") { router.select(AppTab.EXPLORE) }
                        shown.isEmpty() && display != LibraryDisplay.OVERVIEW ->
                            StateMessage("Nothing matches", "No titles in My List match “%s”.".tr(filter.title.tr()), icon = Icons.Rounded.FilterList, actionTitle = "Show All") { filter = LibraryFilter.ALL }
                        else -> when (display) {
                            LibraryDisplay.POSTERS -> FlowRow(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
                                for (item in shown) {
                                    var menu by remember { mutableStateOf(false) }
                                    Box {
                                        // Inside My List every title is listed, so the mark says something more useful than that.
                                        val mark = library.mark(item, downloads)?.takeIf { it.kind != PosterMarkKind.LISTED }
                                        PosterCard(item, metrics.poster, mark = mark, onLongClick = { menu = true }) { router.push(Route.Title(item)) }
                                        TitleMenu(item, menu) { menu = false }
                                    }
                                }
                            }
                            LibraryDisplay.ROWS -> Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                for (item in shown) MediaRow(item, onClick = { router.push(Route.Title(item)) }) { RowStatus(item) }
                            }
                            LibraryDisplay.BANNERS -> FlowRow(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                                for (item in shown) BannerCard(item, metrics.landscape * 1.15f, eyebrow = bannerEyebrow(item), subtitle = heroSubtitle(item), fraction = movieProgress(item)) {
                                    router.push(Route.Title(item))
                                }
                            }
                            LibraryDisplay.OVERVIEW -> LibraryOverview(Modifier.padding(horizontal = 20.dp))
                        }
                    }
                }
            }
            item { ListsSection() }
        }
    }
}

@Composable
private fun movieProgress(item: MediaItem): Double? {
    if (item.kind != MediaKind.MOVIE) return null
    val entry = Env.stores.library.progress(PlaybackTarget(item)) ?: return null
    return if (entry.position >= community.reel.core.Library.MINIMUM_RESUME && !entry.isFinished) entry.fraction else null
}

@Composable
private fun bannerEyebrow(item: MediaItem): String {
    val stores = Env.stores
    if (item.kind == MediaKind.SERIES) stores.upcoming.upcoming.firstOrNull { it.item.id == item.id }?.let { return "${it.episode.code} · ${relativeDay(it.date)}" }
    if (item.kind == MediaKind.MOVIE && stores.library.isWatched(PlaybackTarget(item))) return "Watched".tr()
    return item.kind.singular.tr()
}

@Composable
private fun RowStatus(item: MediaItem) {
    val stores = Env.stores
    val target = PlaybackTarget(item)
    val next = stores.upcoming.upcoming.firstOrNull { it.item.id == item.id }
    when {
        item.kind == MediaKind.MOVIE && stores.library.isWatched(target) -> Icon(Icons.Rounded.CheckCircle, "Watched".tr(), tint = Theme.cached)
        item.kind == MediaKind.MOVIE && stores.downloads.item(target)?.isFinished == true -> Icon(Icons.Rounded.DownloadDone, "Downloaded".tr(), tint = Theme.accent)
        item.kind == MediaKind.SERIES && next != null -> Column(horizontalAlignment = Alignment.End) {
            Text(next.episode.code, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            Text(DateTimeFormatter.ofPattern("d MMM").withZone(ZoneId.systemDefault()).format(next.date), fontSize = 11.sp, color = Theme.secondaryText)
        }
        else -> Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Theme.secondaryText)
    }
}

/** History and Calendar; Downloads joins them only once something has been saved for offline. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QuickLinks() {
    val stores = Env.stores
    val router = Env.router
    val library = stores.library
    val downloads = stores.downloads
    val settings = stores.settings
    FlowRow(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp), maxItemsInEachRow = 2) {
        LinkTile("History", if (library.history.isEmpty()) "Nothing yet".tr() else "%d played".tr(library.history.size), Icons.Rounded.History, Modifier.weight(1f)) { router.push(Route.History) }
        LinkTile("Calendar", stores.upcoming.upcoming.firstOrNull()?.let { "Next: %s".tr(it.item.name) } ?: "Upcoming episodes".tr(), Icons.Rounded.CalendarMonth, Modifier.weight(1f)) {
            router.select(AppTab.CALENDAR)
        }
        if (settings.isDebridConfigured && DebridCloud.supports(settings.debridService)) {
            LinkTile("%s Files".tr(settings.debridService.title), "What's in your account".tr(), Icons.Rounded.Cloud, Modifier.weight(1f)) { router.push(Route.Cloud) }
        }
        if (downloads.items.isNotEmpty()) {
            val failed = downloads.problems.isNotEmpty()
            val detail = when {
                downloads.active.isNotEmpty() -> "%d downloading".tr(downloads.active.size)
                failed -> "%d failed".tr(downloads.problems.size)
                else -> "%d saved offline".tr(downloads.finished.size)
            }
            LinkTile("Offline", detail, Icons.Rounded.Download, Modifier.weight(1f), dot = failed) { router.push(Route.Downloads) }
        }
    }
}

@Composable
private fun LinkTile(title: String, detail: String, icon: ImageVector, modifier: Modifier, dot: Boolean = false, onClick: () -> Unit) {
    Row(modifier.glass(RoundedCornerShape(16.dp)).focusCard(RoundedCornerShape(16.dp), onClick).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Theme.accent)
        Spacer(Modifier.width(10.dp))
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title.tr(), fontWeight = FontWeight.SemiBold, maxLines = 1)
                if (dot) { Spacer(Modifier.width(5.dp)); AttentionDot(7.dp) }
            }
            Text(detail, style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** What's in My List and what you've watched, as numbers and bars. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun LibraryOverview(modifier: Modifier) {
    val stores = Env.stores
    val library = stores.library
    val downloads = stores.downloads
    val history = library.history
    // Time actually played: titles marked watched by hand have no real duration to count.
    val hours = history.filter { it.marked != true }.sumOf { minOf(it.position, it.duration) } / 3600
    val week = now().minus(Duration.ofDays(7))
    val genres = (library.watchlist + history.map { it.item }).flatMap { it.genres.take(2) }.groupingBy { it }.eachCount().toList()
        .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first }).take(6)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp), maxItemsInEachRow = 3) {
            val tile = @Composable { value: String, label: String, icon: ImageVector -> StatTile(value, label, icon, Modifier.weight(1f)) }
            tile("${library.watchlist.count { it.kind == MediaKind.MOVIE }}", "Movies listed", Icons.Rounded.Movie)
            tile("${library.watchlist.count { it.kind == MediaKind.SERIES }}", "Series listed", Icons.Rounded.Tv)
            tile("${history.count { it.isFinished }}", "Finished", Icons.Rounded.CheckCircle)
            tile(if (hours >= 10) "${hours.toInt()}" else "%.1f".format(hours), "Hours watched", Icons.Rounded.Schedule)
            tile("${history.count { it.updatedAt.isAfter(week) }}", "Played this week", Icons.Rounded.CalendarMonth)
            tile("${stores.upcoming.upcoming.size}", "Episodes coming", Icons.Rounded.Event)
            if (downloads.items.isNotEmpty()) tile("${downloads.finished.size}", "Saved offline", Icons.Rounded.DownloadDone)
        }
        if (genres.isNotEmpty()) {
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Theme.surface).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Your Genres".tr(), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                val top = genres.first().second.toFloat()
                for ((genre, count) in genres) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(genre, Modifier.width(110.dp), maxLines = 1)
                        Box(Modifier.weight(1f).height(10.dp).clip(CircleShape).background(Theme.surface)) {
                            Box(Modifier.fillMaxWidth(maxOf(0.04f, count / top)).height(10.dp).clip(CircleShape).background(Theme.accentGradient))
                        }
                        Text("$count", Modifier.width(28.dp).padding(start = 6.dp), fontSize = 12.sp, color = Theme.secondaryText)
                    }
                }
            }
        }
    }
}

@Composable
private fun StatTile(value: String, label: String, icon: ImageVector, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(16.dp)).background(Theme.surface).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, Modifier.size(18.dp), tint = Theme.accent)
        Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, maxLines = 1)
        Text(label.tr(), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 1)
    }
}

/** Your lists and your Trakt lists. */
@Composable
private fun ListsSection() {
    val stores = Env.stores
    val router = Env.router
    val lists = stores.lists.observe()
    val trakt = stores.trakt.observe()
    var traktLists by remember { mutableStateOf<List<Trakt.TraktList>>(emptyList()) }
    var naming by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    LaunchedEffect(trakt.isConnected) { traktLists = if (trakt.isConnected) runCatching { trakt.lists() }.getOrNull() ?: emptyList() else emptyList() }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Lists".tr(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            TextButton({ naming = true }) { Icon(Icons.Rounded.Add, null); Text(" " + "New List".tr()) }
        }
        if (lists.lists.isEmpty() && traktLists.isEmpty()) {
            Text("Make lists of your own beyond My List: long-press a title, or use + here.".tr(), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText,
                modifier = Modifier.padding(horizontal = 20.dp))
        }
        LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(lists.lists, key = { it.id }) { list -> ListTile(list.name, list.items.size, list.items.firstOrNull()?.poster, Icons.AutoMirrored.Rounded.List) { router.push(Route.Lists(ListRoute.Custom(list.id))) } }
            items(traktLists, key = { "t${it.id}" }) { list -> ListTile(list.name, list.itemCount, null, Icons.Rounded.Sync) { router.push(Route.Lists(ListRoute.TraktList(list))) } }
        }
    }
    if (naming) AlertDialog(onDismissRequest = { naming = false }, title = { Text("New List".tr()) },
        text = { OutlinedTextField(name, { name = it }, label = { Text("Name".tr()) }, singleLine = true) },
        confirmButton = { TextButton({ lists.create(name); name = ""; naming = false }) { Text("Create".tr()) } },
        dismissButton = { TextButton({ name = ""; naming = false }) { Text("Cancel".tr()) } })
}

@Composable
private fun ListTile(name: String, count: Int, poster: String?, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.width(210.dp).clip(RoundedCornerShape(14.dp)).background(Theme.surface).focusCard(RoundedCornerShape(14.dp), onClick).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(40.dp).height(60.dp).clip(RoundedCornerShape(8.dp)).background(Theme.surface), contentAlignment = Alignment.Center) {
            if (poster != null) RemoteImage(poster, Modifier.width(40.dp).height(60.dp)) else Icon(icon, null, tint = Theme.accent)
        }
        Spacer(Modifier.width(10.dp))
        Column {
            Text(name, fontWeight = FontWeight.SemiBold, maxLines = 2)
            Text(if (count == 1) "1 title".tr() else "%d titles".tr(count), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText)
        }
    }
}

/** One list as a grid; your own can be renamed and deleted. */
@Composable
fun ListDetailScreen(route: ListRoute) {
    val stores = Env.stores
    val router = Env.router
    val lists = stores.lists.observe()
    var traktItems by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    LaunchedEffect(route) {
        if (route !is ListRoute.TraktList) return@LaunchedEffect
        loading = true
        traktItems = runCatching { stores.trakt.items(route.list) }.getOrNull() ?: emptyList()
        loading = false
    }
    val items = when (route) { is ListRoute.Custom -> lists.list(route.id)?.items ?: emptyList(); is ListRoute.TraktList -> traktItems }
    val title = when (route) { is ListRoute.Custom -> lists.list(route.id)?.name ?: "List"; is ListRoute.TraktList -> route.list.name }
    PushedPage(title, actions = {
        if (route is ListRoute.Custom) Box {
            RoundIconButton(Icons.Rounded.MoreHoriz, "More") { menu = true }
            DropdownMenu(menu, { menu = false }) {
                MenuItem("Rename", Icons.Rounded.Edit) { newName = title; renaming = true; menu = false }
                MenuItem("Delete List", Icons.Rounded.Delete, destructive = true) { confirmDelete = true; menu = false }
            }
        }
    }) {
        LazyColumn(contentPadding = PaddingValues(vertical = 20.dp)) {
            if (loading && items.isEmpty()) item { Box(Modifier.fillMaxWidth().padding(top = 60.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Theme.accent) } }
            if (!loading && items.isEmpty()) item { StateMessage("Empty", "Long-press a title anywhere and choose Add to List.", icon = Icons.AutoMirrored.Rounded.List) }
            item { PosterGrid(items) }
        }
    }
    if (renaming && route is ListRoute.Custom) AlertDialog(onDismissRequest = { renaming = false }, title = { Text("Rename List".tr()) },
        text = { OutlinedTextField(newName, { newName = it }, label = { Text("Name".tr()) }, singleLine = true) },
        confirmButton = { TextButton({ lists.rename(route.id, newName); renaming = false }) { Text("Rename".tr()) } },
        dismissButton = { TextButton({ renaming = false }) { Text("Cancel".tr()) } })
    if (confirmDelete && route is ListRoute.Custom) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("Delete “%s”?".tr(title)) },
        confirmButton = { TextButton({ lists.delete(route.id); confirmDelete = false; router.back() }) { Text("Delete".tr(), color = Theme.problem) } },
        dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel".tr()) } })
}

/** What you've watched, newest first and grouped by day: Today, Yesterday, then dates. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HistoryScreen() {
    val stores = Env.stores
    val library = stores.library.observe()
    var filter by remember { mutableStateOf(LibraryFilter.ALL) }
    var confirmClear by remember { mutableStateOf(false) }
    val entries = library.history.filter { entry ->
        when (filter) {
            LibraryFilter.ALL -> true
            LibraryFilter.MOVIES -> entry.item.kind == MediaKind.MOVIE
            LibraryFilter.SERIES -> entry.item.kind == MediaKind.SERIES
            LibraryFilter.UNWATCHED -> !entry.isFinished
        }
    }
    val days = entries.groupBy { LocalDate.ofInstant(it.updatedAt, ZoneId.systemDefault()) }.toList().sortedByDescending { it.first }
    PushedPage("History", actions = { if (library.history.isNotEmpty()) TextButton({ confirmClear = true }) { Text("Clear".tr(), color = Theme.problem) } }) {
        LazyColumn(contentPadding = PaddingValues(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (library.history.isEmpty()) { item { StateMessage("No history yet", "Films and episodes you play show up here, by day.", icon = Icons.Rounded.History) }; return@LazyColumn }
            item {
                SingleChoiceSegmentedButtonRow(Modifier.padding(horizontal = 20.dp).fillMaxWidth()) {
                    LibraryFilter.entries.forEachIndexed { index, value ->
                        SegmentedButton(filter == value, { filter = value }, SegmentedButtonDefaults.itemShape(index, LibraryFilter.entries.size)) {
                            Text((if (value == LibraryFilter.UNWATCHED) "Unfinished" else value.title).tr(), fontSize = 12.sp, maxLines = 1)
                        }
                    }
                }
            }
            for ((day, dayEntries) in days) {
                stickyHeader(key = day.toString()) {
                    Text(dayTitle(day), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                        modifier = Modifier.fillMaxWidth().background(Theme.background.copy(alpha = 0.85f)).padding(horizontal = 20.dp, vertical = 8.dp))
                }
                items(dayEntries, key = { it.id }) { HistoryRow(it) }
            }
        }
    }
    if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false }, title = { Text("Clear your watch history?".tr()) },
        text = { Text("Resume points and watched marks on this device are removed. Trakt keeps its own history.".tr()) },
        confirmButton = { TextButton({ library.clearHistory(); confirmClear = false }) { Text("Clear History".tr(), color = Theme.problem) } },
        dismissButton = { TextButton({ confirmClear = false }) { Text("Cancel".tr()) } })
}

private fun dayTitle(day: LocalDate): String {
    val today = LocalDate.now()
    return when {
        day == today -> "Today".tr()
        day == today.minusDays(1) -> "Yesterday".tr()
        day.isAfter(today.minusDays(7)) -> DateTimeFormatter.ofPattern("EEEE").format(day)
        else -> DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.FULL).format(day)
    }
}

@Composable
private fun HistoryRow(entry: PlaybackProgress) {
    val stores = Env.stores
    val router = Env.router
    val library = stores.library
    var menu by remember { mutableStateOf(false) }
    val status = if (entry.isFinished) "Finished".tr() else {
        val minutes = (maxOf(0.0, entry.duration - entry.position) / 60).toInt()
        val left = if (minutes >= 60) "%dh %dm left".tr(minutes / 60, minutes % 60) else "%dm left".tr(minutes)
        "${(entry.fraction * 100).toInt()}% · $left"
    }
    Box(Modifier.padding(horizontal = 20.dp)) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Theme.surface)
            .focusCard(RoundedCornerShape(14.dp), { stores.playback.play(entry.target, stores.settings, library, fromStart = entry.isFinished) }, { menu = true })
            .padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(96.dp).height(54.dp).clip(RoundedCornerShape(8.dp))) {
                RemoteImage(entry.episode?.thumbnail ?: entry.item.background ?: entry.item.poster, Modifier.width(96.dp).height(54.dp))
                if (!entry.isFinished) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(entry.fraction.toFloat()).height(3.dp).background(Theme.accent))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(entry.item.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                entry.episode?.let { Text("${it.code} · ${it.title}", style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 1) }
                Text(status, fontSize = 11.sp, color = if (entry.isFinished) Theme.cached else Theme.secondaryText)
            }
            Text(shortTime(entry.updatedAt), fontSize = 11.sp, color = Theme.secondaryText)
        }
        DropdownMenu(menu, { menu = false }) {
            MenuItem("Go to Title", Icons.Rounded.Info) { router.push(Route.Title(entry.item)); menu = false }
            if (entry.isFinished) MenuItem("Mark as Unwatched", Icons.Rounded.RadioButtonUnchecked) { library.markUnwatched(entry.target); menu = false }
            else MenuItem("Mark as Watched", Icons.Rounded.CheckCircle) { library.markWatched(entry.target); menu = false }
            MenuItem("Remove from History", Icons.Rounded.Delete, destructive = true) { library.clearProgress(entry); menu = false }
        }
    }
}

