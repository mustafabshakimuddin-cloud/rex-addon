package community.reel.app.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Backup
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.app.system.Notifier
import community.reel.core.AppConfig
import community.reel.core.DebridCheck
import community.reel.core.DebridService
import community.reel.core.HealthModel
import community.reel.core.Languages
import community.reel.core.SubtitleColor
import community.reel.core.SubtitleStyle
import community.reel.core.TMDB
import community.reel.core.ViewingPreferences
import community.reel.core.readable
import kotlinx.coroutines.launch

/** Settings: the main page, or the page on top of its own stack. */
@Composable
fun SettingsRoot() {
    val router = Env.router
    val top = router.settingsStack.lastOrNull()
    if (top != null) { RouteScreen(top); return }
    SettingsScreen()
}

@Composable
fun SettingsPageScreen(page: SettingsPage) {
    val settings = Env.stores.settings
    when (page) {
    SettingsPage.STATUS -> StatusScreen()
    SettingsPage.PICK_RULES -> PickRulesScreen()
    SettingsPage.ADDONS -> AddonsScreen()
    SettingsPage.TRAKT -> TraktSettingsScreen()
    SettingsPage.APPEARANCE -> AppearanceScreen()
    SettingsPage.HOME_SCREEN -> HomeLayoutScreen()
    SettingsPage.OFFLINE -> OfflineSettingsScreen()
    SettingsPage.BACKUP -> BackupScreen()
    SettingsPage.PROFILES -> ProfilesScreen()
    SettingsPage.TMDB -> TMDBSettingsScreen()
    SettingsPage.GROUPS -> GroupsScreen()
    SettingsPage.HIDE_QUALITIES -> MultiSelectScreen("Hide Qualities", community.reel.core.TorrentioConfig.qualityOptions, { HealthModel.qualityLabel(it).tr() },
        { settings.excludedQualities }, { settings.excludedQualities = it })
    SettingsPage.PROVIDERS -> MultiSelectScreen("Providers", community.reel.core.TorrentioConfig.allProviders, { it },
        { settings.providers }, { settings.providers = it })
    SettingsPage.LANGUAGES -> MultiSelectScreen("Language Priority", community.reel.core.TorrentioConfig.languageOptions, { it.replaceFirstChar { c -> c.uppercase() } },
        { settings.priorityLanguages }, { settings.priorityLanguages = it })
    }
}

