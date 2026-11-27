package community.reel.app.player

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.os.Build
import android.util.Rational
import android.view.ViewGroup
import android.view.WindowManager
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.List
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.FastForward
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.Fullscreen
import androidx.compose.material.icons.rounded.FullscreenExit
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PictureInPictureAlt
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Subtitles
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import community.reel.app.ui.Env
import community.reel.app.ui.FocusRing
import community.reel.app.ui.LocalTelevision
import community.reel.app.ui.PillButton
import community.reel.app.ui.RemoteImage
import community.reel.app.ui.RoundIconButton
import community.reel.app.ui.Theme
import community.reel.app.ui.focusCard
import community.reel.app.ui.glass
import community.reel.app.ui.observe
import community.reel.app.ui.tr
import community.reel.core.Cinemeta
import community.reel.core.Episode
import community.reel.core.Languages
import community.reel.core.PlaybackTarget
import community.reel.core.PlayerSession
import community.reel.core.SubtitleStyle
import community.reel.core.Trakt
import community.reel.core.ViewingChoice
import community.reel.core.ViewingPreferences
import community.reel.core.now
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Whether the activity is in picture-in-picture, set by MainActivity. */
object PipState { var active by mutableStateOf(false) }

fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

fun clock(seconds: Double): String {
    val total = (if (seconds.isFinite()) maxOf(0.0, seconds) else 0.0).toInt()
    val h = total / 3600; val m = (total % 3600) / 60; val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

fun rateLabel(rate: Float): String = if (rate == 1f) "Speed".tr() else if (rate % 1f == 0f) "${rate.toInt()}×" else "$rate×"

enum class OptionsTab(val title: String) { AUDIO("Audio"), SUBTITLES("Subtitles"), SPEED("Speed"), INFO("Info") }

@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(session: PlayerSession) {
    val stores = Env.stores
    val context = LocalContext.current
    val activity = context.findActivity()
    val television = LocalTelevision.current
    val settings = stores.settings.observe()
    val library = stores.library
    val playback = stores.playback.observe()
    val trakt = stores.trakt
    val model = remember(session.id) { PlayerController(context) }
    val scope = rememberCoroutineScope()
    var controlsVisible by remember { mutableStateOf(true) }
    var panel by remember { mutableStateOf<OptionsTab?>(null) }
    var scrubbing by remember { mutableStateOf<Double?>(null) }
    var hideJob by remember { mutableStateOf<Job?>(null) }
    var nextEpisode by remember { mutableStateOf<Episode?>(null) }
    var reportedStart by remember { mutableStateOf(false) }
    var handledFailure by remember { mutableStateOf(false) }
    var reconnecting by remember { mutableStateOf(false) }
    var reconnects by remember { mutableIntStateOf(0) }
    var skipFlash by remember { mutableStateOf<Boolean?>(null) }
    var learnedIntro by remember { mutableStateOf<ViewingChoice?>(null) }
    var preparedNext by remember { mutableStateOf(false) }
    var sentStop by remember { mutableStateOf(false) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    val focus = remember { FocusRequester() }
    val width = with(LocalDensity.current) { size.width.toDp() }

    fun scheduleHide() {
        hideJob?.cancel()
        controlsVisible = true
        hideJob = scope.launch {
            delay(4000)
            if (model.isPlaying && scrubbing == null && panel == null) controlsVisible = false
        }
    }

    /** Trakt hears "stopped" once: Up Next sends it before the player closes. */
    fun scrobble(action: Trakt.ScrobbleAction) {
        if (session.isCloud || sentStop) return
        if (action == Trakt.ScrobbleAction.STOP) sentStop = true
        trakt.scrobble(action, session.target, model.time.currentTime, model.duration)
    }

    fun close() { playback.session = null }

    fun playNext() {
        val next = nextEpisode ?: return
        scrobble(Trakt.ScrobbleAction.STOP)
        library.record(session.target, model.duration, model.duration, live = true)
        playback.playNext(PlaybackTarget(session.target.item, next), session, settings, library)
    }

    fun reconnect() {
        if (reconnecting) return
        reconnecting = true
        reconnects += 1
        val position = model.time.currentTime
        scope.launch {
            try {
                model.reload(playback.reconnect(session, settings), position)
            } catch (e: Exception) {
                // The error card stays, with Retry.
            } finally {
                reconnecting = false
            }
        }
    }

    // Start: the way this film or series was left last time wins over the general settings.
    LaunchedEffect(session.id) {
        val target = session.target
        val choice = ViewingPreferences.choice(target.item.id)
        learnedIntro = choice
        val audio = choice?.audioLanguage?.let { Languages.codes(it) } ?: Languages.codes(settings.preferredAudioLanguage)
        val subtitles = choice?.subtitleLanguage?.let { if (it.isEmpty()) emptyList() else Languages.codes(it) }
            ?: if (settings.autoplaySubtitles) Languages.codes(settings.preferredSubtitleLanguage) else emptyList()
        choice?.let {
            model.fillsScreen = it.fillsScreen
            if (it.subtitleDelay != 0.0) model.changeSubtitleDelay(it.subtitleDelay)
        }
        model.start(session.url, target.item.name, target.episode?.let { "${it.code} · ${it.title}" }, session.startAt, audio, subtitles,
            target.episode?.thumbnail ?: target.item.poster, session.localSubtitles,
            AudioShaper.Settings(settings.nightMode, settings.dialogueBoostDB, settings.liftQuietSources)) { position, duration ->
            if (!session.isCloud) library.record(target, position, duration, live = true)
        }
        scheduleHide()
        runCatching { focus.requestFocus() }
        // The next episode, and its sources looked up now so the switch at the credits is quick.
        val current = target.episode ?: return@LaunchedEffect
        val detail = runCatching { Cinemeta.detail(community.reel.core.MediaKind.SERIES, target.item.id) }.getOrNull() ?: return@LaunchedEffect
        library.learnEpisodes(detail)
        val ordered = detail.episodes.filter { it.season > 0 }.sortedWith(compareBy({ it.season }, { it.number }))
        val index = ordered.indexOfFirst { it.id == current.id }
        val next = ordered.getOrNull(index + 1)?.takeIf { index >= 0 && it.hasAired } ?: return@LaunchedEffect
        nextEpisode = next
        playback.prefetch(PlaybackTarget(target.item, next), settings, immediately = true, prepare = false)
    }

    // The screen stays on while a film plays.
    DisposableEffect(Unit) {
        activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            hideJob?.cancel()
            rememberChoices(model, session, settings)
            scrobble(Trakt.ScrobbleAction.STOP)
            model.stop()
            library.commitLive()
        }
    }

    // Picture in picture when leaving the app while a film plays.
    LaunchedEffect(model.isPlaying, model.videoSize) {
        if (Build.VERSION.SDK_INT >= 31 && activity != null) {
            val (w, h) = model.videoSize ?: (16 to 9)
            runCatching {
                activity.setPictureInPictureParams(PictureInPictureParams.Builder().setAspectRatio(Rational(w, h).coerce()).setAutoEnterEnabled(model.isPlaying).build())
            }
        }
    }

    LaunchedEffect(model.isPlaying) {
        if (model.isPlaying) scheduleHide()
        scrobble(if (model.isPlaying) Trakt.ScrobbleAction.START else Trakt.ScrobbleAction.PAUSE)
    }
    LaunchedEffect(model.state) {
        if (model.state == androidx.media3.common.Player.STATE_ENDED) {
            if (nextEpisode != null && settings.autoPlayNext && !model.stopsAtEnd) playNext() else close()
        }
    }
    LaunchedEffect(model.hasFirstFrame) {
        if (!model.hasFirstFrame || reportedStart) return@LaunchedEffect
        reportedStart = true
        playback.playerStarted(session)
        ViewingPreferences.choice(session.target.item.id)?.rate?.takeIf { it != 1f }?.let { model.changeRate(it) }
        // With subtitles wanted and none in the file in that language, fetch one from OpenSubtitles.
        if (settings.autoplaySubtitles && settings.searchOnlineSubtitles && settings.preferredSubtitleLanguage.isNotEmpty()) {
            delay(1500)
            model.searchOnlineSubtitles(session.target.item.kind, session.target.videoID, session.source.file ?: session.source.release,
                session.source.sizeBytes, Languages.codes(settings.preferredSubtitleLanguage))
        }
    }
    LaunchedEffect(model.errorMessage) {
        val message = model.errorMessage ?: return@LaunchedEffect
        // A stream that played and then failed is opened again from a fresh link at the same place,
        // once, before the error card shows. It is not a mark against the source.
        if (model.hasFirstFrame || reportedStart) { if (reconnects == 0) reconnect(); return@LaunchedEffect }
        // A source that never showed a picture failed to open: move on to the next.
        if (handledFailure) return@LaunchedEffect
        handledFailure = true
        playback.playerFailed(session, message, null, offline = !community.reel.app.system.Network.isOnline(context), settings)
    }
    LaunchedEffect(model.stallCount) { if (model.stallCount > 0) playback.playerStalled(session) }
    LaunchedEffect(settings.nightMode, settings.dialogueBoostDB, settings.liftQuietSources) {
        model.setAudioShaping(AudioShaper.Settings(settings.nightMode, settings.dialogueBoostDB, settings.liftQuietSources))
    }
    // A video paused in the background comes back paused; the controls show again.
    LifecycleResumeEffect(Unit) { controlsVisible = true; scheduleHide(); onPauseOrDispose { if (!PipState.active && !television) model.player.pause() } }
    // The prefetch a minute and a half before Up Next, so the next episode starts at once.
    val upNextStart = if (model.duration > 300) model.duration - 35 else null
    LaunchedEffect(nextEpisode, upNextStart) {
        val next = nextEpisode ?: return@LaunchedEffect
        val at = upNextStart ?: return@LaunchedEffect
        snapshotFlow { model.time.currentTime >= maxOf(0.0, at - 90) }.collect { reached ->
            if (reached && !preparedNext) {
                preparedNext = true
                playback.prefetch(PlaybackTarget(session.target.item, next), settings, immediately = true, prepare = settings.autoPlayNext)
            }
        }
    }

    // The system back gesture: an open panel first, then the player.
    androidx.activity.compose.BackHandler { if (panel != null) panel = null else close() }

    val inPip = PipState.active
    Box(Modifier.fillMaxSize().background(Color.Black).onSizeChanged { size = it }
        .focusRequester(focus).focusable()
        .onPreviewKeyEvent { event ->
            if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
            // A hardware keyboard or a TV remote: space and the remote's centre play and pause,
            // arrows skip, F fills, C turns subtitles on and off, Esc closes.
            val controlsHaveFocus = controlsVisible && television
            when (event.key) {
                Key.Spacebar, Key.MediaPlayPause -> { model.togglePlay(); scheduleHide(); true }
                Key.DirectionCenter, Key.Enter -> if (!controlsVisible) { model.togglePlay(); scheduleHide(); true } else false
                Key.DirectionLeft -> if (!controlsHaveFocus) { model.skip(if (event.isShiftPressed) -60.0 else -10.0); skipFlash = false; true } else { scheduleHide(); false }
                Key.DirectionRight -> if (!controlsHaveFocus) { model.skip(if (event.isShiftPressed) 60.0 else 10.0); skipFlash = true; true } else { scheduleHide(); false }
                Key.DirectionUp, Key.DirectionDown -> { if (!controlsVisible) { scheduleHide(); true } else { scheduleHide(); false } }
                Key.MediaFastForward -> { model.skip(10.0); true }
                Key.MediaRewind -> { model.skip(-10.0); true }
                Key.F -> { model.fillsScreen = !model.fillsScreen; true }
                Key.C -> { toggleSubtitles(model, settings.preferredSubtitleLanguage); true }
                Key.Escape -> { close(); true }
                Key.Back -> if (panel != null) { panel = null; true } else if (controlsVisible && television && model.isPlaying) { controlsVisible = false; true } else { close(); true }
                else -> false
            }
        }) {
        // The picture, with the file's subtitles drawn over it in the reader's style.
        AndroidView(factory = { ctx ->
            PlayerView(ctx).apply {
                useController = false
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                setShutterBackgroundColor(android.graphics.Color.BLACK)
                player = model.player
            }
        }, update = { view ->
            view.resizeMode = if (model.fillsScreen) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
            view.subtitleView?.let { styleSubtitles(it, settings, if (controlsVisible && !inPip) 0.22f else 0.06f) }
        }, modifier = Modifier.fillMaxSize())

        if (!model.hasFirstFrame && model.errorMessage == null) StartupCover(session)

        if (!inPip) {
            // Owns the touches above the video: one tap shows or hides the controls; two taps on the
            // left or right third skip back or ahead 10 s, two in the middle toggle fill; pinching
            // fills or fits; holding plays at double speed until released.
            Box(Modifier.fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { if (panel != null) panel = null else { controlsVisible = !controlsVisible; if (controlsVisible) scheduleHide() } },
                        onDoubleTap = { offset ->
                            val third = offset.x / size.width
                            if (third < 0.33f || third > 0.67f) {
                                val forward = third > 0.67f
                                model.skip(if (forward) 10.0 else -10.0)
                                skipFlash = forward
                            } else model.fillsScreen = !model.fillsScreen
                        },
                        onPress = {
                            val boost = scope.launch { delay(450); model.beginBoost() }
                            tryAwaitRelease()
                            boost.cancel()
                            model.endBoost()
                        },
                    )
                }
                .pointerInput(Unit) {
                    var total = 1f
                    detectTransformGestures { _, _, zoom, _ ->
                        total *= zoom
                        if (total > 1.15f) { model.fillsScreen = true; total = 1f }
                        if (total < 0.87f) { model.fillsScreen = false; total = 1f }
                    }
                })

            skipFlash?.let { forward ->
                LaunchedEffect(forward, model.time.currentTime.toInt() / 10) { delay(600); skipFlash = null }
                Box(Modifier.fillMaxSize().padding(horizontal = 60.dp), contentAlignment = if (forward) Alignment.CenterEnd else Alignment.CenterStart) {
                    Column(Modifier.glass(CircleShape).padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(if (forward) Icons.Rounded.Forward10 else Icons.Rounded.Replay10, null, Modifier.size(34.dp))
                        Text(if (forward) "+10 s" else "−10 s", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            if (model.boosted) TopBadge(Icons.Rounded.FastForward, "2× speed")
            if (model.sleepFired && !model.isPlaying) TopBadge(Icons.Rounded.Bedtime, "Paused by the sleep timer")

            if (model.hasFirstFrame && model.state == androidx.media3.common.Player.STATE_BUFFERING) {
                CircularProgressIndicator(Modifier.align(Alignment.Center).size(48.dp), color = Color.White)
            }

            AnimatedVisibility(controlsVisible || model.errorMessage != null, enter = fadeIn(), exit = fadeOut()) {
                Controls(session, model, width, panelOpen = panel != null, reconnecting = reconnecting,
                    openPanel = { hideJob?.cancel(); panel = it }, close = ::close, retry = ::reconnect,
                    onScrub = { scrubbing = it; hideJob?.cancel() },
                    onCommit = { value ->
                        learnIntro(session, model.time.currentTime, value)
                        model.seek(value)
                        scrubbing = null
                        scheduleHide()
                    }, scrubbing = scrubbing, scheduleHide = ::scheduleHide)
            }

            // Skip Intro and Up Next, bottom right, above the controls.
            Column(Modifier.align(Alignment.BottomEnd).navigationBarsPadding().padding(end = 20.dp, bottom = if (controlsVisible) 170.dp else 40.dp),
                horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val learned = learnedIntro
                val introStart = learned?.introStart
                val introEnd = learned?.introEnd
                if (settings.showSkipButtons && session.target.episode != null && introStart != null && introEnd != null) {
                    val now = model.time.currentTime
                    // Openings drift by a few seconds between episodes; offer it a little early and late.
                    AnimatedVisibility(now >= maxOf(0.0, introStart - 15) && now < introEnd - 5, enter = slideInHorizontally { it } + fadeIn(), exit = slideOutHorizontally { it } + fadeOut()) {
                        PillButton("Skip Intro".tr(), Icons.Rounded.SkipNext) { model.seek(introEnd) }
                    }
                }
                val next = nextEpisode
                if (next != null && upNextStart != null) UpNextCard(model, next, upNextStart, settings.autoPlayNext, ::playNext)
            }

            panel?.let { tab -> OptionsPanel(model, tab, wide = width >= 640.dp, searchOnline = {
                model.searchOnlineSubtitles(session.target.item.kind, session.target.videoID, session.source.file ?: session.source.release, session.source.sizeBytes)
            }) { panel = null; scheduleHide() } }

            playback.fallbackNotice?.let { notice ->
                Row(Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 60.dp).glass(CircleShape).padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                    Spacer(Modifier.width(10.dp))
                    Text(notice, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

private fun Rational.coerce(): Rational {
    // Android allows picture-in-picture between 1:2.39 and 2.39:1.
    val value = toFloat()
    return when {
        value > 2.39f -> Rational(239, 100)
        value < 1 / 2.39f -> Rational(100, 239)
        else -> this
    }
}

@OptIn(UnstableApi::class)
private fun styleSubtitles(view: androidx.media3.ui.SubtitleView, settings: community.reel.core.AppSettings, bottom: Float) {
    val foreground = settings.subtitleColor.argb.toInt()
    val box = (settings.subtitleBoxOpacity * 255).toInt().coerceIn(0, 255) shl 24
    val style = when (settings.subtitleStyle) {
        SubtitleStyle.OUTLINE -> CaptionStyleCompat(foreground, 0, 0, CaptionStyleCompat.EDGE_TYPE_OUTLINE, android.graphics.Color.BLACK, null)
        SubtitleStyle.SHADOW -> CaptionStyleCompat(foreground, 0, 0, CaptionStyleCompat.EDGE_TYPE_DROP_SHADOW, android.graphics.Color.BLACK, null)
        SubtitleStyle.BOX -> CaptionStyleCompat(foreground, box, 0, CaptionStyleCompat.EDGE_TYPE_NONE, 0, null)
    }
    view.setStyle(style)
    view.setApplyEmbeddedStyles(true)
    view.setFractionalTextSize(androidx.media3.ui.SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * settings.subtitleScale.toFloat(), settings.subtitleFollowsTextSize)
    view.setBottomPaddingFraction(bottom + (settings.subtitleLift / 1000).toFloat())
}

private fun toggleSubtitles(model: PlayerController, preferred: String) {
    if (model.activeSubtitle != null) model.selectSubtitle(null)
    else (model.subtitleTracks.firstOrNull { Languages.matches(it.language ?: "", preferred) } ?: model.subtitleTracks.firstOrNull())?.let { model.selectSubtitle(it) }
}

/** What the viewer picked here, for the next episode or the next time. */
private fun rememberChoices(model: PlayerController, session: PlayerSession, settings: community.reel.core.AppSettings) {
    if (!model.hasFirstFrame || session.isCloud) return
    val audio = model.audioTracks.firstOrNull { it.id == model.activeAudio }?.language
    // "Off" is remembered only when subtitles would otherwise have come on by themselves.
    val wouldAutoplay = settings.autoplaySubtitles && model.subtitleTracks.any { Languages.matches(it.language ?: "", settings.preferredSubtitleLanguage) }
    val subtitle = if (model.activeSubtitle == null) (if (wouldAutoplay) "" else null) else model.subtitleTracks.firstOrNull { it.id == model.activeSubtitle }?.language
    val previous = ViewingPreferences.choice(session.target.item.id)
    ViewingPreferences.store(ViewingChoice(
        audioLanguage = audio?.takeIf { it.isNotEmpty() && it != "und" },
        subtitleLanguage = subtitle?.takeIf { it != "und" },
        subtitleDelay = model.subtitleDelay, fillsScreen = model.fillsScreen, rate = if (model.boosted) 1f else model.rate,
        introStart = previous?.introStart, introEnd = previous?.introEnd,
    ), session.target.item.id)
}

/** A drag forward of 20 s to 3 minutes in an episode's first ten minutes is taken as skipping its intro. */
private fun learnIntro(session: PlayerSession, from: Double, to: Double) {
    if (session.target.episode == null || from >= 600 || (to - from) !in 20.0..180.0) return
    val choice = ViewingPreferences.choice(session.target.item.id) ?: ViewingChoice()
    ViewingPreferences.store(choice.copy(introStart = from, introEnd = to, updatedAt = now()), session.target.item.id)
}

@Composable
private fun TopBadge(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Box(Modifier.fillMaxSize().statusBarsPadding().padding(top = 70.dp), contentAlignment = Alignment.TopCenter) {
        Row(Modifier.glass(CircleShape).padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(text.tr(), fontWeight = FontWeight.Bold)
        }
    }
}

/** Shown until there is a first picture: the title's art, blurred, with a spinner. */
@Composable
private fun StartupCover(session: PlayerSession) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        RemoteImage(session.target.episode?.thumbnail ?: session.target.item.background, Modifier.fillMaxSize().blur(30.dp))
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)))
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.padding(16.dp)) {
            CircularProgressIndicator(color = Color.White)
            Text("Opening %s".tr(session.target.displayTitle), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(listOfNotNull(session.source.quality, session.source.size).joinToString(" · "), color = Color.White.copy(alpha = 0.7f))
        }
    }
}

@Composable
private fun Controls(session: PlayerSession, model: PlayerController, width: androidx.compose.ui.unit.Dp, panelOpen: Boolean, reconnecting: Boolean,
                     openPanel: (OptionsTab) -> Unit, close: () -> Unit, retry: () -> Unit, onScrub: (Double) -> Unit, onCommit: (Double) -> Unit,
                     scrubbing: Double?, scheduleHide: () -> Unit) {
    val stores = Env.stores
    val context = LocalContext.current
    val playback = stores.playback
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.7f), 0.3f to Color.Transparent, 0.7f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.8f)))) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal = 20.dp, vertical = 12.dp)) {
            // Top bar
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                RoundIconButton(Icons.Rounded.Close, "Close player", onClick = close)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(session.target.item.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    session.target.episode?.let { Text("${it.code} · ${it.title}", color = Color.White.copy(alpha = 0.75f), maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        PlayerChip(session.source.quality)
                        model.videoFormat.label?.let { PlayerChip(it, highlighted = true) }
                        model.audioTracks.firstOrNull { it.id == model.activeAudio }?.let { audio ->
                            if (audio.isAtmos) PlayerChip("Dolby Atmos", highlighted = true)
                            else TrackLabel.channels(audio.channels)?.takeIf { audio.channels > 2 }?.let { PlayerChip(it) }
                        }
                        session.source.size?.let { PlayerChip(it) }
                    }
                }
                RoundIconButton(Icons.Rounded.Info, "Playback info") { openPanel(OptionsTab.INFO) }
                if (Build.VERSION.SDK_INT >= 26 && context.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
                    RoundIconButton(Icons.Rounded.PictureInPictureAlt, "Picture in Picture") {
                        val (w, h) = model.videoSize ?: (16 to 9)
                        runCatching { context.findActivity()?.enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(w, h).coerce()).build()) }
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            val error = model.errorMessage
            if (error != null) ErrorCard(session, error, reconnecting, retry, close, Modifier.align(Alignment.CenterHorizontally))
            else Transport(model, scheduleHide, Modifier.align(Alignment.CenterHorizontally))
            Spacer(Modifier.weight(1f))
            // Bottom bar
            Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(28.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                TimelineBar(model, scrubbing, onScrub, onCommit, session)
                val showTitles = width >= 520.dp
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    BarButton("Sources", Icons.AutoMirrored.Rounded.List, showTitles) { playback.switchSource(session.target) }
                    BarButton("Audio & Subtitles", Icons.Rounded.Subtitles, showTitles) { openPanel(OptionsTab.AUDIO) }
                    BarButton(rateLabel(model.rate), Icons.Rounded.Speed, showTitles) { openPanel(OptionsTab.SPEED) }
                    if (model.sleepTimer != null) Icon(Icons.Rounded.Bedtime, "Sleep timer on".tr(), tint = Theme.accent)
                    Spacer(Modifier.weight(1f))
                    RoundIconButton(if (model.fillsScreen) Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen, if (model.fillsScreen) "Fit to screen" else "Fill screen") {
                        model.fillsScreen = !model.fillsScreen; scheduleHide()
                    }
                }
            }
        }
    }
}

