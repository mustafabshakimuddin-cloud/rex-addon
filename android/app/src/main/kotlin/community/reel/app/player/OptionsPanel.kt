package community.reel.app.player

import android.view.Display
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.RecordVoiceOver
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.VolumeUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.app.ui.Env
import community.reel.app.ui.PillButton
import community.reel.app.ui.RoundIconButton
import community.reel.app.ui.Theme
import community.reel.app.ui.focusCard
import community.reel.app.ui.glass
import community.reel.app.ui.observe
import community.reel.app.ui.tr
import community.reel.core.Languages
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Audio, subtitles, speed and playback info in one panel: a side panel on wide windows, a bottom
 * card on narrow ones.
 */
@Composable
fun OptionsPanel(model: PlayerController, initial: OptionsTab, wide: Boolean, searchOnline: () -> Unit, close: () -> Unit) {
    var tab by remember { mutableStateOf(initial) }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)).focusCard(RoundedCornerShape(0.dp), close), contentAlignment = if (wide) Alignment.CenterEnd else Alignment.BottomCenter) {
        Column(Modifier.statusBarsPadding().navigationBarsPadding().padding(if (wide) 16.dp else 10.dp)
            .let { if (wide) it.widthIn(max = 400.dp).fillMaxSize() else it.fillMaxWidth().heightIn(max = 460.dp) }
            .glass(RoundedCornerShape(30.dp)).focusCard(RoundedCornerShape(30.dp), {}).padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                    OptionsTab.entries.forEachIndexed { index, value ->
                        SegmentedButton(tab == value, { tab = value }, SegmentedButtonDefaults.itemShape(index, OptionsTab.entries.size)) { Text(value.title.tr(), fontSize = 12.sp, maxLines = 1) }
                    }
                }
                Spacer(Modifier.width(8.dp))
                RoundIconButton(Icons.Rounded.Close, "Close", onClick = close)
            }
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                when (tab) {
                    OptionsTab.AUDIO -> AudioList(model)
                    OptionsTab.SUBTITLES -> SubtitleList(model, searchOnline)
                    OptionsTab.SPEED -> SpeedList(model)
                    OptionsTab.INFO -> PlaybackInfo(model)
                }
            }
            when (tab) {
                OptionsTab.AUDIO -> Footnote("Changing track reopens the stream for a moment. Night mode and the dialogue and loudness lifts shape the decoded sound, so while one is on, passthrough to a receiver is off.")
                OptionsTab.INFO -> Footnote("Updates every second. HDR is easiest to judge in a bright scene, such as daylight or a lamp in shot.")
                else -> {}
            }
        }
    }
}

@Composable
private fun Footnote(text: String) = Text(text.tr(), fontSize = 11.sp, color = Color.White.copy(alpha = 0.6f))

@Composable
private fun OptionRow(selected: Boolean, title: String, detail: String? = null, tags: List<String> = emptyList(), onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(if (selected) Color.White.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.04f))
        .focusCard(RoundedCornerShape(16.dp), onClick).padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(if (selected) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked, null, tint = if (selected) Theme.accent else Color.White.copy(alpha = 0.35f))
        Spacer(Modifier.width(12.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title.tr(), fontWeight = FontWeight.SemiBold, maxLines = 2)
            detail?.takeIf { it.isNotEmpty() }?.let { Text(it, fontSize = 12.sp, color = Color.White.copy(alpha = 0.62f), maxLines = 2) }
            if (tags.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                tags.forEach { PlayerChip(it, highlighted = it == "Dolby Atmos" || it == "Surround") }
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) = Text(text.tr(), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.5f), modifier = Modifier.padding(top = 10.dp))

@Composable
private fun AudioList(model: PlayerController) {
    val settings = Env.stores.settings.observe()
    // Night mode and the dialogue lift: for a quiet room, or speech lost under the music.
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.04f)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ToggleLine(Icons.Rounded.DarkMode, "Night mode", settings.nightMode) { settings.nightMode = it }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.RecordVoiceOver, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
            Text("Dialogue".tr(), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            RoundIconButton(Icons.Rounded.Remove, "Less dialogue boost") { settings.dialogueBoostDB = maxOf(0.0, settings.dialogueBoostDB - 3) }
            Text(if (settings.dialogueBoostDB == 0.0) "Off".tr() else "+${settings.dialogueBoostDB.toInt()} dB", fontWeight = FontWeight.Bold, modifier = Modifier.widthIn(min = 54.dp).padding(horizontal = 6.dp))
            RoundIconButton(Icons.Rounded.Add, "More dialogue boost") { settings.dialogueBoostDB = minOf(12.0, settings.dialogueBoostDB + 3) }
        }
        ToggleLine(Icons.Rounded.VolumeUp, "Lift quiet films", settings.liftQuietSources) { settings.liftQuietSources = it }
        if (!model.shapingAvailable) Text("Not available on this audio route; it applies to the next stream that can carry it.".tr(), fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
    }
    if (model.audioTracks.isEmpty()) Text("No audio tracks reported yet.".tr(), color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(16.dp))
    for (track in model.audioTracks) {
        OptionRow(track.id == model.activeAudio, TrackLabel.title(track), TrackLabel.audioDetail(track), TrackLabel.audioTags(track)) { model.selectAudio(track) }
    }
}

