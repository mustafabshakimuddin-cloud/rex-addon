package community.reel.app.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.LockOpen
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.core.AccentChoice
import community.reel.core.AppConfig
import community.reel.core.Addons
import community.reel.core.Backup
import community.reel.core.HealthModel
import community.reel.core.HomeSection
import community.reel.core.JSONFile
import community.reel.core.Leaning
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.Platform
import community.reel.core.PosterSize
import community.reel.core.TMDB
import community.reel.core.Torrentio
import community.reel.core.TorrentioSort
import community.reel.core.TraktStore
import community.reel.core.readable
import kotlinx.coroutines.launch

private fun open(context: Context, url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))

/** Which releases are listed, and which one Play picks. */
@Composable
fun PickRulesScreen() {
    val router = Env.router
    val settings = Env.stores.settings.observe()
    FormPage("Pick Rules") {
        FormSection(footer = "“Instant” sources are already cached by your debrid service and start straight away. A size limit keeps 4K remuxes off a slow connection.") {
            ToggleRow("Instant sources only", settings.cachedOnly) { settings.cachedOnly = it }
            FormDivider()
            PickerRow("Sort", settings.sort, TorrentioSort.entries.toList(), { it.title.tr() }) { settings.sort = it }
            FormDivider()
            PickerRow("Maximum size", settings.maxSizeGB, listOf(0, 2, 5, 10, 20, 40), { if (it == 0) "No limit".tr() else "$it GB" }) { settings.maxSizeGB = it }
        }
        FormSection(footer = "Play picks instant sources first, then your quality order, then your preferences below, then what has played well for you before. Changes apply to the next search. The seeder minimum applies to releases that aren't instant.") {
            FormRow("Hide qualities", value = if (settings.excludedQualities.isEmpty()) "None".tr() else settings.excludedQualities.joinToString(", ") { HealthModel.qualityLabel(it).tr() },
                chevron = true, onClick = { router.push(Route.Settings(SettingsPage.HIDE_QUALITIES)) })
            FormDivider()
            FormRow("Providers", value = if (settings.providers.isEmpty()) "All".tr() else "%d selected".tr(settings.providers.size), chevron = true,
                onClick = { router.push(Route.Settings(SettingsPage.PROVIDERS)) })
            FormDivider()
            PickerRow("Minimum seeders", settings.minSeeders, listOf(0, 5, 10, 25, 50), { if (it == 0) "Any".tr() else "$it" }) { settings.minSeeders = it }
        }
        FormSection("Preferences", "Within a quality, these decide which release comes first. Matching the device passes over Dolby Vision and HDR on screens that can't show them, and AV1 where the chip can't decode it%s. Long-press a source to prefer its release group."
            .tr(if (Platform.device.av1) "" else " " + "(this one can't)".tr())) {
            for ((title, value, set) in listOf<Triple<String, Leaning, (Leaning) -> Unit>>(
                Triple("HDR", settings.preferHDR) { settings.preferHDR = it }, Triple("Dolby Vision", settings.preferDolbyVision) { settings.preferDolbyVision = it },
                Triple("Dolby Atmos", settings.preferAtmos) { settings.preferAtmos = it }, Triple("Remux", settings.preferRemux) { settings.preferRemux = it })) {
                PickerRow(title, value, Leaning.entries.toList(), { it.title.tr() }, set)
                FormDivider()
            }
            ToggleRow("Favour my audio language", settings.preferAudioLanguageReleases) { settings.preferAudioLanguageReleases = it }
            FormDivider()
            ToggleRow("Match this device", settings.matchDevice) { settings.matchDevice = it }
            FormDivider()
            FormRow("Preferred groups", value = if (settings.preferredGroups.isEmpty()) "None".tr() else settings.preferredGroups.joinToString(", "), chevron = true,
                onClick = { router.push(Route.Settings(SettingsPage.GROUPS)) })
        }
        FormSection("Torrentio", "A self-hosted Torrentio can stand in for the public one. Languages listed here come first in Torrentio's results.") {
            TextRow(settings.torrentioServer, { settings.torrentioServer = it }, "Server", keyboard = KeyboardType.Uri)
            if (settings.torrentioServer != Torrentio.BASE) FormRow("Use the public server", titleColor = Theme.accent, onClick = { settings.torrentioServer = Torrentio.BASE })
            FormDivider()
            FormRow("Language priority", value = if (settings.priorityLanguages.isEmpty()) "None".tr() else settings.priorityLanguages.joinToString(", ") { it.replaceFirstChar { c -> c.uppercase() } },
                chevron = true, onClick = { router.push(Route.Settings(SettingsPage.LANGUAGES)) })
            FormDivider()
            PickerRow("Results per quality", settings.perQualityLimit, listOf(0, 3, 5, 10, 20), { if (it == 0) "All".tr() else "$it" }) { settings.perQualityLimit = it }
        }
    }
}

