package community.reel.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** A grouped section of a settings form, with an optional header and footer, as on iOS. */
@Composable
fun FormSection(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp).widthIn(max = 760.dp).fillMaxWidth()) {
        header?.let { Text(it.tr().uppercase(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Theme.secondaryText, modifier = Modifier.padding(start = 16.dp, bottom = 6.dp)) }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Theme.surface), content = content)
        footer?.let { Text(it.tr(), fontSize = 12.sp, color = Theme.secondaryText, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp)) }
    }
}

@Composable
fun FormDivider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = Color.White.copy(alpha = 0.08f))

/** A row: title on the left, value or control on the right. Tappable when given an action. */
@Composable
fun FormRow(title: String, modifier: Modifier = Modifier, icon: ImageVector? = null, iconTint: Color = Theme.accent, subtitle: String? = null,
            value: String? = null, chevron: Boolean = false, titleColor: Color = Color.White, onClick: (() -> Unit)? = null, trailing: @Composable () -> Unit = {}) {
    Row(modifier.fillMaxWidth().heightIn(min = 52.dp).let { if (onClick != null) it.focusCard(RoundedCornerShape(0.dp), onClick) else it }.padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Icon(it, null, Modifier.size(22.dp), tint = iconTint); Spacer(Modifier.width(12.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title.tr(), color = titleColor, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 3) }
        }
        value?.let { Text(it, color = Theme.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 8.dp).widthIn(max = 220.dp)) }
        trailing()
        if (chevron) Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Theme.secondaryText)
    }
}

@Composable
fun ToggleRow(title: String, value: Boolean, subtitle: String? = null, icon: ImageVector? = null, onChange: (Boolean) -> Unit) {
    FormRow(title, icon = icon, subtitle = subtitle, onClick = { onChange(!value) }) {
        Switch(value, onChange, colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent))
    }
}

/** A choice from a short list, shown as the current value with a menu. */
@Composable
fun <T> PickerRow(title: String, value: T, options: List<T>, label: (T) -> String, onChange: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        FormRow(title, value = label(value), onClick = { open = true }) { Icon(Icons.Rounded.UnfoldMore, null, Modifier.size(18.dp), tint = Theme.secondaryText) }
        DropdownMenu(open, { open = false }) {
            for (option in options) DropdownMenuItem({ Text(label(option)) }, { onChange(option); open = false },
                trailingIcon = { if (option == value) Icon(Icons.Rounded.CheckCircle, null, tint = Theme.accent) })
        }
    }
}

@Composable
fun SliderRow(title: String, valueText: String, value: Float, range: ClosedFloatingPointRange<Float>, steps: Int, onChange: (Float) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row { Text(title.tr(), Modifier.weight(1f)); Text(valueText, color = Theme.secondaryText) }
        Slider(value, onChange, valueRange = range, steps = steps, colors = SliderDefaults.colors(thumbColor = Theme.accent, activeTrackColor = Theme.accent))
    }
}

@Composable
fun TextRow(value: String, onChange: (String) -> Unit, placeholder: String, secret: Boolean = false, keyboard: KeyboardType = KeyboardType.Text) {
    OutlinedTextField(value, onChange, Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), singleLine = true, placeholder = { Text(placeholder.tr()) },
        visualTransformation = if (secret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = if (secret) KeyboardType.Password else keyboard, autoCorrectEnabled = false), shape = RoundedCornerShape(12.dp))
}

/** The result of a key test: a spinner, a pass or a failure. */
sealed class TestState {
    data object Idle : TestState()
    data object Testing : TestState()
    data class Ok(val text: String) : TestState()
    data class Failed(val text: String) : TestState()
}

@Composable
fun TestStatus(state: TestState) {
    when (state) {
        TestState.Idle -> {}
        TestState.Testing -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Theme.accent)
        is TestState.Ok -> Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.CheckCircle, null, Modifier.size(16.dp), tint = Theme.cached); Spacer(Modifier.width(4.dp)); Text(state.text, fontSize = 13.sp, color = Theme.cached)
        }
        is TestState.Failed -> Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Error, null, Modifier.size(16.dp), tint = Theme.problem); Spacer(Modifier.width(4.dp))
            Text(state.text, fontSize = 13.sp, color = Theme.problem, maxLines = 2)
        }
    }
}

/** A settings page: its sections in a column, scrolling. */
@Composable
fun FormPage(title: String, actions: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = {}, content: @Composable ColumnScope.() -> Unit) {
    PushedPage(title, actions) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(22.dp),
            horizontalAlignment = Alignment.CenterHorizontally, content = content)
    }
}
