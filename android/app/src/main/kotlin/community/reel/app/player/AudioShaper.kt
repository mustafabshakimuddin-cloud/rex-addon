package community.reel.app.player

import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.LoudnessEnhancer
import android.os.Build

/**
 * Night mode, the dialogue lift and the loudness lift, on the platform's audio effects: dynamics
 * processing squeezes loud and quiet scenes together and lifts the speech band; the loudness
 * enhancer raises quietly mixed films. The iOS app does the same in its engine's audio graph.
 */
class AudioShaper {
    data class Settings(val nightMode: Boolean = false, val dialogueBoostDB: Double = 0.0, val liftQuiet: Boolean = false) {
        val isActive get() = nightMode || dialogueBoostDB > 0 || liftQuiet
    }

    var settings = Settings()
        set(value) { field = value; apply() }

    private var sessionId = 0
    private var dynamics: DynamicsProcessing? = null
    private var loudness: LoudnessEnhancer? = null

    /** Whether the effects could be attached to the stream's audio session. */
    val available: Boolean get() = !settings.isActive || dynamics != null || loudness != null

    fun attach(audioSessionId: Int) {
        if (audioSessionId == sessionId) return
        release()
        sessionId = audioSessionId
        apply()
    }

    private fun apply() {
        if (sessionId == 0) return
        val s = settings
        runCatching {
            if ((s.nightMode || s.dialogueBoostDB > 0) && Build.VERSION.SDK_INT >= 28) {
                val dp = dynamics ?: DynamicsProcessing(0, sessionId, DynamicsProcessing.Config.Builder(
                    DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, 2, true, 3, true, 1, false, 0, true).build()).also { dynamics = it }
                for (channel in 0 until 2) {
                    // Speech lives roughly between 300 Hz and 4 kHz: the middle band carries the lift.
                    val eq = dp.getPreEqByChannelIndex(channel)
                    eq.isEnabled = s.dialogueBoostDB > 0
                    listOf(300f to 0f, 4000f to s.dialogueBoostDB.toFloat(), 20000f to 0f).forEachIndexed { index, (cutoff, gain) ->
                        eq.getBand(index).apply { cutoffFrequency = cutoff; this.gain = gain; isEnabled = true }
                    }
                    dp.setPreEqByChannelIndex(channel, eq)
                    val mbc = dp.getMbcByChannelIndex(channel)
                    mbc.isEnabled = s.nightMode
                    val band = mbc.getBand(0)
                    band.cutoffFrequency = 20000f
                    band.attackTime = 3f; band.releaseTime = 200f
                    band.ratio = if (s.nightMode) 4f else 1f
                    band.threshold = -30f
                    band.postGain = if (s.nightMode) 8f else 0f
                    mbc.setBand(0, band)
                    dp.setMbcByChannelIndex(channel, mbc)
                    dp.setLimiterByChannelIndex(channel, DynamicsProcessing.Limiter(true, true, 0, 1f, 60f, 10f, -2f, 0f))
                }
                dp.enabled = true
            } else {
                dynamics?.enabled = false
            }
            if (s.liftQuiet) {
                val enhancer = loudness ?: LoudnessEnhancer(sessionId).also { loudness = it }
                enhancer.setTargetGain(600)
                enhancer.enabled = true
            } else loudness?.enabled = false
        }
    }

    fun release() {
        runCatching { dynamics?.release() }
        runCatching { loudness?.release() }
        dynamics = null
        loudness = null
    }
}