/** Release groups whose releases come first within a quality. */
@Composable
fun GroupsScreen() {
    val settings = Env.stores.settings.observe()
    var draft by remember { mutableStateOf("") }
    fun add() {
        val group = draft.trim().uppercase()
        if (group.isEmpty() || group in settings.preferredGroups) return
        settings.preferredGroups = settings.preferredGroups + group
        draft = ""
    }
    FormPage("Preferred Groups") {
        FormSection(footer = "The group is the name after the last dash in a release: “FLUX” in Movie.2024.2160p.WEB-DL.DV-FLUX.") {
            TextRow(draft, { draft = it }, "Group, e.g. FLUX")
            FormRow("Add", titleColor = Theme.accent, onClick = if (draft.isBlank()) null else ::add)
        }
        if (settings.preferredGroups.isNotEmpty()) FormSection {
            settings.preferredGroups.forEachIndexed { index, group ->
                if (index > 0) FormDivider()
                FormRow(group) { IconButton({ settings.preferredGroups = settings.preferredGroups - group }) { Icon(Icons.Rounded.Delete, "Remove".tr(), tint = Theme.problem) } }
            }
        }
    }
}

@Composable
fun MultiSelectScreen(title: String, options: List<String>, label: (String) -> String, read: () -> List<String>, write: (List<String>) -> Unit) {
    Env.stores.settings.observe()
    val selection = read()
    FormPage(title, actions = { if (selection.isNotEmpty()) TextButton({ write(emptyList()) }) { Text("Clear".tr()) } }) {
        FormSection {
            options.forEachIndexed { index, option ->
                if (index > 0) FormDivider()
                FormRow(label(option), onClick = { write(if (option in selection) selection - option else selection + option) }) {
                    if (option in selection) Icon(Icons.Rounded.Check, null, tint = Theme.accent)
                }
            }
        }
    }
}

/** Stremio addons whose streams are merged with Torrentio's. */
@Composable
fun AddonsScreen() {
    val settings = Env.stores.settings.observe()
    val scope = rememberCoroutineScope()
    var address by remember { mutableStateOf("") }
    var adding by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    FormPage("Stremio Addons") {
        FormSection("Add", "Paste the install link from the addon's configure page. It ends in manifest.json and may start with stremio://. If it contains your debrid key, configure it there with the same service you use here. An addon's streams join Torrentio's, and its catalogues appear in Explore under Rows.") {
            TextRow(address, { address = it }, "https://…/manifest.json", keyboard = KeyboardType.Uri)
            FormRow("Add Addon", titleColor = Theme.accent, onClick = if (address.isBlank() || adding) null else ({
                adding = true
                error = null
                scope.launch {
                    try {
                        val addon = Addons.install(address)
                        val index = settings.addons.indexOfFirst { it.id == addon.id }
                        settings.addons = if (index >= 0) settings.addons.toMutableList().apply { set(index, addon) } else settings.addons + addon
                        address = ""
                    } catch (e: Exception) {
                        error = e.readable()
                    } finally {
                        adding = false
                    }
                }
            })) { if (adding) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Theme.accent) }
            error?.let { Row(Modifier.padding(16.dp)) { Icon(Icons.Rounded.Warning, null, tint = Theme.warning); Spacer(Modifier.width(6.dp)); Text(it, color = Theme.warning, fontSize = 13.sp) } }
        }
        FormSection("Installed") {
            if (settings.addons.isEmpty()) Text("None yet. Torrentio is always on.".tr(), color = Theme.secondaryText, modifier = Modifier.padding(16.dp))
            settings.addons.forEachIndexed { index, addon ->
                if (index > 0) FormDivider()
                Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(addon.name)
                            Text(community.reel.core.hostOf(addon.base).ifEmpty { addon.base }, fontSize = 12.sp, color = Theme.secondaryText)
                            val catalogs = addon.catalogs?.size ?: 0
                            Text(listOfNotNull(if (addon.hasStreams) "Streams".tr() else null, if (catalogs > 0) "%d catalogues in Explore".tr(catalogs) else null).joinToString(" · "),
                                fontSize = 11.sp, color = Theme.secondaryText)
                        }
                        IconButton({ if (index > 0) settings.addons = settings.addons.toMutableList().apply { add(index - 1, removeAt(index)) } }) { Icon(Icons.Rounded.ArrowUpward, "Move up".tr()) }
                        IconButton({ if (index < settings.addons.size - 1) settings.addons = settings.addons.toMutableList().apply { add(index + 1, removeAt(index)) } }) { Icon(Icons.Rounded.ArrowDownward, "Move down".tr()) }
                        IconButton({ settings.addons = settings.addons.filter { it.id != addon.id } }) { Icon(Icons.Rounded.Delete, "Remove".tr(), tint = Theme.problem) }
                        Switch(addon.enabled, { on -> settings.addons = settings.addons.map { if (it.id == addon.id) it.copy(enabled = on) else it } },
                            colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent))
                    }
                    if (addon.base.startsWith("http://")) Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.LockOpen, null, Modifier.size(13.dp), tint = Theme.warning); Spacer(Modifier.width(4.dp))
                        Text("Not encrypted: its links, and any key in them, travel in the clear.".tr(), fontSize = 11.sp, color = Theme.warning)
                    }
                }
            }
        }
    }
}

