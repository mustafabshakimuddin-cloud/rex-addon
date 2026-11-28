package community.reel.app.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import community.reel.app.ReelApplication
import community.reel.core.AccentChoice
import community.reel.core.Observed
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.Locale

/** The app's colours, the same as on iOS. */
object Theme {
    var choice: AccentChoice = AccentChoice.ROSE
    val accent: Color get() = Color(choice.argb)
    val accentDeep: Color get() = Color(choice.deep)
    val background = Color(0.035f, 0.035f, 0.055f)
    val surface = Color.White.copy(alpha = 0.06f)
    val surfaceStrong = Color.White.copy(alpha = 0.12f)
    val secondaryText = Color.White.copy(alpha = 0.62f)
    val cached = Color(0.33f, 0.85f, 0.55f)
    val warning = Color(0xFFFF9F0A)
    val problem = Color(1f, 0.33f, 0.33f)
    /** The red dot that marks something waiting on you. */
    val attention = Color(1f, 0.27f, 0.27f)
    val accentGradient: Brush get() = Brush.horizontalGradient(listOf(accentDeep, accent))
}

@Composable
fun ReelTheme(accent: AccentChoice, content: @Composable () -> Unit) {
    Theme.choice = accent
    val scheme = darkColorScheme(
        primary = Theme.accent,
        onPrimary = Color.White,
        secondary = Theme.accentDeep,
        background = Theme.background,
        surface = Color(0.07f, 0.07f, 0.10f),
        surfaceVariant = Color(0.11f, 0.11f, 0.15f),
        surfaceContainer = Color(0.09f, 0.09f, 0.13f),
        surfaceContainerHigh = Color(0.12f, 0.12f, 0.16f),
        surfaceContainerHighest = Color(0.15f, 0.15f, 0.2f),
        onSurface = Color.White,
        onSurfaceVariant = Theme.secondaryText,
        error = Theme.problem,
    )
    MaterialTheme(colorScheme = scheme) {
        // Text without a colour of its own is white: outside a Surface, Compose's default is black,
        // which left titles unreadable on the dark backdrop. The TV components read their own local.
        androidx.compose.runtime.CompositionLocalProvider(
            androidx.compose.material3.LocalContentColor provides Color.White,
            androidx.tv.material3.LocalContentColor provides Color.White,
            content = content,
        )
    }
}

/** The app's backdrop: near-black with a faint bloom of the accent. */
@Composable
fun Backdrop(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(
        modifier.fillMaxSize().background(Theme.background)
            .background(Brush.radialGradient(listOf(Theme.accentDeep.copy(alpha = 0.22f), Color.Transparent), center = Offset.Zero, radius = 1800f))
            .background(Brush.radialGradient(listOf(Theme.accent.copy(alpha = 0.10f), Color.Transparent), center = Offset.Infinite, radius = 1500f)),
        content = content,
    )
}

/** Recomposes when the store publishes a change, then returns it to read from. */
@Composable
fun <T : Observed> T.observe(): T {
    changes.collectAsState().value
    return this
}

/** The store's change counter as state, for keys of effects. */
@Composable
fun Observed.version(): State<Long> = changes.collectAsState()

val LocalTelevision = compositionLocalOf { false }

/**
 * The text in the reader's language when the iOS String Catalog has it, otherwise as it is. Both
 * apps look strings up by their English text; `android/tools/strings.py` writes the table.
 */
object Strings {
    private var table: Map<String, String> = emptyMap()
    private var loadedFor: String? = null

    fun load(context: Context) {
        val language = Locale.getDefault().language
        if (loadedFor == language) return
        loadedFor = language
        table = runCatching {
            val text = context.assets.open("strings.json").bufferedReader().use { it.readText() }
            Json.parseToJsonElement(text).jsonObject[language]?.jsonObject?.mapValues { it.value.jsonPrimitive.content } ?: emptyMap()
        }.getOrDefault(emptyMap())
    }

    fun get(key: String): String = table[key] ?: key
}

fun String.tr(): String = Strings.get(this)
fun String.tr(vararg args: Any?): String = runCatching { String.format(Strings.get(this), *args) }.getOrElse { String.format(this, *args) }

val app: ReelApplication get() = ReelApplication.instance
