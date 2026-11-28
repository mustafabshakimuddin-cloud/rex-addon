package community.reel.app.ui

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.List
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material.icons.rounded.CropFree
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import community.reel.core.Cinemeta
import community.reel.core.HomeSection
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.PlaybackProgress
import community.reel.core.PlaybackTarget
import community.reel.core.TraktStore
import community.reel.core.CalendarEpisode
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Duration

/** Home's catalogue rows, loaded once and kept while the app runs. */
class HomeModel {
    val rows = mutableStateMapOf<HomeSection, List<MediaItem>>()
    var hero by mutableStateOf<List<MediaItem>>(emptyList())
    var error by mutableStateOf<String?>(null)
    var isLoading by mutableStateOf(false)

    /** The featured carousel draws on the popular rows, so those load whenever it is shown. */
    suspend fun load(sections: List<HomeSection>) {
        val wanted = sections.filter { it.catalogue != null }.toMutableList()
        if (HomeSection.HERO in sections) wanted += listOf(HomeSection.POPULAR_MOVIES, HomeSection.POPULAR_SERIES)
        val missing = wanted.toSet().filter { rows[it] == null }
        if (missing.isEmpty() || isLoading) return
        isLoading = true
        try {
            val results = coroutineScope {
                missing.map { section ->
                    async { section to runCatching { section.catalogue!!.let { Cinemeta.catalog(it.kind, it.catalog, it.genre) } }.getOrNull() }
                }.awaitAll()
            }
            for ((section, items) in results) if (items != null) rows[section] = items
            if (hero.isEmpty()) {
                val movies = rows[HomeSection.POPULAR_MOVIES] ?: emptyList()
                val series = rows[HomeSection.POPULAR_SERIES] ?: emptyList()
                hero = movies.take(4).zip(series.take(4)).flatMap { listOf(it.first, it.second) }.filter { it.background != null }.take(6)
            }
            error = if (rows.isEmpty()) "Couldn't reach the catalogue. Check your connection and pull to refresh." else null
        } finally {
            isLoading = false
        }
    }

    suspend fun reload(sections: List<HomeSection>, trakt: TraktStore) {
        rows.clear()
        hero = emptyList()
        load(sections)
        loadTrakt(sections, trakt, force = true)
    }

    /** Trakt's trending and recommended rows, when Trakt is connected. */
    suspend fun loadTrakt(sections: List<HomeSection>, trakt: TraktStore, force: Boolean = false) {
        if (!trakt.isConnected) return
        for (section in sections.filter { it.traktList != null && (force || rows[it] == null) }) {
            val (list, kind) = section.traktList ?: continue
            runCatching { trakt.discover(list, kind) }.getOrNull()?.let { rows[section] = it }
        }
    }

