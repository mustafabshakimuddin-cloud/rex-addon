package community.reel.app.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Lightbulb
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.core.AppAlert
import community.reel.core.AppLog
import community.reel.core.HealthCheck
import community.reel.core.HealthModel
import community.reel.core.Profile
import kotlinx.coroutines.launch

private fun tint(level: HealthCheck.Level) = when (level) {
    HealthCheck.Level.OK -> Theme.cached
    HealthCheck.Level.NOT_SET -> Theme.secondaryText
    HealthCheck.Level.WARNING -> Theme.warning
    HealthCheck.Level.PROBLEM -> Theme.problem
}

/**
 * Is everything working? Each part of the chain a title passes through is checked, the result is
 * OK, WARN, FAIL or Not set, and anything that isn't OK says what to do and links there. Below the
 * checks: recent alerts, and a report to share when asking for help.
 */
@Composable
fun StatusScreen() {
    val stores = Env.stores
    val router = Env.router
    val context = LocalContext.current
    val health = remember { stores.health }.observe()
    val alerts = stores.alerts.observe()
    val scope = rememberCoroutineScope()
    var log by remember { mutableStateOf(AppLog.entries) }
    var showLog by remember { mutableStateOf(false) }
    suspend fun run() = health.run(stores.settings, stores.trakt, stores.downloads, stores.memory)
    LaunchedEffect(Unit) { alerts.markSeen(); run() }
    val openUrl = { url: String -> context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    // Worst first, so what needs doing is at the top.
    val checks = health.checks.withIndex().sortedWith(compareByDescending<IndexedValue<HealthCheck>> { it.value.level }.thenBy { it.index }).map { it.value }
    FormPage("Status", actions = {
        if (health.checks.isNotEmpty() && !health.isRunning) RoundIconButton(Icons.Rounded.Share, "Share report") {
            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, health.report), null))
        }
    }) {
        // Summary
        val worst = health.worst
        Row(Modifier.padding(horizontal = 16.dp).widthIn(max = 760.dp).fillMaxWidth().glass(RoundedCornerShape(20.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(56.dp).clip(CircleShape).background(tint(worst).copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
                if (health.isRunning && health.checks.all { it.detail == "Checking…" }) CircularProgressIndicator(Modifier.size(24.dp), color = Theme.accent)
                else Icon(when (worst) { HealthCheck.Level.WARNING -> Icons.Rounded.Warning; HealthCheck.Level.PROBLEM -> Icons.Rounded.Error; else -> Icons.Rounded.Verified }, null, tint = tint(worst))
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(health.summary.tr(), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(if (health.isRunning) "Checking…".tr() else health.ranAt?.let { "Checked %s.".tr(shortTime(it)) } ?: "", fontSize = 12.sp, color = Theme.secondaryText)
            }
            TextButton({ scope.launch { run() } }, enabled = !health.isRunning) { Text("Check Again".tr()) }
        }
        FormSection("Checks") {
            checks.forEachIndexed { index, check ->
                if (index > 0) FormDivider()
                CheckRow(check) { fix -> router.perform(fix, openUrl) }
            }
        }
        FormSection("Recent Alerts") {
            if (alerts.recent.isEmpty()) Text("No alerts yet.".tr(), color = Theme.secondaryText, modifier = Modifier.padding(16.dp))
            alerts.recent.take(20).forEachIndexed { index, alert ->
                if (index > 0) FormDivider()
                AlertRow(alert)
            }
            if (alerts.recent.isNotEmpty()) { FormDivider(); FormRow("Clear", titleColor = Theme.accent, onClick = { alerts.clear() }) }
        }
        if (log.isNotEmpty()) FormSection("Log", "Included in the shared report. Keys and tokens are removed before anything is kept.") {
            FormRow("%d recent errors".tr(log.size), chevron = true, onClick = { showLog = !showLog })
            if (showLog) {
                for (entry in log.take(30)) {
                    FormDivider()
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                        Text("${entry.area} · ${mediumDate(entry.date)} ${shortTime(entry.date)}", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Theme.secondaryText)
                        SelectionContainer { Text(entry.message, fontSize = 12.sp) }
                    }
                }
                FormDivider()
                FormRow("Clear Log", titleColor = Theme.problem, onClick = { AppLog.clear(); log = emptyList() })
            }
        }
    }
}

@Composable
private fun CheckRow(check: HealthCheck, perform: (HealthCheck.Fix) -> Unit) {
    val pending = check.detail == "Checking…"
    Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(check.title.tr(), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            if (pending) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Theme.secondaryText)
            else Text(check.level.label.tr(), fontSize = 11.sp, fontWeight = FontWeight.Black, color = tint(check.level),
                modifier = Modifier.clip(CircleShape).background(tint(check.level).copy(alpha = 0.16f)).padding(horizontal = 8.dp, vertical = 3.dp))
        }
        Text(check.detail.tr(), fontSize = 14.sp, color = if (pending) Theme.secondaryText else Color.White.copy(alpha = 0.88f))
        if (check.advice != null && check.level != HealthCheck.Level.OK && !pending) Row {
            Icon(Icons.Rounded.Lightbulb, null, Modifier.size(14.dp), tint = Theme.secondaryText); Spacer(Modifier.width(4.dp))
            Text(check.advice!!.tr(), fontSize = 12.sp, color = Theme.secondaryText)
        }
        val fix = check.fix
        val title = check.fixTitle
        if (fix != null && title != null && !pending) PillButton(title.tr()) { perform(fix) }
    }
}

