package community.reel.app.ui

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import community.reel.core.AppStores
import community.reel.core.MediaItem
import community.reel.core.PlaybackTarget

@Composable fun CalendarScreen() = Text("Calendar")
@Composable fun LibraryScreen() = Text("Library")
@Composable fun SearchScreen() = Text("Search")
@Composable fun PersonScreen(name: String) = Text(name)
@Composable fun ListDetailScreen(route: ListRoute) = Text("List")
@Composable fun DownloadsScreen() = Text("Downloads")
@Composable fun HistoryScreen() = Text("History")
@Composable fun DebridCloudScreen() = Text("Cloud")
@Composable fun SettingsRoot() = Text("Settings")
@Composable fun SettingsPageScreen(page: SettingsPage) = Text(page.raw)
@Composable fun SetupScreen() = Text("Setup")
object ScreenshotTour { val isActive = false; fun start(screen: String, router: AppRouter, stores: AppStores) {} }
