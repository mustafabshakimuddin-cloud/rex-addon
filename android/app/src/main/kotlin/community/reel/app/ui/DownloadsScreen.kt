package community.reel.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.HourglassTop
import androidx.compose.material.icons.rounded.Inbox
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.SdStorage
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.core.DebridCloud
import community.reel.core.DownloadItem
import community.reel.core.PlaybackErrors
import community.reel.core.formatBytes
import kotlinx.coroutines.launch
import java.time.Instant

enum class DownloadFilter(val title: String) { ALL("All"), ACTIVE("Active"), SAVED("Saved"), PROBLEMS("Problems") }

/**
 * Every download in one live list: a summary of what's moving and how much room is left, then each
 * title with its progress, speed and the controls its state allows.
 */
@Composable
fun DownloadsScreen() {
    val stores = Env.stores
    val downloads = stores.downloads.observe()
    val library = stores.library.observe()
    var filter by remember { mutableStateOf(DownloadFilter.ALL) }
    var menu by remember { mutableStateOf(false) }
    var confirmCleanup by remember { mutableStateOf(false) }
    val shown = when (filter) {
        DownloadFilter.ALL -> downloads.ordered
        DownloadFilter.ACTIVE -> downloads.ordered.filter { it.state == DownloadItem.State.Downloading || it.state == DownloadItem.State.Paused }
        DownloadFilter.SAVED -> downloads.finished
        DownloadFilter.PROBLEMS -> downloads.problems
    }
    // Finished downloads of things you have also finished watching.
    val watched = downloads.finished.filter { library.isWatched(it.target) }
    fun count(option: DownloadFilter) = when (option) {
        DownloadFilter.ALL -> downloads.items.size
        DownloadFilter.ACTIVE -> downloads.active.size + downloads.paused.size
        DownloadFilter.SAVED -> downloads.finished.size
        DownloadFilter.PROBLEMS -> downloads.problems.size
    }
    PushedPage("Downloads", actions = {
        if (downloads.items.isNotEmpty()) Box {
            RoundIconButton(Icons.Rounded.MoreHoriz, "Manage") { menu = true }
            DropdownMenu(menu, { menu = false }) {
                if (downloads.active.isNotEmpty()) MenuItem("Pause All", Icons.Rounded.Pause) { downloads.pauseAll(); menu = false }
                if (downloads.paused.isNotEmpty() || downloads.problems.isNotEmpty()) MenuItem("Resume All", Icons.Rounded.Download) {
                    (downloads.paused + downloads.problems).forEach { stores.playback.retryDownload(it, stores.settings) }; menu = false
                }
                HorizontalDivider()
                if (watched.isNotEmpty()) MenuItem("Delete Watched Downloads", Icons.Rounded.Delete, destructive = true) { confirmCleanup = true; menu = false }
            }
        }
    }) {
        LazyColumn(contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.widthIn(max = 860.dp)) {
            if (downloads.items.isEmpty()) {
                item { StateMessage("No downloads", "Use the download button on a film, or long-press an episode, to save it for watching offline.", icon = Icons.Rounded.Download) }
                return@LazyColumn
            }
            item { DownloadsSummary() }
            item {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                    DownloadFilter.entries.forEachIndexed { index, option ->
                        SegmentedButton(filter == option, { filter = option }, SegmentedButtonDefaults.itemShape(index, DownloadFilter.entries.size)) {
                            Text("${option.title.tr()} ${count(option)}", fontSize = 12.sp, maxLines = 1)
                        }
                    }
                }
            }
            if (shown.isEmpty()) item {
                Text((if (filter == DownloadFilter.PROBLEMS) "Nothing has failed." else "Nothing here.").tr(), color = Theme.secondaryText,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 30.dp))
            }
            items(shown, key = { it.id }) { DownloadRow(it) }
        }
    }
    if (confirmCleanup) AlertDialog(onDismissRequest = { confirmCleanup = false }, title = { Text("Delete %d downloads you have watched?".tr(watched.size)) },
        text = { Text("They can be downloaded again later.".tr()) },
        confirmButton = { TextButton({ watched.forEach(downloads::delete); confirmCleanup = false }) { Text("Delete".tr(), color = Theme.problem) } },
        dismissButton = { TextButton({ confirmCleanup = false }) { Text("Cancel".tr()) } })
}

