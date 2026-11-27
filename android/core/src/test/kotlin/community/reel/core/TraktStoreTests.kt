package community.reel.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Interceptor
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** The queue of changes for Trakt, sent against a local server that stands in for api.trakt.tv. */
class TraktStoreTests {
    private val server = MockWebServer()
    private val posts = AtomicInteger()
    private val single = Executors.newSingleThreadExecutor().asCoroutineDispatcher()

    @Before fun setUp() {
        freshPlatform()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.method == "POST") { posts.incrementAndGet(); Thread.sleep(150) }
                return MockResponse.Builder().code(201).body("{}").build()
            }
        }
        server.start()
        // Every request to Trakt goes to the local server instead.
        HTTPTestHook.redirect(server.url("/").toString())
        Platform.scope = CoroutineScope(SupervisorJob() + single)
        Platform.secrets.write(ReelJson.encodeToString(Trakt.Credentials("id", "secret")), "trakt.credentials")
        Platform.secrets.write(ReelJson.encodeToString(Trakt.Token("a", "r", Instant.now().plusSeconds(90 * 86400))), "trakt.token")
    }

    @After fun tearDown() { server.close() }

    /** Two flushes at once used to send the head twice and drop the next change unsent. */
    @Test fun concurrentFlushesSendEveryChangeOnce() = runBlocking {
        val store = withContext(single) { TraktStore() }
        val library = withContext(single) { Library(JSONFile.file("library.json")).also { store.attach(it) } }
        withContext(single) {
            library.toggleWatchlist(MediaItem("tt1", MediaKind.MOVIE, "One"))
            library.toggleWatchlist(MediaItem("tt2", MediaKind.MOVIE, "Two"))
            library.toggleWatchlist(MediaItem("tt3", MediaKind.MOVIE, "Three"))
        }
        withContext(single) { listOf(async { store.flush() }, async { store.flush() }).awaitAll() }
        assertEquals(0, withContext(single) { store.pending.size })
        assertEquals(3, posts.get())
    }
}

/** Points the shared HTTP client at a test server. */
object HTTPTestHook {
    fun redirect(base: String) {
        val target = okhttp3.HttpUrl.Companion.run { base.toHttpUrl() }
        HTTP.mock = Interceptor { chain ->
            val original = chain.request()
            val url = original.url.newBuilder().scheme(target.scheme).host(target.host).port(target.port).build()
            chain.proceed(original.newBuilder().url(url).build())
        }
    }
}