    companion object { val shared = HomeModel() }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun HomeScreen() {
    val stores = Env.stores
    val router = Env.router
    val settings = stores.settings.observe()
    val library = stores.library.observe()
    val trakt = stores.trakt.observe()
    val upcoming = stores.upcoming.observe()
    stores.alerts.observe()
    stores.downloads.observe()
    val model = HomeModel.shared
    val scope = rememberCoroutineScope()
    val sections = settings.visibleHomeSections
    val metrics = CardMetrics.current()
    val attention = Attention(settings, library, trakt, upcoming)
    val heroFirst = sections.firstOrNull() == HomeSection.HERO && (model.hero.isNotEmpty() || model.isLoading)
    var refreshing by remember { mutableStateOf(false) }
    val list = rememberLazyListState()

    LaunchedEffect(sections) {
        model.load(sections)
        model.loadTrakt(sections, trakt)
    }
    LaunchedEffect(trakt.isConnected) { model.loadTrakt(sections, trakt) }
    ScrollToTop(AppTab.HOME, list)

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = maxWidth
        val height = maxHeight
        PullToRefreshBox(isRefreshing = refreshing, onRefresh = {
            scope.launch {
                refreshing = true
                model.reload(sections, trakt)
                upcoming.refresh(library, force = true)
                refreshing = false
            }
        }) {
            // Compose on a TV keeps the focused item near the top of a list, which pushed most of the
            // featured picture off screen when its Play button took focus. Home scrolls only as far as
            // the focused item needs.
            CompositionLocalProvider(LocalBringIntoViewSpec provides MinimalBringIntoView) {
                LazyColumn(state = list, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 40.dp),
                    verticalArrangement = Arrangement.spacedBy(30.dp)) {
                    if (!heroFirst) item {
                        Text("Home".tr(), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold,
                            modifier = Modifier.statusBarsPadding().padding(start = 20.dp, top = 8.dp))
                    }
                    for (section in sections) item(key = section.raw) { SectionView(section, model, metrics, attention, width, height) }
                    model.error?.let { error ->
                        item {
                            StateMessage("Offline", error, icon = Icons.Rounded.WifiOff, actionTitle = "Retry") {
                                scope.launch { model.reload(sections, trakt) }
                            }
                        }
                    }
                    if (sections.isEmpty()) item {
                        StateMessage("Home is empty", "Every section is hidden. Choose what Home shows in Settings.", icon = Icons.Rounded.CropFree,
                            actionTitle = "Home Screen Settings") { router.openSettings(SettingsPage.HOME_SCREEN) }
                    }
                }
            }
        }
        Row(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(end = 16.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ProfileSwitcher()
            Box {
                RoundIconButton(Icons.Rounded.Settings, "Settings") { router.openSettings() }
                if (Attention.settingsNeedAttention(settings, trakt, stores.alerts)) Box(Modifier.align(Alignment.TopEnd)) { AttentionDot() }
            }
        }
    }
}

@Composable
private fun SectionView(section: HomeSection, model: HomeModel, metrics: CardMetrics, attention: Attention, width: Dp, height: Dp) {
    val stores = Env.stores
    val router = Env.router
    val settings = stores.settings
    val library = stores.library
    val upcoming = stores.upcoming
    when (section) {
        HomeSection.HERO -> {
            val items = library.shown(model.hero, hidingWatched = false)
            val heroHeight = minOf(heroHeight(width), height * 0.66f)
            if (items.isNotEmpty()) HeroCarousel(items, width, heroHeight)
            else if (model.isLoading) Box(Modifier.fillMaxWidth().height(heroHeight).background(Theme.surface))
        }
        HomeSection.WAITING -> AttentionStrip(attention)
        HomeSection.CONTINUE_WATCHING -> if (library.continueWatching.isNotEmpty()) {
            ShelfRow("Continue Watching", library.continueWatching, key = { it.id }) { entry -> ContinueLink(entry, metrics.landscape) }
        }
        HomeSection.NEW_EPISODES -> {
            val fresh = upcoming.newEpisodes(library)
            val waiting = upcoming.unwatchedNew(library)
            if (fresh.isNotEmpty()) ShelfRow("New Episodes", fresh, key = { it.id }, subtitle = "Aired in the last two weeks") { entry ->
                NewEpisodeCard(entry, (waiting[entry.item.id]?.size ?: 1) - 1, metrics.landscape)
            }
        }
        HomeSection.MY_LIST -> if (library.watchlist.isNotEmpty()) {
            ShelfRow("My List", library.watchlist, key = { it.id }) { PosterLink(it, metrics.poster, menu = false) }
        }
        else -> {
            val items = model.rows[section]?.let { library.shown(it, settings.hideWatched) } ?: emptyList()
            if (items.isEmpty()) return
            if (section.traktList != null) {
                ShelfRow(section.title, items, key = { it.id }, subtitle = "From Trakt") { PosterLink(it, metrics.poster) }
            } else section.catalogue?.let { source ->
                ShelfRow(section.title, items, key = { it.id }, onSeeAll = {
                    router.push(Route.Grid(section.title, source.kind, source.catalog, source.genre))
                }) { PosterLink(it, metrics.poster) }
            }
        }
    }
}

