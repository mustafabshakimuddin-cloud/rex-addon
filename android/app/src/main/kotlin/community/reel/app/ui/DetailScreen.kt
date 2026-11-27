package community.reel.app.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.List
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.Campaign
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.DownloadDone
import androidx.compose.material.icons.rounded.Downloading
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import community.reel.core.Cinemeta
import community.reel.core.Episode
import community.reel.core.HttpStatusException
import community.reel.core.Library
import community.reel.core.MediaDetail
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.PlaybackProgress
import community.reel.core.PlaybackTarget
import community.reel.core.TMDB
import community.reel.core.readable
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

fun mediumDate(date: Instant): String = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault()).format(date)

class DetailModel {
    var detail by mutableStateOf<MediaDetail?>(null)
    var error by mutableStateOf<String?>(null)
    var season by mutableIntStateOf(1)
    var isLoading by mutableStateOf(false)

    suspend fun load(item: MediaItem, library: Library, force: Boolean = false) {
        if ((detail != null && !force) || isLoading) return
        isLoading = true
        try {
            val loaded = try {
                Cinemeta.detail(item.kind, item.id)
            } catch (e: HttpStatusException) {
                // A bare link doesn't say whether it is a film or a series: try the other.
                if (e.code == 404 && item.name.isEmpty()) Cinemeta.detail(if (item.kind == MediaKind.MOVIE) MediaKind.SERIES else MediaKind.MOVIE, item.id) else throw e
            }
            detail = loaded
            error = null
            library.learnEpisodes(loaded)
            val (caughtUp, nextAiring) = library.caughtUp(loaded)
            season = library.nextEpisode(loaded)?.season ?: nextAiring?.season
                ?: (if (caughtUp) loaded.seasons.lastOrNull { it > 0 } else null) ?: loaded.seasons.firstOrNull() ?: 1
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.readable()
        } finally {
            isLoading = false
        }
    }
}

