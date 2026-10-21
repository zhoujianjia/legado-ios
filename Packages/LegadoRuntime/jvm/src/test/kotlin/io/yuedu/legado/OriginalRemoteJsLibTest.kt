package io.yuedu.legado

import com.google.gson.JsonObject
import com.script.rhino.runScriptWithContext
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.yuedu.legado.originalrule.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Synthetic owned HTTP and the existing file Host protocol only. The App's
 * actual cache namespace/owner is covered by its existing Host regression. */
class OriginalRemoteJsLibTest {
    @Test(timeout = 20_000) fun orderedMapUsesOneScopeAcrossPublicSourceRuleAndUrlWithoutSourceHeadersOrCookies() {
        Peer { exchange ->
            if (exchange.requestURI.path == "/redirect") {
                exchange.responseHeaders.add("Location", "/a")
                exchange.sendResponseHeaders(302, -1)
                return@Peer
            }
            exchange.responseHeaders.add("Set-Cookie", "library=must-not-save; Path=/")
            respond(exchange, when (exchange.requestURI.path) {
                "/a" -> "var order = typeof order === 'undefined' ? 'A' : order + 'A';"
                "/b" -> "if(order !== 'A')throw new Error('wrong order');order += 'B';"
                "/http-error-body" -> "order += 'E';"
                else -> "owned body"
            }, if (exchange.requestURI.path == "/http-error-body") 503 else 200)
        }.use { peer -> Owner().use { owner ->
            val libraries = libraries("one" to peer.origin + "/redirect", "ignored" to "throw new Error('must not run')",
                "two" to peer.origin + "/b", "null" to null, "same-url-again" to peer.origin + "/redirect",
                "raw-error-body" to peer.origin + "/http-error-body")
            owner.direct(peer.origin, libraries).use { direct ->
                direct.environment.cookie.setCookie(peer.origin, "seed=existing")
                direct.source.header = "{\"Authorization\":\"synthetic-auth\",\"Cookie\":\"authored=existing\"}"
                assertEquals("ABAE", direct.eval("order").toString())
                AnalyzeRule(source = direct.source).use { rule ->
                    rule.setContent("owned non-null parser content")
                    assertEquals("ABAE", rule.getString("@js:order"))
                }
                val url = AnalyzeUrl("@js:source.getKey()+'/result/'+order", source = direct.source,
                    environment = direct.environment, coroutineContext = direct.task.job)
                assertEquals(peer.origin + "/result/ABAE", url.url)
                assertEquals(listOf("/redirect", "/a", "/b", "/http-error-body"), peer.requests.map { it.path })
                assertTrue(peer.requests.all { it.method == "GET" && it.header("Authorization").isEmpty() && it.header("Cookie").isEmpty() })
                assertTrue(peer.requests.all { it.header("User-Agent") == "owned-library-agent" && it.header("Cache-Control") == "no-cache" })
                assertEquals("existing", direct.environment.cookie.getCookie(peer.origin, "seed"))
                assertEquals("", direct.environment.cookie.getCookie(peer.origin, "library"))
                assertEquals(0, owner.nativeHttp.get())
            }
        } }
    }

    @Test(timeout = 20_000) fun publicRuntimeReopensTheSameCategoryAndRefreshDeletesLibrariesWithoutOrdinaryCacheAliasing() {
        val version = AtomicInteger(1)
        Peer { exchange -> respond(exchange, "var libraryVersion = ${version.get()};") }.use { peer -> Owner().use { owner ->
            val url = peer.origin + "/library"
            val map = libraries("library" to url)
            val key = md5(url)
            val poison = "var libraryVersion = 999;"
            owner.action(peer.origin, map,
                "if(libraryVersion!==1)throw new Error('initial library');cache.put('$key',${GSON.toJson(poison)});" +
                    "cache.put('shareJs/$key','ordinary prefix');cache.putMemory('$key','ordinary memory');")
            version.set(2)
            owner.action(peer.origin, map, "if(libraryVersion!==1)throw new Error('persistent cache miss');" +
                "if(String(cache.get('$key'))!==${GSON.toJson(poison)})throw new Error('ordinary namespace lost');")
            assertEquals(1, peer.requests.size)
            owner.action(peer.origin, map, "source.refreshJSLib();")
            assertEquals(1, peer.requests.size)
            owner.action(peer.origin, map,
                "if(libraryVersion!==2)throw new Error('refresh failed');" +
                    "if(String(cache.get('$key'))!==${GSON.toJson(poison)} || String(cache.get('shareJs/$key'))!=='ordinary prefix')throw new Error('ordinary cache changed');")
            assertEquals(2, peer.requests.size)
            // Current embedding keeps the existing source boundary. A sibling
            // source cannot borrow this source's persistent library category.
            owner.action(peer.origin + "/other-source", map, "if(libraryVersion!==2)throw new Error('sibling library');")
            assertEquals(3, peer.requests.size)
            assertTrue(owner.areas.contains("jslib-text")); assertEquals(0, owner.nativeHttp.get())
        } }
    }

