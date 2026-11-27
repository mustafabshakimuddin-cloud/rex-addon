package community.reel.app.system

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import community.reel.app.MainActivity
import community.reel.app.R
import community.reel.app.ReelApplication
import community.reel.app.ui.tr
import community.reel.core.CalendarEpisode
import community.reel.core.DownloadItem
import community.reel.core.EpisodeTiming
import community.reel.core.formatBytes
import community.reel.core.now
import java.time.Duration
import java.util.concurrent.TimeUnit

/**
 * Notifications: a download that finished while the app was away, new episodes of the series you
 * follow, and a running download's progress (Android's counterpart of the iOS Live Activity).
 * Episodes are scheduled ahead for when they air; a background refresh a few times a day keeps the
 * schedule current.
 */
object Notifier {
    const val DOWNLOADS = "downloads"
    const val PROGRESS = "download.progress"
    const val EPISODES = "episodes"
    private const val EPISODE_TAG = "episode"
    private const val REFRESH = "community.reel.app.refresh"
    const val PROGRESS_ID = 4242

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(DOWNLOADS, "Downloads".tr(), NotificationManager.IMPORTANCE_DEFAULT))
        manager.createNotificationChannel(NotificationChannel(PROGRESS, "Download progress".tr(), NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        manager.createNotificationChannel(NotificationChannel(EPISODES, "New episodes".tr(), NotificationManager.IMPORTANCE_DEFAULT))
    }

    fun allowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    /** Opens a title, as a tapped iOS notification does. */
    private fun open(context: Context, link: String, request: Int): PendingIntent =
        PendingIntent.getActivity(context, request, Intent(Intent.ACTION_VIEW, Uri.parse(link), context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun post(context: Context, id: Int, notification: android.app.Notification) {
        if (!allowed(context)) return
        runCatching { NotificationManagerCompat.from(context).notify(id, notification) }
    }

    fun downloadFinished(context: Context, item: DownloadItem) {
        if (ReelApplication.instance.isForeground) return
        post(context, item.id.hashCode(), NotificationCompat.Builder(context, DOWNLOADS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Downloaded".tr())
            .setContentText("%s is ready to watch offline.".tr(item.target.displayTitle))
            .setContentIntent(open(context, "reel://downloads", 1))
            .setAutoCancel(true).build())
    }

    /** The running download as an ongoing notification, updated every few seconds. */
    fun downloadProgress(context: Context, item: DownloadItem, speed: Double?) {
        var detail = if (item.expected > 0) "%s of %s".tr(formatBytes(item.written), formatBytes(item.expected)) else "Starting…".tr()
        if (speed != null && speed > 0) detail += " · ${formatBytes(speed.toLong())}/s"
        DownloadService.lastProgress = progressNotification(context, item.target.displayTitle, detail, item.fraction)
        post(context, PROGRESS_ID, DownloadService.lastProgress!!)
    }

    fun progressNotification(context: Context, title: String, detail: String, fraction: Double?): android.app.Notification =
        NotificationCompat.Builder(context, PROGRESS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(detail)
            .setOngoing(true).setOnlyAlertOnce(true).setSilent(true)
            .setProgress(1000, ((fraction ?: 0.0) * 1000).toInt(), fraction == null)
            .setContentIntent(open(context, "reel://downloads", 2))
            .build()

    fun downloadEnded(context: Context, @Suppress("UNUSED_PARAMETER") item: DownloadItem) {
        val stores = ReelApplication.instance.stores
        if (stores.downloads.active.isEmpty()) NotificationManagerCompat.from(context).cancel(PROGRESS_ID)
    }

    /** Replaces the scheduled episode notifications with one for each episode airing in the next two weeks. */
    fun scheduleEpisodes(context: Context, episodes: List<CalendarEpisode>) {
        val work = WorkManager.getInstance(context)
        work.cancelAllWorkByTag(EPISODE_TAG)
        val time = now()
        for (episode in episodes.filter { it.date.isAfter(time) && it.date.isBefore(time.plus(Duration.ofDays(14))) }.take(50)) {
            val fire = EpisodeTiming.fireTime(episode.date)
            val delay = Duration.between(time, fire).toMillis().coerceAtLeast(0)
            work.enqueue(OneTimeWorkRequestBuilder<EpisodeWorker>().setInitialDelay(delay, TimeUnit.MILLISECONDS).addTag(EPISODE_TAG)
                .setInputData(Data.Builder().putString("title", episode.item.name).putString("id", episode.item.id)
                    .putString("body", "%s · %s is out.".tr(episode.episode.code, episode.episode.title)).build()).build())
        }
    }

    fun cancelEpisodes(context: Context) = WorkManager.getInstance(context).cancelAllWorkByTag(EPISODE_TAG)

    /** Asks Android to wake the app every few hours to refresh the calendar. */
    fun scheduleRefresh(context: Context) {
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(REFRESH, ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<RefreshWorker>(4, TimeUnit.HOURS).build())
    }

    class EpisodeWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
        override suspend fun doWork(): Result {
            val id = inputData.getString("id") ?: return Result.success()
            post(applicationContext, id.hashCode(), NotificationCompat.Builder(applicationContext, EPISODES)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(inputData.getString("title"))
                .setContentText(inputData.getString("body"))
                .setContentIntent(open(applicationContext, "reel://title/$id?type=series", id.hashCode()))
                .setAutoCancel(true).build())
            return Result.success()
        }
    }

    /** The background refresh: new and upcoming episodes, and their notifications. */
    class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
        override suspend fun doWork(): Result {
            val stores = (applicationContext as ReelApplication).stores
            if (!stores.settings.notifyNewEpisodes) return Result.success()
            stores.upcoming.refresh(stores.library, force = true)
            scheduleEpisodes(applicationContext, stores.upcoming.upcoming)
            Widgets.publish(applicationContext, stores)
            return Result.success()
        }
    }
}