private val ratingWords = listOf("", "Weak sauce", "Terrible", "Bad", "Poor", "Meh", "Fair", "Good", "Great", "Superb", "Totally ninja!")

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DetailScreen(item: MediaItem) {
    val stores = Env.stores
    val router = Env.router
    val context = LocalContext.current
    val library = stores.library.observe()
    val settings = stores.settings.observe()
    val downloads = stores.downloads.observe()
    stores.trakt.observe()
    val playback = stores.playback
    val model = remember(item.id) { DetailModel() }
    val scope = rememberCoroutineScope()
    var expandedOverview by remember { mutableStateOf(false) }
    val shown = model.detail?.item ?: item

    val primaryTarget: PlaybackTarget? = if (shown.kind == MediaKind.MOVIE) PlaybackTarget(shown)
    else model.detail?.let { detail -> library.nextEpisode(detail)?.let { PlaybackTarget(shown, it) } }

    LaunchedEffect(item.id) {
        model.load(item, library)
        val target = if (shown.kind == MediaKind.MOVIE) PlaybackTarget(model.detail?.item ?: item)
        else model.detail?.let { detail -> library.nextEpisode(detail)?.let { PlaybackTarget(detail.item, it) } }
        target?.let { playback.prefetch(it, settings) }
    }
    DisposableEffect(item.id) { onDispose { primaryTarget?.let { playback.cancelPrefetch(it) } } }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = maxWidth
        val wide = width >= 700.dp
        val headerHeight = minOf(if (wide) minOf(maxOf(width * 0.42f, 380.dp), 560.dp) else minOf(width * 1.05f, 520.dp), maxHeight * 0.62f)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 50.dp), verticalArrangement = Arrangement.spacedBy(26.dp)) {
            // Header
            Box(Modifier.fillMaxWidth().height(headerHeight)) {
                RemoteImage(shown.background ?: shown.poster, Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.25f to Color.Transparent, 0.7f to Theme.background.copy(alpha = 0.75f), 1f to Theme.background)))
                if (wide) Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Theme.background.copy(alpha = 0.85f), 0.5f to Color.Transparent)))
                Column(Modifier.align(Alignment.BottomStart).padding(horizontal = if (wide) 48.dp else 20.dp).padding(bottom = 8.dp).widthIn(max = 1100.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    TitleLogo(shown, if (wide) 120.dp else 90.dp, Modifier.widthIn(max = if (wide) 460.dp else 300.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        shown.rating?.let {
                            Icon(Icons.Rounded.Star, null, Modifier.size(15.dp), tint = Color(0xFFFFD60A))
                            Text(" $it   ", color = Color(0xFFFFD60A), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                        }
                        Text((listOfNotNull(shown.year, model.detail?.runtime) + shown.genres.take(3)).joinToString(" · "), color = Theme.secondaryText,
                            style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    ActionButtons(shown, model, primaryTarget)
                }
            }
            Column(Modifier.padding(horizontal = if (wide) 48.dp else 20.dp).widthIn(max = 1100.dp), verticalArrangement = Arrangement.spacedBy(26.dp)) {
                LibraryState(shown, model.detail)
                // Overview
                Column(Modifier.widthIn(max = 760.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    shown.overview?.takeIf { it.isNotEmpty() }?.let {
                        Text(it, style = MaterialTheme.typography.bodyLarge, color = Color.White.copy(alpha = 0.86f),
                            maxLines = if (expandedOverview) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.focusCard(RoundedCornerShape(8.dp), { expandedOverview = !expandedOverview }))
                    }
                    model.detail?.directors?.takeIf { it.isNotEmpty() }?.let {
                        Text("Directed by %s".tr(it.joinToString(", ")), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText)
                    }
                }
                model.detail?.let { detail ->
                    if (shown.kind == MediaKind.SERIES && detail.episodes.isNotEmpty()) EpisodesSection(shown, detail, model, wide)
                    if (detail.cast.isNotEmpty() || detail.directors.isNotEmpty()) CastSection(detail)
                }
                val error = model.error
                if (error != null && model.detail == null) {
                    StateMessage("Couldn't load details", error, actionTitle = if (model.isLoading) null else "Retry") {
                        scope.launch { model.load(item, library, force = true) }
                    }
                }
            }
            MoreLikeThis(shown)
        }
        // The bar over the picture: back, My List and the "…" menu.
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            RoundIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back") { router.back() }
            Spacer(Modifier.weight(1f))
            val listed = library.isInWatchlist(shown)
            RoundIconButton(if (listed) Icons.Rounded.Check else Icons.Rounded.Add, if (listed) "Remove from My List" else "Add to My List") { library.toggleWatchlist(shown) }
            Spacer(Modifier.width(10.dp))
            MoreMenu(shown, model.detail)
        }
    }
}

@Composable
private fun ActionButtons(shown: MediaItem, model: DetailModel, primaryTarget: PlaybackTarget?) {
    val stores = Env.stores
    val context = LocalContext.current
    val library = stores.library
    val settings = stores.settings
    val playback = stores.playback
    var playMenu by remember { mutableStateOf(false) }
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        val rewatch = rewatchTarget(shown, model.detail, library)
        if (primaryTarget != null) {
            val resume = library.resumePosition(primaryTarget)
            Box {
                val verb = (if (resume == null) "Play" else "Resume").tr()
                PillButton(primaryTarget.episode?.let { "$verb ${it.code}" } ?: verb, Icons.Rounded.PlayArrow, prominent = true,
                    onLongClick = if (resume != null) ({ playMenu = true }) else null) { playback.play(primaryTarget, settings, library) }
                DropdownMenu(playMenu, { playMenu = false }) {
                    MenuItem("Play from Beginning", Icons.Rounded.SkipPrevious) { playback.play(primaryTarget, settings, library, fromStart = true); playMenu = false }
                }
            }
            // With automatic play on, Play skips the list; this is the way back to it.
            if (settings.autoPlayBest) RoundIconButton(Icons.AutoMirrored.Rounded.List, "Sources") { playback.chooseSource(primaryTarget) }
        } else if (rewatch != null) {
            PillButton("Watch Again".tr(), Icons.Rounded.Replay, prominent = true) { playback.play(rewatch, settings, library, fromStart = true) }
        } else if (shown.kind == MediaKind.SERIES && model.detail == null && model.error == null) {
            CircularProgressIndicator(Modifier.size(24.dp), color = Color.White, strokeWidth = 2.dp)
        }
        if (primaryTarget != null && shown.kind == MediaKind.MOVIE) DownloadButton(primaryTarget)
        model.detail?.trailerYouTubeID?.let { trailer ->
            RoundIconButton(Icons.Rounded.Movie, "Trailer") {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/watch?v=$trailer")))
            }
        }
    }
}

/** For a series you're up to date with: the first episode, to watch it again. */
private fun rewatchTarget(shown: MediaItem, detail: MediaDetail?, library: Library): PlaybackTarget? {
    if (shown.kind != MediaKind.SERIES || detail == null || !library.caughtUp(detail).first) return null
    val first = detail.episodes.filter { it.season > 0 && it.hasAired }.minWithOrNull(compareBy({ it.season }, { it.number })) ?: return null
    return PlaybackTarget(shown, first)
}

