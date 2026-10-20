package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
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

/** Only public createSession/execute/cancel/close and the real state host protocol are used. */
class OriginalTraditionalRuntimeTest {
    @Test(timeout = 15_000) fun searchDoesNotInventShelfIdentityButDetailsStillRequireTheGrantedBookOwner() {
        Peer { respond(it, "<div class='book'><a href='/book'>Unshelved</a></div>") }.use { peer ->
            val directory = Files.createTempDirectory("public-unshelved-owner-")
            val host = RulePersistenceHost(FileRulePersistenceAdapter(directory))
            LegadoRuntime.setHostCallback { _, operation, raw ->
                if (operation == "task.cancel") "{}" else {
                    val request = parseObject(raw)
                    val bookRead = operation == "state.read" && request["keys"].asJsonArray.any {
                        val key = com.google.gson.JsonParser.parseString(it.asString).asJsonArray
                        key[1].asString == "variables" && key[2].asString == "book"
                    }
                    if (bookRead) """{"ok":false,"error":{"code":"UNSUPPORTED_CAPABILITY","message":"No App book UUID grant"}}"""
                    else host.dispatch(operation, request).toString()
                }
            }
            val created = parseObject(LegadoRuntime.createSession(source(peer.origin).toString(), options.toString()))
            assertTrue(created.toString(), created["ok"].asBoolean); val id = created["sessionId"].asString
            try {
                val search = parseObject(LegadoRuntime.execute(id, "public-unshelved-search", "search", "{\"key\":\"owned\"}"))
                assertTrue(search.toString(), search["ok"].asBoolean)
                val books = search["result"].asJsonObject["books"].asJsonArray
                assertEquals(1, books.size()); assertEquals("Unshelved", books[0].asJsonObject["name"].asString)
                val detail = parseObject(LegadoRuntime.execute(id, "public-ungranted-details", "details", jsonObject("book" to books[0]).toString()))
                assertEquals("UNSUPPORTED_CAPABILITY", detail["error"].asJsonObject["code"].asString)
                assertEquals(1, peer.requests.size)
            } finally { LegadoRuntime.closeSession(id); LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
        }
    }
    @Test(timeout = 25_000) fun publicFourStageChainKeepsOriginalSelectorsPagingVariablesCookiesAndBusinessDtos() {
        Peer { e -> when (e.requestURI.path) {
            "/search" -> { e.responseHeaders.add("Set-Cookie", "owned=1; Path=/"); respond(e, "<div class='book'><a href='/book'>Original</a><b>Author</b></div>") }
            "/book" -> respond(e, "<h1>Updated</h1><a id='toc' href='/toc'>toc</a>")
            "/toc" -> respond(e, """{"chapters":[{"name":"One","url":"/c1"}],"next":["/toc2"]}""")
            "/toc2" -> respond(e, """{"chapters":[{"name":"Two","url":"/c2"}],"next":[]}""")
            "/c1" -> respond(e, "<div id='text'>first&amp;page</div><a class='next' href='/c1p2'>next</a>")
            "/c1p2" -> respond(e, "<div id='text'>lastREMOVE</div><a class='next' href='/c2'>chapter</a>")
            "/c2" -> respond(e, "<div id='text'>chapter two</div>")
            else -> error("Unexpected request ${e.requestURI}")
        } }.use { peer -> Owned(source(peer.origin).apply {
            addProperty("header", "@js:({'X-Phase':source.get('phase')||'search'})")
            add("ruleSearch", jsonObject("bookList" to ".book", "name" to "a@text@js:source.putVariable('[1]');source.put('phase','details');result", "author" to "b@text", "bookUrl" to "a@href"))
            add("ruleBookInfo", jsonObject("init" to "@js:book.putVariable('info','ready');result", "name" to "@XPath://h1/text()", "tocUrl" to "#toc@href", "canReName" to "yes"))
            add("ruleToc", jsonObject("preUpdateJs" to "java.put('large','x'.repeat(10000));java.put('toc','ready');source.put('phase','content')", "chapterList" to "$.chapters", "chapterName" to "$.name", "chapterUrl" to "$.url", "nextTocUrl" to "$.next"))
            add("ruleContent", jsonObject("content" to "#text@html", "nextContentUrl" to ".next@href", "replaceRegex" to "##REMOVE##", "title" to "@js:if(String(java.get('large')).length!==10000)throw new Error('large lost');chapter.putVariable('parsed','yes');String(chapter.title)+'!'"))
        }).use { owned ->
            val found = owned.result("search", jsonObject("key" to "阅读", "page" to 2))["books"].asJsonArray
            assertEquals(1, found.size()); var book = found[0].asJsonObject
            assertEquals("Original", book["name"].asString); assertEquals(peer.origin, book["origin"].asString)
            assertFalse(book.has("environment")); assertFalse(book.has("variableMap\$delegate"))
            book = owned.result("getBookInfo", jsonObject("book" to book))["book"].asJsonObject
            assertEquals("Updated", book["name"].asString)
            assertEquals("ready", parseObject(book["variable"].asString)["info"].asString)
            val toc = owned.result("getChapters", jsonObject("book" to book, "runPreUpdateJs" to true))
            book = toc["book"].asJsonObject; val chapters = toc["chapters"].asJsonArray
            assertEquals(2, chapters.size()); assertEquals(listOf(0, 1), chapters.map { it.asJsonObject["index"].asInt })
            assertEquals("ready", parseObject(book["variable"].asString)["toc"].asString)
            assertEquals(2, book["totalChapterNum"].asInt)
            val first = owned.result("getContent", jsonObject("book" to book, "chapter" to chapters[0], "needSave" to false))
            assertTrue(first["content"].asString, first["content"].asString.contains("first&page"))
            assertTrue(first["content"].asString.contains("last")); assertFalse(first["content"].asString.contains("REMOVE"))
            assertEquals("One!", first["chapter"].asJsonObject["title"].asString)
            assertEquals("yes", parseObject(first["chapter"].asJsonObject["variable"].asString)["parsed"].asString)
            assertEquals(0, peer.requests.count { it.path == "/c2" })
            val second = owned.result("content", jsonObject("book" to first["book"], "chapter" to chapters[1], "needSave" to false))
            assertTrue(second["content"].asString.contains("chapter two")); assertEquals("Two!", second["chapter"].asJsonObject["title"].asString)
            assertTrue(peer.requests.first().uri.contains("p=2")); assertTrue(peer.requests.first().uri.contains("%E9%98%85"))
            assertEquals(7, peer.requests.size)
            assertTrue(peer.requests.drop(1).all { it.cookie.contains("owned=1") })
            assertEquals("details", peer.requests[1].phase); assertTrue(peer.requests.drop(2).all { it.phase == "content" })
            assertTrue(owned.hostCalls.any { it.second == "state.commit" }); assertTrue(owned.hostCalls.all { it.first.startsWith("public-") })
            assertTrue(owned.hostRequests.all { it["deadlineEpochMs"].asLong > 0 && it["remainingTimeoutMs"].asLong > 0 })
        } }
    }

    @Test(timeout = 15_000) fun publicRegexSearchRetainsOriginalGroupAndReverseContract() {
        Peer { respond(it, "BOOK[First|Author|/one]BOOK[Second|Author|/two]") }.use { peer ->
            Owned(source(peer.origin).apply {
                add("ruleSearch", jsonObject("bookList" to "-:BOOK\\[([^|]*)\\|([^|]*)\\|([^\\]]*)\\]", "name" to "\$1", "author" to "\$2", "bookUrl" to "\$3"))
            }).use { owned ->
                val books = owned.result("search", jsonObject("key" to "x"))["books"].asJsonArray
                assertEquals(listOf("Second", "First"), books.map { it.asJsonObject["name"].asString })
            }
        }
    }

    @Test(timeout = 15_000) fun explicitModeAndStrictDtosFailBeforeWritesWithoutChangingTheDefaultRoute() {
        val raw = source("https://owned.invalid")
        val missingOwner = parseObject(LegadoRuntime.createSession(raw.toString(), jsonObject("httpTransport" to "jvm-okhttp", "sourceMode" to "original-traditional").toString()))
        assertEquals("UNSUPPORTED_CAPABILITY", missingOwner["error"].asJsonObject["code"].asString)
        val wrongTransport = parseObject(LegadoRuntime.createSession(raw.toString(), jsonObject("stateOwner" to "owner", "sourceMode" to "original-traditional").toString()))
        assertEquals("UNSUPPORTED_CAPABILITY", wrongTransport["error"].asJsonObject["code"].asString)
        val existing = parseObject(LegadoRuntime.createSession(jsonObject("bookSourceUrl" to "https://owned.invalid", "mainJs" to "function search(){return [{name:'legacy',bookUrl:'https://owned.invalid/book'}]}").toString()))
        val existingSession = existing["sessionId"].asString
        try {
            val result = parseObject(LegadoRuntime.execute(existingSession, UUID.randomUUID().toString(), "search", "{}"))
            assertTrue(result.toString(), result["ok"].asBoolean); assertTrue(result["result"].isJsonArray)
        } finally { LegadoRuntime.closeSession(existingSession) }
        Owned(raw).use { owned ->
            assertEquals("UNSUPPORTED_OPERATION", owned.error("batch", JsonObject()))
            assertEquals("UNSUPPORTED_OPERATION", owned.error("evaluate", jsonObject("script" to "1")))
            assertEquals("INVALID_ARGUMENT", owned.error("details", JsonObject()))
            assertEquals("INVALID_ARGUMENT", owned.error("details", jsonObject("book" to book("https://other.invalid"))))
            assertEquals("INVALID_ARGUMENT", owned.error("details", jsonObject("book" to book("https://owned.invalid").apply { addProperty("environment", "injected") })))
            assertEquals("INVALID_ARGUMENT", owned.error("details", jsonObject("book" to book("https://owned.invalid").apply { addProperty("variable", "[]") })))
            assertEquals("UNSUPPORTED_CAPABILITY", owned.error("details", jsonObject("book" to book("https://owned.invalid").apply { addProperty("type", 128) })))
            assertEquals("UNSUPPORTED_CAPABILITY", owned.error("content", jsonObject("book" to book("https://owned.invalid"))))
            assertEquals("UNSUPPORTED_CAPABILITY", owned.error("content", jsonObject("needSave" to true)))
            assertEquals("INVALID_ARGUMENT", owned.error("content", jsonObject("book" to book("https://owned.invalid"), "chapter" to chapter("another"), "needSave" to false)))
            assertEquals("INVALID_ARGUMENT", owned.error("search", jsonObject("key" to "x", "page" to 1.5)))
            assertEquals("INVALID_ARGUMENT", owned.error("search", jsonObject("key" to "x", "unexpected" to true)))
            // Constructing the valid book before rejecting a mismatched chapter may read its
            // owned variables, but invalid requests must never commit state or dispatch HTTP.
            assertTrue(owned.hostCalls.all { it.second == "state.read" })
        }
    }

    @Test(timeout = 15_000) fun publicEmptyAndUnsupportedHostFailuresKeepTypedEnvelopes() {
        Peer { respond(it, "<div>no matches</div>") }.use { peer ->
            Owned(source(peer.origin).apply { add("ruleToc", jsonObject("chapterList" to ".absent", "chapterName" to "text", "chapterUrl" to "href")) }).use { owned ->
                assertEquals("TOC_EMPTY", owned.error("toc", jsonObject("book" to book(peer.origin))))
                assertEquals("CONTENT_EMPTY", owned.error("content", jsonObject("book" to book(peer.origin), "chapter" to chapter(peer.origin + "/book"), "needSave" to false)))
            }
            val created = parseObject(LegadoRuntime.createSession(source(peer.origin).toString(), options.toString()))
            val id = created["sessionId"].asString
            LegadoRuntime.setHostCallback { _, operation, _ -> if (operation == "task.cancel") "{}" else """{"ok":false,"error":{"code":"UNSUPPORTED_CAPABILITY","message":"owned Cookie mapping not ready"}}""" }
            try {
                val error = parseObject(LegadoRuntime.execute(id, "public-host-unsupported", "search", "{\"key\":\"x\"}"))
                assertEquals("UNSUPPORTED_CAPABILITY", error["error"].asJsonObject["code"].asString)
            } finally { LegadoRuntime.closeSession(id); LegadoRuntime.setHostCallback(null) }
        }
    }

    @Test(timeout = 25_000) fun publicCancellationCloseAndAbsoluteDeadlineRejectLateHttpResults() {
        for (mode in listOf("cancel", "close", "deadline")) {
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            Peer { e -> entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); respond(e, "<div class='book'><a href='/book'>late</a></div>") }.use { peer ->
                Owned(source(peer.origin)).use { owned ->
                    val executor = Executors.newSingleThreadExecutor(); val task = "public-$mode"
                    try {
                        val request = jsonObject("key" to "x", "timeoutMs" to if (mode == "deadline") 1200 else 8000)
                        val future = executor.submit<String> { LegadoRuntime.execute(owned.id, task, "search", request.toString()) }
                        assertTrue("HTTP never entered: $mode", entered.await(3, TimeUnit.SECONDS))
                        when (mode) { "cancel" -> LegadoRuntime.cancel(task); "close" -> LegadoRuntime.closeSession(owned.id) }
                        val response = parseObject(future.get(4, TimeUnit.SECONDS))
                        assertEquals(if (mode == "deadline") "TIMEOUT" else "CANCELLED", response["error"].asJsonObject["code"].asString)
                        release.countDown()
                    } finally { release.countDown(); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)) }
                }
            }
        }
    }

    @Test(timeout = 25_000) fun publicInputAndOutputBudgetsRejectRatherThanTruncate() {
        Peer { respond(it, "<div>owned</div>") }.use { peer ->
            Owned(source(peer.origin).apply { add("ruleContent", jsonObject("content" to "@js:'x'.repeat(8388609)")) }).use { owned ->
                val oversized = jsonObject("key" to "阅".repeat(1_400_000)).toString()
                val rejected = parseObject(LegadoRuntime.execute(owned.id, "public-large-input", "search", oversized))
                assertEquals("PAYLOAD_TOO_LARGE", rejected["error"].asJsonObject["code"].asString)
                assertTrue(peer.requests.isEmpty())
                assertEquals("PAYLOAD_TOO_LARGE", owned.error("content", jsonObject("book" to book(peer.origin), "chapter" to chapter(peer.origin + "/book"), "needSave" to false)))
            }
            Owned(source(peer.origin).apply { add("ruleContent", jsonObject("content" to "@js:throw new Error('x'.repeat(8388609))")) }).use { owned ->
                assertEquals("PAYLOAD_TOO_LARGE", owned.error("content", jsonObject("book" to book(peer.origin), "chapter" to chapter(peer.origin + "/book"), "needSave" to false)))
            }
        }
    }

    private class Owned(source: JsonObject) : Closeable {
        private val directory = Files.createTempDirectory("public-original-owner-")
        val hostCalls = CopyOnWriteArrayList<Pair<String, String>>()
        val hostRequests = CopyOnWriteArrayList<JsonObject>()
        val id: String
        init {
            val host = RulePersistenceHost(FileRulePersistenceAdapter(directory))
            LegadoRuntime.setHostCallback { task, operation, raw ->
                if (operation == "task.cancel") "{}" else {
                    val request = parseObject(raw); hostCalls += task to operation; hostRequests += request
                    host.dispatch(operation, request).toString()
                }
            }
            val result = parseObject(LegadoRuntime.createSession(source.toString(), options.toString()))
            assertTrue(result.toString(), result["ok"].asBoolean); id = result["sessionId"].asString
        }
        fun result(operation: String, request: JsonObject): JsonObject {
            val response = parseObject(LegadoRuntime.execute(id, "public-${UUID.randomUUID()}", operation, request.toString()))
            assertTrue(response.toString(), response["ok"].asBoolean); return response["result"].asJsonObject
        }
        fun error(operation: String, request: JsonObject): String {
            val response = parseObject(LegadoRuntime.execute(id, "public-${UUID.randomUUID()}", operation, request.toString()))
            assertFalse(response.toString(), response["ok"].asBoolean); return response["error"].asJsonObject["code"].asString
        }
        override fun close() { LegadoRuntime.closeSession(id); LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
    }
    private data class Capture(val path: String, val uri: String, val cookie: String, val phase: String)
    private class Peer(handler: (HttpExchange) -> Unit) : Closeable {
        val requests = CopyOnWriteArrayList<Capture>()
        private val errors = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool()
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            this.executor = this@Peer.executor
            createContext("/") { e ->
                requests += Capture(e.requestURI.path, e.requestURI.toString(), e.requestHeaders.getFirst("Cookie").orEmpty(), e.requestHeaders.getFirst("X-Phase").orEmpty())
                try { handler(e) } catch (_: IOException) { /* cancellation closes the owned socket */ }
                catch (error: Throwable) { errors += error } finally { e.close() }
            }; start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() { server.stop(0); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)); if (errors.isNotEmpty()) throw AssertionError("Owned peer failed", errors.first()) }
    }
    companion object {
        private val options get() = jsonObject("httpTransport" to "jvm-okhttp", "stateOwner" to "owner", "sourceMode" to "original-traditional")
        private fun source(origin: String) = jsonObject("bookSourceUrl" to origin, "searchUrl" to "/search?q={{key}}&p={{page}}",
            "ruleSearch" to jsonObject("bookList" to ".book", "name" to "a@text", "bookUrl" to "a@href"),
            "ruleContent" to jsonObject("content" to "#text@html"))
        private fun book(origin: String) = jsonObject("bookUrl" to "$origin/book", "origin" to origin, "tocUrl" to "$origin/toc")
        private fun chapter(bookUrl: String) = jsonObject("url" to "/chapter", "title" to "Owned", "bookUrl" to bookUrl, "baseUrl" to bookUrl, "index" to 0)
        private fun respond(exchange: HttpExchange, text: String) {
            val bytes = text.toByteArray(); exchange.responseHeaders.add("Content-Type", "text/html; charset=utf-8")
            exchange.sendResponseHeaders(200, bytes.size.toLong()); exchange.responseBody.write(bytes)
        }
    }
}