/** What's moving, how fast, and how much room is left. */
@Composable
private fun DownloadsSummary() {
    val downloads = Env.stores.downloads
    val active = downloads.active
    val written = active.sumOf { it.written }
    val expected = active.sumOf { it.expected }
    val speed = active.mapNotNull { downloads.speeds[it.id] }.sum()
    val used = downloads.usedBytes
    val free = downloads.freeBytes
    Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(20.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(if (active.isEmpty()) "Nothing downloading".tr() else if (active.size == 1) "1 downloading".tr() else "%d downloading".tr(active.size),
                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(if (active.isNotEmpty() && expected > 0) "%s of %s".tr(formatBytes(written), formatBytes(expected)) + if (speed > 0) " · ${formatBytes(speed.toLong())}/s" else ""
                    else "%d saved for offline".tr(downloads.finished.size), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText)
            }
            if (downloads.problems.isNotEmpty()) StatusPill("%d failed".tr(downloads.problems.size), Icons.Rounded.Warning, Theme.problem)
        }
        if (active.isNotEmpty() && expected > 0) LinearProgressIndicator(progress = { written.toFloat() / expected }, Modifier.fillMaxWidth(), color = Theme.accent)
        if (free != null) Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val total = (used + free).toFloat()
            Box(Modifier.fillMaxWidth().height(8.dp).clip(CircleShape).background(Theme.surface)) {
                Box(Modifier.fillMaxWidth(if (total > 0) maxOf(0.02f, used / total) else 0f).height(8.dp).clip(CircleShape).background(Theme.accentGradient))
            }
            Row {
                Icon(Icons.Rounded.SdStorage, null, Modifier.size(14.dp), tint = Theme.secondaryText)
                Text(" " + "%s downloads".tr(formatBytes(used)), fontSize = 12.sp, color = Theme.secondaryText, modifier = Modifier.weight(1f))
                Text("%s free".tr(formatBytes(free)), fontSize = 12.sp, color = Theme.secondaryText)
            }
        }
    }
}

@Composable
private fun DownloadRow(item: DownloadItem) {
    val stores = Env.stores
    val router = Env.router
    val downloads = stores.downloads
    val library = stores.library
    val settings = stores.settings
    var menu by remember { mutableStateOf(false) }
    val status = when (val state = item.state) {
        DownloadItem.State.Finished -> if (item.expected > 0) formatBytes(item.expected) else "Downloaded".tr()
        DownloadItem.State.Downloading -> if (item.expected <= 0) "Starting…".tr() else {
            var text = "%d%% of %s".tr((item.fraction * 100).toInt(), formatBytes(item.expected))
            downloads.remainingSeconds(item)?.let { text += " · " + remaining(it) }
            text
        }
        DownloadItem.State.Paused -> "Paused · %d%%".tr((item.fraction * 100).toInt())
        is DownloadItem.State.Failed -> state.message
    }
    Box {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Theme.surface)
            .focusCard(RoundedCornerShape(16.dp), { if (item.isFinished) stores.playback.play(item.target, settings, library) else menu = true }, { menu = true })
            .padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(112.dp).height(63.dp).clip(RoundedCornerShape(10.dp))) {
                RemoteImage(item.target.episode?.thumbnail ?: item.target.item.background ?: item.target.item.poster, Modifier.width(112.dp).height(63.dp))
                if (library.isWatched(item.target)) Icon(Icons.Rounded.CheckCircle, null, Modifier.align(Alignment.BottomEnd).padding(4.dp).size(16.dp), tint = Theme.cached)
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(item.target.displayTitle, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    QualityBadge(item.source.quality); Spacer(Modifier.width(6.dp))
                    Text(status, fontSize = 12.sp, color = if (item.state is DownloadItem.State.Failed) Theme.problem else Theme.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (!item.isFinished) LinearProgressIndicator(progress = { item.fraction.toFloat() }, Modifier.fillMaxWidth(), color = Theme.accent)
            }
            Spacer(Modifier.width(4.dp))
            when (item.state) {
                DownloadItem.State.Finished -> RoundIconButton(Icons.Rounded.PlayArrow, "Play %s".tr(item.target.displayTitle)) { stores.playback.play(item.target, settings, library) }
                DownloadItem.State.Downloading -> RoundIconButton(Icons.Rounded.Pause, "Pause") { downloads.pause(item) }
                DownloadItem.State.Paused -> RoundIconButton(Icons.Rounded.Download, "Resume") { stores.playback.retryDownload(item, settings) }
                is DownloadItem.State.Failed -> RoundIconButton(Icons.Rounded.Refresh, "Retry") { stores.playback.retryDownload(item, settings) }
            }
        }
        DropdownMenu(menu, { menu = false }) {
            if (item.isFinished) MenuItem("Play", Icons.Rounded.PlayArrow) { stores.playback.play(item.target, settings, library); menu = false }
            MenuItem("Go to Title", Icons.Rounded.Info) { router.push(Route.Title(item.target.item)); menu = false }
            MenuItem("Delete Download", Icons.Rounded.Delete, destructive = true) { downloads.delete(item); menu = false }
        }
    }
}

