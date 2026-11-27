package community.reel.app.system

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.allowHardware
import coil3.toBitmap
import community.reel.app.MainActivity
import community.reel.app.ui.tr
import community.reel.core.AppStores
import community.reel.core.DownloadStore
import community.reel.core.ReelJson
import kotlinx.serialization.Serializable
import java.io.File
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * What the app hands its widgets: Continue Watching and the next episodes, written into the app's
 * own folder. Pictures are saved beside it, small, so a widget never waits on the network.
 */
@Serializable
data class WidgetData(val continueWatching: List<Entry> = emptyList(), val upcoming: List<Entry> = emptyList()) {
    @Serializable
    data class Entry(val id: String, val title: String, val subtitle: String, val fraction: Double? = null, val image: String? = null, val link: String)
}

object Widgets {
    private fun folder(context: Context) = File(context.filesDir, "Widgets").apply { mkdirs() }

    fun load(context: Context): WidgetData? = runCatching {
        ReelJson.decodeFromString<WidgetData>(File(folder(context), "widgets.json").readText())
    }.getOrNull()

    private var lastWritten: WidgetData? = null

    suspend fun publish(context: Context, stores: AppStores) {
        val folder = folder(context)
        val keep = mutableSetOf<String>()
        val continuing = stores.library.continueWatching.take(6).map { entry ->
            val image = picture(context, entry.episode?.thumbnail ?: entry.item.background ?: entry.item.poster, "cw-${DownloadStore.safeName(entry.id)}", folder)
            image?.let { keep += it }
            val left = maxOf(0.0, entry.duration - entry.position)
            val subtitle = (entry.episode?.let { "${it.code} · " } ?: "") + when {
                entry.isUpNext -> "Next episode".tr()
                left >= 3600 -> "%dh %dm left".tr((left / 3600).toInt(), ((left % 3600) / 60).toInt())
                else -> "%dm left".tr((left / 60).toInt())
            }
            WidgetData.Entry(entry.id, entry.item.name, subtitle, if (entry.isUpNext) null else entry.fraction, image,
                "reel://resume/${Uri.encode(entry.id)}?type=${entry.item.kind.raw}")
        }
        val seen = mutableSetOf<String>()
        val day = DateTimeFormatter.ofPattern("EEE d MMM").withZone(ZoneId.systemDefault())
        val coming = stores.upcoming.upcoming.filter { seen.add(it.item.id) }.take(5).map { episode ->
            val image = picture(context, episode.item.background ?: episode.item.poster, "up-${DownloadStore.safeName(episode.item.id)}", folder)
            image?.let { keep += it }
            WidgetData.Entry(episode.id, episode.item.name, "${episode.episode.code} · ${day.format(episode.date)}", null, image,
                "reel://title/${episode.item.id}?type=series")
        }
        val data = WidgetData(continuing, coming)
        if (data == lastWritten) return
        File(folder, "widgets.json").writeText(ReelJson.encodeToString(WidgetData.serializer(), data))
        lastWritten = data
        // Pictures of titles no longer shown go.
        folder.listFiles()?.filter { it.name.endsWith(".jpg") && it.name !in keep }?.forEach { it.delete() }
        runCatching { ContinueWatchingWidget().updateAll(context); NextEpisodesWidget().updateAll(context) }
    }

    private suspend fun picture(context: Context, url: String?, name: String, folder: File): String? {
        url ?: return null
        val file = "$name.jpg"
        val path = File(folder, file)
        if (path.exists()) return file
        val result = SingletonImageLoader.get(context).execute(ImageRequest.Builder(context).data(url).size(400).allowHardware(false).build())
        val bitmap = result.image?.toBitmap() ?: return null
        return runCatching { path.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, it) }; file }.getOrNull()
    }

    fun imageFile(context: Context, name: String?) = name?.let { File(folder(context), it).takeIf { file -> file.exists() } }
}

private val white = ColorProvider(Color.White)
private val secondary = ColorProvider(Color.White.copy(alpha = 0.62f))

@Composable
private fun WidgetBody(context: Context, title: String, empty: String, entries: List<WidgetData.Entry>) {
    Column(GlanceModifier.fillMaxSize().background(Color.Black).padding(12.dp)) {
        Text(title, style = TextStyle(color = secondary, fontSize = 12.sp, fontWeight = FontWeight.Bold))
        Spacer(GlanceModifier.height(8.dp))
        if (entries.isEmpty()) Text(empty, style = TextStyle(color = secondary, fontSize = 13.sp))
        for (entry in entries.take(4)) {
            val open = Intent(Intent.ACTION_VIEW, Uri.parse(entry.link), context, MainActivity::class.java)
            Row(GlanceModifier.fillMaxWidth().padding(vertical = 4.dp).clickable(actionStartActivity(open)), verticalAlignment = Alignment.CenterVertically) {
                Widgets.imageFile(context, entry.image)?.let { file ->
                    BitmapFactory.decodeFile(file.path)?.let {
                        Image(ImageProvider(it), null, GlanceModifier.size(64.dp, 36.dp).cornerRadius(6.dp))
                        Spacer(GlanceModifier.width(8.dp))
                    }
                }
                Column(GlanceModifier.defaultWeight()) {
                    Text(entry.title, style = TextStyle(color = white, fontSize = 13.sp, fontWeight = FontWeight.Bold), maxLines = 1)
                    Text(entry.subtitle, style = TextStyle(color = secondary, fontSize = 11.sp), maxLines = 1)
                    entry.fraction?.let { LinearProgressIndicator(it.toFloat(), GlanceModifier.fillMaxWidth().height(3.dp)) }
                }
            }
        }
    }
}

/** Continue Watching on the home screen: pick up where you left off. */
class ContinueWatchingWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.load(context)
        provideContent { WidgetBody(context, "Continue Watching".tr(), "Nothing to continue yet.".tr(), data?.continueWatching ?: emptyList()) }
    }
}

/** When the series you follow come back. */
class NextEpisodesWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.load(context)
        provideContent { WidgetBody(context, "Next Episodes".tr(), "No episodes coming up.".tr(), data?.upcoming ?: emptyList()) }
    }
}

class ContinueWatchingReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = ContinueWatchingWidget() }
class NextEpisodesReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = NextEpisodesWidget() }