    @Test(timeout = 20_000) fun syntaxAndOwnerFailuresRetainAcceptedCacheAndPartialRefreshOrderWithoutPublishingFailedScope() {
        val corrected = AtomicInteger(0)
        Peer { exchange -> respond(exchange, when (exchange.requestURI.path) {
            "/a" -> "var prefix = 'A';"
            else -> if (corrected.get() == 0) "var = ;" else "var suffix = 'B';"
        }) }.use { peer -> Owner().use { owner ->
            val a = peer.origin + "/a"; val b = peer.origin + "/b"
            val map = libraries("first" to a, "second" to b)
            owner.direct(peer.origin, map).use { direct ->
                assertTrue(runCatching { direct.eval("prefix+suffix") }.isFailure)
                assertEquals(listOf("/a", "/b"), peer.requests.map { it.path })
                corrected.set(1)
                // Original caches even syntactically bad non-null text before
                // eval. No partially initialized scope is installed on error.
                assertTrue(runCatching { direct.eval("prefix+suffix") }.isFailure)
                assertEquals(2, peer.requests.size)
                direct.source.refreshJSLib()
                assertEquals("AB", direct.eval("prefix+suffix").toString())
                assertEquals(4, peer.requests.size)
                owner.rejectRemovalOf = md5(b)
                assertTrue(runCatching { direct.source.refreshJSLib() }.exceptionOrNull() is RulePersistenceException)
                assertNull(owner.library(peer.origin, md5(a)))
                assertNotNull(owner.library(peer.origin, md5(b)))
                // Earlier deletion remains accepted, while failing the next
                // deletion leaves the previous complete scope/global intact.
                assertEquals("AB", direct.eval("prefix+suffix").toString())
                assertEquals(4, peer.requests.size)
                owner.rejectRemovalOf = null
            }
            owner.rejectLibraryWrite = true
            val fresh = libraries("new" to peer.origin + "/new")
            val failed = owner.action(peer.origin, fresh, "throw new Error('must not execute');", success = false)
            assertEquals("STATE_IO", failed["error"].asJsonObject["code"].asString)
            assertNull(owner.library(peer.origin, md5(peer.origin + "/new")))
            assertEquals(0, owner.nativeHttp.get())
        } }
    }

