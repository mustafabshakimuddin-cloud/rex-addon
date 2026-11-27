package community.reel.app.ui

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Campaign
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.PersonSearch
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import community.reel.core.Cinemeta
import community.reel.core.MediaItem
import community.reel.core.MediaKind
import community.reel.core.PlaybackErrors
import community.reel.core.TMDB
import community.reel.core.placeholder
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class SearchScope(val title: String) { ALL("All"), MOVIES("Movies"), SERIES("Series"), PEOPLE("People") }

/** A grid of posters inside a scrolling page. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PosterGrid(items: List<MediaItem>, modifier: Modifier = Modifier) {
    val metrics = CardMetrics.current()
    FlowRow(modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        for (item in items) PosterLink(item, metrics.poster)
    }
}

@Composable
fun SearchScreen() {
    val stores = Env.stores
    val router = Env.router
    val settings = stores.settings.observe()
    val library = stores.library.observe()
    var query by remember { mutableStateOf("") }
    var movies by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var series by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var searchError by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var scope by remember { mutableStateOf(SearchScope.ALL) }
    val list = rememberLazyListState()
    ScrollToTop(AppTab.SEARCH, list)
    val trimmed = query.trim()

    LaunchedEffect(router.pendingSearch) { router.pendingSearch?.let { query = it; router.pendingSearch = null } }
    LaunchedEffect(query, attempt) {
        searchError = null
        if (trimmed.isEmpty()) { movies = emptyList(); series = emptyList(); searching = false; return@LaunchedEffect }
        searching = true
        delay(350)  // debounce typing
        val (m, s) = coroutineScope {
            val m = async { runCatching { Cinemeta.search(trimmed, MediaKind.MOVIE) } }
            val s = async { runCatching { Cinemeta.search(trimmed, MediaKind.SERIES) } }
            m.await() to s.await()
        }
        movies = library.shown(m.getOrNull() ?: emptyList(), false)
        series = library.shown(s.getOrNull() ?: emptyList(), false)
        // Both failing is an error worth showing; one failing still shows the other's titles.
        if (m.isFailure && s.isFailure) searchError = PlaybackErrors.describe(m.exceptionOrNull()!!)
        searching = false
    }

    val metrics = CardMetrics.current()
    val linked = Regex("tt\\d{5,10}").find(trimmed)?.value?.let { id -> MediaItem.placeholder(id, if (series.any { it.id == id }) MediaKind.SERIES else MediaKind.MOVIE) }
    val top = (movies + series).firstOrNull { it.name.equals(trimmed, ignoreCase = true) } ?: movies.firstOrNull() ?: series.firstOrNull()

    Page("Search", large = true) {
        LazyColumn(state = list, contentPadding = PaddingValues(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            item {
                Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), singleLine = true, shape = RoundedCornerShape(16.dp),
                        placeholder = { Text("Titles, cast and directors".tr()) }, leadingIcon = { Icon(Icons.Rounded.Search, null) },
                        trailingIcon = { if (query.isNotEmpty()) IconButton({ query = "" }) { Icon(Icons.Rounded.Close, "Clear".tr()) } },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { settings.rememberSearch(query) }))
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(SearchScope.entries) { value -> Chip(value.title, selected = scope == value) { scope = value } }
                    }
                }
            }
            if (trimmed.isEmpty()) {
                if (settings.recentSearches.isNotEmpty()) item { RecentSearches { query = it } }
                item { LazyShelf("Popular Movies", MediaKind.MOVIE, Cinemeta.Catalog.POPULAR, null) }
                item { LazyShelf("Popular Series", MediaKind.SERIES, Cinemeta.Catalog.POPULAR, null) }
                return@LazyColumn
            }
            if (scope == SearchScope.PEOPLE) { item { PersonResults(trimmed) }; return@LazyColumn }
            linked?.let { link ->
                item {
                    Row(Modifier.padding(horizontal = 20.dp).fillMaxWidth().glass(RoundedCornerShape(18.dp)).focusCard(RoundedCornerShape(18.dp), { router.push(Route.Title(link)) })
                        .padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.Link, null); Spacer(Modifier.width(8.dp))
                        Text("Open %s from the link".tr(link.id), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            when {
                searchError != null && !searching -> item {
                    StateMessage("Couldn't search", searchError ?: "", icon = Icons.Rounded.WifiOff, actionTitle = "Retry") { attempt += 1 }
                }
                searching && movies.isEmpty() && series.isEmpty() -> item { Box(Modifier.fillMaxWidth().padding(top = 60.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Theme.accent) } }
                !searching && movies.isEmpty() && series.isEmpty() -> item {
                    StateMessage("No results", "Nothing matches “%s”. Try People to search by cast or director.".tr(query), icon = Icons.Rounded.Search,
                        actionTitle = "Search People") { scope = SearchScope.PEOPLE }
                }
            }
            if (scope == SearchScope.ALL && top != null) item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SectionHeader("Top Result", Modifier.padding(horizontal = 20.dp))
                    BannerCard(top, minOf(metrics.landscape * 1.5f, 520.dp), Modifier.padding(horizontal = 20.dp), eyebrow = top.kind.singular.tr(), subtitle = heroSubtitle(top)) {
                        settings.rememberSearch(query); router.push(Route.Title(top))
                    }
                }
            }
            if (scope != SearchScope.SERIES && movies.isNotEmpty()) item { ResultSection("Movies", movies) }
            if (scope != SearchScope.MOVIES && series.isNotEmpty()) item { ResultSection("Series", series) }
        }
    }
}

@Composable
private fun ResultSection(title: String, items: List<MediaItem>) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionHeader(title, Modifier.padding(horizontal = 20.dp), "%d found".tr(items.size))
        PosterGrid(items)
    }
}

/** Before anything is typed: recent searches. */
@Composable
private fun RecentSearches(pick: (String) -> Unit) {
    val settings = Env.stores.settings
    Column(Modifier.padding(horizontal = 20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Recent Searches".tr(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            TextButton({ settings.clearRecentSearches() }) { Text("Clear".tr()) }
        }
        for (recent in settings.recentSearches) {
            Row(Modifier.fillMaxWidth().focusCard(RoundedCornerShape(8.dp), { pick(recent) }).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.History, null, tint = Theme.secondaryText); Spacer(Modifier.width(10.dp))
                Text(recent, Modifier.weight(1f))
                IconButton({ settings.forgetSearch(recent) }) { Icon(Icons.Rounded.Close, "Remove %s".tr(recent), tint = Theme.secondaryText) }
            }
            HorizontalDivider(color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.08f))
        }
    }
}

