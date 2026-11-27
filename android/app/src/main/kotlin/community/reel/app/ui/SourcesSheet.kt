package community.reel.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Extension
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.Inbox
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.SdStorage
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarOutline
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.core.AppSettings
import community.reel.core.HealthModel
import community.reel.core.PlaybackCenter
import community.reel.core.PlaybackErrors
import community.reel.core.PlaybackTarget
import community.reel.core.SourceMemory
import community.reel.core.SourceQuery
import community.reel.core.SourceRanker
import community.reel.core.SourceVerification
import community.reel.core.StreamSource
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class SourcesModel {
    var sources by mutableStateOf<List<StreamSource>>(emptyList())
    var isLoading by mutableStateOf(true)
    var error by mutableStateOf<String?>(null)
    val verifying = mutableStateMapOf<String, Boolean>()
    val verifyErrors = mutableStateMapOf<String, String>()

    suspend fun load(target: PlaybackTarget, playback: PlaybackCenter, query: SourceQuery, refresh: Boolean = false) {
        if (!refresh) playback.cachedSources(target, query)?.let { sources = it; isLoading = false; return }
        isLoading = sources.isEmpty()
        try {
            sources = playback.sources(target, query, refresh)
            error = null
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            error = PlaybackErrors.describe(e)
        } finally {
            isLoading = false
        }
    }

    suspend fun verify(source: StreamSource, playback: PlaybackCenter, settings: AppSettings) {
        if (verifying[source.fileKey] == true) return
        verifying[source.fileKey] = true
        verifyErrors.remove(source.fileKey)
        try {
            playback.verify(source, settings)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            verifyErrors[source.fileKey] = PlaybackErrors.describe(e)
        } finally {
            verifying.remove(source.fileKey)
        }
    }
}

enum class SourceOrder(val title: String) { BEST("Best for you"), LARGEST("Largest"), SMALLEST("Smallest"), SEEDERS("Most seeders") }

/** Tags that can narrow the list, when at least one source carries them. */
private val filterTags = listOf("Instant", "DV", "HDR", "Atmos", "Remux", "HEVC", "AV1")

private fun matches(source: StreamSource, tag: String) = when (tag) {
    "Instant" -> source.isCached
    "HDR" -> source.hasHDR
    else -> tag in source.tags
}

/**
 * Every release found, grouped by quality, with what matters for choosing one: what history says
 * about it, and what the file really contains once checked.
 */