@Composable
private fun DownloadButton(target: PlaybackTarget) {
    val stores = Env.stores
    val item = stores.downloads.item(target)
    when {
        item?.isFinished == true -> RoundIconButton(Icons.Rounded.DownloadDone, "Downloaded") {}
        item?.state == community.reel.core.DownloadItem.State.Downloading -> Box(Modifier.size(44.dp).glass(CircleShape), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(progress = { item.fraction.toFloat() }, Modifier.size(22.dp), color = Theme.accent, strokeWidth = 3.dp)
        }
        else -> RoundIconButton(Icons.Rounded.Download, "Download") { if (item == null) stores.playback.download(target, stores.settings) }
    }
}

/** Share, IMDb and watched state: what the "…" holds. */
@Composable
private fun MoreMenu(shown: MediaItem, detail: MediaDetail?) {
    val stores = Env.stores
    val context = LocalContext.current
    val library = stores.library
    val trakt = stores.trakt
    var open by remember { mutableStateOf(false) }
    var rating by remember { mutableStateOf(false) }
    var lists by remember { mutableStateOf(false) }
    Box {
        RoundIconButton(Icons.Rounded.MoreHoriz, "More") { open = true }
        DropdownMenu(open, { open = false }) {
            if (shown.kind == MediaKind.MOVIE) {
                val target = PlaybackTarget(shown)
                if (library.isWatched(target)) MenuItem("Mark as Unwatched", Icons.Rounded.RadioButtonUnchecked) { library.markUnwatched(target); open = false }
                else MenuItem("Mark as Watched", Icons.Rounded.CheckCircle) { library.markWatched(target); open = false }
                MenuItem("Choose Source", Icons.AutoMirrored.Rounded.List) { stores.playback.chooseSource(target); open = false }
            } else if (detail != null) {
                MenuItem("Mark All Aired as Watched", Icons.Rounded.CheckCircle) { library.markWatched(detail.episodes.filter { it.season > 0 && it.hasAired }, shown); open = false }
                MenuItem("Mark All as Unwatched", Icons.Rounded.RadioButtonUnchecked) { library.markUnwatched(detail.episodes, shown); open = false }
            }
            MenuItem("Add to List", Icons.AutoMirrored.Rounded.PlaylistAdd) { lists = true; open = false }
            if (trakt.isConnected) MenuItem("Rate on Trakt", Icons.Rounded.Star) { rating = true; open = false }
            HorizontalDivider()
            val imdb = "https://www.imdb.com/title/${shown.id}/"
            MenuItem("Share", Icons.Rounded.Share) {
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, shown.name).putExtra(Intent.EXTRA_TEXT, imdb), null))
                open = false
            }
            MenuItem("Open in IMDb", Icons.AutoMirrored.Rounded.OpenInNew) { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(imdb))); open = false }
        }
        DropdownMenu(rating, { rating = false }) {
            for (value in 10 downTo 1) DropdownMenuItem({ Text("$value – ${ratingWords[value].tr()}") }, { trakt.rate(shown, value); rating = false })
            HorizontalDivider()
            DropdownMenuItem({ Text("Remove Rating".tr(), color = Theme.problem) }, { trakt.rate(shown, 0); rating = false })
        }
    }
    if (lists) AddToListDialog(shown) { lists = false }
}

/** Where this title stands in your library, at a glance. */
@Composable
private fun LibraryState(shown: MediaItem, detail: MediaDetail?) {
    val stores = Env.stores
    val library = stores.library
    val downloads = stores.downloads
    val pills = mutableListOf<@Composable () -> Unit>()
    if (library.isInWatchlist(shown)) pills += { StatusPill("In My List", Icons.Rounded.Bookmark) }
    if (shown.kind == MediaKind.MOVIE) {
        val target = PlaybackTarget(shown)
        val entry = library.progress(target)
        if (library.isWatched(target)) pills += { StatusPill("Watched", Icons.Rounded.CheckCircle, Theme.cached) }
        else if (entry != null && entry.position >= Library.MINIMUM_RESUME) pills += { StatusPill("%d%% watched".tr((entry.fraction * 100).toInt()), Icons.Rounded.PlayCircle, Theme.accent) }
        if (downloads.item(target)?.isFinished == true) pills += { StatusPill("Downloaded", Icons.Rounded.DownloadDone, Theme.accent) }
    } else if (detail != null) {
        val regular = detail.episodes.filter { it.season > 0 && it.hasAired }
        val watched = regular.count { library.isWatched(it) }
        if (watched > 0) pills += { StatusPill("%d of %d watched".tr(watched, regular.size), Icons.Rounded.CheckCircle, if (watched == regular.size) Theme.cached else Color.White) }
        val saved = detail.episodes.count { downloads.item(PlaybackTarget(shown, it))?.isFinished == true }
        if (saved > 0) pills += { StatusPill("%d downloaded".tr(saved), Icons.Rounded.DownloadDone, Theme.accent) }
        if (library.caughtUp(detail).first) pills += { StatusPill("Caught up", Icons.Rounded.Verified, Theme.cached) }
        detail.episodes.filter { !it.hasAired && it.season > 0 }.minByOrNull { it.released ?: Instant.MAX }?.let { next ->
            next.released?.let { date -> pills += { StatusPill("${next.code} ${relativeDay(date)}", Icons.Rounded.CalendarMonth, Theme.accent) } }
        }
    }
    if (pills.isEmpty()) return
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { items(pills.size) { pills[it]() } }
}