@Composable
private fun ContinueLink(entry: PlaybackProgress, width: Dp) {
    val stores = Env.stores
    val router = Env.router
    var expanded by remember { mutableStateOf(false) }
    Box {
        ContinueCard(entry, width, onLongClick = { expanded = true }) { stores.playback.play(entry.target, stores.settings, stores.library) }
        DropdownMenu(expanded, { expanded = false }) {
            MenuItem("Go to Title", Icons.Rounded.Info) { router.push(Route.Title(entry.item)); expanded = false }
            MenuItem("Mark as Watched", Icons.Rounded.CheckCircle) { stores.library.markWatched(entry.target); expanded = false }
            MenuItem("Remove", Icons.Rounded.Close, destructive = true) { stores.library.clearProgress(entry); expanded = false }
        }
    }
}

@Composable
private fun NewEpisodeCard(entry: CalendarEpisode, more: Int, width: Dp) {
    val stores = Env.stores
    val router = Env.router
    var expanded by remember { mutableStateOf(false) }
    Box {
        BannerCard(entry.item, width, image = entry.episode.thumbnail ?: entry.item.background,
            eyebrow = "New · %s".tr(entry.episode.code) + if (more > 0) " · " + "+%d more".tr(more) else "", title = entry.item.name,
            subtitle = "${entry.episode.title} · ${relativeDay(entry.date)}", onLongClick = { expanded = true }) {
            stores.playback.play(entry.target, stores.settings, stores.library)
        }
        DropdownMenu(expanded, { expanded = false }) {
            MenuItem("Go to Series", Icons.Rounded.Info) { router.push(Route.Title(entry.item)); expanded = false }
            MenuItem("Choose Source", Icons.AutoMirrored.Rounded.List) { stores.playback.chooseSource(entry.target); expanded = false }
            MenuItem("Mark as Watched", Icons.Rounded.CheckCircle) { stores.library.markWatched(entry.target); expanded = false }
        }
    }
}

/** "today", "yesterday", "3 days ago", "in 2 days": a date said the way people say it. */
fun relativeDay(date: java.time.Instant): String =
    android.text.format.DateUtils.getRelativeTimeSpanString(date.toEpochMilli(), System.currentTimeMillis(), android.text.format.DateUtils.DAY_IN_MILLIS).toString()

/** Taller on narrow screens (poster-like), wider and shallower when the window is wide. */
fun heroHeight(width: Dp): Dp = if (width < 600.dp) minOf(width * 1.25f, 620.dp) else minOf(maxOf(width * 0.48f, 420.dp), 620.dp)

@Composable
fun HeroCarousel(items: List<MediaItem>, width: Dp, height: Dp) {
    val stores = Env.stores
    val router = Env.router
    val settings = stores.settings.observe()
    val library = stores.library.observe()
    val playback = stores.playback.observe()
    val pager = rememberPagerState { items.size }
    var visible by remember { mutableStateOf(true) }
    LifecycleResumeEffect(Unit) { visible = true; onPauseOrDispose { visible = false } }
    val reduceMotion = android.provider.Settings.Global.getFloat(app.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    val autoAdvance = settings.heroAutoAdvance && !reduceMotion && visible && playback.session == null
    // Gentle auto-advance; any swipe simply moves the position it continues from.
    LaunchedEffect(items.map { it.id }, autoAdvance) {
        if (!autoAdvance) return@LaunchedEffect
        while (true) {
            delay(7000)
            if (items.isEmpty()) return@LaunchedEffect
            pager.animateScrollToPage((pager.currentPage + 1) % items.size)
        }
    }
    val wide = width >= 600.dp
    Box(Modifier.fillMaxWidth().height(height)) {
        HorizontalPager(pager, Modifier.fillMaxSize()) { page ->
            val item = items[page]
            Box(Modifier.fillMaxSize()) {
                RemoteImage(if (wide) item.background ?: item.poster else item.poster ?: item.background, Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.35f to Color.Transparent, 0.72f to Theme.background.copy(alpha = 0.7f), 1f to Theme.background)))
                if (wide) Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Theme.background.copy(alpha = 0.8f), 0.5f to Color.Transparent)))
                Column(Modifier.align(if (wide) Alignment.BottomStart else Alignment.BottomCenter).padding(horizontal = if (wide) 48.dp else 20.dp).padding(bottom = 34.dp),
                    horizontalAlignment = if (wide) Alignment.Start else Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    TitleLogo(item, if (wide) 110.dp else 84.dp, Modifier.widthIn(max = if (wide) 420.dp else width * 0.75f))
                    Text(heroSubtitle(item), style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, textAlign = TextAlign.Center)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (item.kind == MediaKind.MOVIE) PillButton("Play".tr(), Icons.Rounded.PlayArrow, prominent = true) {
                            stores.playback.play(PlaybackTarget(item), settings, library)
                        }
                        PillButton((if (item.kind == MediaKind.MOVIE) "Details" else "Episodes").tr(), Icons.Rounded.Info) { router.push(Route.Title(item)) }
                        val listed = library.isInWatchlist(item)
                        RoundIconButton(if (listed) Icons.Rounded.Check else Icons.Rounded.Add, if (listed) "Remove from My List" else "Add to My List") {
                            library.toggleWatchlist(item)
                        }
                    }
                }
            }
        }
        Row(Modifier.align(Alignment.BottomCenter).padding(bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items.indices.forEach { index ->
                val selected = index == pager.currentPage
                val dotWidth by animateDpAsState(if (selected) 18.dp else 6.dp, label = "dot")
                Box(Modifier.width(dotWidth).height(6.dp).clip(CircleShape).background(if (selected) Color.White else Color.White.copy(alpha = 0.3f)))
            }
        }
    }
}

