package community.reel.app.ui

import androidx.compose.foundation.border
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp

/**
 * The focus ring a TV remote or keyboard moves: the focused card grows a little and gets a white
 * outline, as on Apple TV. Touch screens never see it.
 */
@Suppress("FunctionName")
fun FocusRing(shape: Shape): Modifier = Modifier.composed {
    var focused by remember { mutableStateOf(false) }
    Modifier.onFocusChanged { focused = it.hasFocus || it.isFocused }
        .scale(if (focused) 1.06f else 1f)
        .then(if (focused) Modifier.border(3.dp, Color.White, shape) else Modifier)
}