@Composable
private fun EpisodesSection(shown: MediaItem, detail: MediaDetail, model: DetailModel, wide: Boolean) {
    val stores = Env.stores
    val library = stores.library
    val downloads = stores.downloads
    val playback = stores.playback
    val settings = stores.settings
    var menu by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Episodes".tr(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            Box {
                Chip(if (model.season == 0) "Specials".tr() else "Season %d".tr(model.season), icon = Icons.Rounded.UnfoldMore) { menu = true }
                DropdownMenu(menu, { menu = false }) {
                    for (season in detail.seasons) DropdownMenuItem({ Text(if (season == 0) "Specials".tr() else "Season %d".tr(season)) }, { model.season = season; menu = false })
                    HorizontalDivider()
                    val episodes = detail.episodes(model.season)
                    val toSave = episodes.filter { it.hasAired && downloads.item(PlaybackTarget(shown, it)) == null }
                    if (toSave.isNotEmpty()) MenuItem("Download Season (%d)".tr(toSave.size), Icons.Rounded.Download) { playback.download(toSave, shown, settings); menu = false }
                    library.nextEpisode(detail)?.let { next ->
                        val following = detail.episodes.filter { it.season > 0 && it.hasAired }.sortedWith(compareBy({ it.season }, { it.number }))
                            .dropWhile { it.id != next.id }.take(3)
                        MenuItem("Download Next %d Episodes".tr(following.size), Icons.Rounded.Downloading) { playback.download(following, shown, settings); menu = false }
                    }
                    if (episodes.filter { it.hasAired }.all { library.isWatched(it) }) MenuItem("Mark Season as Unwatched", Icons.Rounded.RadioButtonUnchecked) { library.markUnwatched(episodes, shown); menu = false }
                    else MenuItem("Mark Season as Watched", Icons.Rounded.CheckCircle) { library.markWatched(episodes, shown); menu = false }
                }
            }
        }
        val episodes = detail.episodes(model.season)
        val columns = if (wide) 2 else 1
        for (row in episodes.chunked(columns)) {
            Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                for (episode in row) {
                    val target = PlaybackTarget(shown, episode)
                    Box(Modifier.weight(1f)) {
                        EpisodeRow(episode, library.progress(target), library.isWatched(episode), downloads.item(target)?.isFinished == true,
                            play = { playback.play(target, settings, library) }, chooseSource = { playback.chooseSource(target) },
                            download = { playback.download(target, settings) },
                            toggleWatched = { if (library.isWatched(episode)) library.markUnwatched(target) else library.markWatched(target) })
                    }
                }
                if (row.size < columns) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
fun EpisodeRow(episode: Episode, progress: PlaybackProgress?, watchedElsewhere: Boolean, downloaded: Boolean,
               play: () -> Unit, chooseSource: () -> Unit, download: () -> Unit = {}, toggleWatched: () -> Unit = {}) {
    var menu by remember { mutableStateOf(false) }
    val watched = progress?.isFinished == true || (progress == null && watchedElsewhere)
    Box {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Theme.surface)
            .focusCard(RoundedCornerShape(18.dp), { if (episode.hasAired) play() }, { menu = true }).padding(10.dp)) {
            Box(Modifier.width(150.dp).height(150.dp * 9f / 16f).clip(RoundedCornerShape(12.dp)).alpha(if (episode.hasAired) 1f else 0.45f)) {
                RemoteImage(episode.thumbnail, Modifier.fillMaxSize())
                if (progress != null && !progress.isFinished) ProgressBar(progress.fraction, Modifier.align(Alignment.BottomCenter).padding(6.dp))
                Icon(if (watched) Icons.Rounded.CheckCircle else Icons.Rounded.PlayCircle, null, Modifier.align(Alignment.Center).size(30.dp), tint = Color.White)
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("${episode.number}. ${episode.title}", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 2,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (downloaded) { Spacer(Modifier.width(6.dp)); Icon(Icons.Rounded.DownloadDone, "Downloaded".tr(), Modifier.size(14.dp), tint = Theme.accent) }
                }
                episode.released?.let {
                    Text(if (episode.hasAired) mediumDate(it) else "Airs %s".tr(mediumDate(it)), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText)
                }
                episode.overview?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            }
        }
        DropdownMenu(menu, { menu = false }) {
            MenuItem("Play", Icons.Rounded.PlayArrow) { play(); menu = false }
            MenuItem("Choose Source", Icons.AutoMirrored.Rounded.List) { chooseSource(); menu = false }
            if (!downloaded) MenuItem("Download", Icons.Rounded.Download) { download(); menu = false }
            if (episode.hasAired) MenuItem(if (watched) "Mark as Unwatched" else "Mark as Watched", if (watched) Icons.Rounded.RadioButtonUnchecked else Icons.Rounded.CheckCircle) { toggleWatched(); menu = false }
        }
    }
}

