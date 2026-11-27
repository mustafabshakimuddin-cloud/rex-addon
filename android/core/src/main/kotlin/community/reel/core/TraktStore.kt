package community.reel.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import java.io.File
import java.time.Instant

/** A change made here that Trakt still has to hear about. Kept on disk until Trakt accepts it. */
@Serializable
sealed class TraktChange {
    @Serializable @kotlinx.serialization.SerialName("watchlist")
    data class Watchlist(val item: MediaItem, val added: Boolean) : TraktChange()
    @Serializable @kotlinx.serialization.SerialName("history")
    data class History(val targets: List<PlaybackTarget>, val watched: Boolean, val at: Date) : TraktChange()
    @Serializable @kotlinx.serialization.SerialName("rating")
    data class Rating(val item: MediaItem, val rating: Int) : TraktChange()
}

/**
 * Keeps the library in step with a Trakt account: the watchlist and watched history both ways,
 * resume points in, and scrobbles out while something plays. Signing in uses Trakt's device flow.
 * Trakt needs an API application of the user's own, because a sideloaded app cannot ship a shared
 * secret safely.
 */
class TraktStore : Observed() {
    sealed class SignIn {
        data object Idle : SignIn()
        data class Waiting(val code: String, val url: String) : SignIn()
        data class Failed(val message: String) : SignIn()
    }

    var credentials: Trakt.Credentials? = null; private set
    var isConnected = false; private set
    var signIn: SignIn = SignIn.Idle; private set
    var lastSync: Instant? = null; private set
    var syncError: String? = null; private set
    var isSyncing = false; private set
    /** Changes waiting to reach Trakt. */
    var pending: List<TraktChange> = emptyList(); private set

    private var token: Trakt.Token? = null
    private var library: Library? = null
    private var signInJob: Job? = null
    /** The one refresh in flight: Trakt's refresh tokens work once. */
    private var refreshTask: Deferred<Trakt.Token?>? = null
    private var flushJob: Job? = null
    /** The send in progress: two at once would both send the head of the queue, then each remove one entry. */
    private var sendTask: Deferred<Unit>? = null
    /** Moves on every profile switch, so work begun for one account never lands in another's. */
    private var generation = 0
    private var queueWriter = SnapshotWriter(JSONFile.file("trakt-queue.json"))
    private var profile = Profile.default
    private val defaults get() = Platform.defaults
    private val scope get() = Platform.scope

    private val tokenKey get() = profile.key("trakt.token")
    private val activitiesKey get() = profile.key("trakt.lastActivities")

    init {
        credentials = Platform.secrets.read(CREDENTIALS)?.let { runCatching { ReelJson.decodeFromString<Trakt.Credentials>(it) }.getOrNull() }
        token = Platform.secrets.read(Profile.default.key("trakt.token"))?.let { runCatching { ReelJson.decodeFromString<Trakt.Token>(it) }.getOrNull() }
        isConnected = credentials != null && token != null
        pending = readQueue(JSONFile.file("trakt-queue.json"))
    }

    private fun readQueue(file: File) = JSONFile.read(file) { it.lossyList<TraktChange>() } ?: emptyList()

    /** Signs in as another profile's Trakt account, or none: its token, its queue, a fresh sync. */
    fun switchProfile(profile: Profile) {
        saveQueue()
        queueWriter.waitUntilWritten()
        signInJob?.cancel()
        refreshTask = null
        sendTask = null
        flushJob?.cancel()
        // A sync still running for the previous profile finds the generation moved and stops;
        // this profile's own sync must not wait for it.
        generation += 1
        isSyncing = false
        this.profile = profile
        queueWriter = SnapshotWriter(profile.file("trakt-queue"))
        pending = readQueue(profile.file("trakt-queue"))
        token = Platform.secrets.read(tokenKey)?.let { runCatching { ReelJson.decodeFromString<Trakt.Token>(it) }.getOrNull() }
        isConnected = credentials != null && token != null
        signIn = SignIn.Idle
        syncError = null
        lastSync = null
        changed()
        if (isConnected) scope.launch { sync() }
    }

    fun attach(library: Library) {
        this.library = library
        library.onWatchlistChange = { item, included -> enqueue(TraktChange.Watchlist(item, included)) }
        library.onWatchedChange = { targets, watched -> enqueue(TraktChange.History(targets, watched, now())) }
        if (isConnected) scope.launch { sync() }
    }

    // Connecting

    fun connect(clientID: String, clientSecret: String) {
        val credentials = Trakt.Credentials(clientID.trim(), clientSecret.trim())
        if (credentials.clientID.isEmpty() || credentials.clientSecret.isEmpty()) {
            signIn = SignIn.Failed("Enter both the Client ID and the Client Secret.")
            changed()
            return
        }
        this.credentials = credentials
        Platform.secrets.write(ReelJson.encodeToString(credentials), CREDENTIALS)
        signInJob?.cancel()
        signInJob = scope.launch { runDeviceFlow(credentials) }
    }

