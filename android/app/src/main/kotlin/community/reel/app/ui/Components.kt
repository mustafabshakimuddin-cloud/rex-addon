package community.reel.app.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.compose.SubcomposeAsyncImage
import community.reel.core.DownloadStore
import community.reel.core.Library
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.PlaybackProgress
import community.reel.core.PlaybackTarget

/** Settings → Appearance → Poster size, as a multiplier on card widths. */
val LocalCardScale = compositionLocalOf { 1f }
/** Settings → Appearance → Show ratings on posters. */
val LocalShowsRatings = compositionLocalOf { true }

/** Card widths follow the window's width, never the device, so they suit phones, tablets and foldables alike. */
data class CardMetrics(val poster: Dp, val landscape: Dp) {
    companion object {
        @Composable
        fun current(): CardMetrics {
            val scale = LocalCardScale.current
            val regular = LocalConfiguration.current.screenWidthDp >= 600 || LocalTelevision.current
            return if (regular) CardMetrics(160.dp * scale, 340.dp * scale) else CardMetrics(116.dp * scale, 260.dp * scale)
        }
    }
}

@Composable
fun RemoteImage(url: String?, modifier: Modifier = Modifier, contentScale: ContentScale = ContentScale.Crop) {
    Box(modifier.background(Theme.surface)) {
        if (url != null) AsyncImage(model = url, contentDescription = null, contentScale = contentScale, modifier = Modifier.fillMaxSize())
    }
}

enum class PosterMarkKind { WATCHED, DOWNLOADED, LISTED, PROGRESS }
data class PosterMark(val kind: PosterMarkKind, val fraction: Double = 0.0)

/** The corner mark a poster gets for what you've done with that title. */
fun Library.mark(item: MediaItem, downloads: DownloadStore? = null): PosterMark? {
    if (item.kind == MediaKind.MOVIE) {
        val target = PlaybackTarget(item)
        if (isWatched(target)) return PosterMark(PosterMarkKind.WATCHED)
        progress(target)?.let { if (it.position >= Library.MINIMUM_RESUME) return PosterMark(PosterMarkKind.PROGRESS, it.fraction) }
        if (downloads?.item(target)?.isFinished == true) return PosterMark(PosterMarkKind.DOWNLOADED)
    }
    return if (isInWatchlist(item)) PosterMark(PosterMarkKind.LISTED) else null
}

@Composable
fun PosterCard(item: MediaItem, width: Dp, modifier: Modifier = Modifier, showTitle: Boolean = true, mark: PosterMark? = null,
               onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    val showsRatings = LocalShowsRatings.current
    val description = buildList {
        add(item.name); item.year?.let { add(it) }; item.rating?.let { add("rated %s".tr(it)) }
        when (mark?.kind) {
            PosterMarkKind.WATCHED -> add("watched".tr()); PosterMarkKind.DOWNLOADED -> add("downloaded".tr())
            PosterMarkKind.LISTED -> add("in My List".tr()); PosterMarkKind.PROGRESS -> add("%d percent watched".tr((mark.fraction * 100).toInt()))
            null -> {}
        }
    }.joinToString(", ")
    Column(modifier.width(width).semantics(mergeDescendants = true) { contentDescription = description }.focusCard(RoundedCornerShape(14.dp), onClick, onLongClick)) {
        Box(Modifier.width(width).height(width * 1.5f).clip(RoundedCornerShape(14.dp)).border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(14.dp))) {
            RemoteImage(item.poster, Modifier.fillMaxSize())
            when (mark?.kind) {
                PosterMarkKind.WATCHED -> CornerIcon(Icons.Rounded.Check, Theme.cached, Modifier.align(Alignment.TopStart))
                PosterMarkKind.DOWNLOADED -> CornerIcon(Icons.Rounded.Download, Theme.accent, Modifier.align(Alignment.TopStart))
                PosterMarkKind.LISTED -> CornerIcon(Icons.Rounded.Bookmark, Color.White, Modifier.align(Alignment.TopStart))
                PosterMarkKind.PROGRESS -> ProgressBar(mark.fraction, Modifier.align(Alignment.BottomCenter).padding(8.dp))
                null -> {}
            }
            if (showsRatings && item.rating != null) {
                Row(Modifier.align(Alignment.TopEnd).padding(6.dp).glass(CircleShape).padding(horizontal = 7.dp, vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Star, null, Modifier.size(11.dp), tint = Color.White)
                    Spacer(Modifier.width(2.dp))
                    Text(item.rating ?: "", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
        if (showTitle) {
            Spacer(Modifier.height(6.dp))
            Text(item.name, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(item.year ?: " ", fontSize = 11.sp, color = Theme.secondaryText, maxLines = 1)
        }
    }
}

@Composable
private fun CornerIcon(icon: ImageVector, tint: Color, modifier: Modifier) {
    Box(modifier.padding(6.dp).size(24.dp).glass(CircleShape), contentAlignment = Alignment.Center) {
        Icon(icon, null, Modifier.size(14.dp), tint = tint)
    }
}

@Composable
fun ProgressBar(fraction: Double, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.25f))) {
        Box(Modifier.fillMaxWidth(fraction.toFloat().coerceIn(0f, 1f)).height(4.dp).clip(CircleShape).background(Theme.accentGradient))
    }
}

/** A frosted surface, Android's stand-in for iOS's Liquid Glass. */
fun Modifier.glass(shape: androidx.compose.ui.graphics.Shape = RoundedCornerShape(18.dp), tint: Color? = null): Modifier =
    this.clip(shape).background(tint?.copy(alpha = 0.25f) ?: Color.White.copy(alpha = 0.12f)).border(1.dp, Color.White.copy(alpha = 0.10f), shape)

/** A wide card with the title's backdrop and logo: Library's Banners layout and Calendar's cards. */
@Composable
fun BannerCard(item: MediaItem, width: Dp, modifier: Modifier = Modifier, image: String? = null, eyebrow: String? = null,
               title: String? = null, subtitle: String? = null, fraction: Double? = null, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    Box(modifier.width(width).height(width * 9f / 16f).clip(RoundedCornerShape(16.dp))
        .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp)).focusCard(RoundedCornerShape(16.dp), onClick, onLongClick)) {
        RemoteImage(image ?: item.background ?: item.poster, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.3f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.85f))))
        Column(Modifier.align(Alignment.BottomStart).padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            eyebrow?.let { Text(it.uppercase(), fontSize = 11.sp, fontWeight = FontWeight.Black, color = Theme.accent, maxLines = 1) }
            if (title != null) Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            else TitleLogo(item, 44.dp, Modifier.widthIn(max = width * 0.6f))
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.8f), maxLines = 2) }
            fraction?.let { LinearProgressIndicator(progress = { it.toFloat() }, Modifier.fillMaxWidth(), color = Theme.accent) }
        }
    }
}

