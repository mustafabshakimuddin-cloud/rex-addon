package community.reel.app.player

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.MetadataRetriever
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import community.reel.core.HTTP
import community.reel.core.SourceVerification
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Opens a source the way the player would and reads what is really inside: Dolby Vision, PQ or HLG
 * transfer, bit depth, and whether the audio is Dolby Atmos. Release names claim these often and
 * wrongly; the file's own headers do not.
 */
@OptIn(UnstableApi::class)
object SourceVerifier {
    suspend fun verify(context: Context, url: String): SourceVerification = withTimeout(25_000) {
        val factory = DefaultMediaSourceFactory(DefaultDataSource.Factory(context, OkHttpDataSource.Factory(HTTP.client).setUserAgent(HTTP.userAgent)))
        val groups = withContext(Dispatchers.IO) {
            MetadataRetriever.Builder(context, MediaItem.fromUri(url)).setMediaSourceFactory(factory).build().use {
                it.retrieveTrackGroups().get(24, TimeUnit.SECONDS)
            }
        }
        val formats = (0 until groups.length).flatMap { g -> val group = groups[g]; (0 until group.length).map { group.getFormat(it) } }
        val video = formats.firstOrNull { MimeTypes.isVideo(it.sampleMimeType) } ?: throw IOException("No video in this file.")
        val audio = formats.filter { MimeTypes.isAudio(it.sampleMimeType) }
        val atmos = audio.any { it.sampleMimeType == MimeTypes.AUDIO_E_AC3_JOC || it.codecs?.contains("ec+3") == true }
        val format = PlayerController.formatOf(video)
        val dvProfile = video.codecs?.takeIf { format == VideoFormat.DOLBY_VISION }?.split('.')?.getOrNull(1)?.toIntOrNull()
        val bitDepth = video.colorInfo?.lumaBitdepth?.takeIf { it != androidx.media3.common.Format.NO_VALUE }
        val main = audio.firstOrNull { it.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0 } ?: audio.firstOrNull()
        SourceVerification(
            videoFormat = format.label ?: "SDR",
            dolbyVisionProfile = dvProfile,
            resolution = if (video.width > 0) "${video.width}×${video.height}" else null,
            bitDepth = bitDepth,
            codec = PlayerController.codecOf(video).uppercase(),
            atmos = atmos,
            audio = main?.let { listOfNotNull(TrackLabel.codecName(PlayerController.codecOf(it)), TrackLabel.channels(it.channelCount)).joinToString(" · ") },
        )
    }
}
