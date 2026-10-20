package io.yuedu.legado

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.yuedu.legado.originalrule.NetworkUtils
import io.yuedu.legado.originalrule.RulePersistenceHost
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Actual public execute/host seam and the existing production OkHttp pool.
 * The fixture host returns owned text; no native/Swift execution is claimed.
 */
class AppCookieOwnerReadTest {
    @Test(timeout = 25_000) fun publicFourStagesReadCookieTextAndHeadersWithoutReconstructingAnRfcJar() {
        Peer().use { peer -> Owned(source(peer.origin)).use { owned ->
            val books = owned.result("search", jsonObject("key" to "owned"))["books"].asJsonArray
            var book = books[0].asJsonObject
            book = owned.result("details", jsonObject("book" to book))["book"].asJsonObject
            val toc = owned.result("toc", jsonObject("book" to book))
            book = toc["book"].asJsonObject; val chapters = toc["chapters"].asJsonArray
            assertEquals(2, chapters.size())
            val first = owned.result("content", jsonObject("book" to book, "chapter" to chapters[0], "needSave" to false))
            assertTrue(first["content"].asString.contains("first-page")); assertTrue(first["content"].asString.contains("last-page"))
            val second = owned.result("content", jsonObject("book" to first["book"], "chapter" to chapters[1], "needSave" to false))
            assertTrue(second["content"].asString.contains("second-chapter"))
            assertEquals(7, peer.requests.size)
            assertTrue(peer.requests.all { it.second == "owned=shared" && it.third == "left=right" })
            val reads = owned.calls.filter { it.first == "cookie.owner.read" }.map { it.second }
            assertTrue(reads.any { it["purpose"].asString == "getCookie" && it["domain"].asString == "example.co.uk" })
            assertTrue(reads.any { it["purpose"].asString == "requestHeader" && it["url"].asString == peer.origin + "/c2" })
            assertTrue(reads.all { it["owner"].asString == "fixture-owner" && it["remainingTimeoutMs"].asLong > 0 })
            assertFalse(owned.calls.filter { it.first == "state.read" }.flatMap { it.second["keys"].asJsonArray }.any {
                JsonParser.parseString(it.asString).asJsonArray[1].asString == "cookies"
            })
        } }
    }

    @Test(timeout = 15_000) fun writesLoginBatchesAndEnabledResponseJarRejectBeforeMutationOrHttp() {
        Peer().use { peer ->
            listOf("cookie.setCookie(baseUrl,'changed=value')", "cookie.replaceCookie(baseUrl,'changed=value')", "cookie.removeCookie(baseUrl)",
                "source.putLoginHeader('{\"Cookie\":\"changed=value\"}')", "source.removeLoginHeader()").forEach { script ->
                Owned(source(peer.origin).apply { addProperty("header", "@js:$script; ({})") }).use { owned ->
                    assertEquals("UNSUPPORTED_CAPABILITY", owned.error("search", jsonObject("key" to "x")))
                    assertTrue(owned.calls.none { it.first == "state.commit" })
                }
            }
            Owned(source(peer.origin).apply { addProperty("enabledCookieJar", true) }).use { owned ->
                assertEquals("UNSUPPORTED_CAPABILITY", owned.error("search", jsonObject("key" to "x")))
                assertTrue(owned.calls.none { it.first == "state.commit" })
            }
            assertTrue(peer.requests.isEmpty())
        }
    }