/** Connects a Trakt account with the device flow. */
@Composable
fun TraktSettingsScreen() {
    val context = LocalContext.current
    val trakt = Env.stores.trakt.observe()
    val scope = rememberCoroutineScope()
    var clientID by remember { mutableStateOf(trakt.credentials?.clientID ?: "") }
    var clientSecret by remember { mutableStateOf(trakt.credentials?.clientSecret ?: "") }
    FormPage("Trakt") {
        if (trakt.isConnected) {
            FormSection(footer = "Your watchlist, resume points and watched episodes come in from Trakt; what you watch and add here goes back.") {
                FormRow("Status", value = "Connected".tr())
                trakt.lastSync?.let { FormDivider(); FormRow("Last sync", value = shortTime(it)) }
                trakt.syncError?.let { FormDivider(); Row(Modifier.padding(16.dp)) { Icon(Icons.Rounded.Warning, null, tint = Theme.warning); Spacer(Modifier.width(6.dp)); Text(it, color = Theme.warning, fontSize = 13.sp) } }
                FormDivider()
                FormRow("Sync Now", titleColor = Theme.accent, onClick = if (trakt.isSyncing) null else ({ scope.launch { trakt.sync() } })) {
                    if (trakt.isSyncing) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Theme.accent)
                }
                FormDivider()
                FormRow("Disconnect", titleColor = Theme.problem, onClick = { trakt.disconnect() })
            }
            return@FormPage
        }
        when (val signIn = trakt.signIn) {
            is TraktStore.SignIn.Waiting -> FormSection {
                Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Enter this code at".tr(), color = Theme.secondaryText)
                    Text(signIn.url.removePrefix("https://"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(signIn.code, fontSize = 40.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        PillButton("Copy Code".tr(), Icons.Rounded.ContentCopy) {
                            context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Trakt", signIn.code))
                        }
                        PillButton("Open Trakt".tr(), Icons.AutoMirrored.Rounded.OpenInNew, prominent = true) { open(context, signIn.url) }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Theme.secondaryText); Spacer(Modifier.width(8.dp))
                        Text("Waiting for you to approve…".tr(), fontSize = 13.sp, color = Theme.secondaryText)
                    }
                }
                FormDivider()
                FormRow("Cancel", titleColor = Theme.accent, onClick = { trakt.cancelSignIn() })
            }
            else -> {
                FormSection("Your Trakt API App", "Trakt needs an API app of your own: open trakt.tv/oauth/applications, choose New Application, give it any name, enter urn:ietf:wg:oauth:2.0:oob as the redirect URI, and save. Paste its Client ID and Client Secret here. They are kept encrypted on this device.") {
                    TextRow(clientID, { clientID = it }, "Client ID")
                    TextRow(clientSecret, { clientSecret = it }, "Client Secret", secret = true)
                    FormRow("Connect", titleColor = Theme.accent, onClick = if (clientID.isEmpty() || clientSecret.isEmpty()) null else ({ trakt.connect(clientID, clientSecret) }))
                    (signIn as? TraktStore.SignIn.Failed)?.let { Row(Modifier.padding(16.dp)) { Icon(Icons.Rounded.Warning, null, tint = Theme.warning); Spacer(Modifier.width(6.dp)); Text(it.message, color = Theme.warning, fontSize = 13.sp) } }
                }
                FormSection {
                    FormRow("Create a Trakt API App", icon = Icons.AutoMirrored.Rounded.OpenInNew, titleColor = Theme.accent, onClick = { open(context, "https://trakt.tv/oauth/applications/new") })
                }
            }
        }
    }
}

