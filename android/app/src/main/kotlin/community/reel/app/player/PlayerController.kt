package community.reel.app.player

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.ForwardingRenderer
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.session.MediaSession
import community.reel.app.ui.tr
import community.reel.core.HTTP
import community.reel.core.Languages
import community.reel.core.OnlineSubtitles
import community.reel.core.Platform
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant

/** The scrubber's position, kept apart so only it redraws on each tick. */
class PlaybackTime {
    var currentTime by mutableDoubleStateOf(0.0)
    var buffered by mutableDoubleStateOf(0.0)
}

/** One audio or subtitle track, as the options panel lists it. */
data class TrackInfo(
    val id: String,
    val groupIndex: Int,
    val trackIndex: Int,
    val language: String?,
    val name: String,
    val codec: String,
    val channels: Int,
    val isDefault: Boolean,
    val isForced: Boolean,
    val isExternal: Boolean,
    val isAtmos: Boolean,
    val isCommentary: Boolean,
    val isHearingImpaired: Boolean,
)

enum class VideoFormat(val label: String?) { SDR(null), HDR10("HDR10"), HDR10_PLUS("HDR10+"), HLG("HLG"), DOLBY_VISION("Dolby Vision") }

sealed class SleepTimer {
    data class At(val time: Instant) : SleepTimer()
    data object EndOfEpisode : SleepTimer()
}

/** A chapter from the file, for Skip Intro and the scrubber's marks. */
data class Chapter(val name: String, val start: Double, val duration: Double)

/**
 * Drives one playback with Media3's ExoPlayer and mirrors its state for the player screen: the
 * counterpart of the iOS PlayerModel around AetherEngine. FFmpeg decodes the audio Android can't
 * (DTS, TrueHD); the platform's decoders do the rest, Dolby Vision and HDR included where the
 * device supports them.
 */
@OptIn(UnstableApi::class)
class PlayerController(private val context: Context) {
    val time = PlaybackTime()
    var isPlaying by mutableStateOf(false); private set
    var state by mutableIntStateOf(Player.STATE_IDLE); private set
    var duration by mutableDoubleStateOf(0.0); private set
    var hasFirstFrame by mutableStateOf(false); private set
    var errorMessage by mutableStateOf<String?>(null); private set
    var rate by mutableFloatStateOf(1f); private set
    var videoFormat by mutableStateOf(VideoFormat.SDR); private set
    val audioTracks = mutableStateListOf<TrackInfo>()
    val subtitleTracks = mutableStateListOf<TrackInfo>()
    var activeAudio by mutableStateOf<String?>(null); private set
    var activeSubtitle by mutableStateOf<String?>(null); private set
    var subtitleDelay by mutableDoubleStateOf(0.0); private set
    var cues by mutableStateOf<List<Cue>>(emptyList()); private set
    val chapters = mutableStateListOf<Chapter>()
    var onlineSubtitles by mutableStateOf<List<OnlineSubtitles.Result>>(emptyList()); private set
    var searchingSubtitles by mutableStateOf(false); private set
    /** Raised each time playback rebuffers after the first picture, for the source memory. */
    var stallCount by mutableIntStateOf(0); private set
    var fillsScreen by mutableStateOf(false)
    var sleepTimer by mutableStateOf<SleepTimer?>(null)
    var sleepFired by mutableStateOf(false); private set
    var boosted by mutableStateOf(false); private set
    var videoSize by mutableStateOf<Pair<Int, Int>?>(null); private set
    /** What the Info panel shows: resolution, codecs, bitrate, buffer, dropped frames. */
    var stats by mutableStateOf(Stats()); private set

    data class Stats(val video: Format? = null, val audio: Format? = null, val droppedFrames: Int = 0, val bitrate: Long = 0, val bufferedAhead: Double = 0.0)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var started = false
    private var lastSaved = -100.0
    private var onProgress: ((Double, Double) -> Unit)? = null
    private var rateBeforeBoost = 1f
    private var tick: Job? = null
    private var mediaItem: MediaItem? = null
    private val external = mutableListOf<MediaItem.SubtitleConfiguration>()
    @Volatile private var delayUs = 0L
    private val shaper = AudioShaper()
    private var session: MediaSession? = null

