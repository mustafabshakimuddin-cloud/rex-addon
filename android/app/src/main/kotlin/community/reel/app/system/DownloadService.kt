package community.reel.app.system

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import community.reel.app.ReelApplication
import community.reel.app.ui.tr
import community.reel.core.AppStores
import community.reel.core.Platform
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Keeps the app running while anything is downloading, so a film keeps coming down with the app
 * closed: Android's stand-in for the iOS background download session. It stops itself once
 * nothing is left to fetch.
 */
class DownloadService : Service() {
    private var watch: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = lastProgress ?: Notifier.progressNotification(this, "Downloading".tr(), "Starting…".tr(), null)
        val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        runCatching { ServiceCompat.startForeground(this, Notifier.PROGRESS_ID, notification, type) }
        val downloads = (application as ReelApplication).stores.downloads
        watch?.cancel()
        watch = Platform.scope.launch {
            downloads.changes.collectLatest {
                if (downloads.active.isEmpty()) {
                    lastProgress = null
                    ServiceCompat.stopForeground(this@DownloadService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        watch?.cancel()
        super.onDestroy()
    }

    companion object {
        @Volatile var lastProgress: Notification? = null

        /** Starts the service when a download is running; it stops by itself when none is. */
        fun update(context: Context, stores: AppStores) {
            if (stores.downloads.active.isEmpty()) return
            runCatching { ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java)) }
        }
    }
}