/** Accent colour, poster size and the small things that change how the app looks. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AppearanceScreen() {
    val settings = Env.stores.settings.observe()
    val sample = MediaItem("tt0111161", MediaKind.MOVIE, "The Shawshank Redemption", poster = "https://images.metahub.space/poster/medium/tt0111161/img", year = "1994", rating = "9.3")
    FormPage("Appearance") {
        FormSection("Accent Colour") {
            FlowRow(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                for (choice in AccentChoice.entries) {
                    val selected = settings.accent == choice
                    Column(Modifier.width(64.dp).focusCard(RoundedCornerShape(12.dp), { settings.accent = choice }), horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(Modifier.size(44.dp).clip(CircleShape).background(Brush.linearGradient(listOf(Color(choice.deep), Color(choice.argb))))
                            .border(2.dp, Color.White.copy(alpha = if (selected) 0.9f else 0.15f), CircleShape), contentAlignment = Alignment.Center) {
                            if (selected) Icon(Icons.Rounded.Check, null, tint = Color.White)
                        }
                        Spacer(Modifier.size(6.dp))
                        Text(choice.title.tr(), fontSize = 12.sp, color = if (selected) Color.White else Theme.secondaryText)
                    }
                }
            }
        }
        FormSection("Posters", "Larger posters show fewer titles per row.") {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(12.dp)) {
                PosterSize.entries.forEachIndexed { index, size ->
                    SegmentedButton(settings.posterSize == size, { settings.posterSize = size }, SegmentedButtonDefaults.itemShape(index, PosterSize.entries.size)) { Text(size.title.tr()) }
                }
            }
            Box(Modifier.fillMaxWidth().padding(vertical = 6.dp), contentAlignment = Alignment.Center) {
                CompositionLocalProvider(LocalShowsRatings provides settings.showRatings) { PosterCard(sample, 116.dp * settings.posterSize.scale) {} }
            }
            FormDivider()
            ToggleRow("Show ratings on posters", settings.showRatings) { settings.showRatings = it }
        }
        FormSection("Home", "The featured titles at the top of Home move on every few seconds. Turn this off to move them only by swiping.") {
            ToggleRow("Move the featured row by itself", settings.heroAutoAdvance) { settings.heroAutoAdvance = it }
        }
    }
}

/** Which sections Home shows, in what order. */
@Composable
fun HomeLayoutScreen() {
    val settings = Env.stores.settings.observe()
    var confirmReset by remember { mutableStateOf(false) }
    FormPage("Home Screen") {
        FormSection(footer = "Use the arrows to reorder. Hidden sections aren't loaded. Waiting on You collects anything that needs you: setup, failed downloads, new episodes, a stopped sync.") {
            settings.homeOrder.forEachIndexed { index, section ->
                if (index > 0) FormDivider()
                FormRow(section.title) {
                    IconButton({ if (index > 0) settings.homeOrder = settings.homeOrder.toMutableList().apply { add(index - 1, removeAt(index)) } }) { Icon(Icons.Rounded.ArrowUpward, "Move up".tr()) }
                    IconButton({ if (index < settings.homeOrder.size - 1) settings.homeOrder = settings.homeOrder.toMutableList().apply { add(index + 1, removeAt(index)) } }) { Icon(Icons.Rounded.ArrowDownward, "Move down".tr()) }
                    Switch(section !in settings.homeHidden, { shown -> settings.homeHidden = if (shown) settings.homeHidden - section else settings.homeHidden + section },
                        colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent))
                }
            }
        }
        FormSection { FormRow("Reset to Default", titleColor = Theme.problem, onClick = { confirmReset = true }) }
    }
    if (confirmReset) AlertDialog(onDismissRequest = { confirmReset = false }, title = { Text("Show every section in the original order?".tr()) },
        confirmButton = { TextButton({ settings.resetHomeLayout(); confirmReset = false }) { Text("Reset".tr(), color = Theme.problem) } },
        dismissButton = { TextButton({ confirmReset = false }) { Text("Cancel".tr()) } })
}

