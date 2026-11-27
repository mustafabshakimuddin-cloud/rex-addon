package community.reel.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * A screen's title bar: a back button when there is somewhere to go back to, the title (large on a
 * tab's first screen, small on the pages above it) and actions on the right.
 */
@Composable
fun TitleBar(title: String, large: Boolean, onBack: (() -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = if (onBack != null) 12.dp else 20.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        if (onBack != null) {
            RoundIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onClick = onBack)
            Spacer(Modifier.width(12.dp))
        }
        Text(title.tr(), style = if (large) MaterialTheme.typography.displaySmall else MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically, content = actions)
    }
}

/** A page with a title bar over its content, on the app's backdrop. */
@Composable
fun Page(title: String, large: Boolean = false, onBack: (() -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {},
         content: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        TitleBar(title, large, onBack, actions)
        Box(Modifier.fillMaxSize()) { content() }
    }
}

/** Where a pushed page's back button goes, when not the router's own stack (Setup's pages). */
val LocalBack = androidx.compose.runtime.compositionLocalOf<(() -> Unit)?> { null }

/** A pushed page: the back button pops it. */
@Composable
fun PushedPage(title: String, actions: @Composable RowScope.() -> Unit = {}, content: @Composable () -> Unit) {
    val router = Env.router
    val back = LocalBack.current ?: { router.back(); Unit }
    Page(title, large = false, onBack = back, actions = actions, content = content)
}

@Composable
fun Gap(height: androidx.compose.ui.unit.Dp) = Spacer(Modifier.height(height))
