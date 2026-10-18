package io.yuedu.legado

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import com.script.ScriptBindings
import kotlinx.coroutines.InternalCoroutinesApi
import okhttp3.Call
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.SocketTimeoutException
import java.net.URI
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Packaged only by -PincludeEngineTests=true; never selects a production transport. */
internal object OkHttpWireCapabilityProbe {
    private const val FIXTURE_SHA256 = "731f1f1f743b9bc393ea221a7118ff4a115ffa35947aa40c88ff088bb758a894"
    private const val CANONICAL_ORIGIN = "https://fixture.invalid"

    @JvmStatic
    @OptIn(InternalCoroutinesApi::class)
    fun run(parent: RuntimeTask, runner: ProbeOperationRunner): JsonObject {
        val started = System.nanoTime()
        parent.job.ensureActiveForRuntime()
        val report = jsonObject("suite" to "OkHttpWireCapabilityProbe", "passed" to false,
            "fixtureOnly" to true, "g4ValidationPassed" to false, "loopbackOnly" to true,
            "mainJsSHA256" to FIXTURE_SHA256, "httpClient" to "okhttp-jvm:5.4.0", "okio" to "okio-jvm:3.17.0",
            "parentDeadlineEpochMs" to parent.deadlineEpochMs,
            "normalization" to "Only loopback origin and its Host authority are replaced, as in the original Android reference harness.")
        val errors = JsonArray()
        val steps = JsonArray()
        val cleanupErrors = mutableListOf<String>()
        val sourceBytes = checkNotNull(javaClass.getResourceAsStream("/fixtures/main-source.js")) { "Missing shared main-source.js" }
            .use { it.readBytes() }
        check(ReferenceLoopbackFixture.sha256(sourceBytes) == FIXTURE_SHA256) { "Shared main-source.js bytes changed" }
        val server = ReferenceLoopbackFixture()
        val transport = try { ProbeOkHttpTransport(parent, server.origin) } catch (error: Throwable) {
            try { server.close() } catch (cleanup: Exception) { error.addSuppressed(cleanup) }
            throw error
        }
        var isolated: RuntimeSession? = null
        val cancellation = parent.job.invokeOnCompletion(onCancelling = true, invokeImmediately = true) {
            try { server.abort() } catch (error: Exception) { synchronized(cleanupErrors) { cleanupErrors += error.toString() } }
        }
        try {
            check(ReferenceLoopbackFixture.sha256(sourceBytes) == FIXTURE_SHA256) { "Shared main-source.js bytes changed" }
            val sourceInput = jsonObject("bookSourceName" to "Synthetic fixture", "bookSourceUrl" to server.origin,
                "header" to ReferenceLoopbackFixture.FIXED_HEADERS, "enabledCookieJar" to true,
                "jsLib" to ReferenceLoopbackFixture.SHARED_JS_LIB, "mainJsSHA256" to FIXTURE_SHA256)
            val source = sourceInput.deepCopy().apply {
                remove("mainJsSHA256"); addProperty("mainJs", sourceBytes.toString(Charsets.UTF_8))
            }
            val session = RuntimeSession("wire-probe:" + UUID.randomUUID(), source).also { isolated = it }
            val child = RuntimeTask(parent.id, session, parent.job, parent.deadlineEpochMs, transport)
            check(child.deadlineEpochMs == parent.deadlineEpochMs)
            report.addProperty("childDeadlineEpochMs", child.deadlineEpochMs)
            fun step(name: String, operation: String, input: JsonObject = JsonObject()): JsonElement {
                parent.job.ensureActiveForRuntime(); remaining(parent)
                return runner.execute(child, operation, input).also { steps.add(name) }
            }
            steps.add("login.begin")
            val login = step("login.returned", "login")
            check(login.asBoolean) { "Login failed" }
            val search = step("search", "search", jsonObject("key" to "书", "page" to 1)).asJsonArray
            check(search.size() == 1 && search[0].asJsonObject["name"].asString == "Fixture")
            val book = step("details", "details", jsonObject("book" to search[0])).asJsonObject
            check(book["intro"].asString == "Introduction")
            val chapters = step("toc", "toc", jsonObject("book" to book)).asJsonArray
            check(chapters.size() == 2)
            val content = step("content", "content", jsonObject("book" to book, "chapter" to chapters[0],
                "nextChapterUrl" to chapters[1].asJsonObject["url"]))
            check(content.asString == ReferenceLoopbackFixture.CONTENT_ONE)
            val before = runner.execute(child, "snapshot", JsonObject()).asJsonObject
            val readbackBefore = JsonObject().apply { chapters.forEach { add(chapterUrl(it.asJsonObject), JsonNull.INSTANCE) } }
            check(before["contents"].asJsonObject.size() == 0)
            val batch = step("batch.returned", "batch", jsonObject("book" to book, "chapters" to chapters)).asJsonObject
            check(batch["exists"].asBoolean && batch["saved"].asJsonArray.size() == 2 && batch["missing"].asJsonArray.isEmpty)
            val snapshot = runner.execute(child, "snapshot", JsonObject()).asJsonObject
            val calls = runner.execute(child, "evaluate", jsonObject("script" to "globalThis.calls")).asInt
            check(calls == 1)
            check(snapshot["variables"].asJsonObject["@variable"].asString == "logged-in")
            check(snapshot["cache"].asJsonObject["lastKey"].asString == "书")
            check(session.cookies.getCookie(server.origin) == "sid=fixture")
            check(snapshot["contents"].asJsonObject[server.origin + "/chapter/1"].asString == ReferenceLoopbackFixture.CONTENT_ONE)
            check(snapshot["contents"].asJsonObject[server.origin + "/chapter/2"].asString == ReferenceLoopbackFixture.CONTENT_TWO)
            val captures = server.requests()
            check(captures.size == 7) { "Exactly seven real HTTP requests must execute" }
            captures.forEach { check(it.awaitResponse(remaining(parent))) { "Response write did not complete" } }
            verifyWire(captures)
            server.assertHealthy()
            report.add("preparedRequests", snapshot["requests"].deepCopy())
            // The compared snapshot uses the peer's actual wire bytes, not these
            // prepared intents. Keep both so a transport mutation stays visible.
            snapshot.add("requests", JsonArray().apply { captures.forEach { add(it.comparable()) } })
            val chain = jsonObject("traceVersion" to "legado-main-js-v1", "sourceInput" to sourceInput,
                "login" to login, "search" to search, "details" to book, "toc" to chapters, "content" to content,
                "batch" to batch, "cacheBeforeContent" to before["contents"], "snapshot" to snapshot,
                "sharedCalls" to calls, "exceptions" to errors)
            report.add("rawReadingChain", chain)
            report.add("readingChain", replaceOrigin(chain, server.origin))
            report.add("cacheReadbackBeforeBatch", readbackBefore)
            report.add("state", jsonObject("loginInfo" to session.variables["@loginInfo"],
                "loginHeader" to session.variables["@loginHeader"], "variable" to session.variables["@variable"],
                "cookie" to session.cookies.getCookie(server.origin), "lastKey" to session.cache.get("lastKey"), "calls" to calls))
        } catch (error: Throwable) {
            if (error is VirtualMachineError || error is ThreadDeath) throw error
            errors.add(jsonObject("type" to error.javaClass.name, "message" to error.message, "stackTrace" to error.stackTraceToString()))
        } finally {
            cancellation.dispose()
            fun clean(action: () -> Unit) { try { action() } catch (error: Exception) { synchronized(cleanupErrors) { cleanupErrors += error.toString() } } }
            clean { transport.close() }; clean { server.close() }
            isolated?.let { session ->
                session.closed.set(true); session.sharedGlobal?.let(ScriptBindings::removeSharedGlobalState)
                session.variables.clear(); session.cache.clear(); session.contents.clear()
            }
            report.add("steps", steps)
            report.add("exceptions", errors)
            report.add("wireSnapshot", jsonObject("origin" to server.origin,
                "requests" to JsonArray().apply { server.requests().forEach { add(it.evidence()) } }))
            report.add("transportResponses", transport.responses())
            val transportCleanup = transport.cleanup()
            val serverCleanup = server.cleanup()
            report.add("cleanup", jsonObject("transport" to transportCleanup, "server" to serverCleanup,
                "isolatedSessionClosed" to (isolated?.closed?.get() == true), "errors" to synchronized(cleanupErrors) { cleanupErrors.toList() }))
            report.addProperty("passed", errors.isEmpty && cleanupErrors.isEmpty() && report.has("readingChain") &&
                transportCleanup["passed"].asBoolean && serverCleanup.entrySet().all { it.value.asBoolean })
            report.addProperty("totalMilliseconds", (System.nanoTime() - started) / 1_000_000.0)
        }
        parent.job.ensureActiveForRuntime()
        return report
    }