@Composable
private fun BarButton(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, showTitle: Boolean, onClick: () -> Unit) {
    if (showTitle) PillButton(title.tr(), icon, onClick = onClick) else RoundIconButton(icon, title, onClick = onClick)
}

@Composable
private fun Transport(model: PlayerController, scheduleHide: () -> Unit, modifier: Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(46.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(56.dp).clip(CircleShape).focusCard(CircleShape, { model.skip(-10.0); scheduleHide() }), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Replay10, "Back 10 Seconds".tr(), Modifier.size(34.dp))
        }
        Box(Modifier.size(86.dp).glass(CircleShape).focusCard(CircleShape, { model.togglePlay(); scheduleHide() }), contentAlignment = Alignment.Center) {
            Icon(if (model.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, "Play or Pause".tr(), Modifier.size(44.dp))
        }
        Box(Modifier.size(56.dp).clip(CircleShape).focusCard(CircleShape, { model.skip(10.0); scheduleHide() }), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Forward10, "Ahead 10 Seconds".tr(), Modifier.size(34.dp))
        }
    }
}

@Composable
private fun ErrorCard(session: PlayerSession, message: String, reconnecting: Boolean, retry: () -> Unit, close: () -> Unit, modifier: Modifier) {
    val playback = Env.stores.playback
    Column(modifier.widthIn(max = 420.dp).glass(RoundedCornerShape(28.dp)).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(Icons.Rounded.Warning, null, Modifier.size(40.dp), tint = Color(0xFFFFD60A))
        Text("This source couldn't be played".tr(), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(message, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.75f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (!session.isLocal) PillButton((if (reconnecting) "Retrying…" else "Retry").tr(), prominent = true, enabled = !reconnecting, onClick = retry)
            PillButton("Try Another Source".tr()) { playback.switchSource(session.target) }
            PillButton("Close".tr(), onClick = close)
        }
    }
}

@Composable
fun PlayerChip(text: String, highlighted: Boolean = false) {
    Box(Modifier.clip(RoundedCornerShape(5.dp)).background(if (highlighted) Theme.accentGradient else Brush.linearGradient(listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0.16f))))
        .padding(horizontal = 7.dp, vertical = 3.dp)) {
        Text(text.tr(), fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

/** The scrubber and time labels. Dragging previews the time (and the frame) and seeks on release. */
@Composable
private fun TimelineBar(model: PlayerController, scrubbing: Double?, onScrub: (Double) -> Unit, onCommit: (Double) -> Unit, session: PlayerSession) {
    val shown = scrubbing ?: model.time.currentTime
    val duration = model.duration
    var width by remember { mutableIntStateOf(1) }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(scrubbing?.let { (it / 2).toInt() }) {
        // One decode per two-second step of the finger, and only once it pauses for a moment.
        val at = scrubbing ?: run { preview = null; return@LaunchedEffect }
        delay(120)
        model.thumbnail(session.url, at)?.let { preview = it }
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.fillMaxWidth().height(28.dp).onSizeChanged { width = maxOf(1, it.width) }
            .then(FocusRing(RoundedCornerShape(8.dp)))
            .onPreviewKeyEvent { event ->
                // A remote's left and right move the playhead a fortieth of the film at a time.
                if (event.type != KeyEventType.KeyDown || duration <= 0) return@onPreviewKeyEvent false
                val step = (duration / 40).coerceIn(10.0, 300.0)
                when (event.key) {
                    Key.DirectionLeft -> { onCommit(shown - step); true }
                    Key.DirectionRight -> { onCommit(shown + step); true }
                    else -> false
                }
            }.focusable()
            .pointerInput(duration) {
                detectDragGestures(
                    onDragStart = { onScrub((it.x / width).coerceIn(0f, 1f) * duration) },
                    onDragEnd = { scrubbing?.let(onCommit) },
                    onDragCancel = { scrubbing?.let(onCommit) },
                ) { change, _ -> onScrub((change.position.x / width).coerceIn(0f, 1f) * duration) }
            }
            .pointerInput(duration) { detectTapGestures { onCommit((it.x / width).coerceIn(0f, 1f) * duration) } },
            contentAlignment = Alignment.CenterStart) {
            val span = maxOf(duration, 1.0)
            val progress = (shown / span).coerceIn(0.0, 1.0).toFloat()
            val loaded = (model.time.buffered / span).coerceIn(0.0, 1.0).toFloat()
            val dragging = scrubbing != null
            Box(Modifier.fillMaxWidth().height(if (dragging) 8.dp else 5.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.18f))) {
                Box(Modifier.fillMaxWidth(maxOf(loaded, progress)).fillMaxSize().clip(CircleShape).background(Color.White.copy(alpha = 0.32f)))
                Box(Modifier.fillMaxWidth(progress).fillMaxSize().clip(CircleShape).background(Theme.accentGradient))
            }
            val knob = if (dragging) 22.dp else 14.dp
            val density = LocalDensity.current
            Box(Modifier.offset(x = with(density) { (width * progress).toDp() } - knob / 2).size(knob).clip(CircleShape).background(Color.White))
            if (dragging && duration > 0) {
                val x = with(density) { (width * progress).toDp() }
                val maxX = with(density) { width.toDp() }
                Column(Modifier.offset(x = (x - 88.dp).coerceIn(0.dp, maxOf(0.dp, maxX - 176.dp)), y = (-96).dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.width(176.dp).height(99.dp).clip(RoundedCornerShape(12.dp)).background(Color.Black.copy(alpha = 0.5f))) {
                        preview?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(clock(scrubbing ?: 0.0), fontWeight = FontWeight.Bold, fontSize = 12.sp, modifier = Modifier.glass(CircleShape).padding(horizontal = 8.dp, vertical = 3.dp))
                }
            }
        }
        Row {
            Text(clock(shown), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.85f))
            Spacer(Modifier.weight(1f))
            Text("-" + clock(maxOf(0.0, duration - shown)), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.85f))
        }
    }
}

