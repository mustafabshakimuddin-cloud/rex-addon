package community.reel.app.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Extension
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.core.AppConfig
import community.reel.core.DebridCheck
import community.reel.core.DebridService
import community.reel.core.Languages
import community.reel.core.readable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class SetupStep { WELCOME, DEBRID, ADDONS, PLAYBACK, SYNC, DONE }

/**
 * First-run setup, also reachable from Settings. One question per page; every step but the first can
 * be skipped, and the last page lists what is set and what isn't, each with a way back to it.
 */
@Composable
fun SetupScreen() {
    val stores = Env.stores
    val router = Env.router
    val context = LocalContext.current
    val settings = stores.settings.observe()
    val trakt = stores.trakt.observe()
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(SetupStep.WELCOME) }
    var keyDraft by remember { mutableStateOf(settings.debridKey) }
    var test by remember { mutableStateOf<TestState>(TestState.Idle) }
    var subPage by remember { mutableStateOf<SettingsPage?>(null) }

    fun saveKey() { val key = keyDraft.trim(); if (key != settings.debridKey) settings.debridKey = key }
    fun finish() { saveKey(); settings.setupFinished = true; router.showingSetup = false }
    fun go(target: SetupStep) { step = target }

    BackHandler {
        when {
            subPage != null -> subPage = null
            step > SetupStep.WELCOME && step < SetupStep.DONE -> go(SetupStep.entries[step.ordinal - 1])
            else -> finish()
        }
    }

    subPage?.let { page ->
        CompositionLocalProvider(LocalBack provides { subPage = null }) { SettingsPageScreen(page) }
        return
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            if (step > SetupStep.WELCOME && step < SetupStep.DONE) RoundIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back") { go(SetupStep.entries[step.ordinal - 1]) }
            Spacer(Modifier.weight(1f))
            if (step != SetupStep.WELCOME && step != SetupStep.DONE) ProgressDots(step)
            Spacer(Modifier.weight(1f))
            RoundIconButton(Icons.Rounded.Close, "Close setup") { finish() }
        }
        AnimatedContent(step, Modifier.weight(1f), transitionSpec = {
            (slideInHorizontally { it } + fadeIn()) togetherWith (slideOutHorizontally { -it } + fadeOut())
        }, label = "setup") { current ->
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
                Column(Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(horizontal = 24.dp, vertical = 28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    when (current) {
                        SetupStep.WELCOME -> {
                            Header("Welcome to %s".tr(AppConfig.NAME), Icons.Rounded.PlayCircle,
                                "Browse films and series, and stream them through your own debrid service or Stremio addons. A few questions and you're watching.")
                            Card {
                                Bullet(Icons.Rounded.Search, "Explore what's popular, new and top rated")
                                Bullet(Icons.Rounded.Bolt, "Play the best instant source in one tap")
                                Bullet(Icons.Rounded.CalendarMonth, "Follow series and see new episodes on Calendar")
                                Bullet(Icons.Rounded.Sync, "Pick up where you left off, in step with Trakt")
                            }
                        }
                        SetupStep.DEBRID -> {
                            Header("How should titles play?", Icons.Rounded.Key,
                                "A debrid service fetches releases for you and streams them over HTTPS. Torrentio needs one to give playable links.")
                            FormSection {
                                PickerRow("Service", settings.debridService, DebridService.entries.toList(),
                                    { if (it == DebridService.NONE) "Choose a service".tr() else it.title }) { settings.debridService = it; test = TestState.Idle }
                                if (settings.debridService != DebridService.NONE) {
                                    TextRow(keyDraft, { keyDraft = it }, "API key", secret = true)
                                    FormRow("Test Key", titleColor = Theme.accent, onClick = if (keyDraft.isBlank() || test == TestState.Testing) null else ({
                                        saveKey()
                                        test = TestState.Testing
                                        scope.launch {
                                            DebridCheck.run(settings.torrentio).onSuccess { test = TestState.Ok(it.summary.tr()); settings.debridAccount = it.account }
                                                .onFailure { test = TestState.Failed(it.readable()) }
                                        }
                                    })) { TestStatus(test) }
                                    settings.debridService.keyPage?.let { page ->
                                        FormDivider()
                                        FormRow("Get your %s API key".tr(settings.debridService.title), icon = Icons.AutoMirrored.Rounded.OpenInNew, titleColor = Theme.accent,
                                            onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(page))) })
                                    }
                                }
                            }
                            Note("No debrid service? Skip this and add a Stremio addon that gives direct links on the next page.")
                        }
                        SetupStep.ADDONS -> {
                            Header("More sources", Icons.Rounded.Extension,
                                "Stremio addons such as Comet or MediaFusion add their results to Torrentio's, so a title still plays when one of them is down.")
                            LinkCard(if (settings.addons.isEmpty()) "Add an Addon" else "Addons", Icons.Rounded.AddCircle,
                                if (settings.addons.isEmpty()) "None".tr() else "%d on".tr(settings.addons.count { it.enabled })) { subPage = SettingsPage.ADDONS }
                            Note("Optional. You can add addons any time under Settings → Stremio addons.")
                        }
                        SetupStep.PLAYBACK -> {
                            Header("Your preferences", Icons.Rounded.Tune,
                                "How Play chooses, and which audio and subtitles start with a title. All of this can change later in Settings.")
                            FormSection {
                                ToggleRow("Play the best source automatically", settings.autoPlayBest) { settings.autoPlayBest = it }
                                FormDivider()
                                ToggleRow("Instant sources only", settings.cachedOnly) { settings.cachedOnly = it }
                                FormDivider()
                                PickerRow("Audio language", settings.preferredAudioLanguage, Languages.options.map { it.first },
                                    { code -> Languages.options.first { it.first == code }.second.tr() }) { settings.preferredAudioLanguage = it }
                                FormDivider()
                                ToggleRow("Turn on subtitles automatically", settings.autoplaySubtitles) { settings.autoplaySubtitles = it }
                                if (settings.autoplaySubtitles) {
                                    FormDivider()
                                    PickerRow("Subtitle language", settings.preferredSubtitleLanguage, Languages.options.map { it.first }.filter { it.isNotEmpty() },
                                        { code -> Languages.options.firstOrNull { it.first == code }?.second ?: code }) { settings.preferredSubtitleLanguage = it }
                                }
                            }
                            Note(if (settings.autoPlayBest) "Play starts the best instant release straight away; the Sources button still lists them all."
                                 else "Play shows every release so you pick the quality and size yourself.")
                        }
                        SetupStep.SYNC -> {
                            Header("Keep in sync", Icons.Rounded.Sync,
                                "Connect Trakt to keep My List, resume points and watched episodes in step with your other apps and devices.")
                            LinkCard(if (trakt.isConnected) "Trakt connected" else "Connect Trakt", if (trakt.isConnected) Icons.Rounded.CheckCircle else Icons.Rounded.Link, null) {
                                subPage = SettingsPage.TRAKT
                            }
                            Note("Optional. Trakt needs a free API app of your own; the Trakt page explains how.")
                        }
                        SetupStep.DONE -> {
                            val ready = settings.canFindSources
                            Header(if (ready) "You're ready" else "Almost there", if (ready) Icons.Rounded.Verified else Icons.Rounded.Warning,
                                if (ready) "Here's what is set up. Anything marked Not set can be added later." else "Nothing can play until a debrid service or an addon is added. You can still browse.")
                            FormSection {
                                SummaryRow("Debrid service", if (settings.isDebridConfigured) settings.debridService.title else null) { go(SetupStep.DEBRID) }
                                FormDivider()
                                SummaryRow("Stremio addons", if (settings.addons.isEmpty()) null else "%d on".tr(settings.addons.count { it.enabled })) { go(SetupStep.ADDONS) }
                                FormDivider()
                                SummaryRow("Play", (if (settings.autoPlayBest) "Best source automatically" else "Choose from the list").tr()) { go(SetupStep.PLAYBACK) }
                                FormDivider()
                                SummaryRow("Trakt", if (trakt.isConnected) "Connected".tr() else null) { go(SetupStep.SYNC) }
                            }
                        }
                    }
                }
            }
        }
        // Buttons
        Column(Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 16.dp).align(Alignment.CenterHorizontally),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            when (step) {
                SetupStep.WELCOME -> PillButton("Get Started".tr(), prominent = true, modifier = Modifier.fillMaxWidth()) { go(SetupStep.DEBRID) }
                SetupStep.DONE -> {
                    PillButton("Start Watching".tr(), prominent = true, modifier = Modifier.fillMaxWidth()) { finish() }
                    TextButton({ finish(); scope.launch { delay(300); router.openSettings(SettingsPage.STATUS) } }) { Text("Check Status".tr()) }
                }
                SetupStep.DEBRID -> PillButton((if (settings.isDebridConfigured || keyDraft.isNotEmpty()) "Continue" else "Continue without one").tr(), prominent = true,
                    modifier = Modifier.fillMaxWidth()) { saveKey(); go(SetupStep.ADDONS) }
                else -> {
                    PillButton("Continue".tr(), prominent = true, modifier = Modifier.fillMaxWidth()) { go(SetupStep.entries[step.ordinal + 1]) }
                    if (step == SetupStep.ADDONS || step == SetupStep.SYNC) TextButton({ go(SetupStep.entries[step.ordinal + 1]) }) { Text("Skip for Now".tr(), color = Theme.secondaryText) }
                }
            }
        }
    }
}

