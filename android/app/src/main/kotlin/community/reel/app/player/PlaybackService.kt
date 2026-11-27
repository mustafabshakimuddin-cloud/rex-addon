package community.reel.app.player

import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Keeps playback going in the background and shows the lock-screen / notification controls, as
 * iOS's Now Playing card does. The player hands it its session while one is open.
 */
class PlaybackService : MediaSessionService() {
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = current

    companion object {
        @Volatile var current: MediaSession? = null
    }
}