/** Near the end of an episode: the next one, with a countdown when autoplay is on. */
@Composable
private fun UpNextCard(model: PlayerController, next: Episode, startsAt: Double, countdown: Boolean, playNext: () -> Unit) {
    var dismissed by remember(next.id) { mutableStateOf(false) }
    var remaining by remember(next.id) { mutableIntStateOf(10) }
    val visible = !dismissed && model.time.currentTime >= startsAt
    if (visible) {
        LaunchedEffect(model.isPlaying) {
            if (!countdown || !model.isPlaying) return@LaunchedEffect
            while (remaining > 0) {
                delay(1000)
                if (dismissed) return@LaunchedEffect
                remaining -= 1
            }
            playNext()
        }
    }
    AnimatedVisibility(visible, enter = slideInHorizontally { it } + fadeIn(), exit = slideOutHorizontally { it } + fadeOut()) {
        Row(Modifier.widthIn(max = 420.dp).glass(RoundedCornerShape(24.dp)).padding(12.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            RemoteImage(next.thumbnail, Modifier.width(128.dp).height(72.dp).clip(RoundedCornerShape(12.dp)))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("UP NEXT".tr(), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.6f))
                Text("${next.code} · ${next.title}", fontWeight = FontWeight.SemiBold, maxLines = 2)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PillButton(if (countdown) "Play in %d".tr(remaining) else "Play Now".tr(), Icons.Rounded.PlayArrow, prominent = true, onClick = playNext)
                    PillButton("Cancel".tr()) { dismissed = true }
                }
            }
        }
    }
}

