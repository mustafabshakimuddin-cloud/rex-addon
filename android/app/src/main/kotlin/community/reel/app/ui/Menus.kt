package community.reel.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.RemoveCircleOutline
import androidx.compose.material.icons.rounded.Games
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.Eco
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Pets
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.PlaybackTarget
import community.reel.core.Profile

@Composable
fun MenuItem(text: String, icon: ImageVector, destructive: Boolean = false, onClick: () -> Unit) {
    DropdownMenuItem(text = { Text(text.tr(), color = if (destructive) Theme.problem else Color.Unspecified) },
        leadingIcon = { Icon(icon, null, tint = if (destructive) Theme.problem else Color.White) }, onClick = onClick)
}

/** The long-press menu shared by poster cards: list, watched, details. */
@Composable
fun TitleMenu(item: MediaItem, expanded: Boolean, onDismiss: () -> Unit) {
    val stores = Env.stores
    val router = Env.router
    val library = stores.library.observe()
    var choosingList by remember { mutableStateOf(false) }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        val listed = library.isInWatchlist(item)
        MenuItem(if (listed) "Remove from My List" else "Add to My List", if (listed) Icons.Rounded.RemoveCircleOutline else Icons.Rounded.Add) {
            library.toggleWatchlist(item); onDismiss()
        }
        if (item.kind == MediaKind.MOVIE) {
            val target = PlaybackTarget(item)
            MenuItem("Play", Icons.Rounded.PlayArrow) { stores.playback.play(target, stores.settings, library); onDismiss() }
            if (library.isWatched(target)) MenuItem("Mark as Unwatched", Icons.Rounded.RadioButtonUnchecked) { library.markUnwatched(target); onDismiss() }
            else MenuItem("Mark as Watched", Icons.Rounded.CheckCircle) { library.markWatched(target); onDismiss() }
        }
        MenuItem("Add to List", Icons.AutoMirrored.Rounded.PlaylistAdd) { choosingList = true }
        MenuItem(if (item.kind == MediaKind.MOVIE) "Details" else "Episodes", Icons.Rounded.Info) { router.push(Route.Title(item)); onDismiss() }
    }
    if (choosingList) AddToListDialog(item) { choosingList = false; onDismiss() }
}

/** A poster that opens its title, with the shared long-press menu. */
@Composable
fun PosterLink(item: MediaItem, width: Dp, modifier: Modifier = Modifier, menu: Boolean = true) {
    val stores = Env.stores
    val router = Env.router
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        PosterCard(item, width, mark = stores.library.mark(item, stores.downloads), onLongClick = if (menu) ({ expanded = true }) else null) {
            router.push(Route.Title(item))
        }
        if (menu) TitleMenu(item, expanded) { expanded = false }
    }
}

/** Your own lists, to add a title to or take it off; or a new one. */
@Composable
fun AddToListDialog(item: MediaItem, onDismiss: () -> Unit) {
    val lists = Env.stores.lists.observe()
    var naming by remember { mutableStateOf(lists.lists.isEmpty()) }
    var name by remember { mutableStateOf("") }
    if (naming) {
        AlertDialog(onDismissRequest = onDismiss, title = { Text("New List".tr()) },
            text = {
                androidx.compose.foundation.layout.Column {
                    Text("%s is added to it.".tr(item.name))
                    OutlinedTextField(name, { name = it }, label = { Text("Name".tr()) }, singleLine = true)
                }
            },
            confirmButton = { TextButton({ lists.create(name, item); onDismiss() }) { Text("Create".tr()) } },
            dismissButton = { TextButton(onDismiss) { Text("Cancel".tr()) } })
        return
    }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Add to List".tr()) },
        text = {
            androidx.compose.foundation.layout.Column {
                for (list in lists.lists) {
                    DropdownMenuItem(text = { Text(list.name) }, onClick = { lists.toggle(item, list.id) },
                        leadingIcon = { Icon(if (lists.contains(item, list.id)) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked, null) })
                }
                HorizontalDivider()
                DropdownMenuItem(text = { Text("New List…".tr()) }, onClick = { naming = true }, leadingIcon = { Icon(Icons.Rounded.Add, null) })
            }
        },
        confirmButton = { TextButton(onDismiss) { Text("Done".tr()) } })
}

fun profileIcon(symbol: String): ImageVector = when (symbol.substringBefore('.')) {
    "star" -> Icons.Rounded.Star
    "heart" -> Icons.Rounded.Favorite
    "moon" -> Icons.Rounded.DarkMode
    "flame" -> Icons.Rounded.LocalFireDepartment
    "leaf" -> Icons.Rounded.Eco
    "pets", "pawprint" -> Icons.Rounded.Pets
    "games", "gamecontroller" -> Icons.Rounded.Games
    else -> Icons.Rounded.Person
}

@Composable
fun ProfileBadge(profile: Profile, size: Dp) {
    Box(Modifier.size(size).clip(CircleShape).background(Theme.accentGradient), contentAlignment = Alignment.Center) {
        Icon(profileIcon(profile.symbol), null, Modifier.size(size * 0.55f), tint = Color.White)
    }
}

/** Only once there is someone to switch to; one profile needs no button. */
@Composable
fun ProfileSwitcher() {
    val stores = Env.stores
    val router = Env.router
    val profiles = stores.profiles.observe()
    if (!profiles.hasSeveral) return
    var expanded by remember { mutableStateOf(false) }
    Box {
        Box(Modifier.clip(CircleShape).focusCard(CircleShape, { expanded = true })) { ProfileBadge(profiles.current, 34.dp) }
        DropdownMenu(expanded, { expanded = false }) {
            for (profile in profiles.profiles) {
                MenuItem(profile.name, if (profile.id == profiles.current.id) Icons.Rounded.Check else profileIcon(profile.symbol)) {
                    stores.switchProfile(profile); router.stack(AppTab.HOME).clear(); router.stack(AppTab.LIBRARY).clear(); expanded = false
                }
            }
            HorizontalDivider()
            MenuItem("Manage Profiles", Icons.Rounded.Groups) { router.openSettings(SettingsPage.PROFILES); expanded = false }
        }
    }
}

