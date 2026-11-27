package community.reel.app

import android.app.Application
import android.content.pm.PackageManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.memory.MemoryCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import community.reel.app.system.DeviceCapabilities
import community.reel.app.system.DownloadService
import community.reel.app.system.KeystoreSecrets
import community.reel.app.system.MockPictures
import community.reel.app.system.Notifier
import community.reel.app.system.PreferencesStore
import community.reel.app.system.Widgets
import community.reel.core.AppConfig
import community.reel.core.AppStores
import community.reel.core.HTTP
import community.reel.core.MockServer
import community.reel.core.Platform
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import okio.Path.Companion.toOkioPath

class ReelApplication : Application(), SingletonImageLoader.Factory {
    /** Built on first use, after the launch options (mock mode) are known. */
    val stores: AppStores by lazy { buildStores() }
    /** Whether a screen of the app is showing. */
    @Volatile var isForeground = false
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        AppConfig.version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "1.0"
        Platform.defaults = PreferencesStore(this)
        Platform.secrets = KeystoreSecrets(this)
        Platform.folder = filesDir
        Platform.main = Dispatchers.Main.immediate
        Platform.scope = MainScope()
        Platform.device = runCatching { DeviceCapabilities.read(this) }.getOrDefault(Platform.device)
        Platform.languageCode = resources.configuration.locales[0].language
        HTTP.cacheFolder = cacheDir
        Notifier.createChannels(this)
    }

    /** Turns on fixed answers for every request (CI screenshots), before anything is fetched. */
    fun useMockData() {
        if (HTTP.mock != null) return
        MockServer.picture = MockPictures::png
        HTTP.mock = MockServer
    }

    private fun buildStores(): AppStores {
        val stores = AppStores()
        stores.onDownloadFinished = { Notifier.downloadFinished(this, it) }
        stores.onDownloadEnded = { item, _ -> Notifier.downloadEnded(this, item) }
        // The service that keeps downloads running starts with the first one and stops after the last.
        Platform.scope.launch {
            var running = false
            stores.downloads.changes.collect {
                val active = stores.downloads.active.isNotEmpty()
                if (active && !running) DownloadService.update(this@ReelApplication, stores)
                running = active
            }
        }
        stores.downloads.onProgress = { item, speed -> Notifier.downloadProgress(this, item, speed) }
        stores.downloads.networkAllowed = { item -> NetworkGate.allowed(this, item.allowsCellular ?: false) }
        stores.playback.verifier = { url -> community.reel.app.player.SourceVerifier.verify(this, url) }
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) { isForeground = true; stores.becameActive() }
            override fun onStop(owner: LifecycleOwner) {
                isForeground = false
                stores.wentToBackground()
                Platform.scope.launch { Widgets.publish(this@ReelApplication, stores) }
                if (stores.settings.notifyNewEpisodes) Notifier.scheduleRefresh(this@ReelApplication)
            }
        })
        return stores
    }

    override fun newImageLoader(context: PlatformContext): ImageLoader = ImageLoader.Builder(context)
        // The app's own client, so mock mode answers pictures too and the cache is shared.
        .components { add(OkHttpNetworkFetcherFactory(callFactory = { HTTP.client })) }
        .memoryCache { MemoryCache.Builder().maxSizePercent(context, 0.2).build() }
        .diskCache { DiskCache.Builder().directory(cacheDir.resolve("images").toOkioPath()).maxSizeBytes(256L shl 20).build() }
        .crossfade(250)
        .build()

    val isTelevision: Boolean get() = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)

    companion object {
        lateinit var instance: ReelApplication
            private set
    }
}

/** Whether the network in use may carry a download: Wi-Fi always, mobile data only when allowed. */
object NetworkGate {
    fun allowed(context: android.content.Context, cellular: Boolean): Boolean {
        if (cellular) return true
        val manager = context.getSystemService(android.net.ConnectivityManager::class.java)
        return !manager.isActiveNetworkMetered
    }
}