@Composable
private fun AlertRow(alert: AppAlert) {
    val router = Env.router
    val (icon, color) = when (alert.level) {
        AppAlert.Level.INFO -> Icons.Rounded.Info to Theme.accent
        AppAlert.Level.SUCCESS -> Icons.Rounded.CheckCircle to Theme.cached
        AppAlert.Level.WARNING -> Icons.Rounded.Warning to Theme.warning
        AppAlert.Level.PROBLEM -> Icons.Rounded.Error to Theme.problem
    }
    Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = color)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(alert.title.tr(), fontWeight = FontWeight.SemiBold)
            alert.message?.let { Text(it, fontSize = 12.sp, color = Theme.secondaryText, maxLines = 3) }
            Text(relativeDay(alert.date), fontSize = 11.sp, color = Theme.secondaryText)
        }
        val action = alert.action
        val title = alert.actionTitle
        if (action != null && title != null) TextButton({ router.perform(action) }) { Text(title.tr()) }
    }
}

/** Who is watching: switch, add, rename and remove profiles. */
@Composable
fun ProfilesScreen() {
    val stores = Env.stores
    val router = Env.router
    val profiles = stores.profiles.observe()
    var editing by remember { mutableStateOf<Profile?>(null) }
    var confirmDelete by remember { mutableStateOf<Profile?>(null) }
    FormPage("Profiles") {
        FormSection(footer = "Each profile has its own My List, history and resume points, lists, player choices and Trakt account. The debrid service, addons and other settings are shared. Long-press a profile to edit or delete it.") {
            profiles.profiles.forEachIndexed { index, profile ->
                if (index > 0) FormDivider()
                var menu by remember { mutableStateOf(false) }
                Box {
                    Row(Modifier.fillMaxWidth().focusCard(RoundedCornerShape(0.dp), { editing = profile }, { menu = true }).padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        ProfileBadge(profile, 36.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(profile.name, fontWeight = FontWeight.SemiBold)
                            if (profile.isKids) Text("Kids: family and animation only".tr(), fontSize = 12.sp, color = Theme.secondaryText)
                        }
                        if (profile.id == profiles.current.id) Icon(Icons.Rounded.Check, null, tint = Theme.accent)
                        else PillButton("Switch".tr()) { stores.switchProfile(profile); router.stack(AppTab.HOME).clear(); router.stack(AppTab.LIBRARY).clear() }
                    }
                    DropdownMenu(menu, { menu = false }) {
                        MenuItem("Edit", Icons.Rounded.Edit) { editing = profile; menu = false }
                        if (!profile.isDefault && profile.id != profiles.current.id) MenuItem("Delete", Icons.Rounded.Delete, destructive = true) { confirmDelete = profile; menu = false }
                    }
                }
            }
            FormDivider()
            FormRow("Add Profile", icon = Icons.Rounded.Add, titleColor = Theme.accent, onClick = { editing = Profile("", "", Profile.symbols[1]) })
        }
    }
    editing?.let { profile -> ProfileEditor(profile, { editing = null }) { edited ->
        if (edited.id.isEmpty()) profiles.add(edited.name, edited.symbol, edited.isKids) else profiles.update(edited)
        editing = null
    } }
    confirmDelete?.let { profile ->
        AlertDialog(onDismissRequest = { confirmDelete = null }, title = { Text("Delete %s? Its My List, history and lists go with it.".tr(profile.name)) },
            confirmButton = { TextButton({ profiles.delete(profile); confirmDelete = null }) { Text("Delete".tr(), color = Theme.problem) } },
            dismissButton = { TextButton({ confirmDelete = null }) { Text("Cancel".tr()) } })
    }
}

@Composable
private fun ProfileEditor(initial: Profile, dismiss: () -> Unit, save: (Profile) -> Unit) {
    var profile by remember { mutableStateOf(initial) }
    AlertDialog(onDismissRequest = dismiss, title = { Text((if (initial.id.isEmpty()) "New Profile" else "Edit Profile").tr()) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                OutlinedTextField(profile.name, { profile = profile.copy(name = it) }, label = { Text("Name".tr()) }, singleLine = true)
                Text("Symbol".tr(), fontSize = 12.sp, color = Theme.secondaryText)
                androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    for (symbol in Profile.symbols) {
                        Box(Modifier.size(48.dp).clip(CircleShape).background(if (profile.symbol == symbol) Theme.accent.copy(alpha = 0.35f) else Theme.surface)
                            .focusCard(CircleShape, { profile = profile.copy(symbol = symbol) }), contentAlignment = Alignment.Center) {
                            Icon(profileIcon(symbol), symbol)
                        }
                    }
                }
                if (!profile.isDefault) Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Kids profile".tr(), Modifier.weight(1f))
                    Switch(profile.isKids, { profile = profile.copy(isKids = it) }, colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent))
                }
            }
        },
        confirmButton = { TextButton({ save(profile) }, enabled = profile.name.isNotBlank()) { Text("Save".tr()) } },
        dismissButton = { TextButton(dismiss) { Text("Cancel".tr()) } })
}