@Composable
fun SourcesSheet(target: PlaybackTarget) {
    val stores = Env.stores
    val router = Env.router
    val settings = stores.settings.observe()
    val memory = stores.memory.observe()
    stores.downloads.observe()
    val playback = stores.playback
    val model = remember(target.videoID) { SourcesModel() }
    val scope = rememberCoroutineScope()
    var quality by remember { mutableStateOf("All") }
    var order by remember { mutableStateOf(SourceOrder.BEST) }
    var text by remember { mutableStateOf("") }
    var required by remember { mutableStateOf(setOf<String>()) }
    var addon by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }

    val query = settings.sourceQuery
    LaunchedEffect(target.videoID, query) { model.load(target, playback, query) }

    val ranked = remember(model.sources, settings.sourcePreferences, memory.records) { SourceRanker.rank(model.sources, memory, preferences = settings.sourcePreferences) }
    val recommended = ranked.firstOrNull { it.isCached || !settings.isDebridConfigured }
    val present = model.sources.map { it.quality }.toSet()
    val qualities = listOf("All") + (StreamSource.QUALITY_ORDER + "Other").filter { it in present } + (present - (StreamSource.QUALITY_ORDER + "Other").toSet()).sorted()
    val availableTags = filterTags.filter { tag -> model.sources.any { matches(it, tag) } }
    val addons = model.sources.map { it.addon }.toSet().sorted()
    val words = text.lowercase().split(" ").filter { it.isNotEmpty() }
    val filtered = model.sources.filter { source ->
        if (quality != "All" && source.quality != quality) return@filter false
        if (addon != null && source.addon != addon) return@filter false
        if (!required.all { matches(source, it) }) return@filter false
        if (words.isNotEmpty()) {
            val haystack = listOf(source.release, source.file ?: "", source.languages ?: "", source.provider ?: "", source.tags.joinToString(" "), source.releaseGroup ?: "")
                .joinToString(" ").lowercase()
            if (!words.all { haystack.contains(it) }) return@filter false
        }
        true
    }
    val isFiltering = quality != "All" || addon != null || required.isNotEmpty() || text.isNotEmpty()
    val rankIndex = ranked.withIndex().associate { it.value.id to it.index }
    fun cachedFirst(list: List<StreamSource>) = list.filter { it.isCached } + list.filter { !it.isCached }
    fun sorted(list: List<StreamSource>) = when (order) {
        SourceOrder.BEST -> list.filter { it.isPlayable }.sortedBy { rankIndex[it.id] ?: Int.MAX_VALUE } + list.filter { !it.isPlayable }
        SourceOrder.LARGEST -> cachedFirst(list.sortedByDescending { it.sizeBytes })
        SourceOrder.SMALLEST -> cachedFirst(list.sortedBy { if (it.sizeBytes == 0.0) Double.MAX_VALUE else it.sizeBytes })
        SourceOrder.SEEDERS -> cachedFirst(list.sortedByDescending { it.seeders ?: 0 })
    }
    val groups = filtered.groupBy { it.quality }.toList().sortedWith(compareBy({ StreamSource.QUALITY_ORDER.indexOf(it.first).let { i -> if (i < 0) 99 else i } }, { it.first }))
        .map { it.first to sorted(it.second) }

    fun pick(source: StreamSource) {
        playback.choosingSource = null
        playback.play(target, settings, stores.library, source = source, fromStart = playback.chooseFromStart)
    }

    Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(target.displayTitle, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Box {
                RoundIconButton(Icons.Rounded.FilterList, "Sort and filter") { menu = true }
                DropdownMenu(menu, { menu = false }) {
                    Text("Sort".tr(), style = MaterialTheme.typography.labelMedium, color = Theme.secondaryText, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                    for (value in SourceOrder.entries) DropdownMenuItem({ Text(value.title.tr()) }, { order = value; menu = false },
                        trailingIcon = { if (order == value) Icon(Icons.Rounded.CheckCircle, null, tint = Theme.accent) })
                    if (qualities.size > 2) {
                        HorizontalDivider()
                        for (value in qualities) DropdownMenuItem({ Text(value.tr()) }, { quality = value; menu = false },
                            trailingIcon = { if (quality == value) Icon(Icons.Rounded.CheckCircle, null, tint = Theme.accent) })
                    }
                    if (addons.size > 1) {
                        HorizontalDivider()
                        DropdownMenuItem({ Text("All addons".tr()) }, { addon = null; menu = false })
                        for (value in addons) DropdownMenuItem({ Text(value) }, { addon = value; menu = false },
                            trailingIcon = { if (addon == value) Icon(Icons.Rounded.CheckCircle, null, tint = Theme.accent) })
                    }
                    HorizontalDivider()
                    if (settings.isDebridConfigured) MenuItem("Check Top 5 Formats", Icons.Rounded.Verified) {
                        menu = false
                        // Reads the real format of the five likeliest picks, one after another.
                        scope.launch {
                            for (source in ranked.filter { it.isCached && memory.verification(it) == null }.take(5)) model.verify(source, playback, settings)
                        }
                    }
                    MenuItem("Refresh", Icons.Rounded.Refresh) { menu = false; scope.launch { model.load(target, playback, settings.sourceQuery, refresh = true) } }
                }
            }
        }
        OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), singleLine = true,
            placeholder = { Text("Release, group, language".tr()) }, leadingIcon = { Icon(Icons.Rounded.Search, null) }, shape = RoundedCornerShape(14.dp))

        when {
            model.isLoading -> Box(Modifier.fillMaxWidth().height(240.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = Theme.accent)
                    Gap(10.dp)
                    Text("Searching sources…".tr(), color = Theme.secondaryText)
                }
            }
            model.error != null && model.sources.isEmpty() -> StateMessage("Couldn't load sources", model.error ?: "", actionTitle = "Retry") {
                scope.launch { model.load(target, playback, settings.sourceQuery, refresh = true) }
            }
            model.sources.isEmpty() -> StateMessage("No sources", "Nothing was found with your current filters and addons.", icon = Icons.Rounded.Inbox)
            else -> LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!settings.isDebridConfigured) item {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.Info, null, tint = Theme.secondaryText); Spacer(Modifier.width(8.dp))
                        Text("Add a debrid service in Settings to play Torrentio's sources.".tr(), color = Theme.secondaryText, style = MaterialTheme.typography.bodySmall)
                    }
                }
                item {
                    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Theme.surface)
                        .focusCard(RoundedCornerShape(16.dp), { playback.choosingSource = null; router.openSettings(SettingsPage.PICK_RULES) }).padding(12.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.Tune, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                            Text("Pick Rules".tr(), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                        }
                        Text(rulesSummary(settings), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 2)
                    }
                }
                if (availableTags.isNotEmpty()) item {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        items(availableTags) { tag ->
                            val on = tag in required
                            Chip(tag, selected = on) { required = if (on) required - tag else required + tag }
                        }
                        if (isFiltering) item { TextButton({ required = emptySet(); addon = null; quality = "All"; text = "" }) { Text("Clear".tr()) } }
                    }
                }
                item { Text(foundSummary(model.sources, filtered.size, isFiltering, settings), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText) }
                if (recommended != null && !isFiltering && order == SourceOrder.BEST) {
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.AutoAwesome, null, Modifier.size(16.dp), tint = Theme.accent); Spacer(Modifier.width(6.dp))
                            Text("Recommended".tr(), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                        }
                    }
                    item(key = "rec-" + recommended.id) { SourceButton(recommended, target, model, memory, ::pick) }
                    item {
                        Text("What Play picks: instant first, then your quality order and source preferences, then what has played well for you before.".tr(),
                            style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText)
                    }
                }
                if (filtered.isEmpty()) item { Text("Nothing matches these filters.".tr(), color = Theme.secondaryText) }
                for ((name, list) in groups) {
                    item(key = "h-$name") { Text("$name · ${list.size}", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp)) }
                    items(list, key = { it.id }) { SourceButton(it, target, model, memory, ::pick) }
                }
            }
        }
    }
}