    fun cancelSignIn() {
        signInJob?.cancel()
        signIn = SignIn.Idle
        changed()
    }

    fun disconnect() {
        signInJob?.cancel()
        token = null
        isConnected = false
        signIn = SignIn.Idle
        syncError = null
        pending = emptyList()
        saveQueue()
        defaults.remove(activitiesKey)
        Platform.secrets.write("", tokenKey)
        library?.forgetTraktState()
        changed()
    }

    private suspend fun runDeviceFlow(credentials: Trakt.Credentials) {
        try {
            val code = Trakt.deviceCode(credentials)
            signIn = SignIn.Waiting(code.userCode, code.verificationURL)
            changed()
            var interval = maxOf(code.interval, 5)
            val deadline = now().plusSeconds(code.expiresIn.toLong())
            while (now().isBefore(deadline)) {
                delay(interval * 1000L)
                when (val result = Trakt.poll(code, credentials)) {
                    Trakt.PollResult.Pending -> continue
                    Trakt.PollResult.SlowDown -> interval += 5
                    is Trakt.PollResult.Success -> {
                        store(result.token)
                        signIn = SignIn.Idle
                        syncError = null
                        defaults.remove(activitiesKey)
                        changed()
                        sync()
                        return
                    }
                    is Trakt.PollResult.Failed -> {
                        signIn = SignIn.Failed(result.message)
                        changed()
                        return
                    }
                }
            }
            signIn = SignIn.Failed("The code expired. Start again.")
            changed()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            signIn = SignIn.Failed(e.readable())
            changed()
        }
    }

    // Syncing