    @Test(timeout = 20_000) fun cancelledLibraryDownloadUsesTheExistingCallAndCannotPublishLateCacheOrScope() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        Peer { exchange ->
            entered.countDown(); check(release.await(8, TimeUnit.SECONDS))
            try { respond(exchange, "var lateLibrary = 'must not publish';") } catch (_: IOException) { /* client actually cancelled */ }
        }.use { peer -> Owner().use { owner ->
            val url = peer.origin + "/held"; val map = libraries("held" to url)
            owner.direct(peer.origin, map).use { direct ->
                val executor = Executors.newSingleThreadExecutor()
                try {
                    val pending = executor.submit<Throwable?> { runCatching { direct.eval("lateLibrary") }.exceptionOrNull() }
                    assertTrue(entered.await(5, TimeUnit.SECONDS))
                    direct.task.job.cancel(); release.countDown()
                    val failure = pending.get(5, TimeUnit.SECONDS)
                    assertNotNull(failure)
                    assertTrue(generateSequence(failure) { it.cause }.take(32).any { it is CancellationException })
                    assertNull(owner.library(peer.origin, md5(url)))
                    assertEquals(1, peer.requests.size)
                    assertTrue(direct.task.hostEffectsSnapshot().contains("sourceJsLibMaySend"))
                    assertFalse(direct.task.hostEffectsSnapshot().contains("sourceJsLibResponseReceived"))
                    assertEquals(0, owner.nativeHttp.get())
                } finally {
                    release.countDown(); executor.shutdownNow()
                    check(executor.awaitTermination(3, TimeUnit.SECONDS))
                }
            }
        } }
    }

    private class Owner : Closeable {
        private val directory = Files.createTempDirectory("owned-remote-jslib-")
        private val adapter = FileRulePersistenceAdapter(directory)
        private val host = RulePersistenceHost(adapter)
        val nativeHttp = AtomicInteger()
        val areas = CopyOnWriteArrayList<String>()
        var rejectRemovalOf: String? = null
        var rejectLibraryWrite = false
        init { LegadoRuntime.setHostCallback { _, operation, raw ->
            if (operation == "task.cancel") "{}" else {
                val input = parseObject(raw)
                when (operation) {
                    "state.read" -> {
                        input["keys"].asJsonArray.forEach { areas += com.google.gson.JsonParser.parseString(it.asString).asJsonArray[1].asString }
                        host.dispatch(operation, input).toString()
                    }
                    "state.commit" -> {
                        val reject = input["changes"].asJsonObject.entrySet().any { (key, value) ->
                            val parts = com.google.gson.JsonParser.parseString(key).asJsonArray
                            parts[1].asString == "jslib-text" && (rejectLibraryWrite && !value.isJsonNull ||
                                rejectRemovalOf == parts[2].asString && value.isJsonNull)
                        }
                        if (reject) jsonObject("ok" to false, "error" to jsonObject("code" to "STATE_IO", "message" to "Owned cache write rejected")).toString()
                        else host.dispatch(operation, input).toString()
                    }
                    "http.request" -> { nativeHttp.incrementAndGet(); error("Must use the existing JVM HTTP transport") }
                    else -> error("Unexpected jsLib Host operation: $operation")
                }
            }
        } }
        fun direct(origin: String, library: String): Direct = Direct(origin, library)
        fun library(origin: String, key: String): ByteArray? = adapter.read("library-owner", setOf(GSON.toJson(listOf(origin, "jslib-text", key)))).values.values.singleOrNull()
        fun action(origin: String, library: String, script: String, success: Boolean = true): JsonObject {
            val source = jsonObject("bookSourceUrl" to origin, "bookSourceType" to 0, "enabledCookieJar" to true,
                "jsLib" to library, "loginUrl" to "var syntheticPrelude=true;", "ruleContent" to JsonObject())
            val created = parseObject(LegadoRuntime.createSession(source.toString(), jsonObject("httpTransport" to "jvm-okhttp",
                "userAgent" to "owned-library-agent", "sourceMode" to "original-traditional", "stateOwner" to "library-owner").toString()))
            assertTrue(created.toString(), created["ok"].asBoolean)
            val id = created["sessionId"].asString
            try {
                val result = parseObject(LegadoRuntime.execute(id, UUID.randomUUID().toString(), "loginAction",
                    jsonObject("action" to script, "credentials" to emptyMap<String, String>()).toString()))
                assertEquals(result.toString(), success, result["ok"].asBoolean)
                return result
            } finally { LegadoRuntime.closeSession(id) }
        }
        override fun close() { LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
    }
    private class Direct(origin: String, library: String) : Closeable {
        private val session = RuntimeSession(UUID.randomUUID().toString(), jsonObject("bookSourceUrl" to origin, "enabledCookieJar" to true),
            RuntimeSessionOptions("jvm-okhttp", "owned-library-agent", "library-owner", "original-traditional"))
        val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + 12_000)
        val environment = LegadoRuntime.originalRuleEnvironment(task)
        val source = BookSource(environment, origin, "Owned library", jsLib = library)
        fun eval(script: String): Any? = runScriptWithContext(task.job) { source.evalJS(script) }
        override fun close() { environment.close(); task.job.cancel(); session.closed.set(true); session.http!!.close() }
    }
    private data class Capture(val path: String, val method: String, val headers: Map<String, List<String>>) {
        fun header(name: String): String = headers.entries.firstOrNull { it.key.equals(name, true) }?.value.orEmpty().joinToString("; ")
    }
    private class Peer(handler: (HttpExchange) -> Unit) : Closeable {
        val requests = CopyOnWriteArrayList<Capture>()
        private val errors = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool { Thread(it, "owned-jslib-peer").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = this@Peer.executor
            createContext("/") { exchange ->
                try {
                    requests += Capture(exchange.requestURI.toString(), exchange.requestMethod, exchange.requestHeaders.mapValues { it.value.toList() })
                    handler(exchange)
                } catch (error: Throwable) { errors += error } finally { exchange.close() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() {
            server.stop(0); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS))
            if (errors.isNotEmpty()) throw AssertionError("Owned jsLib HTTP peer failed", errors.first())
        }
    }
    companion object {
        private fun libraries(vararg values: Pair<String, String?>): String = GSON.toJson(linkedMapOf(*values))
        private fun md5(value: String): String = MessageDigest.getInstance("MD5").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        private fun respond(exchange: HttpExchange, value: String, status: Int = 200) {
            exchange.responseHeaders.add("Content-Type", "application/javascript; charset=utf-8")
            val bytes = value.toByteArray(Charsets.UTF_8)
            exchange.sendResponseHeaders(status, bytes.size.toLong()); exchange.responseBody.write(bytes)
        }
    }
}