    @Test(timeout = 25_000) fun readHostErrorsMalformedResponsesCancellationAndDeadlineRemainTyped() {
        Peer().use { peer ->
            listOf("unsupported", "io", "malformed").forEach { mode ->
                Owned(source(peer.origin), mode).use { owned ->
                    assertEquals(if (mode == "unsupported") "UNSUPPORTED_CAPABILITY" else "STATE_IO", owned.error("search", jsonObject("key" to "x")))
                }
            }
            for (mode in listOf("cancel", "deadline", "close")) {
                Owned(source(peer.origin), mode).use { owned ->
                    val executor = Executors.newSingleThreadExecutor(); val task = "cookie-owner-$mode"
                    try {
                        val pending = executor.submit<String> { LegadoRuntime.execute(owned.id, task, "search", jsonObject("key" to "x", "timeoutMs" to if (mode == "deadline") 1200 else 8000).toString()) }
                        assertTrue(owned.entered.await(3, TimeUnit.SECONDS))
                        when (mode) { "cancel" -> LegadoRuntime.cancel(task); "close" -> LegadoRuntime.closeSession(owned.id) }
                        if (mode != "deadline") owned.release.countDown()
                        val result = parseObject(pending.get(5, TimeUnit.SECONDS))
                        assertEquals(if (mode == "deadline") "TIMEOUT" else "CANCELLED", result["error"].asJsonObject["code"].asString)
                    } finally { owned.release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS)) }
                }
            }
            assertTrue(peer.requests.isEmpty())
        }
    }

    @Test fun originalDomainFallbackAndExplicitOptionGatesUseThePinnedMethods() {
        linkedMapOf("https://a.example.co.uk/path" to "example.co.uk", "https://a.user.github.io" to "user.github.io",
            "http://127.0.0.1:80/path" to "127.0.0.1", "http://[::1]/path" to "[::1]", "foo.example.com" to "foo.example.com",
            "javascript:owned" to "javascript:owned").forEach { (url, expected) -> assertEquals(expected, NetworkUtils.getSubDomain(url)) }
        assertFalse(RuntimeSessionOptions().usesAppCookieOwner)
        val invalid = listOf(jsonObject("cookieAccess" to "app-owner-read"), jsonObject("cookieAccess" to "app-owner-read", "stateOwner" to "owner"))
        invalid.forEach { options ->
            val result = parseObject(LegadoRuntime.createSession(source("https://owned.invalid").toString(), options.toString()))
            assertEquals("UNSUPPORTED_CAPABILITY", result["error"].asJsonObject["code"].asString)
        }
    }

    private class Owned(source: JsonObject, private val mode: String = "ok") : Closeable {
        private val directory = Files.createTempDirectory("app-cookie-owner-read-")
        val calls = CopyOnWriteArrayList<Pair<String, JsonObject>>()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val id: String
        init {
            val state = RulePersistenceHost(FileRulePersistenceAdapter(directory))
            LegadoRuntime.setHostCallback { _, operation, raw ->
                if (operation == "task.cancel") { if (mode == "deadline") release.countDown(); "{}" }
                else {
                    val request = parseObject(raw); calls += operation to request
                    if (operation != "cookie.owner.read") state.dispatch(operation, request).toString()
                    else {
                        when (mode) {
                            "unsupported" -> """{"ok":false,"error":{"code":"UNSUPPORTED_CAPABILITY","message":"No Cookie owner"}}"""
                            "io" -> """{"ok":false,"error":{"code":"STATE_IO","message":"Owned Cookie file unreadable"}}"""
                            "malformed" -> """{"cookie":42}"""
                            else -> {
                                if (mode in setOf("cancel", "close", "deadline")) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
                                jsonObject("cookie" to if (request["purpose"].asString == "getCookie") "token=left=right; other=owned" else "owned=shared").toString()
                            }
                        }
                    }
                }
            }
            val created = parseObject(LegadoRuntime.createSession(source.toString(), options.toString()))
            assertTrue(created.toString(), created["ok"].asBoolean); id = created["sessionId"].asString
        }
        fun result(operation: String, input: JsonObject): JsonObject {
            val response = parseObject(LegadoRuntime.execute(id, "cookie-owner-${UUID.randomUUID()}", operation, input.toString()))
            assertTrue(response.toString(), response["ok"].asBoolean); return response["result"].asJsonObject
        }
        fun error(operation: String, input: JsonObject): String {
            val response = parseObject(LegadoRuntime.execute(id, "cookie-owner-${UUID.randomUUID()}", operation, input.toString()))
            assertFalse(response.toString(), response["ok"].asBoolean); return response["error"].asJsonObject["code"].asString
        }
        override fun close() { release.countDown(); LegadoRuntime.closeSession(id); LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
    }
    private class Peer : Closeable {
        val requests = CopyOnWriteArrayList<Triple<String, String, String>>()
        private val executor = Executors.newCachedThreadPool()
        private val errors = CopyOnWriteArrayList<Throwable>()
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            this.executor = this@Peer.executor
            createContext("/") { e ->
                requests += Triple(e.requestURI.path, e.requestHeaders.getFirst("Cookie").orEmpty(), e.requestHeaders.getFirst("X-Token").orEmpty())
                try {
                    val body = when (e.requestURI.path) {
                        "/search" -> "<div class='book'><a href='/book'>Owned</a></div>"
                        "/book" -> "<h1>Owned</h1><a id='toc' href='/toc'>toc</a>"
                        "/toc" -> """{"chapters":[{"name":"One","url":"/c1"}],"next":["/toc2"]}"""
                        "/toc2" -> """{"chapters":[{"name":"Two","url":"/c2"}],"next":[]}"""
                        "/c1" -> "<div id='text'>first-page</div><a class='next' href='/c1p2'>next</a>"
                        "/c1p2" -> "<div id='text'>last-page</div><a class='next' href='/c2'>chapter</a>"
                        "/c2" -> "<div id='text'>second-chapter</div>"
                        else -> error("Unexpected fixture path ${e.requestURI}")
                    }
                    respond(e, body)
                } catch (_: IOException) { } catch (error: Throwable) { errors += error } finally { e.close() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() { server.stop(0); executor.shutdownNow(); assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS)); if (errors.isNotEmpty()) throw AssertionError(errors.first()) }
    }
    companion object {
        private val options get() = jsonObject("httpTransport" to "jvm-okhttp", "sourceMode" to "original-traditional", "stateOwner" to "fixture-owner", "cookieAccess" to "app-owner-read")
        private fun source(origin: String) = jsonObject("bookSourceUrl" to origin, "bookSourceName" to "Owned Cookie read", "enabledCookieJar" to false,
            "header" to "@js:({'X-Token':cookie.getCookie('https://sub.example.co.uk/read','token')})", "searchUrl" to "$origin/search",
            "ruleSearch" to jsonObject("bookList" to ".book", "name" to "a@text", "bookUrl" to "a@href"),
            "ruleBookInfo" to jsonObject("name" to "h1@text", "tocUrl" to "#toc@href"),
            "ruleToc" to jsonObject("chapterList" to "$.chapters", "chapterName" to "$.name", "chapterUrl" to "$.url", "nextTocUrl" to "$.next"),
            "ruleContent" to jsonObject("content" to "#text@html", "nextContentUrl" to ".next@href"))
        private fun respond(e: HttpExchange, value: String) { val bytes = value.toByteArray(); e.sendResponseHeaders(200, bytes.size.toLong()); e.responseBody.use { it.write(bytes) } }
    }
}