    private fun verifyWire(captures: List<ReferenceLoopbackFixture.Capture>) {
        check(captures.map { it.target } == listOf("/login", "/search?key=%E4%B9%A6&page=1", "/book/1", "/toc/1", "/chapter/1", "/chapter/1", "/chapter/2"))
        captures.forEachIndexed { index, capture ->
            check(capture.version == "HTTP/1.1" && capture.method == if (index == 0) "POST" else "GET")
            fun values(name: String) = capture.headers.filter { it.first.equals(name, true) }.map { it.second }
            check(values("Connection") == listOf("close", "Keep-Alive"))
            check(values("Keep-Alive") == listOf("300") && values("Cache-Control") == listOf("no-cache"))
            check(values("Accept-Encoding") == listOf("identity"))
            if (index == 0) {
                check(values("Content-Type") == listOf("application/x-www-form-urlencoded; charset=utf-8"))
                check(capture.body.toString(Charsets.UTF_8) == "name=reader&password=%E4%B9%A6")
            } else {
                check(values("Cookie") == listOf("sid=fixture") && values("Authorization") == listOf("Bearer fixture"))
                check(capture.body.isEmpty())
            }
        }
    }

    private fun replaceOrigin(value: JsonElement, origin: String): JsonElement = when {
        value.isJsonNull -> value
        value.isJsonObject -> JsonObject().apply { value.asJsonObject.entrySet().forEach { (key, child) -> add(key.replace(origin, CANONICAL_ORIGIN), replaceOrigin(child, origin)) } }
        value.isJsonArray -> JsonArray().apply { value.asJsonArray.forEach { add(replaceOrigin(it, origin)) } }
        value.isJsonPrimitive && value.asJsonPrimitive.isString -> JsonPrimitive(value.asString.let {
            if (it == origin.substringAfter("://")) CANONICAL_ORIGIN.substringAfter("://") else it.replace(origin, CANONICAL_ORIGIN)
        })
        else -> value
    }