/** A title's logo artwork when Cinemeta has one, otherwise its name in large type. */
@Composable
fun TitleLogo(item: MediaItem, maxHeight: Dp, modifier: Modifier = Modifier) {
    val name = @Composable {
        Text(item.name, fontSize = (maxHeight.value * 0.42f).sp, fontWeight = FontWeight.Black, maxLines = 2, overflow = TextOverflow.Ellipsis,
            lineHeight = (maxHeight.value * 0.46f).sp)
    }
    if (item.logo == null) { Box(modifier) { name() }; return }
    SubcomposeAsyncImage(model = item.logo, contentDescription = item.name, contentScale = ContentScale.Fit, alignment = Alignment.CenterStart,
        modifier = modifier.heightIn(max = maxHeight), loading = { Spacer(Modifier.height(maxHeight * 0.6f)) }, error = { name() })
}

/** One title as a row: poster thumbnail, name, facts and an optional trailing status. */
@Composable
fun MediaRow(item: MediaItem, modifier: Modifier = Modifier, subtitle: String? = null, onClick: (() -> Unit)? = null, trailing: @Composable () -> Unit = {}) {
    Row(modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Theme.surface)
        .let { if (onClick != null) it.focusCard(RoundedCornerShape(16.dp), onClick) else it }.padding(10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        RemoteImage(item.poster, Modifier.width(54.dp).height(81.dp).clip(RoundedCornerShape(9.dp)))
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(item.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(subtitle ?: itemSubtitle(item), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 2)
            item.rating?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Star, null, Modifier.size(12.dp), tint = Color(0xFFFFD60A))
                    Text(" $it", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color(0xFFFFD60A))
                }
            }
        }
        Spacer(Modifier.width(6.dp))
        trailing()
    }
}

/** "Movie · 2019 · Drama · Mystery": what a title's subtitle says on a card or row. */
fun itemSubtitle(item: MediaItem): String = (listOf(item.kind.singular.tr()) + listOfNotNull(item.year) + item.genres.take(2)).joinToString(" · ")

/** A small coloured label: "In My List", "Downloaded", "FAIL". */
@Composable
fun StatusPill(text: String, icon: ImageVector? = null, tint: Color = Color.White) {
    Row(Modifier.clip(CircleShape).background(tint.copy(alpha = 0.16f)).padding(horizontal = 9.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Icon(it, null, Modifier.size(13.dp), tint = tint); Spacer(Modifier.width(4.dp)) }
        Text(text.tr(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = tint)
    }
}

/** The red dot on anything that is waiting on you. */
@Composable
fun AttentionDot(size: Dp = 9.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(Theme.attention).semantics { contentDescription = "Needs attention".tr() })
}