fun heroSubtitle(item: MediaItem) = (listOf(item.kind.singular.tr()) + listOfNotNull(item.year) + item.genres.take(2)).joinToString(" · ")

/** A round glass button with an icon, like iOS's toolbar buttons. */
@Composable
fun RoundIconButton(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, modifier: Modifier = Modifier, tint: Color = Color.White, onClick: () -> Unit) {
    Box(modifier.size(44.dp).glass(CircleShape).focusCard(CircleShape, onClick), contentAlignment = Alignment.Center) {
        Icon(icon, description.tr(), tint = tint)
    }
}

/** Home's "Waiting on You" row: one card per item, each opening where it can be dealt with. */
@Composable
fun AttentionStrip(attention: Attention) {
    val router = Env.router
    if (attention.items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Waiting on You".tr(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            if (attention.badgeCount > 0) { Spacer(Modifier.width(8.dp)); AttentionDot() }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(attention.items, key = { it.id }) { item ->
                Row(Modifier.width(280.dp).heightIn(min = 72.dp).glass(RoundedCornerShape(18.dp)).focusCard(RoundedCornerShape(18.dp), {
                    when (val action = item.action) {
                        Attention.Action.Setup -> router.openSetup()
                        is Attention.Action.Settings -> router.openSettings(action.page)
                        Attention.Action.Calendar -> router.select(AppTab.CALENDAR)
                    }
                }).padding(12.dp)) {
                    Box(Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(item.tint.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
                        Icon(when (item.icon) {
                            Attention.Icons.SETUP -> Icons.Rounded.AutoAwesome
                            Attention.Icons.KEY -> Icons.Rounded.Key
                            Attention.Icons.SYNC -> Icons.Rounded.Sync
                            Attention.Icons.NEW -> Icons.Rounded.Tv
                            Attention.Icons.TODAY -> Icons.Rounded.CalendarMonth
                        }, null, tint = item.tint)
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(item.title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 1)
                            if (item.needsYou) { Spacer(Modifier.width(6.dp)); AttentionDot(7.dp) }
                        }
                        Text(item.detail, style = MaterialTheme.typography.bodySmall, color = Theme.secondaryText, maxLines = 2)
                    }
                }
            }
        }
    }
}

/** Scrolls a tab's list back to the top when its tab is chosen again. */
@Composable
fun ScrollToTop(tab: AppTab, state: androidx.compose.foundation.lazy.LazyListState) {
    val router = Env.router
    LaunchedEffect(router.scrollToTop) {
        if (router.scrollToTop == tab) { state.animateScrollToItem(0); router.scrollToTop = null }
    }
}

/** Scrolls just enough to show the focused item, as touch lists do, instead of TV's pinned focus. */
@OptIn(ExperimentalFoundationApi::class)
private val MinimalBringIntoView = object : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        val end = offset + size
        return when {
            offset >= 0f && end <= containerSize -> 0f
            offset < 0f || size > containerSize -> offset
            else -> end - containerSize
        }
    }
}