@Composable
private fun ToggleLine(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.focusCard(RoundedCornerShape(10.dp), { onChange(!value) })) {
        Icon(icon, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
        Text(title.tr(), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        Switch(value, onChange, colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent))
    }
}

@Composable
private fun SubtitleList(model: PlayerController, searchOnline: () -> Unit) {
    if (model.activeSubtitle != null) {
        // Nudges the subtitles against the picture when a file's timing is off.
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.04f)).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            RoundIconButton(Icons.Rounded.Remove, "Show subtitles earlier") { model.changeSubtitleDelay(model.subtitleDelay - 0.25) }
            Column(Modifier.weight(1f).focusCard(RoundedCornerShape(10.dp), { model.changeSubtitleDelay(0.0) }), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Timing".tr(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.62f))
                Text(if (model.subtitleDelay == 0.0) "In sync".tr() else "%+.2f s".format(model.subtitleDelay), fontWeight = FontWeight.Bold)
            }
            RoundIconButton(Icons.Rounded.Add, "Show subtitles later") { model.changeSubtitleDelay(model.subtitleDelay + 0.25) }
        }
    }
    OptionRow(model.activeSubtitle == null, "Off") { model.selectSubtitle(null) }
    for (track in model.subtitleTracks) {
        OptionRow(track.id == model.activeSubtitle, TrackLabel.title(track), TrackLabel.subtitleDetail(track), if (track.isForced) listOf("Forced") else emptyList()) {
            model.selectSubtitle(track)
        }
    }
    val added = model.subtitleTracks.filter { it.isExternal }.map { it.name }.toSet()
    Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("ONLINE".tr(), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.5f), modifier = Modifier.weight(1f))
        if (model.searchingSubtitles) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.White)
        else if (model.onlineSubtitles.isEmpty()) PillButton("Search OpenSubtitles".tr(), Icons.Rounded.Search, onClick = searchOnline)
    }
    // A handful per language is plenty; files of one release rarely differ.
    val grouped = model.onlineSubtitles.groupBy { it.language }
    for (language in grouped.keys.sortedBy { Languages.name(it) }) {
        grouped.getValue(language).take(3).forEachIndexed { index, result ->
            val title = if (index == 0) Languages.name(language) else "${Languages.name(language)} ${index + 1}"
            val name = "$title · OpenSubtitles"
            OptionRow(false, title, "OpenSubtitles", if (name in added) listOf("Added") else emptyList()) { model.addOnlineSubtitle(result, name) }
        }
    }
}

@Composable
private fun SpeedList(model: PlayerController) {
    var timerMinutes by remember { mutableStateOf<Int?>(null) }
    for (value in listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f)) {
        OptionRow(kotlin.math.abs(model.rate - value) < 0.01f, if (value == 1f) "Normal" else "${if (value % 1f == 0f) value.toInt().toString() else value.toString()}×") { model.changeRate(value) }
    }
    SectionLabel("SLEEP TIMER")
    OptionRow(model.sleepTimer == null, "Off") { model.sleepTimer = null }
    val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())
    for (minutes in listOf(15, 30, 45, 60, 90)) {
        val timer = model.sleepTimer
        val on = timer is SleepTimer.At && timerMinutes == minutes
        OptionRow(on, "%d minutes".tr(minutes), if (on && timer is SleepTimer.At) "Pauses at %s".tr(time.format(timer.time)) else null) {
            model.sleepTimer = SleepTimer.At(Instant.now().plusSeconds(minutes * 60L))
            timerMinutes = minutes
        }
    }
    OptionRow(model.sleepTimer == SleepTimer.EndOfEpisode, "At the end of this one") { model.sleepTimer = SleepTimer.EndOfEpisode }
}