private fun rulesSummary(settings: AppSettings): String {
    val parts = mutableListOf<String>()
    if (settings.cachedOnly && settings.isDebridConfigured) parts += "Instant only".tr()
    if (settings.excludedQualities.isNotEmpty()) parts += "Hides %s".tr(settings.excludedQualities.joinToString(", ") { HealthModel.qualityLabel(it).tr() })
    if (settings.maxSizeGB > 0) parts += "Up to %d GB".tr(settings.maxSizeGB)
    if (settings.providers.isNotEmpty()) parts += "%d providers".tr(settings.providers.size)
    val addons = settings.addons.count { it.enabled }
    if (addons > 0) parts += if (addons == 1) "+1 addon".tr() else "+%d addons".tr(addons)
    return if (parts.isEmpty()) "No filters".tr() else parts.joinToString(" · ")
}

private fun foundSummary(sources: List<StreamSource>, shown: Int, filtering: Boolean, settings: AppSettings): String {
    var text = "%d found".tr(sources.size)
    if (settings.isDebridConfigured) text += " · " + "%d instant".tr(sources.count { it.isCached })
    val addons = sources.map { it.addon }.toSet().size
    if (addons > 1) text += " · " + "from %d addons".tr(addons)
    if (filtering) text += " · " + "%d shown".tr(shown)
    return text
}

@Composable
private fun SourceButton(source: StreamSource, target: PlaybackTarget, model: SourcesModel, memory: SourceMemory, pick: (StreamSource) -> Unit) {
    val stores = Env.stores
    val settings = stores.settings
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    Box {
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Theme.surface)
            .let { if (source.isPlayable) it.focusCard(RoundedCornerShape(16.dp), { pick(source) }, { menu = true }) else it }.padding(12.dp)) {
            SourceRow(source, if (memory.failedBefore(source)) false else if (memory.playedWell(source)) true else null, memory.verification(source),
                model.verifying[source.fileKey] == true, model.verifyErrors[source.fileKey])
        }
        DropdownMenu(menu, { menu = false }) {
            MenuItem("Play", Icons.Rounded.PlayArrow) { menu = false; pick(source) }
            if (source.isCached) {
                MenuItem("Check Format", Icons.Rounded.Verified) { menu = false; scope.launch { model.verify(source, stores.playback, settings) } }
                MenuItem(if (stores.downloads.item(target) == null) "Download" else "Download This Instead", Icons.Rounded.Download) {
                    menu = false; stores.playback.download(target, settings, source)
                }
            }
            source.releaseGroup?.let { group ->
                val favoured = settings.preferredGroups.any { it.equals(group, ignoreCase = true) }
                MenuItem(if (favoured) "Stop Preferring %s".tr(group) else "Prefer %s Releases".tr(group), if (favoured) Icons.Rounded.StarOutline else Icons.Rounded.Star) {
                    menu = false
                    settings.preferredGroups = if (favoured) settings.preferredGroups.filterNot { it.equals(group, ignoreCase = true) } else settings.preferredGroups + group
                }
            }
        }
    }
}