/** A shelf or section title, with an optional "See All" on the right. */
@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, subtitle: String? = null, onSeeAll: (() -> Unit)? = null) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Column(Modifier.weight(1f)) {
            Text(title.tr(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            subtitle?.let { Text(it.tr(), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText) }
        }
        if (onSeeAll != null) {
            Row(Modifier.clip(CircleShape).focusCard(CircleShape, onSeeAll).padding(horizontal = 6.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("See All".tr(), color = Theme.accent, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Theme.accent)
            }
        }
    }
}

@Composable
fun ContinueCard(entry: PlaybackProgress, width: Dp, modifier: Modifier = Modifier, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    val remaining = if (entry.isUpNext) "Next episode".tr() else {
        val minutes = (maxOf(0.0, entry.duration - entry.position) / 60).toInt()
        if (minutes >= 60) "%dh %dm left".tr(minutes / 60, minutes % 60) else "%dm left".tr(minutes)
    }
    Column(modifier.width(width).focusCard(RoundedCornerShape(16.dp), onClick, onLongClick)) {
        Box(Modifier.width(width).height(width * 9f / 16f).clip(RoundedCornerShape(16.dp)).border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))) {
            RemoteImage(entry.episode?.thumbnail ?: entry.item.background ?: entry.item.poster, Modifier.fillMaxSize())
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.5f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.75f))))
            Row(Modifier.align(Alignment.BottomStart).padding(start = 10.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(30.dp).glass(CircleShape), contentAlignment = Alignment.Center) { Icon(Icons.Rounded.PlayArrow, null, Modifier.size(18.dp)) }
                Spacer(Modifier.width(8.dp))
                Text(remaining, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.9f))
            }
            if (!entry.isUpNext) ProgressBar(entry.fraction, Modifier.align(Alignment.BottomCenter).padding(horizontal = 10.dp, vertical = 6.dp))
        }
        Spacer(Modifier.height(8.dp))
        Text(entry.item.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        entry.episode?.let { Text("${it.code} · ${it.title}", style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    }
}

/** A titled horizontal row of cards. */
@Composable
fun <T> ShelfRow(title: String, items: List<T>, key: (T) -> Any, modifier: Modifier = Modifier, subtitle: String? = null,
                 spacing: Dp = 14.dp, onSeeAll: (() -> Unit)? = null, content: @Composable (T) -> Unit) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionHeader(title, Modifier.padding(horizontal = 20.dp), subtitle, onSeeAll)
        LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(spacing)) {
            items(items, key = { key(it) }) { content(it) }
        }
    }
}

@Composable
fun Chip(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, tint: Color? = null, selected: Boolean = false, onClick: (() -> Unit)? = null) {
    val base = modifier.glass(CircleShape, if (selected) Theme.accent else tint)
    Row((if (onClick != null) base.focusCard(CircleShape, onClick) else base).padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Icon(it, null, Modifier.size(14.dp), tint = tint ?: Color.White); Spacer(Modifier.width(4.dp)) }
        Text(text.tr(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = tint ?: Color.White)
    }
}

@Composable
fun QualityBadge(quality: String) {
    Box(Modifier.clip(RoundedCornerShape(6.dp)).background(if (quality == "4K") Theme.accentGradient else Brush.linearGradient(listOf(Color.White.copy(alpha = 0.14f), Color.White.copy(alpha = 0.14f))))
        .padding(horizontal = 8.dp, vertical = 4.dp)) {
        Text(quality, fontSize = 12.sp, fontWeight = FontWeight.Black)
    }
}

@Composable
fun StateMessage(title: String, message: String, modifier: Modifier = Modifier, icon: ImageVector = Icons.Rounded.Warning,
                 actionTitle: String? = null, action: (() -> Unit)? = null) {
    Column(modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, null, Modifier.size(44.dp), tint = Theme.secondaryText)
        Text(title.tr(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Text(message.tr(), style = MaterialTheme.typography.bodyMedium, color = Theme.secondaryText, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (actionTitle != null && action != null) {
            Button(onClick = action, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)) { Text(actionTitle.tr()) }
        }
    }
}

/** A tappable card that also takes the focus ring on TV and keyboards. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
fun Modifier.focusCard(shape: androidx.compose.ui.graphics.Shape, onClick: () -> Unit, onLongClick: (() -> Unit)? = null): Modifier =
    this.then(FocusRing(shape)).clip(shape).combinedClickable(onClick = onClick, onLongClick = onLongClick)

/** Page content stays readable on wide screens. */
fun Modifier.readableWidth(max: Dp = 980.dp) = this.widthIn(max = max)

/** A capsule button with an icon and a label: filled with the accent when prominent, glass otherwise. */
@Composable
fun PillButton(text: String, icon: ImageVector? = null, modifier: Modifier = Modifier, prominent: Boolean = false, enabled: Boolean = true,
               onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    val shape = CircleShape
    val base = if (prominent) modifier.clip(shape).background(Theme.accent) else modifier.glass(shape)
    Row((if (enabled) base.focusCard(shape, onClick, onLongClick) else base.alpha(0.5f)).heightIn(min = 44.dp).padding(horizontal = 18.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Icon(it, null, Modifier.size(20.dp), tint = Color.White); Spacer(Modifier.width(6.dp)) }
        Text(text, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