/** A cast or crew member: what they're known for, then everything they're credited in. */
@Composable
fun PersonScreen(name: String) {
    var person by remember(name) { mutableStateOf<TMDB.Person?>(null) }
    var expanded by remember { mutableStateOf(false) }
    LaunchedEffect(name) { person = TMDB.person(name, details = true) }
    PushedPage(name) {
        LazyColumn(contentPadding = PaddingValues(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(26.dp)) {
            item {
                Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                    PersonPhoto(name, person?.photo, 84.dp)
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text(name, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, maxLines = 2)
                        val parts = listOfNotNull(person?.department ?: "Cast and crew".tr(), person?.birthday?.let { "Born %s".tr(it) }, person?.birthplace)
                        Text(parts.joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = Theme.secondaryText)
                    }
                }
            }
            person?.biography?.let { bio ->
                item {
                    Text(bio, style = MaterialTheme.typography.bodyMedium, maxLines = if (expanded) Int.MAX_VALUE else 5,
                        modifier = Modifier.padding(horizontal = 20.dp).focusCard(RoundedCornerShape(8.dp), { expanded = !expanded }))
                }
            }
            item { PersonResults(name) }
        }
    }
}

/** Known For and Filmography for a name; used by the person page and Search's People scope. */
@Composable
fun PersonResults(name: String) {
    var credits by remember(name) { mutableStateOf<Cinemeta.Credits?>(null) }
    var loading by remember(name) { mutableStateOf(true) }
    var error by remember(name) { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    val router = Env.router
    val metrics = CardMetrics.current()
    LaunchedEffect(name, attempt) {
        delay(300)  // debounce typing in Search
        loading = true
        runCatching { Cinemeta.person(name) }.onSuccess { credits = it; error = null }.onFailure { if (it !is kotlinx.coroutines.CancellationException) error = it.message }
        loading = false
    }
    val found = credits
    val all = found?.let { it.movies + it.series } ?: emptyList()
    Column(verticalArrangement = Arrangement.spacedBy(26.dp)) {
        when {
            loading && all.isEmpty() -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Theme.accent) }
            error != null && all.isEmpty() -> StateMessage("Couldn't search", error ?: "", actionTitle = "Retry") { attempt += 1 }
            all.isEmpty() || found == null -> StateMessage("No credits found", "Cinemeta lists nothing for “%s”.".tr(name), icon = Icons.Rounded.PersonSearch)
            else -> {
                LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item { StatusPill("%d movies".tr(found.movies.size), Icons.Rounded.Movie) }
                    item { StatusPill("%d series".tr(found.series.size), Icons.Rounded.Tv) }
                    if (found.directed.isNotEmpty()) item { StatusPill("Directed %d".tr(found.directed.size), Icons.Rounded.Campaign, Theme.accent) }
                }
                val knownFor = all.sortedByDescending { it.rating?.toDoubleOrNull() ?: 0.0 }.take(10)
                ShelfRow("Known For", knownFor, key = { it.id }) { PosterLink(it, metrics.poster) }
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Filmography", Modifier.padding(horizontal = 20.dp), "Newest first")
                    for (item in all.sortedByDescending { it.year ?: "" }) {
                        MediaRow(item, Modifier.padding(horizontal = 20.dp), onClick = { router.push(Route.Title(item)) }) {
                            if (item.id in found.directed) StatusPill("Director", tint = Theme.accent)
                        }
                    }
                }
            }
        }
    }
}