@Composable
fun SourceRow(source: StreamSource, playedWell: Boolean?, verification: SourceVerification?, verifying: Boolean, verifyError: String?) {
    Column(Modifier.fillMaxWidth().alpha(if (source.isPlayable) 1f else 0.5f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            QualityBadge(source.quality)
            // Once the file has been checked, its real format replaces the release name's claims.
            val claimed = source.tags.take(4)
            val shownTags = if (verification == null) claimed else claimed.filter { it !in listOf("DV", "HDR", "HDR10", "HDR10+", "HLG", "Atmos") }
            for (tag in shownTags) SmallTag(tag)
            Spacer(Modifier.weight(1f))
            if (source.debridTag != null || source.isCached) {
                Icon(if (source.isCached) Icons.Rounded.Bolt else Icons.Rounded.Download, null, Modifier.size(14.dp), tint = if (source.isCached) Theme.cached else Theme.secondaryText)
                Text((if (source.isCached) "Instant" else "Download").tr(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                    color = if (source.isCached) Theme.cached else Theme.secondaryText)
            }
        }
        Text(source.release, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
        source.file?.takeIf { it != source.release }?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        when {
            verifying -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = Theme.secondaryText); Spacer(Modifier.width(6.dp))
                Text("Checking the file…".tr(), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText)
            }
            verification != null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Rounded.Verified, null, Modifier.size(15.dp), tint = Theme.accent)
                for (badge in verification.badges.ifEmpty { listOf("SDR") }) {
                    Box(Modifier.clip(RoundedCornerShape(5.dp)).background(Theme.accentGradient).padding(horizontal = 6.dp, vertical = 3.dp)) {
                        Text(badge, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                }
                listOfNotNull(verification.resolution, verification.audio).joinToString(" · ").takeIf { it.isNotEmpty() }?.let {
                    Text(it, fontSize = 11.sp, color = Theme.secondaryText, maxLines = 1)
                }
            }
            verifyError != null -> Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Warning, null, Modifier.size(14.dp), tint = Theme.warning); Spacer(Modifier.width(4.dp))
                Text(verifyError, style = MaterialTheme.typography.bodySmall, color = Theme.warning, maxLines = 2)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            source.size?.let { Fact(Icons.Rounded.SdStorage, it) }
            source.seeders?.let { Fact(Icons.Rounded.Groups, "$it") }
            if (source.addon != "Torrentio") Fact(Icons.Rounded.Extension, source.addon) else source.provider?.let { Fact(Icons.Rounded.Language, it) }
            source.languages?.let { Text(it, fontSize = 12.sp, color = Theme.secondaryText, maxLines = 1) }
        }
        playedWell?.let { good ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(if (good) Icons.Rounded.CheckCircle else Icons.Rounded.Warning, null, Modifier.size(14.dp), tint = if (good) Theme.cached else Theme.warning)
                Spacer(Modifier.width(4.dp))
                Text((if (good) "Played well before" else "Failed to play before").tr(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                    color = if (good) Theme.cached else Theme.warning)
            }
        }
    }
}

@Composable
private fun SmallTag(tag: String) {
    Box(Modifier.clip(RoundedCornerShape(5.dp)).background(Color.White.copy(alpha = 0.1f)).padding(horizontal = 6.dp, vertical = 3.dp)) {
        Text(tag, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun Fact(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(13.dp), tint = Theme.secondaryText); Spacer(Modifier.width(3.dp))
        Text(text, fontSize = 12.sp, color = Theme.secondaryText, maxLines = 1)
    }
}

