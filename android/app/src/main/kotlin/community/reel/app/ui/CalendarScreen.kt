package community.reel.app.ui

import android.content.Intent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.List
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.EventAvailable
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.RemoveCircleOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import community.reel.core.CalendarEpisode
import community.reel.core.CalendarExport
import community.reel.core.MediaKind
import community.reel.core.Platform
import community.reel.core.UpcomingStore
import kotlinx.coroutines.launch
import java.io.File
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

fun shortTime(date: java.time.Instant): String = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault()).format(date)

/** Shares a file the app wrote, through the system share sheet. */
fun shareFile(context: android.content.Context, name: String, text: String, type: String) {
    val folder = File(context.cacheDir, "shared").apply { mkdirs() }
    val file = File(folder, name).apply { writeText(text) }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null))
}

/**
 * New and upcoming episodes of the series you follow, day by day. Cards shows each episode's
 * picture; List is compact. Recent looks back a month for what you may have missed.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
fun CalendarScreen() {
    val stores = Env.stores
    val router = Env.router
    val context = LocalContext.current
    val upcoming = stores.upcoming.observe()
    val library = stores.library.observe()
    val metrics = CardMetrics.current()
    val scope = rememberCoroutineScope()
    var cards by remember { mutableStateOf(Platform.defaults.string("calendar.layout") != "list") }
    var recent by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    ScrollToTop(AppTab.CALENDAR, list)

    val source = if (!recent) upcoming.upcoming + upcoming.airingToday.filter { it.hasAired } else upcoming.recent
    val seen = mutableSetOf<String>()
    val unique = source.filter { seen.add(it.id) }
    val grouped = unique.groupBy { LocalDate.ofInstant(it.date, ZoneId.systemDefault()) }
    val days = (if (recent) grouped.keys.sortedDescending() else grouped.keys.sorted()).map { day ->
        day to grouped.getValue(day).sortedWith(compareBy({ it.date }, { it.item.name }, { it.episode.number }))
    }

    Page("Calendar", large = true, actions = {
        RoundIconButton(if (cards) Icons.AutoMirrored.Rounded.List else Icons.Rounded.GridView, "Layout") {
            cards = !cards; Platform.defaults.putString("calendar.layout", if (cards) "cards" else "list")
        }
        if (upcoming.upcoming.isNotEmpty()) RoundIconButton(Icons.Rounded.EventAvailable, "Add to Calendar") {
            shareFile(context, "Upcoming Episodes.ics", CalendarExport.ics(upcoming.upcoming), "text/calendar")
        }
    }) {
        PullToRefreshBox(refreshing, { scope.launch { refreshing = true; upcoming.refresh(library, force = true); refreshing = false } }) {
            LazyColumn(state = list, contentPadding = PaddingValues(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.fillMaxSize()) {
                item {
                    SingleChoiceSegmentedButtonRow(Modifier.padding(horizontal = 20.dp).widthIn(max = 360.dp).fillMaxWidth()) {
                        listOf(false to "Upcoming", true to "Recent").forEachIndexed { index, (value, title) ->
                            SegmentedButton(recent == value, { recent = value }, SegmentedButtonDefaults.itemShape(index, 2)) { Text(title.tr()) }
                        }
                    }
                }
                when {
                    UpcomingStore.followedSeries(library).isEmpty() -> item {
                        StateMessage("No series yet", "Add series to My List, or start watching one, and their new episodes appear here.",
                            icon = Icons.Rounded.CalendarMonth, actionTitle = "Explore Series") { router.exploreKind = MediaKind.SERIES; router.select(AppTab.EXPLORE) }
                    }
                    upcoming.isLoading && upcoming.episodes.isEmpty() -> item {
                        Column(Modifier.fillMaxWidth().padding(top = 60.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            CircularProgressIndicator(color = Theme.accent); Gap(8.dp); Text("Checking your series…".tr(), color = Theme.secondaryText)
                        }
                    }
                    upcoming.error != null && upcoming.episodes.isEmpty() -> item {
                        StateMessage("Couldn't load the calendar", upcoming.error ?: "", actionTitle = "Retry") { scope.launch { upcoming.refresh(library, force = true) } }
                    }
                    days.isEmpty() -> item {
                        StateMessage(if (recent) "Nothing recent" else "Nothing scheduled",
                            if (recent) "None of your series aired an episode in the last month." else "None of your series has a date for its next episode yet.",
                            icon = Icons.Rounded.CalendarMonth)
                    }
                    else -> for ((day, episodes) in days) {
                        stickyHeader(key = day.toString()) { DayHeader(day, episodes.size) }
                        if (cards) item(key = "$day-cards") {
                            FlowRow(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                                for (entry in episodes) EpisodeCard(entry, metrics.landscape)
                            }
                        } else items(episodes, key = { "$day-${it.id}" }) { EpisodeLine(it) }
                    }
                }
            }
        }
    }
}

@Composable
private fun DayHeader(day: LocalDate, count: Int) {
    val today = LocalDate.now()
    val title = when (day) {
        today -> "Today".tr()
        today.plusDays(1) -> "Tomorrow".tr()
        today.minusDays(1) -> "Yesterday".tr()
        else -> DateTimeFormatter.ofPattern("EEEE d MMMM").format(day)
    }
    Row(Modifier.fillMaxWidth().background(Theme.background.copy(alpha = 0.85f)).padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.Bottom) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.width(8.dp))
        Text(if (count == 1) "1 episode".tr() else "%d episodes".tr(count), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText)
    }
}

private fun subtitle(entry: CalendarEpisode) = "${entry.episode.title} · ${(if (entry.hasAired) "Aired" else "Airs").tr()} ${shortTime(entry.date)}"

@Composable
private fun EpisodeCard(entry: CalendarEpisode, width: androidx.compose.ui.unit.Dp) {
    val router = Env.router
    val watched = Env.stores.library.isWatched(entry.target)
    var menu by remember { mutableStateOf(false) }
    Box {
        BannerCard(entry.item, width, Modifier.alpha(if (watched) 0.6f else 1f), image = entry.episode.thumbnail ?: entry.item.background,
            eyebrow = entry.episode.code + if (watched) " · " + "Watched".tr() else if (entry.hasAired) " · " + "New".tr() else "",
            title = entry.item.name, subtitle = subtitle(entry), onLongClick = { menu = true }) { router.push(Route.Title(entry.item)) }
        EpisodeMenu(entry, menu) { menu = false }
    }
}

@Composable
private fun EpisodeLine(entry: CalendarEpisode) {
    val router = Env.router
    val watched = Env.stores.library.isWatched(entry.target)
    var menu by remember { mutableStateOf(false) }
    Box(Modifier.padding(horizontal = 20.dp)) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Theme.surface)
            .focusCard(RoundedCornerShape(14.dp), { router.push(Route.Title(entry.item)) }, { menu = true }).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            RemoteImage(entry.item.poster, Modifier.width(44.dp).height(66.dp).clip(RoundedCornerShape(8.dp)))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(entry.item.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("${entry.episode.code} · ${entry.episode.title}", style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (watched) Icon(Icons.Rounded.CheckCircle, "Watched".tr(), tint = Theme.cached)
            else Text(shortTime(entry.date), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
        }
        EpisodeMenu(entry, menu) { menu = false }
    }
}

@Composable
private fun EpisodeMenu(entry: CalendarEpisode, expanded: Boolean, dismiss: () -> Unit) {
    val stores = Env.stores
    val router = Env.router
    val library = stores.library
    DropdownMenu(expanded, dismiss) {
        if (entry.hasAired) {
            MenuItem("Play", Icons.Rounded.PlayArrow) { stores.playback.play(entry.target, stores.settings, library); dismiss() }
            MenuItem("Choose Source", Icons.AutoMirrored.Rounded.List) { stores.playback.chooseSource(entry.target); dismiss() }
            if (library.isWatched(entry.target)) MenuItem("Mark as Unwatched", Icons.Rounded.RadioButtonUnchecked) { library.markUnwatched(entry.target); dismiss() }
            else MenuItem("Mark as Watched", Icons.Rounded.CheckCircle) { library.markWatched(entry.target); dismiss() }
        }
        MenuItem("Go to Series", Icons.Rounded.Info) { router.push(Route.Title(entry.item)); dismiss() }
        val listed = library.isInWatchlist(entry.item)
        MenuItem(if (listed) "Remove from My List" else "Add to My List", if (listed) Icons.Rounded.RemoveCircleOutline else Icons.Rounded.Add) { library.toggleWatchlist(entry.item); dismiss() }
    }
}