@Composable
fun SettingsScreen() {
    val stores = Env.stores
    val router = Env.router
    val context = LocalContext.current
    val settings = stores.settings.observe()
    val trakt = stores.trakt.observe()
    val alerts = stores.alerts.observe()
    val profiles = stores.profiles.observe()
    val scope = rememberCoroutineScope()
    var keyDraft by remember { mutableStateOf(settings.debridKey) }
    var secondDraft by remember { mutableStateOf(settings.secondaryKey) }
    var test by remember { mutableStateOf<TestState>(TestState.Idle) }
    var secondTest by remember { mutableStateOf<TestState>(TestState.Idle) }
    var confirmForget by remember { mutableStateOf(false) }
    LaunchedEffect(settings.debridService) { test = TestState.Idle }
    fun scheduleEpisodes() {
        if (settings.notifyNewEpisodes) scope.launch {
            stores.upcoming.refresh(stores.library)
            Notifier.scheduleEpisodes(context, stores.upcoming.upcoming)
            Notifier.scheduleRefresh(context)
        }
    }
    // Android 13 asks before an app may notify; turned down, both switches go back off.
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) { settings.notifyNewEpisodes = false; settings.notifyDownloads = false } else scheduleEpisodes()
    }
    fun askToNotify() { if (Build.VERSION.SDK_INT >= 33 && !Notifier.allowed(context)) permission.launch(Manifest.permission.POST_NOTIFICATIONS) else scheduleEpisodes() }

    Page("Settings", large = true, actions = { RoundIconButton(Icons.Rounded.Check, "Done") { router.showingSettings = false } }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(22.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            FormSection(footer = "Status checks your debrid service, Torrentio, the catalogue and each addon, and says what to do about anything that fails.") {
                val (icon, tint) = when {
                    !settings.canFindSources -> Icons.Rounded.Error to Theme.problem
                    trakt.syncError != null || alerts.unseenProblems > 0 -> Icons.Rounded.Warning to Theme.warning
                    else -> Icons.Rounded.Verified to Theme.cached
                }
                val line = when {
                    !settings.canFindSources -> "Nothing can play yet".tr()
                    trakt.syncError != null -> "Trakt sync stopped".tr()
                    alerts.unseenProblems > 0 -> if (alerts.unseenProblems == 1) "1 new alert".tr() else "%d new alerts".tr(alerts.unseenProblems)
                    else -> "Check that everything works".tr()
                }
                FormRow("Status", icon = icon, iconTint = tint, subtitle = line, chevron = true, onClick = { router.push(Route.Settings(SettingsPage.STATUS)) }) {
                    if (Attention.settingsNeedAttention(settings, trakt, alerts)) AttentionDot()
                }
                FormDivider()
                FormRow("Profile", value = profiles.current.name, chevron = true, onClick = { router.push(Route.Settings(SettingsPage.PROFILES)) }) {}
                FormDivider()
                FormRow(if (settings.setupFinished) "Run Setup Again" else "Finish Setup", icon = Icons.Rounded.AutoAwesome, titleColor = Theme.accent, onClick = { router.openSetup() })
            }

            FormSection("Debrid Service", "Streams play through your debrid account: the release is fetched by the service and streamed to you over HTTPS. The key is stored encrypted on this device.") {
                PickerRow("Service", settings.debridService, DebridService.entries.toList(), { it.title.tr() }) { settings.debridService = it }
                if (settings.debridService != DebridService.NONE) {
                    TextRow(keyDraft, { keyDraft = it }, "API key", secret = true)
                    FormRow("Save and Test", titleColor = Theme.accent, onClick = if (keyDraft.isBlank() || test == TestState.Testing) null else ({
                        settings.debridKey = keyDraft.trim()
                        test = TestState.Testing
                        scope.launch {
                            // The key as playback uses it, checked without adding anything to the account.
                            DebridCheck.run(settings.torrentio).onSuccess { test = TestState.Ok(it.summary.tr()); settings.debridAccount = it.account }
                                .onFailure { test = TestState.Failed(it.readable()) }
                        }
                    })) { TestStatus(test) }
                    settings.debridService.keyPage?.let { page ->
                        FormDivider()
                        FormRow("Get your %s API key".tr(settings.debridService.title), icon = Icons.AutoMirrored.Rounded.OpenInNew, titleColor = Theme.accent,
                            onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(page))) })
                    }
                    settings.debridAccount?.let { account ->
                        account.username?.let { FormDivider(); FormRow("Account", value = it) }
                        account.expires?.let { FormDivider(); FormRow("Plan ends", value = mediumDate(it)) }
                    }
                }
            }

            if (settings.isDebridConfigured) FormSection("Second Debrid Service",
                "Optional. Torrentio is asked through both, and releases only the second has cached are added to the list. Useful when one service lacks a title the other has.") {
                PickerRow("Second service", settings.secondaryService, DebridService.entries.filter { it != settings.debridService }, { it.title.tr() }) { settings.secondaryService = it }
                if (settings.secondaryService != DebridService.NONE) {
                    TextRow(secondDraft, { secondDraft = it }, "API key", secret = true)
                    FormRow("Save and Test", titleColor = Theme.accent, onClick = if (secondDraft.isBlank() || secondTest == TestState.Testing) null else ({
                        settings.secondaryKey = secondDraft.trim()
                        val config = settings.secondaryTorrentio
                        if (config == null) secondTest = TestState.Failed("Enter a key first.".tr()) else {
                            secondTest = TestState.Testing
                            scope.launch { DebridCheck.run(config).onSuccess { secondTest = TestState.Ok(it.summary.tr()) }.onFailure { secondTest = TestState.Failed(it.readable()) } }
                        }
                    })) { TestStatus(secondTest) }
                }
            }

            FormSection("Sources", "With automatic play off, Play shows every source so you can pick. Pick rules decide which releases are listed and which Play chooses. Addons such as Comet or MediaFusion add their results to Torrentio's. Getting streams ready resolves the likely pick when you open a title, so Play starts at once; it adds that release to your debrid account before you press Play.") {
                ToggleRow("Play the best source automatically", settings.autoPlayBest) { settings.autoPlayBest = it }
                FormDivider()
                FormRow("Pick rules", value = pickRulesSummary(settings), chevron = true, onClick = { router.push(Route.Settings(SettingsPage.PICK_RULES)) })
                FormDivider()
                FormRow("Stremio addons", value = if (settings.addons.isEmpty()) "None".tr() else "%d on".tr(settings.addons.count { it.enabled }), chevron = true,
                    onClick = { router.push(Route.Settings(SettingsPage.ADDONS)) })
                FormDivider()
                ToggleRow("Get streams ready on title pages", settings.prepareAhead) { settings.prepareAhead = it }
            }

            FormSection("Playback", "%s remembers which releases played and which failed, and uses that when it picks a source for you. Skip Intro appears where you skipped the intro in an earlier episode. Each series also remembers its audio and subtitle language, subtitle timing, fill and speed.".tr(AppConfig.NAME)) {
                ToggleRow("Play next episode automatically", settings.autoPlayNext) { settings.autoPlayNext = it }
                FormDivider()
                ToggleRow("Show Skip Intro and Skip Credits", settings.showSkipButtons) { settings.showSkipButtons = it }
                FormDivider()
                ToggleRow("Skip intros automatically", settings.autoSkipIntro) { settings.autoSkipIntro = it }
                FormDivider()
                ToggleRow("Skip recaps automatically", settings.autoSkipRecap) { settings.autoSkipRecap = it }
                FormDivider()
                FormRow("Forget player choices", titleColor = Theme.accent, onClick = { ViewingPreferences.forgetAll() })
                FormDivider()
                FormRow("Forget source history", titleColor = Theme.problem, onClick = { confirmForget = true })
            }

            FormSection("Sync and Services", "Trakt keeps your watchlist, resume points and watched episodes in step with other apps and devices, and records what you watch here.") {
                FormRow("Trakt", value = (if (trakt.isConnected) "Connected" else "Not connected").tr(), chevron = true, onClick = { router.push(Route.Settings(SettingsPage.TRAKT)) }) {
                    if (trakt.syncError != null) { Spacer(Modifier.width(6.dp)); AttentionDot(7.dp) }
                }
                FormDivider()
                FormRow("TMDB", value = (if (TMDB.isConfigured) "On" else "Off").tr(), chevron = true, onClick = { router.push(Route.Settings(SettingsPage.TMDB)) })
            }

            FormSection("Player", "The audio language is chosen as the stream opens, so the right track starts straight away. Missing subtitles come from OpenSubtitles. Night mode narrows the gap between whispers and explosions; the dialogue boost raises speech; lifting quiet films evens out releases mixed low.") {
                PickerRow("Audio language", settings.preferredAudioLanguage, Languages.options.map { it.first }, { code -> Languages.options.first { it.first == code }.second.tr() }) { settings.preferredAudioLanguage = it }
                FormDivider()
                ToggleRow("Turn on subtitles automatically", settings.autoplaySubtitles) { settings.autoplaySubtitles = it }
                FormDivider()
                PickerRow("Subtitle language", settings.preferredSubtitleLanguage, Languages.options.map { it.first }.filter { it.isNotEmpty() },
                    { code -> Languages.options.firstOrNull { it.first == code }?.second ?: code }) { settings.preferredSubtitleLanguage = it }
                FormDivider()
                ToggleRow("Find subtitles online when missing", settings.searchOnlineSubtitles) { settings.searchOnlineSubtitles = it }
                FormDivider()
                ToggleRow("Night mode", settings.nightMode) { settings.nightMode = it }
                FormDivider()
                PickerRow("Dialogue boost", settings.dialogueBoostDB, listOf(0.0, 3.0, 6.0, 9.0, 12.0), { if (it == 0.0) "Off".tr() else "+${it.toInt()} dB" }) { settings.dialogueBoostDB = it }
                FormDivider()
                ToggleRow("Lift quiet films", settings.liftQuietSources) { settings.liftQuietSources = it }
            }

            FormSection("Subtitle Appearance") {
                SliderRow("Size", "${(settings.subtitleScale * 100).toInt()}%", settings.subtitleScale.toFloat(), 0.7f..1.6f, 8) { settings.subtitleScale = Math.round(it * 10) / 10.0 }
                FormDivider()
                PickerRow("Style", settings.subtitleStyle, SubtitleStyle.entries.toList(), { it.title.tr() }) { settings.subtitleStyle = it }
                FormDivider()
                PickerRow("Colour", settings.subtitleColor, SubtitleColor.entries.toList(), { it.title.tr() }) { settings.subtitleColor = it }
                if (settings.subtitleStyle == SubtitleStyle.BOX) {
                    FormDivider()
                    SliderRow("Box", "${(settings.subtitleBoxOpacity * 100).toInt()}%", settings.subtitleBoxOpacity.toFloat(), 0.3f..1f, 13) { settings.subtitleBoxOpacity = Math.round(it * 20) / 20.0 }
                }
                FormDivider()
                SliderRow("Height", if (settings.subtitleLift == 0.0) "Default".tr() else "+${settings.subtitleLift.toInt()} pt", settings.subtitleLift.toFloat(), 0f..120f, 11) {
                    settings.subtitleLift = (Math.round(it / 10) * 10).toDouble()
                }
                FormDivider()
                ToggleRow("Follow the system text size", settings.subtitleFollowsTextSize) { settings.subtitleFollowsTextSize = it }
                SubtitlePreview(settings)
            }

            FormSection("Downloads and Notifications", "New episodes of the series you follow are checked in the background a few times a day.") {
                FormRow("Offline copies", value = (if (settings.downloadsOverCellular) "Wi-Fi and mobile data" else "Wi-Fi only").tr(), chevron = true,
                    onClick = { router.push(Route.Settings(SettingsPage.OFFLINE)) })
                FormDivider()
                ToggleRow("Tell me about new episodes", settings.notifyNewEpisodes) {
                    settings.notifyNewEpisodes = it
                    if (it) askToNotify() else Notifier.cancelEpisodes(context)
                }
                FormDivider()
                ToggleRow("Tell me when a download finishes", settings.notifyDownloads) { settings.notifyDownloads = it; if (it) askToNotify() }
            }

            FormSection("Customise") {
                FormRow("Appearance", value = settings.accent.title.tr(), chevron = true, onClick = { router.push(Route.Settings(SettingsPage.APPEARANCE)) }) {
                    Box(Modifier.padding(start = 6.dp).size(12.dp).clip(CircleShape).background(Color(settings.accent.argb)))
                }
                FormDivider()
                FormRow("Home Screen", value = "%d sections".tr(settings.visibleHomeSections.size), chevron = true, onClick = { router.push(Route.Settings(SettingsPage.HOME_SCREEN)) })
                FormDivider()
                FormRow("Back Up and Restore", icon = Icons.Rounded.Backup, chevron = true, onClick = { router.push(Route.Settings(SettingsPage.BACKUP)) })
            }

            FormSection("About") {
                FormRow("Version", value = AppConfig.version)
                Text("Catalogue by Cinemeta. Sources by Torrentio and the addons you add. Subtitles by OpenSubtitles. Sync by Trakt. Playback by Media3 (Apache 2.0) and FFmpeg (LGPL). %s hosts no content.".tr(AppConfig.NAME),
                    fontSize = 12.sp, color = Theme.secondaryText, modifier = Modifier.padding(16.dp))
            }
        }
    }
    if (confirmForget) AlertDialog(onDismissRequest = { confirmForget = false }, title = { Text("Forget which sources played well and which failed?".tr()) },
        confirmButton = { TextButton({ stores.memory.forgetAll(); confirmForget = false }) { Text("Forget".tr(), color = Theme.problem) } },
        dismissButton = { TextButton({ confirmForget = false }) { Text("Cancel".tr()) } })
}