/** Cast and directors; each opens that person's page. */
@Composable
private fun CastSection(detail: MediaDetail) {
    val router = Env.router
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Cast & Crew".tr(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            items(detail.directors) { name -> Chip(name, icon = Icons.Rounded.Campaign, tint = Theme.accent) { router.push(Route.Person(name)) } }
            items(detail.cast) { name ->
                if (TMDB.isConfigured) CastCard(name) { router.push(Route.Person(name)) }
                else Chip(name, icon = Icons.Rounded.Person) { router.push(Route.Person(name)) }
            }
        }
    }
}

/** A cast member with their photo, when TMDB is set up. */
@Composable
private fun CastCard(name: String, onClick: () -> Unit) {
    var photo by remember(name) { mutableStateOf<String?>(null) }
    LaunchedEffect(name) { photo = TMDB.person(name)?.photo }
    Column(Modifier.width(84.dp).focusCard(RoundedCornerShape(12.dp), onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        PersonPhoto(name, photo, 64.dp)
        Text(name, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, maxLines = 2, textAlign = TextAlign.Center)
    }
}

/** A round photo, or the person's initials on the accent gradient when there is none. */
@Composable
fun PersonPhoto(name: String, photo: String?, size: Dp) {
    Box(Modifier.size(size).clip(CircleShape).background(Theme.accentGradient), contentAlignment = Alignment.Center) {
        val initials = name.split(" ").filter { it.isNotEmpty() }.take(2).joinToString("") { it.first().uppercase() }
        Text(initials, fontSize = (size.value * 0.36f).sp, fontWeight = FontWeight.Bold)
        if (photo != null) RemoteImage(photo, Modifier.fillMaxSize())
    }
}

/** Popular titles that share this one's main genre, or Trakt's related titles. */
@Composable
fun MoreLikeThis(item: MediaItem) {
    val stores = Env.stores
    val router = Env.router
    val metrics = CardMetrics.current()
    var items by remember(item.id) { mutableStateOf<List<MediaItem>>(emptyList()) }
    var fromTrakt by remember(item.id) { mutableStateOf(false) }
    LaunchedEffect(item.id + (item.genres.firstOrNull() ?: "")) {
        // Trakt's "related" knows what people actually watch next; the genre list is the fallback.
        if (stores.trakt.credentials != null) {
            val related = runCatching { stores.trakt.related(item) }.getOrNull()
            if (related != null && related.size >= 4) { items = related.filter { it.id != item.id }; fromTrakt = true; return@LaunchedEffect }
        }
        fromTrakt = false
        val genre = item.genres.firstOrNull() ?: return@LaunchedEffect
        val found = runCatching { Cinemeta.catalog(item.kind, Cinemeta.Catalog.POPULAR, genre) }.getOrNull() ?: emptyList()
        // Titles sharing a second genre too come first.
        val others = item.genres.drop(1)
        items = found.filter { it.id != item.id }.sortedByDescending { other -> other.genres.any { it in others } }.take(16)
    }
    val genre = item.genres.firstOrNull()
    if (items.isEmpty() || genre == null) return
    ShelfRow("More Like This", items, key = { it.id }, subtitle = if (fromTrakt) "Watched alongside it on Trakt" else "Popular in %s".tr(genre),
        onSeeAll = { router.push(Route.Grid("$genre ${item.kind.title.tr()}", item.kind, Cinemeta.Catalog.POPULAR, genre)) }) { PosterLink(it, metrics.poster) }
}