    /** Positive shows subtitles later, negative earlier: the text renderer runs on a shifted clock. */
    private inner class DelayedText(renderer: Renderer) : ForwardingRenderer(renderer) {
        override fun render(positionUs: Long, elapsedRealtimeUs: Long) = super.render(maxOf(0, positionUs - delayUs), elapsedRealtimeUs)
    }

    val player: ExoPlayer = run {
        val renderers = object : DefaultRenderersFactory(context) {
            override fun buildTextRenderers(context: Context, output: TextOutput, outputLooper: android.os.Looper, extensionRendererMode: Int, out: ArrayList<Renderer>) {
                val start = out.size
                super.buildTextRenderers(context, output, outputLooper, extensionRendererMode, out)
                for (i in start until out.size) out[i] = DelayedText(out[i])
            }
        }.setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON).setEnableDecoderFallback(true)
        val http = OkHttpDataSource.Factory(HTTP.client).setUserAgent(HTTP.userAgent)
        ExoPlayer.Builder(context, renderers)
            .setMediaSourceFactory(DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http)))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .setSeekBackIncrementMs(10_000).setSeekForwardIncrementMs(10_000)
            .build()
    }

    init {
        player.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) { isPlaying = playing }
            override fun onPlaybackStateChanged(value: Int) {
                if (value == Player.STATE_BUFFERING && hasFirstFrame && state == Player.STATE_READY) stallCount += 1
                state = value
                if (value == Player.STATE_READY) duration = player.duration.takeIf { it > 0 }?.div(1000.0) ?: duration
                if (value == Player.STATE_ENDED) saveProgress(force = true)
            }
            override fun onRenderedFirstFrame() { hasFirstFrame = true }
            override fun onPlayerError(error: PlaybackException) { errorMessage = message(error) }
            override fun onTracksChanged(tracks: Tracks) = readTracks(tracks)
            override fun onCues(cueGroup: CueGroup) { cues = cueGroup.cues }
            override fun onPlaybackParametersChanged(parameters: PlaybackParameters) { rate = parameters.speed }
            override fun onVideoSizeChanged(size: androidx.media3.common.VideoSize) { if (size.width > 0) videoSize = size.width to size.height }
            override fun onAudioSessionIdChanged(audioSessionId: Int) { shaper.attach(audioSessionId) }
        })
        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
                stats = stats.copy(droppedFrames = stats.droppedFrames + droppedFrames)
            }
            override fun onBandwidthEstimate(eventTime: AnalyticsListener.EventTime, totalLoadTimeMs: Int, totalBytesLoaded: Long, bitrateEstimate: Long) {
                stats = stats.copy(bitrate = bitrateEstimate)
            }
            override fun onVideoInputFormatChanged(eventTime: AnalyticsListener.EventTime, format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?) {
                stats = stats.copy(video = format)
                videoFormat = formatOf(format)
            }
            override fun onAudioInputFormatChanged(eventTime: AnalyticsListener.EventTime, format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?) {
                stats = stats.copy(audio = format)
            }
        })
    }

    fun start(url: String, title: String, subtitle: String?, startAt: Double?, audioLanguages: List<String>, subtitleLanguages: List<String>,
              artwork: String?, localSubtitles: List<String>, shaping: AudioShaper.Settings, onProgress: (Double, Double) -> Unit) {
        if (started) return
        started = true
        this.onProgress = onProgress
        shaper.settings = shaping
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setPreferredAudioLanguages(*audioLanguages.toTypedArray())
            .setPreferredTextLanguages(*subtitleLanguages.toTypedArray())
            .setSelectUndeterminedTextLanguage(false)
            // Subtitles come on only in a language asked for (or when the file forces them).
            .setIgnoredTextSelectionFlags(if (subtitleLanguages.isEmpty()) C.SELECTION_FLAG_DEFAULT else 0)
            .build()
        for (file in localSubtitles) {
            val language = Uri.parse(file).lastPathSegment?.substringBeforeLast('.')?.substringAfterLast('.') ?: "und"
            external += MediaItem.SubtitleConfiguration.Builder(Uri.parse(file)).setMimeType(MimeTypes.APPLICATION_SUBRIP)
                .setLanguage(language).setLabel("%s · Saved".tr(Languages.name(language))).build()
        }
        val metadata = MediaMetadata.Builder().setTitle(title).setArtist(subtitle).apply { artwork?.let { setArtworkUri(Uri.parse(it)) } }.build()
        mediaItem = MediaItem.Builder().setUri(url).setMediaMetadata(metadata).setSubtitleConfigurations(external.toList()).build()
        player.setMediaItem(mediaItem!!, ((startAt ?: 0.0) * 1000).toLong())
        player.prepare()
        player.playWhenReady = true
        // The lock screen, notification and headset controls, as the iOS Now Playing card.
        session = runCatching { MediaSession.Builder(context, player).build() }.getOrNull()
        PlaybackService.current = session
        runCatching { context.startService(Intent(context, PlaybackService::class.java)) }
        tick = scope.launch {
            while (isActive) {
                time.currentTime = player.currentPosition / 1000.0
                time.buffered = (player.bufferedPosition / 1000.0).let { kotlin.math.floor(it) }
                if (duration <= 0 && player.duration > 0) duration = player.duration / 1000.0
                stats = stats.copy(bufferedAhead = maxOf(0.0, (player.bufferedPosition - player.currentPosition) / 1000.0))
                saveProgress(force = false)
                checkSleepTimer()
                delay(250)
            }
        }
    }

    /** Opens a fresh address for the same file at the same place, after a link expired. */
    fun reload(url: String, at: Double?) {
        errorMessage = null
        val item = (mediaItem ?: return).buildUpon().setUri(url).build()
        mediaItem = item
        player.setMediaItem(item, ((at?.takeIf { it > 1 } ?: 0.0) * 1000).toLong())
        player.prepare()
        player.playWhenReady = true
    }

    fun stop() {
        saveProgress(force = true)
        tick?.cancel()
        PlaybackService.current = null
        session?.release()
        session = null
        context.stopService(Intent(context, PlaybackService::class.java))
        shaper.release()
        player.release()
        scope.cancel()
    }

    // Transport

    fun togglePlay() {
        if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
        if (player.isPlaying) player.pause() else player.play()
    }

    fun seek(seconds: Double) {
        if (duration <= 0) return
        val target = seconds.coerceIn(0.0, maxOf(0.0, duration - 1))
        time.currentTime = target
        player.seekTo((target * 1000).toLong())
    }

    fun skip(seconds: Double) = seek(time.currentTime + seconds)

    fun changeRate(value: Float) {
        player.setPlaybackSpeed(value)
        rate = value
    }

    fun beginBoost() {
        if (boosted || !isPlaying) return
        rateBeforeBoost = rate
        boosted = true
        changeRate(2f)
    }

    fun endBoost() {
        if (!boosted) return
        boosted = false
        changeRate(rateBeforeBoost)
    }

    private fun checkSleepTimer() {
        val timer = sleepTimer as? SleepTimer.At ?: return
        if (sleepFired || Instant.now().isBefore(timer.time)) return
        sleepTimer = null
        if (isPlaying) player.pause()
        sleepFired = true
    }

    val stopsAtEnd: Boolean get() = sleepTimer == SleepTimer.EndOfEpisode

    // Tracks

    private fun readTracks(tracks: Tracks) {
        val audio = mutableListOf<TrackInfo>()
        val text = mutableListOf<TrackInfo>()
        var selectedAudio: String? = null
        var selectedText: String? = null
        tracks.groups.forEachIndexed { groupIndex, group ->
            for (index in 0 until group.length) {
                val format = group.getTrackFormat(index)
                val info = TrackInfo(
                    id = "$groupIndex:$index", groupIndex = groupIndex, trackIndex = index,
                    language = format.language, name = format.label ?: "", codec = codecOf(format), channels = format.channelCount.takeIf { it > 0 } ?: 0,
                    isDefault = format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0, isForced = format.selectionFlags and C.SELECTION_FLAG_FORCED != 0,
                    isExternal = group.mediaTrackGroup.id.contains("external") || external.any { it.label == format.label && format.label != null },
                    isAtmos = format.codecs?.contains("ec+3") == true || format.sampleMimeType == MimeTypes.AUDIO_E_AC3_JOC || format.sampleMimeType == MimeTypes.AUDIO_TRUEHD && format.channelCount > 8,
                    isCommentary = format.roleFlags and C.ROLE_FLAG_COMMENTARY != 0,
                    isHearingImpaired = format.roleFlags and C.ROLE_FLAG_DESCRIBES_MUSIC_AND_SOUND != 0,
                )
                when (group.type) {
                    C.TRACK_TYPE_AUDIO -> { audio += info; if (group.isTrackSelected(index)) selectedAudio = info.id }
                    C.TRACK_TYPE_TEXT -> { text += info; if (group.isTrackSelected(index)) selectedText = info.id }
                }
            }
        }
        audioTracks.clear(); audioTracks += audio
        subtitleTracks.clear(); subtitleTracks += text
        activeAudio = selectedAudio
        activeSubtitle = selectedText
    }

    fun selectAudio(track: TrackInfo) = select(C.TRACK_TYPE_AUDIO, track)

    fun selectSubtitle(track: TrackInfo?) {
        if (track == null) {
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
            activeSubtitle = null
        } else select(C.TRACK_TYPE_TEXT, track)
    }

    private fun select(type: Int, track: TrackInfo) {
        val group = player.currentTracks.groups.getOrNull(track.groupIndex) ?: return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, track.trackIndex))
            .build()
    }

    fun changeSubtitleDelay(seconds: Double) {
        val value = Math.round(seconds * 4) / 4.0
        subtitleDelay = value
        delayUs = (value * 1_000_000).toLong()
    }

    /** Looks the title up on OpenSubtitles. With `autoAdd`, the first result in a preferred language becomes a track. */
    fun searchOnlineSubtitles(kind: community.reel.core.MediaKind, videoID: String, filename: String?, size: Double?, autoAdd: List<String> = emptyList()) {
        if (searchingSubtitles) return
        searchingSubtitles = true
        scope.launch {
            val results = runCatching { OnlineSubtitles.search(kind, videoID, filename, size) }.getOrNull() ?: emptyList()
            onlineSubtitles = results
            searchingSubtitles = false
            if (autoAdd.isEmpty()) return@launch
            val hasOwn = subtitleTracks.any { track -> track.language?.lowercase()?.let { it in autoAdd } == true }
            if (!hasOwn) results.firstOrNull { it.language in autoAdd }?.let { addOnlineSubtitle(it, select = true) }
        }
    }

    /**
     * Adds a subtitle file as a track. Media3 reads side-loaded files when the item is prepared, so
     * the stream reopens at the same place for a moment.
     */
    fun addOnlineSubtitle(result: OnlineSubtitles.Result, name: String? = null, select: Boolean = true) {
        val label = name ?: "%s · OpenSubtitles".tr(Languages.name(result.language))
        subtitleTracks.firstOrNull { it.isExternal && it.name == label }?.let { if (select) selectSubtitle(it); return }
        external += MediaItem.SubtitleConfiguration.Builder(Uri.parse(result.url)).setMimeType(MimeTypes.APPLICATION_SUBRIP)
            .setLanguage(result.language).setLabel(label).setSelectionFlags(if (select) C.SELECTION_FLAG_DEFAULT else 0).build()
        val item = (mediaItem ?: return).buildUpon().setSubtitleConfigurations(external.toList()).build()
        mediaItem = item
        val position = player.currentPosition
        val playing = player.playWhenReady
        if (select) player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .clearOverridesOfType(C.TRACK_TYPE_TEXT).setPreferredTextLanguages(result.language).build()
        player.setMediaItem(item, position)
        player.prepare()
        player.playWhenReady = playing
    }

    // Audio shaping

    fun setAudioShaping(settings: AudioShaper.Settings) { shaper.settings = settings }
    val shapingAvailable: Boolean get() = shaper.available

    // Previews

    /** A frame for the scrubber, read from the file itself; null where the server or format doesn't allow it. */
    suspend fun thumbnail(url: String, seconds: Double): Bitmap? = withContext(Dispatchers.IO) {
        runCatching {
            MediaMetadataRetriever().use { retriever ->
                if (url.startsWith("file:")) retriever.setDataSource(Uri.parse(url).path) else retriever.setDataSource(url, mapOf("User-Agent" to HTTP.userAgent))
                retriever.getScaledFrameAtTime((seconds * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 320, 180)
            }
        }.getOrNull()
    }

    private fun saveProgress(force: Boolean) {
        val now = player.currentPosition / 1000.0
        if (duration <= 0 || !now.isFinite()) return
        if (force || kotlin.math.abs(now - lastSaved) >= 10) {
            lastSaved = now
            onProgress?.invoke(now, duration)
        }
    }

    private fun message(error: PlaybackException): String {
        val text = error.cause?.message?.takeIf { it.isNotBlank() } ?: error.message
        return when (error.errorCode) {
            PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS -> "The server refused the stream (%s).".tr(text ?: "")
            PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> "The connection dropped. Check your network.".tr()
            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED, PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> "This device can't decode this file. Try another source.".tr()
            else -> text?.let { "${error.errorCodeName}: $it" } ?: "This stream couldn't be opened. Try another source.".tr()
        }
    }

    companion object {
        fun formatOf(format: Format): VideoFormat {
            if (format.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION || format.codecs?.startsWith("dvh") == true || format.codecs?.startsWith("dav1") == true) return VideoFormat.DOLBY_VISION
            return when (format.colorInfo?.colorTransfer) {
                C.COLOR_TRANSFER_ST2084 -> VideoFormat.HDR10
                C.COLOR_TRANSFER_HLG -> VideoFormat.HLG
                else -> VideoFormat.SDR
            }
        }

        fun codecOf(format: Format): String = when (format.sampleMimeType) {
            MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "eac3"
            MimeTypes.AUDIO_AC3 -> "ac3"
            MimeTypes.AUDIO_TRUEHD -> "truehd"
            MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_DTS_EXPRESS, MimeTypes.AUDIO_DTS_X -> "dts"
            MimeTypes.AUDIO_AAC -> "aac"
            MimeTypes.AUDIO_FLAC -> "flac"
            MimeTypes.AUDIO_OPUS -> "opus"
            MimeTypes.AUDIO_MPEG -> "mp3"
            MimeTypes.APPLICATION_SUBRIP -> "subrip"
            MimeTypes.TEXT_SSA -> "ass"
            MimeTypes.TEXT_VTT -> "webvtt"
            MimeTypes.APPLICATION_PGS -> "hdmv_pgs_subtitle"
            MimeTypes.APPLICATION_VOBSUB -> "dvd_subtitle"
            MimeTypes.APPLICATION_DVBSUBS -> "dvb_subtitle"
            MimeTypes.APPLICATION_TX3G -> "mov_text"
            MimeTypes.VIDEO_H265 -> "hevc"
            MimeTypes.VIDEO_H264 -> "h264"
            MimeTypes.VIDEO_AV1 -> "av1"
            MimeTypes.VIDEO_VP9 -> "vp9"
            MimeTypes.VIDEO_DOLBY_VISION -> "dolby vision"
            else -> format.sampleMimeType?.substringAfter('/') ?: "?"
        }
    }
}