/** What is actually reaching the screen, read once a second. */
@Composable
private fun PlaybackInfo(model: PlayerController) {
    val context = LocalContext.current
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(1000); tick++ } }
    tick
    val display = (context.getSystemService(android.hardware.display.DisplayManager::class.java))?.getDisplay(Display.DEFAULT_DISPLAY)
    @Suppress("DEPRECATION") val hdrTypes = display?.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)
    val stats = model.stats
    val video = stats.video
    val audio = stats.audio
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val verdict = when {
            model.videoFormat == VideoFormat.SDR -> "Playing in SDR."
            hdrTypes.isEmpty() -> "This is an HDR file, but this screen shows it as SDR."
            else -> "%s is reaching the screen.".tr(model.videoFormat.label ?: "")
        }
        Text(verdict.tr(), fontWeight = FontWeight.SemiBold)
        InfoSection("Display") {
            InfoLine("Can show HDR", if (hdrTypes.isNotEmpty()) "Yes" else "No")
            InfoLine("Dolby Vision", if (Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in hdrTypes) "Yes" else "No")
            InfoLine("HDR10+", if (android.os.Build.VERSION.SDK_INT >= 29 && Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS in hdrTypes) "Yes" else "No")
        }
        InfoSection("Video") {
            InfoLine("Format", model.videoFormat.label ?: "SDR")
            video?.let { format ->
                InfoLine("Codec", PlayerController.codecOf(format).uppercase())
                format.codecs?.let { InfoLine("Profile", it) }
                if (format.width > 0) InfoLine("Resolution", "${format.width} × ${format.height}")
                if (format.frameRate > 0) InfoLine("Frame rate", "%.3f".format(format.frameRate).trimEnd('0').trimEnd('.'))
            }
            InfoLine("Dropped frames", "${stats.droppedFrames}")
        }
        InfoSection("Audio") {
            audio?.let { format ->
                InfoLine("Codec", TrackLabel.codecName(PlayerController.codecOf(format)))
                TrackLabel.channels(format.channelCount)?.let { InfoLine("Channels", it) }
                if (format.sampleRate > 0) InfoLine("Sample rate", "${format.sampleRate / 1000.0} kHz")
            }
        }
        InfoSection("Stream") {
            if (stats.bitrate > 0) InfoLine("Bandwidth", "%.1f Mb/s".format(stats.bitrate / 1_000_000.0))
            InfoLine("Buffered ahead", "%.0f s".format(stats.bufferedAhead))
            InfoLine("Rebuffers", "${model.stallCount}")
        }
    }
}

@Composable
private fun InfoSection(title: String, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Color.White.copy(alpha = 0.04f)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title.tr().uppercase(), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.5f))
        content()
    }
}

@Composable
private fun InfoLine(label: String, value: String) {
    Row {
        Text(label.tr(), fontSize = 13.sp, color = Color.White.copy(alpha = 0.7f), modifier = Modifier.weight(1f))
        Text(value.tr(), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Human labels for tracks. */
object TrackLabel {
    fun title(track: TrackInfo): String {
        val language = track.language?.let(::languageName)
        val name = track.name.trim()
        if (name.isNotEmpty() && language != null && !name.contains(language, ignoreCase = true)) return "$language · $name"
        if (name.isNotEmpty()) return name
        return language ?: "Track %s".tr(track.id)
    }

    fun audioDetail(track: TrackInfo) = (listOf(codecName(track.codec)) + listOfNotNull(channels(track.channels),
        if (track.isCommentary) "Commentary".tr() else null)).joinToString(" · ")

    fun subtitleDetail(track: TrackInfo) = (listOf(codecName(track.codec)) + listOfNotNull(if (track.isHearingImpaired) "SDH" else null,
        if (track.isExternal) "External".tr() else null)).joinToString(" · ")

    fun audioTags(track: TrackInfo) = listOfNotNull(if (track.isAtmos) "Dolby Atmos" else null, if (track.isAtmos || track.channels > 2) "Surround" else null,
        if (track.isDefault) "Default" else null)

    fun channels(count: Int): String? = when {
        count < 1 -> null
        count == 1 -> "Mono".tr()
        count == 2 -> "Stereo".tr()
        count == 6 -> "5.1"
        count == 8 -> "7.1"
        else -> "%d channels".tr(count)
    }

    fun codecName(codec: String) = when (codec.lowercase()) {
        "eac3" -> "Dolby Digital Plus"
        "ac3" -> "Dolby Digital"
        "truehd" -> "Dolby TrueHD"
        "dts" -> "DTS"
        "aac" -> "AAC"
        "flac" -> "FLAC"
        "opus" -> "Opus"
        "mp3" -> "MP3"
        "subrip", "srt" -> "SRT"
        "ass", "ssa" -> "ASS"
        "webvtt" -> "WebVTT"
        "mov_text" -> "Text"
        "hdmv_pgs_subtitle" -> "PGS"
        "dvd_subtitle" -> "VobSub"
        "dvb_subtitle" -> "DVB"
        else -> codec.uppercase()
    }

    private fun languageName(code: String): String? {
        val trimmed = code.trim()
        if (trimmed.isEmpty() || trimmed.lowercase() == "und") return null
        return Languages.name(trimmed)
    }
}