private fun pickRulesSummary(settings: community.reel.core.AppSettings): String {
    val parts = mutableListOf<String>()
    if (settings.cachedOnly) parts += "Instant".tr()
    if (settings.maxSizeGB > 0) parts += "≤ ${settings.maxSizeGB} GB"
    if (settings.excludedQualities.isNotEmpty()) parts += "%d hidden".tr(settings.excludedQualities.size)
    return if (parts.isEmpty()) "None".tr() else parts.joinToString(", ")
}

/** What subtitles will look like, over a picture-like gradient. */
@Composable
fun SubtitlePreview(settings: community.reel.core.AppSettings) {
    Box(Modifier.fillMaxWidth().padding(8.dp).height(130.dp).clip(RoundedCornerShape(12.dp))
        .background(Brush.linearGradient(listOf(Color(0.95f, 0.8f, 0.55f), Color(0.2f, 0.25f, 0.4f)))), contentAlignment = Alignment.BottomCenter) {
        val text = "The quick brown fox\njumps over the lazy dog".tr()
        val color = Color(settings.subtitleColor.argb)
        val size = (17 * settings.subtitleScale).sp
        val shadow = when (settings.subtitleStyle) {
            SubtitleStyle.OUTLINE -> androidx.compose.ui.graphics.Shadow(Color.Black, blurRadius = 4f)
            SubtitleStyle.SHADOW -> androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.85f), androidx.compose.ui.geometry.Offset(3f, 4f), 6f)
            SubtitleStyle.BOX -> null
        }
        Text(text, color = color, fontSize = size, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodyLarge.copy(shadow = shadow),
            modifier = Modifier.padding(bottom = 14.dp).let {
                if (settings.subtitleStyle == SubtitleStyle.BOX) it.clip(RoundedCornerShape(6.dp)).background(Color.Black.copy(alpha = settings.subtitleBoxOpacity.toFloat())).padding(horizontal = 8.dp, vertical = 3.dp) else it
            })
    }
}