/** How offline copies are made and kept. */
@Composable
fun OfflineSettingsScreen() {
    val router = Env.router
    val settings = Env.stores.settings.observe()
    FormPage("Offline Copies") {
        FormSection(footer = "Downloads pick the release Play would, within this size. Subtitles in your subtitle language come from OpenSubtitles and play offline too.") {
            ToggleRow("Download over mobile data", settings.downloadsOverCellular) { settings.downloadsOverCellular = it }
            FormDivider()
            PickerRow("Largest download", settings.downloadMaxSizeGB, listOf(0, 2, 4, 8, 15, 30), { if (it == 0) "Same as streaming".tr() else "$it GB" }) { settings.downloadMaxSizeGB = it }
            FormDivider()
            ToggleRow("Save subtitles with downloads", settings.downloadSubtitles) { settings.downloadSubtitles = it }
        }
        FormSection(footer = "A copy you've finished watching is deleted this long after, to free space.") {
            PickerRow("Delete after watching", settings.deleteWatchedDownloadsAfterDays, listOf(0, 1, 3, 7, 14, 30),
                { when (it) { 0 -> "Never".tr(); 1 -> "After a day".tr(); else -> "After %d days".tr(it) } }) { settings.deleteWatchedDownloadsAfterDays = it }
        }
        FormSection { FormRow("Open Downloads", titleColor = Theme.accent, onClick = { router.openLibrary(Route.Downloads) }) }
    }
}

/** A file with My List, history, source memory and settings, to restore after a reinstall. */
@Composable
fun BackupScreen() {
    val stores = Env.stores
    val context = LocalContext.current
    var message by remember { mutableStateOf<String?>(null) }
    var pending by remember { mutableStateOf<Uri?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) pending = uri }
    FormPage("Back Up and Restore") {
        FormSection(footer = "Saves My List, your history and resume points, what %s learned about sources, addons and settings. Your debrid key and Trakt sign-in aren't included; enter them again after restoring.".tr(AppConfig.NAME)) {
            FormRow("Save Backup…", titleColor = Theme.accent, onClick = {
                shareFile(context, Backup.fileName(), Backup.data(stores.library, stores.memory, stores.lists), "application/json")
            })
        }
        FormSection(footer = "Replaces My List, history and settings on this device with the backup's.") {
            FormRow("Restore from a Backup…", titleColor = Theme.accent, onClick = { picker.launch(arrayOf("application/json", "text/plain", "*/*")) })
        }
        message?.let { FormSection { Text(it, fontSize = 13.sp, modifier = Modifier.padding(16.dp)) } }
        if (JSONFile.unreadableFiles.isNotEmpty()) FormSection {
            Text("These files couldn't be read at launch and were kept aside rather than lost: %s. A backup restores what they held.".tr(JSONFile.unreadableFiles.joinToString(", ")),
                fontSize = 13.sp, color = Theme.warning, modifier = Modifier.padding(16.dp))
        }
    }
    pending?.let { uri ->
        AlertDialog(onDismissRequest = { pending = null }, title = { Text("Replace this device's library and settings with the backup?".tr()) },
            confirmButton = {
                TextButton({
                    pending = null
                    message = try {
                        val text = context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } ?: ""
                        Backup.restore(text, stores.library, stores.memory, stores.lists)
                        "Restored. Close and reopen %s for the restored settings to take effect.".tr(AppConfig.NAME)
                    } catch (e: Exception) {
                        "That file isn't a %s backup.".tr(AppConfig.NAME)
                    }
                }) { Text("Restore".tr(), color = Theme.problem) }
            },
            dismissButton = { TextButton({ pending = null }) { Text("Cancel".tr()) } })
    }
}

/** An optional key for The Movie Database, for photos and biographies of cast and crew. */
@Composable
fun TMDBSettingsScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var draft by remember { mutableStateOf(TMDB.key) }
    var state by remember { mutableStateOf<TestState>(TestState.Idle) }
    FormPage("TMDB") {
        FormSection(footer = "Optional. With a key, cast and crew get photos and person pages get a biography. Leave it empty to turn this off. The key is kept encrypted on this device.") {
            TextRow(draft, { draft = it }, "API key or read access token", secret = true)
            FormRow("Save and Test", titleColor = Theme.accent, onClick = if (state == TestState.Testing) null else ({
                val key = draft.trim()
                if (key.isEmpty()) { TMDB.setKey(""); state = TestState.Ok("Off".tr()) } else {
                    state = TestState.Testing
                    scope.launch { state = if (TMDB.test(key)) { TMDB.setKey(key); TestState.Ok("Working".tr()) } else TestState.Failed("TMDB refused that key.".tr()) }
                }
            })) { TestStatus(state) }
            FormDivider()
            FormRow("Get a free TMDB key", icon = Icons.AutoMirrored.Rounded.OpenInNew, titleColor = Theme.accent, onClick = { open(context, "https://www.themoviedb.org/settings/api") })
        }
    }
}

