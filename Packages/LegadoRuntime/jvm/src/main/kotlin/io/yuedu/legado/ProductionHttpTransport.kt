package io.yuedu.legado

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import kotlinx.coroutines.InternalCoroutinesApi
import okhttp3.Call
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody.Companion.asResponseBody
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okio.buffer
import okio.source
import org.brotli.dec.BrotliInputStream
import java.io.Closeable
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.Proxy
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.GZIPInputStream
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

/** Production JVM transport: owns only its session's calls and connection pool. */
@OptIn(InternalCoroutinesApi::class)
internal class ProductionHttpTransport(private val session: RuntimeSession) : Closeable {
    private data class InitialCookies(val host: String, val authored: String?)
    private val stopped = AtomicBoolean(false)
    private val active = ConcurrentHashMap.newKeySet<Call>()
    private val client = OkHttpClient.Builder()
        // Proxy rules are explicitly rejected by SourceJavaHost in this slice.
        // Do not enter unvalidated native system-proxy discovery on iOS.
        .proxy(Proxy.NO_PROXY)
        .connectTimeout(15, TimeUnit.SECONDS).writeTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS).callTimeout(60, TimeUnit.SECONDS)
        .followRedirects(true).followSslRedirects(true)
        // JSSE's ordinary trust store and OkHttp hostname validation are retained.
        // The Android application's unsafe SSLHelper is not installed on iOS.
        .addInterceptor(TransparentDecompression)
        .addNetworkInterceptor { chain ->
            var request = chain.request()
            if (session.source["enabledCookieJar"]?.takeIf { it.isJsonPrimitive }?.asBoolean == true) {
                val saved = session.cookies.getCookie(request.url.toString())
                val initial = request.tag(InitialCookies::class.java)
                val authored = initial?.takeIf { it.host == request.url.host }?.authored
                val cookie = mergeCookies(authored, saved)
                request = request.newBuilder().removeHeader("Cookie")
                    .apply { if (cookie.isNotEmpty()) header("Cookie", cookie) }.build()
            }
            val response = chain.proceed(request)
            if (session.source["enabledCookieJar"]?.takeIf { it.isJsonPrimitive }?.asBoolean == true) {
                response.headers.values("Set-Cookie").forEach { session.cookies.setCookie(response.request.url.toString(), it) }
            }
            response
        }.build()

    fun request(task: RuntimeTask, input: JsonObject): JsonObject {
        require(task.session === session) { "HTTP transport belongs to another session" }
        task.ensureActiveForRuntime()
        check(!stopped.get()) { "HTTP transport is closed" }
        val headers = Headers.Builder().apply {
            input["headers"].asJsonArray.forEach { value ->
                val entry = value.asJsonObject; add(entry["name"].asString, entry["value"].asString)
            }
        }.build()
        val method = input["method"].asString
        val bytes = input["bodyBase64"]?.takeUnless { it.isJsonNull }?.asString?.let { Base64.getDecoder().decode(it) }
        val body = if (method == "POST") requireNotNull(bytes).toRequestBody(headers["Content-Type"]?.toMediaTypeOrNull()) else null
        val requestUrl = input["url"].asString.toHttpUrl()
        val request = Request.Builder().url(requestUrl).headers(headers).method(method, body)
            .tag(InitialCookies::class.java, InitialCookies(requestUrl.host, headers["Cookie"])).build()
        val follow = input["followRedirects"]?.asBoolean ?: true
        val configured = client.newBuilder().followRedirects(follow).followSslRedirects(follow).apply {
            input["readTimeoutMs"]?.asLong?.let { readTimeout(it, TimeUnit.MILLISECONDS) }
        }.build()
        var retries = input["retry"]?.asInt ?: 0
        while (true) {
            task.ensureActiveForRuntime()
            check(!stopped.get()) { "HTTP transport is closed" }
            val call = configured.newCall(request)
            val budget = task.deadlineEpochMs - System.currentTimeMillis()
            if (budget <= 0) { task.ensureActiveForRuntime(); throw SocketTimeoutException("Task deadline exceeded before HTTP request") }
            call.timeout().timeout(minOf(input["timeoutMs"]?.asLong ?: 60_000L, budget), TimeUnit.MILLISECONDS)
            active.add(call)
            val callId = System.identityHashCode(call)
            RuntimeTaskTrace.event(TaskTraceStage.HTTP_REGISTERED, task, callId, callCancelled = call.isCanceled())
            val cancellation = task.job.invokeOnCompletion(onCancelling = true, invokeImmediately = true) {
                RuntimeTaskTrace.event(TaskTraceStage.HTTP_CANCEL_BEFORE, task, callId, callCancelled = call.isCanceled())
                var completed = false
                try { call.cancel(); completed = true }
                finally { RuntimeTaskTrace.event(TaskTraceStage.HTTP_CANCEL_AFTER, task, callId, callCancelled = call.isCanceled(), completed = completed) }
            }
            try {
                task.ensureActiveForRuntime()
                if (stopped.get()) { call.cancel(); throw IOException("HTTP transport is closed") }
                RuntimeTaskTrace.event(TaskTraceStage.HTTP_EXECUTE_BEFORE, task, callId)
                call.execute().use { response ->
                    RuntimeTaskTrace.event(TaskTraceStage.HTTP_HEADERS, task, callId)
                    if (!response.isSuccessful && response.code !in 300..399 && retries > 0) {
                        retries--
                    } else {
                        RuntimeTaskTrace.event(TaskTraceStage.HTTP_BODY_BEFORE, task, callId)
                        var completed = false
                        val payload = try { response.body.bytes().also { completed = true } }
                        finally { RuntimeTaskTrace.event(TaskTraceStage.HTTP_BODY_AFTER, task, callId, callCancelled = call.isCanceled(), completed = completed) }
                        task.ensureActiveForRuntime()
                        val grouped = JsonObject().apply {
                            response.headers.names().forEach { name -> add(name, JsonArray().apply { response.headers.values(name).forEach { add(it) } }) }
                        }
                        val handle = UUID.randomUUID().toString()
                        task.rawHttpResponses[handle] = response
                        return jsonObject("url" to response.request.url.toString(), "status" to response.code, "jvmResponseHandle" to handle,
                            "headers" to grouped, "headerEntries" to response.headers.map { jsonObject("name" to it.first, "value" to it.second) },
                            "bodyBase64" to Base64.getEncoder().encodeToString(payload), "protocol" to response.protocol.toString())
                    }
                }
            } catch (error: IOException) {
                task.ensureActiveForRuntime(); throw error
            } finally {
                cancellation.dispose(); call.cancel(); active.remove(call)
                RuntimeTaskTrace.event(TaskTraceStage.HTTP_FINISHED, task, callId, callCancelled = call.isCanceled())
            }
        }
    }

    override fun close() {
        if (!stopped.compareAndSet(false, true)) return
        active.forEach(Call::cancel)
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }

    /** Original AnalyzeUrl matches the registrable domain, with unknown-domain fallback. */
    companion object {
        fun sameLoginSite(source: String, target: String): Boolean {
            fun site(value: String): String? = runCatching {
                value.toHttpUrl().let { it.topPrivateDomain() ?: it.host }
            }.getOrNull()
            val sourceSite = site(source) ?: return true
            val targetSite = site(target) ?: return true
            return sourceSite.equals(targetSite, true)
        }

        private fun mergeCookies(vararg values: String?): String {
            val cookies = linkedMapOf<String, String>()
            values.forEach { value -> value?.split(';')?.forEach { entry ->
                val pair = entry.split('=', limit = 2)
                if (pair.size == 2 && pair[1].isNotBlank()) cookies[pair[0].trim()] = pair[1].trim()
            } }
            return cookies.entries.joinToString("; ") { "${it.key}=${it.value}" }
        }
    }

    /** Port of the original DecompressInterceptor; explicit Accept-Encoding/Range opts out. */
    private object TransparentDecompression : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            val transparent = request.header("Accept-Encoding") == null && request.header("Range") == null
            val response = chain.proceed(if (transparent) request.newBuilder().header("Accept-Encoding", "gzip, deflate, br").build() else request)
            if (!transparent || request.method == "HEAD" || response.code in listOf(204, 304) || response.code in 100..199) return response
            val body = response.body
            val source = try {
                when (response.header("Content-Encoding")?.lowercase()) {
                    "gzip" -> GZIPInputStream(body.byteStream()).source().buffer()
                    "deflate" -> InflaterInputStream(body.byteStream(), Inflater(true)).source().buffer()
                    "br" -> BrotliInputStream(body.byteStream()).source().buffer()
                    else -> return response
                }
            } catch (error: Throwable) { body.close(); throw error }
            return response.newBuilder().removeHeader("Content-Encoding").removeHeader("Content-Length")
                .body(source.asResponseBody(body.contentType(), -1)).build()
        }
    }
}
