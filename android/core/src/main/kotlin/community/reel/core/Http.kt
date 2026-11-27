package community.reel.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.JsonElement
import okhttp3.Cache
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.URLEncoder
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** A server answered outside 2xx. */
class HttpStatusException(val code: Int, val url: String) : IOException("The server ${hostOf(url)} answered $code.")

class InvalidUrlException(val text: String) : IOException("That address isn't valid.")

fun hostOf(url: String): String = try { java.net.URI(url).host ?: "" } catch (_: Exception) { "" }

object HTTP {
    val userAgent: String get() = "${AppConfig.NAME}/${AppConfig.version}"

    /** Set by the app: answers every request from fixed data (`-ReelMock` on iOS). */
    @Volatile var mock: Interceptor? = null
    @Volatile var cacheFolder: File? = null

    val client: OkHttpClient by lazy {
        val builder = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .followRedirects(true)
            .addInterceptor { chain ->
                val request = chain.request()
                val withHeaders = request.newBuilder().apply {
                    if (request.header("User-Agent") == null) header("User-Agent", userAgent)
                    if (request.header("Accept") == null) header("Accept", "application/json")
                }.build()
                chain.proceed(withHeaders)
            }
        cacheFolder?.let { builder.cache(Cache(File(it, "http"), 128L shl 20)) }
        mock?.let { builder.addInterceptor(it) }
        builder.build()
    }

    /** One that doesn't follow redirects: resolving a debrid link reads the redirect itself. */
    val noRedirects: OkHttpClient by lazy { client.newBuilder().followRedirects(false).followSslRedirects(false).readTimeout(90, TimeUnit.SECONDS).build() }

    /** The body of a GET as text, with up to two retries for the failures that usually pass. */
    suspend fun getText(url: String, retries: Int = 2): String {
        var attempt = 0
        while (true) {
            try {
                val request = Request.Builder().url(parse(url)).build()
                return client.newCall(request).await().use { response ->
                    if (!response.isSuccessful) throw HttpStatusException(response.code, url)
                    response.body.string()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (attempt >= retries || !isTransient(e)) throw e
                attempt += 1
                delay(attempt * 700L)
            }
        }
    }

    suspend fun getJson(url: String, retries: Int = 2): JsonElement =
        parseJson(getText(url, retries)) ?: throw IOException("The server's answer couldn't be read.")

    fun parse(text: String): okhttp3.HttpUrl =
        text.trim().toHttpUrlOrNull() ?: throw InvalidUrlException(text)

    fun isTransient(error: Throwable): Boolean {
        if (error is CancellationException) return false
        if (error is HttpStatusException) return error.code == 429 || error.code in 500..599
        return error is SocketTimeoutException || error is ConnectException || error is UnknownHostException ||
            (error is IOException && error.message?.contains("reset", ignoreCase = true) == true)
    }

    /** Whether an error means the device has no usable network, rather than a server at fault. */
    fun isOffline(error: Throwable): Boolean {
        var e: Throwable? = error
        while (e != null) {
            if (e is UnknownHostException || e is ConnectException || e is SocketTimeoutException ||
                e is java.net.NoRouteToHostException) return true
            e = e.cause
        }
        return false
    }

    /** Percent-encodes a value for a Stremio-style path segment (`genre=Sci-Fi`). */
    fun pathValue(text: String): String =
        URLEncoder.encode(text, "UTF-8").replace("+", "%20").replace("%2D", "-").replace("%2E", ".").replace("%7E", "~")

    /** Encodes an id for a path: keeps `:` (episode ids), encodes `/`. */
    fun idValue(text: String): String = pathValue(text).replace("%3A", ":")

    fun queryValue(text: String): String = URLEncoder.encode(text, "UTF-8")
}

suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = continuation.resume(response)
        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isCancelled) continuation.resumeWithException(e)
        }
    })
}

/**
 * Removes credentials from text that may be shown or shared: Torrentio paths carry the debrid key
 * (`realdebrid=KEY`), resolve links carry it as a path segment, some services take `apikey=`.
 */
object Redact {
    private val patterns = listOf(
        Regex("((?:realdebrid|alldebrid|premiumize|torbox|debridlink|easydebrid|offcloud|putio)(?:=|%3D))[^|/%&\\s]+", RegexOption.IGNORE_CASE) to "$1•••",
        Regex("(/resolve/[a-z]+/)[^/\\s]+", RegexOption.IGNORE_CASE) to "$1•••",
        Regex("((?:apikey|api_key|token|key)=)[^&\\s]+", RegexOption.IGNORE_CASE) to "$1•••",
        Regex("(Bearer\\s+)[A-Za-z0-9._-]+", RegexOption.IGNORE_CASE) to "$1•••",
    )

    fun text(text: String): String = patterns.fold(text) { acc, (regex, replacement) -> regex.replace(acc, replacement) }
}

/** A readable message for any error, with no key in sight. */
fun Throwable.readable(): String = Redact.text(message ?: javaClass.simpleName)

/** A request's status and body, for services that read either. */
data class HttpAnswer(val status: Int, val body: String, val headers: okhttp3.Headers) {
    val ok: Boolean get() = status in 200..299
}

suspend fun HTTP.send(request: Request, client: OkHttpClient = this.client): HttpAnswer =
    client.newCall(request).await().use { HttpAnswer(it.code, it.body.string(), it.headers) }

private val jsonMedia = "application/json; charset=utf-8".toMediaTypeOrNullCompat()

fun String.toMediaTypeOrNullCompat(): okhttp3.MediaType? = okhttp3.MediaType.Companion.run { this@toMediaTypeOrNullCompat.toMediaTypeOrNull() }

fun jsonBody(text: String): okhttp3.RequestBody = okhttp3.RequestBody.Companion.run { text.toRequestBody(jsonMedia) }

fun formBody(text: String): okhttp3.RequestBody =
    okhttp3.RequestBody.Companion.run { text.toRequestBody("application/x-www-form-urlencoded".toMediaTypeOrNullCompat()) }