    internal fun remaining(task: RuntimeTask): Long = (task.deadlineEpochMs - System.currentTimeMillis())
        .also { if (it <= 0) throw SocketTimeoutException("Wire probe absolute task deadline exceeded") }
}

/** Solely this test task owns this client, calls, pool and dispatcher. */
@OptIn(InternalCoroutinesApi::class)
internal class ProbeOkHttpTransport(private val owner: RuntimeTask, private val origin: String,
                                    private val onHeaders: () -> Unit = {}) : TaskHttpDispatcher, Closeable {
    private val active = ConcurrentHashMap.newKeySet<Call>()
    private val received = java.util.Collections.synchronizedList(mutableListOf<JsonObject>())
    private val client = OkHttpClient.Builder().proxy(Proxy.NO_PROXY)
        .followRedirects(false).followSslRedirects(false)
        .dns { host -> check(host == "127.0.0.1"); listOf(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))) }
        .connectTimeout(15, TimeUnit.SECONDS).writeTimeout(15, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()
    private val cancellation = owner.job.invokeOnCompletion(onCancelling = true, invokeImmediately = true) { active.forEach(Call::cancel) }
    @Volatile private var stopped = false

    override fun request(task: RuntimeTask, request: JsonObject): JsonObject {
        check(task.job === owner.job && task.deadlineEpochMs == owner.deadlineEpochMs) { "HTTP transport belongs to one parent task" }
        task.job.ensureActiveForRuntime()
        val url = request["url"].asString
        val uri = URI(url); val base = URI(origin)
        require(uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port == base.port && uri.rawUserInfo == null) { "Only the owned fixed loopback server is allowed" }
        val builder = Headers.Builder()
        request["headers"].asJsonArray.forEach { val header = it.asJsonObject; builder.add(header["name"].asString, header["value"].asString) }
        val headers = builder.build()
        val bytes = request["bodyBase64"]?.takeUnless { it.isJsonNull }?.asString?.let { Base64.getDecoder().decode(it) }
        val method = request["method"].asString
        val body = if (method == "POST") requireNotNull(bytes).toRequestBody(headers["Content-Type"]?.toMediaType()) else null
        val call = client.newCall(Request.Builder().url(url).headers(headers).method(method, body).build())
        call.timeout().timeout(minOf(request["timeoutMs"]?.asLong ?: 30_000, OkHttpWireCapabilityProbe.remaining(task)), TimeUnit.MILLISECONDS)
        active.add(call)
        try {
            task.job.ensureActiveForRuntime()
            return call.execute().use { response ->
                onHeaders()
                val payload = response.body.bytes()
                task.job.ensureActiveForRuntime()
                val values = JsonObject().apply { response.headers.names().forEach { name -> add(name, JsonArray().apply { response.headers.values(name).forEach { add(it) } }) } }
                jsonObject("url" to response.request.url.toString(), "status" to response.code,
                    "headers" to values, "headerEntries" to response.headers.map { jsonObject("name" to it.first, "value" to it.second) },
                    "bodyBase64" to ReferenceLoopbackFixture.b64(payload), "bodySHA256" to ReferenceLoopbackFixture.sha256(payload),
                    "protocol" to response.protocol.toString()).also { received.add(it.deepCopy()) }
            }
        } catch (error: IOException) {
            task.job.ensureActiveForRuntime(); throw error
        } finally { call.cancel(); active.remove(call) }
    }

    fun responses() = JsonArray().apply { synchronized(received) { received.forEach { add(it.deepCopy()) } } }
    override fun close() {
        cancellation.dispose(); active.forEach(Call::cancel); client.dispatcher.cancelAll(); client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdownNow()
        stopped = client.dispatcher.executorService.awaitTermination(2, TimeUnit.SECONDS)
    }
    fun cleanup() = jsonObject("passed" to (stopped && active.isEmpty() && client.connectionPool.connectionCount() == 0),
        "dispatcherStopped" to stopped, "activeCalls" to active.size, "pooledConnections" to client.connectionPool.connectionCount())
}