@Composable
private fun ProgressDots(step: SetupStep) {
    val steps = SetupStep.entries.filter { it != SetupStep.WELCOME && it != SetupStep.DONE }
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        for (item in steps) {
            val width by animateDpAsState(if (item == step) 22.dp else 8.dp, label = "dot")
            Box(Modifier.width(width).height(8.dp).clip(CircleShape).background(if (item <= step) Theme.accent else Color.White.copy(alpha = 0.2f)))
        }
    }
}

@Composable
private fun Header(title: String, icon: ImageVector, text: String) {
    Column(Modifier.padding(bottom = 22.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(64.dp).glass(RoundedCornerShape(18.dp), Theme.accent), contentAlignment = Alignment.Center) { Icon(icon, null, Modifier.size(34.dp), tint = Theme.accent) }
        Text(title.tr(), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        Text(text.tr(), style = MaterialTheme.typography.bodyLarge, color = Theme.secondaryText)
    }
}

@Composable
private fun Card(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(22.dp)).padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) { content() }
}

@Composable
private fun Bullet(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(22.dp), tint = Theme.accent); Spacer(Modifier.width(12.dp)); Text(text.tr())
    }
}

@Composable
private fun Note(text: String) = Text(text.tr(), fontSize = 13.sp, color = Theme.secondaryText)

@Composable
private fun LinkCard(title: String, icon: ImageVector, value: String?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).focusCard(RoundedCornerShape(18.dp), onClick).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Theme.accent); Spacer(Modifier.width(10.dp))
        Text(title.tr(), Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
        value?.let { Text(it, color = Theme.secondaryText) }
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Theme.secondaryText)
    }
}

@Composable
private fun SummaryRow(title: String, value: String?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().focusCard(RoundedCornerShape(0.dp), onClick).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(if (value == null) Icons.Rounded.RadioButtonUnchecked else Icons.Rounded.CheckCircle, null, tint = if (value == null) Theme.secondaryText else Theme.cached)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title.tr(), fontWeight = FontWeight.SemiBold)
            Text(value ?: "Not set".tr(), fontSize = 12.sp, color = Theme.secondaryText)
        }
        Text((if (value == null) "Set Up" else "Change").tr(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Theme.accent)
    }
}