    /**
     * Sends what is waiting, then pulls the watchlist, resume points and watched history, skipping
     * the parts Trakt says haven't changed since the last sync.
     */
    suspend fun sync(force: Boolean = false) {
        val library = library ?: return
        val credentials = credentials ?: return
        if (isSyncing) return
        val generation = this.generation
        val activitiesKey = this.activitiesKey
        isSyncing = true
        changed()
        try {
            val token = validToken() ?: return
            if (generation != this.generation) return
            flush()
            if (generation != this.generation) return
            try {
                val activities = Trakt.lastActivities(credentials, token)
                val previous: Map<String, String> = if (force) emptyMap() else
                    defaults.string(activitiesKey)?.let { runCatching { ReelJson.decodeFromString<Map<String, String>>(it) }.getOrNull() } ?: emptyMap()
                fun changedPart(key: String) = previous[key] == null || previous[key] != activities[key]

                val (list, resumes, history) = coroutineScope {
                    val list = async { if (changedPart("watchlist")) Trakt.watchlist(credentials, token) else null }
                    val resumes = async { if (changedPart("playback")) Trakt.playback(credentials, token) else null }
                    val history = async { if (changedPart("watched")) Trakt.watched(credentials, token) else null }
                    Triple(list.await(), resumes.await(), history.await())
                }
                // Another profile was chosen meanwhile: this account's lists aren't its business.
                if (generation != this.generation) return

                list?.let { library.applyTraktWatchlist(it, pendingWatchlist(true), pendingWatchlist(false)) }
                resumes?.forEach { library.importResume(it.target, it.fraction, it.runtimeSeconds, it.pausedAt) }
                history?.let { library.setExternalWatched(it.first, it.second) }
                defaults.putString(activitiesKey, ReelJson.encodeToString(activities))
                lastSync = now()
                syncError = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation != this.generation) return
                syncError = describe(e)
                AppLog.record("Trakt sync", e)
            }
        } finally {
            if (generation == this.generation) {
                isSyncing = false
                changed()
            }
        }
    }

    private fun pendingWatchlist(added: Boolean): Set<String> =
        pending.mapNotNull { (it as? TraktChange.Watchlist)?.takeIf { change -> change.added == added }?.item?.id }.toSet()

    // Changes

    private fun enqueue(change: TraktChange) {
        if (credentials == null || !isConnected) return
        // A later change to the same title's watchlist entry replaces the earlier one.
        if (change is TraktChange.Watchlist) pending = pending.filterNot { it is TraktChange.Watchlist && it.item.id == change.item.id }
        pending = pending + change
        saveQueue()
        changed()
        scheduleFlush()
    }

    private fun scheduleFlush() {
        flushJob?.cancel()
        flushJob = scope.launch {
            // A short pause gathers a burst of changes (a season marked episode by episode).
            delay(1500)
            if (isActive) flush()
        }
    }

    /**
     * Sends waiting changes in order. A change Trakt refuses outright is dropped; a network
     * failure stops the run, to be tried again at the next sync. One run at a time; a second
     * caller waits for it. The run reads the queue live.
     */
    suspend fun flush() {
        sendTask?.let { it.await(); return }
        val task = scope.async { send() }
        sendTask = task
        try { task.await() } finally { if (sendTask === task) sendTask = null }
    }

    private suspend fun send() {
        val generation = this.generation
        val credentials = credentials ?: return
        if (pending.isEmpty()) return
        val token = validToken() ?: return
        if (generation != this.generation) return
        while (generation == this.generation) {
            val change = pending.firstOrNull() ?: break
            try {
                when (change) {
                    is TraktChange.Watchlist -> Trakt.setWatchlist(change.item, change.added, credentials, token)
                    is TraktChange.History -> Trakt.history(change.targets, change.watched, change.at, credentials, token)
                    is TraktChange.Rating -> Trakt.rate(change.item, change.rating, credentials, token)
                }
                settle(change, generation)
            } catch (e: Trakt.TraktException) {
                if (e.code in 400..499 && e.code != 401 && e.code != 429) settle(change, generation)  // Trakt won't ever take it
                else break
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                break
            }
        }
        if (generation == this.generation) { saveQueue(); changed() }
    }

    /** Takes a sent change off the queue. Found by value: a newer change may have replaced it. */
    private fun settle(change: TraktChange, generation: Int) {
        if (generation != this.generation) return
        val index = pending.indexOf(change)
        if (index >= 0) pending = pending.toMutableList().apply { removeAt(index) }
    }

    /** Rates a title on Trakt, from 1 to 10. */
    fun rate(item: MediaItem, rating: Int) = enqueue(TraktChange.Rating(item, rating))

    /**
     * Tells Trakt what is playing. Called by the player on start, pause and exit. A stop that can't
     * be sent, near the end, is kept as a watched mark instead.
     */
    fun scrobble(action: Trakt.ScrobbleAction, target: PlaybackTarget, position: Double, duration: Double) {
        val credentials = credentials
        if (!isConnected || credentials == null || duration <= 0) return
        val progress = position / duration * 100
        scope.launch {
            val token = validToken() ?: return@launch
            try {
                Trakt.scrobble(action, target, progress, credentials, token)
            } catch (e: Trakt.TraktException) {
                // 409: Trakt already recorded this play a moment ago; marking it again would count twice.
                if (e.code != 409 && action == Trakt.ScrobbleAction.STOP && progress >= 80) enqueue(TraktChange.History(listOf(target), true, now()))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (action == Trakt.ScrobbleAction.STOP && progress >= 80) enqueue(TraktChange.History(listOf(target), true, now()))
            }
        }
    }

    // Lists

    suspend fun discover(list: Trakt.Discovery, kind: MediaKind): List<MediaItem> {
        val credentials = credentials ?: return emptyList()
        val token = if (list.needsSignIn) validToken() else null
        if (list.needsSignIn && token == null) return emptyList()
        return Trakt.discover(list, kind, credentials, token)
    }

    /** Titles related to this one, from Trakt; needs only the API application, not a sign-in. */
    suspend fun related(item: MediaItem): List<MediaItem> = credentials?.let { Trakt.related(item, it) } ?: emptyList()

    suspend fun lists(): List<Trakt.TraktList> {
        val credentials = credentials ?: return emptyList()
        val token = validToken() ?: return emptyList()
        return Trakt.lists(credentials, token)
    }

    suspend fun items(list: Trakt.TraktList): List<MediaItem> {
        val credentials = credentials ?: return emptyList()
        val token = validToken() ?: return emptyList()
        return Trakt.listItems(list, credentials, token)
    }

    // Token

    private suspend fun validToken(): Trakt.Token? {
        val token = token ?: return null
        val credentials = credentials ?: return null
        if (!token.isExpiring) return token
        refreshTask?.let { return it.await() }
        val generation = this.generation
        val tokenKey = this.tokenKey
        val task = scope.async {
            try {
                val fresh = Trakt.refresh(token, credentials)
                // Saved under the account it belongs to, even if another profile is in use now.
                Platform.secrets.write(ReelJson.encodeToString(fresh), tokenKey)
                if (generation == this@TraktStore.generation) { this@TraktStore.token = fresh; isConnected = true; changed() }
                fresh
            } catch (e: Trakt.TraktException) {
                if (e.code == 400 || e.code == 401) {
                    syncError = "Trakt sign-in expired. Connect again in Settings."
                    changed()
                    null
                } else fallback(token, e)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fallback(token, e)
            }
        }
        refreshTask = task
        val result = task.await()
        if (generation == this.generation) refreshTask = null
        return result
    }

    /** Offline or Trakt down: the old token still works until it actually expires. */
    private fun fallback(token: Trakt.Token, error: Exception): Trakt.Token? {
        if (token.expiresAt.isAfter(now())) return token
        syncError = describe(error)
        changed()
        return null
    }

    private fun describe(error: Throwable) =
        if (HTTP.isOffline(error)) "Couldn't reach Trakt. It will sync when you're back online." else error.readable()

    private fun store(token: Trakt.Token) {
        this.token = token
        isConnected = true
        Platform.secrets.write(ReelJson.encodeToString(token), tokenKey)
    }

    private fun saveQueue() {
        val snapshot = pending
        queueWriter.schedule(0.2) { ReelJson.encodeToString(snapshot) }
    }

    companion object {
        private const val CREDENTIALS = "trakt.credentials"
    }
}