private fun remaining(seconds: Double): String {
    val total = seconds.toLong()
    val text = if (total >= 3600) "${total / 3600}h ${(total % 3600) / 60}m" else if (total >= 60) "${total / 60}m ${total % 60}s" else "${total}s"
    return "%s left".tr(text)
}

/** Everything already in the debrid account, newest first. Nothing here adds to the account. */
@Composable
fun DebridCloudScreen() {
    val stores = Env.stores
    val router = Env.router
    val settings = stores.settings
    var entries by remember { mutableStateOf<List<DebridCloud.Entry>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var attempt by remember { mutableStateOf(0) }
    LaunchedEffect(attempt) {
        loading = true
        runCatching { DebridCloud.list(settings.debridService, settings.debridKey) }.onSuccess { entries = it; error = null }
            .onFailure { if (it !is kotlinx.coroutines.CancellationException) error = PlaybackErrors.describe(it) }
        loading = false
    }
    val words = query.lowercase().split(" ").filter { it.isNotEmpty() }
    val shown = entries.filter { entry -> words.all { entry.name.lowercase().contains(it) } }.sortedByDescending { it.added ?: Instant.MIN }
    PushedPage("%s Files".tr(settings.debridService.title)) {
        LazyColumn(contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), singleLine = true, shape = RoundedCornerShape(14.dp),
                    placeholder = { Text("Search your files".tr()) }, leadingIcon = { Icon(Icons.Rounded.Search, null) })
            }
            when {
                loading && entries.isEmpty() -> item { Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Theme.accent) } }
                error != null && entries.isEmpty() -> item { StateMessage("Couldn't load your files", error ?: "", actionTitle = "Retry") { attempt++ } }
                entries.isEmpty() -> item { StateMessage("Nothing here yet", "Releases you play or download through %s appear here.".tr(settings.debridService.title), icon = Icons.Rounded.Inbox) }
            }
            items(shown, key = { it.id }) { entry ->
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Theme.surface)
                    .let { if (entry.ready) it.focusCard(RoundedCornerShape(14.dp), { router.push(Route.CloudFiles(entry)) }) else it }.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(entry.name, fontWeight = FontWeight.SemiBold, maxLines = 2)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (entry.bytes > 0) Text(formatBytes(entry.bytes), fontSize = 12.sp, color = Theme.secondaryText)
                        entry.added?.let { Text(mediumDate(it), fontSize = 12.sp, color = Theme.secondaryText) }
                        if (!entry.ready) { Icon(Icons.Rounded.HourglassTop, null, Modifier.size(13.dp), tint = Theme.warning); Text("Not ready".tr(), fontSize = 12.sp, color = Theme.warning) }
                    }
                }
            }
        }
    }
}

/** The video files of one release in the account. */
@Composable
fun CloudFilesScreen(entry: DebridCloud.Entry) {
    val stores = Env.stores
    val settings = stores.settings
    val scope = rememberCoroutineScope()
    var files by remember { mutableStateOf<List<DebridCloud.File>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var opening by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(entry.id) {
        runCatching { DebridCloud.files(entry, settings.debridService, settings.debridKey) }.onSuccess { files = it }
            .onFailure { if (it !is kotlinx.coroutines.CancellationException) error = PlaybackErrors.describe(it) }
        loading = false
    }
    PushedPage(entry.name) {
        LazyColumn(contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            when {
                loading && files.isEmpty() -> item { Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Theme.accent) } }
                error != null && files.isEmpty() -> item { StateMessage("Couldn't list the files", error ?: "") }
                files.isEmpty() -> item { StateMessage("No video files", "This release has nothing that plays.", icon = Icons.Rounded.Movie) }
            }
            items(files.sortedBy { it.name.lowercase() }, key = { it.id }) { file ->
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Theme.surface).focusCard(RoundedCornerShape(14.dp), {
                    if (opening != null) return@focusCard
                    opening = file.id
                    scope.launch {
                        try {
                            stores.playback.playCloudFile(file.name, file.bytes, DebridCloud.link(file, settings.debridService, settings.debridKey))
                        } catch (e: Exception) {
                            stores.playback.errorMessage = PlaybackErrors.describe(e)
                        } finally {
                            opening = null
                        }
                    }
                }).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(file.name, fontWeight = FontWeight.Medium, maxLines = 2)
                        if (file.bytes > 0) Text(formatBytes(file.bytes), fontSize = 12.sp, color = Theme.secondaryText)
                    }
                    if (opening == file.id) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Theme.accent)
                    else Icon(Icons.Rounded.PlayArrow, null, tint = Theme.accent)
                }
            }
        }
    }
}
