package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.yuedu.legado.originalrule.RulePersistenceHost
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real public execute and existing OkHttp pool. The owned fixture models the
 * native text protocol; Swift owner execution is covered by separate SDK tests.
 */
class AppCookieOwnerTextTest {
    @Test(timeout = 30_000) fun publicFourStagesCommitRedirectCookieBeforeFollowingAndKeepOriginalTextPrecedence() {
        Peer().use { peer -> Owned().use { owned ->
            val source = source(peer.origin, jar = true).apply {
                addProperty("header", """@js:if(source.get('seeded')!='yes'){cookie.setCookie(baseUrl,'seed=owned');source.put('seeded','yes')}; ({Cookie:'authored=kept; sid=authored'})""")
            }
            val id = owned.session(source)
            var book = owned.result(id, "search", jsonObject("key" to "owned"))["books"].asJsonArray[0].asJsonObject
            book = owned.result(id, "details", jsonObject("book" to book))["book"].asJsonObject
            val toc = owned.result(id, "toc", jsonObject("book" to book))
            book = toc["book"].asJsonObject; val chapters = toc["chapters"].asJsonArray
            assertEquals(2, chapters.size())
            val first = owned.result(id, "content", jsonObject("book" to book, "chapter" to chapters[0], "needSave" to false))
            assertTrue(first["content"].asString.contains("first-page")); assertTrue(first["content"].asString.contains("last-page"))
            val second = owned.result(id, "content", jsonObject("book" to first["book"], "chapter" to chapters[1], "needSave" to false))
            assertTrue(second["content"].asString.contains("second-chapter"))
            assertEquals(listOf("/start", "/search", "/book", "/toc", "/toc2", "/c1", "/c1p2", "/c2"), peer.requests.map { it.path })
            assertTrue(peer.requests.first().cookie.contains("sid=authored"))
            assertTrue(peer.requests.drop(1).all { it.cookie.contains("sid=redirect") && it.cookie.contains("persist=durable") && it.cookie.contains("authored=kept") })
            val response = owned.calls.single { it.first == "cookie.owner.text" && it.second["action"].asString == "response" }.second
            assertEquals(peer.origin + "/start", response["url"].asString)
            val cookies = response["cookies"].asJsonArray.map { it.asJsonObject }
            assertTrue(cookies.all { it["hostOnly"].asBoolean && it["domain"].asString == "127.0.0.1" })
            assertEquals("/private", cookies.single { it["name"].asString == "persist" }["path"].asString)
            assertTrue(cookies.single { it["name"].asString == "persist" }["httpOnly"].asBoolean)
            assertTrue(owned.calls.none { it.first == "cookie.owner.read" })
            assertFalse(owned.calls.filter { it.first == "state.read" }.flatMap { it.second["keys"].asJsonArray }.any { parseObjectOrArrayDomain(it.asString) == "cookies" })
            owned.reopenCookieFile() // Persistent DB text survives; session text does not.
            val restarted = source(peer.origin, jar = false).apply {
                addProperty("searchUrl", peer.origin + "/search")
                addProperty("header", "@js:({'X-Snapshot':encodeURIComponent(cookie.getCookie(baseUrl))})")
            }
            owned.result(owned.session(restarted), "search", jsonObject("key" to "again"))
            assertEquals("seed=owned; persist=durable", decode(peer.requests.last().snapshot))
        } }
    }

    @Test(timeout = 25_000) fun scalarRawReplaceRemoveAndPruningExecuteThroughThePublicRuleContract() {
        Peer().use { peer -> Owned().use { owned ->
            val raw = " Case =one; case=two; dup=first; dup=last; eq=left=right; empty=; blank=\u00a0; nel=\u0085; null=null; =empty-key;;"
            val incoming = "dup=new; extra=three; blank= ; empty=; eq=a=b=c"
            val script = """@js:cookie.setCookie('https://a.example.co.uk/a',${gson.toJson(raw)}); var a=cookie.getCookie('https://b.example.co.uk/b'); cookie.replaceCookie('https://b.example.co.uk/b',${gson.toJson(incoming)}); var b=cookie.getCookie('https://a.example.co.uk/a'); cookie.removeCookie('https://a.example.co.uk/a'); var c=cookie.getCookie('https://b.example.co.uk/b'); ({'X-A':encodeURIComponent(a),'X-B':encodeURIComponent(b),'X-C':encodeURIComponent(c)})"""
            val source = source(peer.origin, false).apply { addProperty("searchUrl", peer.origin + "/search"); addProperty("header", script) }
            owned.result(owned.session(source), "search", jsonObject("key" to "raw"))
            val request = peer.requests.last()
            assertEquals(OriginalCookieTextOracle.mergeCookies(raw, ""), decode(request.a))
            assertEquals(OriginalCookieTextOracle.mergeCookieValues(raw, incoming), decode(request.b))
            assertEquals("", decode(request.c)); assertFalse(owned.db.containsKey("example.co.uk"))
            assertTrue(owned.calls.filter { it.first == "cookie.owner.text" && it.second["action"].asString in setOf("set", "replace", "remove") }.all { it.second["domain"].asString == "example.co.uk" })
            val giant = "giant=" + "x".repeat(5000)
            val pruneSource = source(peer.origin, false).apply {
                addProperty("searchUrl", peer.origin + "/search")
                addProperty("header", "@js:cookie.setCookie('https://prune.invalid',${gson.toJson(giant)}); ({'X-A':cookie.getCookie('https://prune.invalid')})")
            }
            owned.result(owned.session(pruneSource), "search", jsonObject("key" to "prune"))
            assertEquals("", peer.requests.last().a)
            // Original removeKey deliberately does not replace an empty map.
            assertEquals(giant, owned.db["prune.invalid"])
            assertTrue(owned.calls.any { it.first == "cookie.owner.text" && it.second["action"].asString == "removeKey" })
        } }
    }

    @Test(timeout = 20_000) fun loginEffectsFollowTheOriginalDifferentOrdersAndExposePartialFailure() {
        Peer().use { peer -> Owned().use { owned ->
            owned.failHeaderCommit = true
            val put = source(peer.origin, false).apply { addProperty("header", """@js:source.putLoginHeader('{"Cookie":"login=committed"}'); ({})""") }
            val failedPut = owned.execute(owned.session(put), "search", jsonObject("key" to "x"))
            assertEquals("STATE_IO", failedPut["error"].asJsonObject["code"].asString)
            assertTrue(failedPut.toString().contains("Cookie text was committed"))
            assertEquals("login=committed", owned.db["127.0.0.1"])
            assertTrue(owned.events.indexOf("cookie:replace") < owned.events.indexOf("header:put"))
            owned.failHeaderCommit = false
            val initialHeader = source(peer.origin, false).apply { addProperty("header", """@js:source.putLoginHeader('{"Authorization":"owned"}'); ({})"""); addProperty("searchUrl", peer.origin + "/search") }
            owned.result(owned.session(initialHeader), "search", jsonObject("key" to "x"))
            owned.events.clear(); owned.failCookieRemove = true
            val remove = source(peer.origin, false).apply { addProperty("header", "@js:source.removeLoginHeader(); ({})") }
            val failedRemove = owned.execute(owned.session(remove), "search", jsonObject("key" to "x"))
            assertEquals("STATE_IO", failedRemove["error"].asJsonObject["code"].asString)
            assertTrue(failedRemove.toString().contains("login header was removed"))
            assertTrue(owned.events.indexOf("header:remove") < owned.events.indexOf("cookie:remove"))
            assertEquals("login=committed", owned.db["127.0.0.1"])
            assertEquals(1, peer.requests.size) // Failed header initialization never reaches HTTP.
        } }
    }

    @Test(timeout = 30_000) fun failedCancelledClosedAndTimedOutResponseCommitsNeverFollowRedirects() {
        for (mode in listOf("io", "cancel", "close", "deadline")) {
            Peer().use { peer -> Owned().use { owned ->
                owned.responseMode = mode
                val id = owned.session(source(peer.origin, true))
                val executor = Executors.newSingleThreadExecutor(); val task = "cookie-text-$mode"
                try {
                    val pending = executor.submit<String> { LegadoRuntime.execute(id, task, "search", jsonObject("key" to "x", "timeoutMs" to if (mode == "deadline") 1200 else 7000).toString()) }
                    if (mode != "io") {
                        assertTrue(owned.entered.await(3, TimeUnit.SECONDS))
                        if (mode == "cancel") LegadoRuntime.cancel(task)
                        if (mode == "close") LegadoRuntime.closeSession(id)
                        if (mode != "deadline") owned.release.countDown()
                    }
                    val result = parseObject(pending.get(6, TimeUnit.SECONDS))
                    assertEquals(if (mode == "io") "STATE_IO" else if (mode == "deadline") "TIMEOUT" else "CANCELLED", result["error"].asJsonObject["code"].asString)
                    assertEquals(listOf("/start"), peer.requests.map { it.path })
                    assertTrue(owned.db.isEmpty()); assertTrue(owned.sessions.isEmpty())
                } finally { owned.release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS)) }
            } }
        }
    }

    @Test fun pureOriginalWhitespaceAndOptionGatesStayPinned() {
        val actual = (0..0xFFFF).filter { it.toChar().isWhitespace() }
        val expected = listOf(9..13, 28..32, 0xA0..0xA0, 0x1680..0x1680, 0x2000..0x200A, 0x2028..0x2029, 0x202F..0x202F, 0x205F..0x205F, 0x3000..0x3000).flatMap { it.toList() }
        assertEquals(expected, actual)
        assertEquals("a=\u0085; c=null; eq=a=b", OriginalCookieTextOracle.mapToCookie(OriginalCookieTextOracle.cookieToMap("a=\u0085; b=\u00a0; c=null; eq=a=b; empty=")))
        assertEquals(" incoming = raw;;", OriginalCookieTextOracle.mergeCookieValues("", " incoming = raw;;"))
        assertTrue(RuntimeSessionOptions.parse(options).writesAppCookieOwner)
        for (bad in listOf(jsonObject("cookieAccess" to "app-owner-text"), jsonObject("stateOwner" to "owner", "cookieAccess" to "app-owner-text"))) {
            val result = parseObject(LegadoRuntime.createSession(source("https://owned.invalid", false).toString(), bad.toString()))
            assertEquals("UNSUPPORTED_CAPABILITY", result["error"].asJsonObject["code"].asString)
        }
    }

    private class Owned : Closeable {
        private val directory = Files.createTempDirectory("cookie-text-owner-")
        private val cookieFile = directory.resolve("cookies.json")
        private val state = RulePersistenceHost(FileRulePersistenceAdapter(directory.resolve("state")))
        val db = linkedMapOf<String, String>(); val sessions = linkedMapOf<String, String>()
        val calls = CopyOnWriteArrayList<Pair<String, JsonObject>>(); val events = CopyOnWriteArrayList<String>()
        private val ids = CopyOnWriteArrayList<String>(); private val cancelled = ConcurrentHashMap.newKeySet<String>()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        var failHeaderCommit = false; var failCookieRemove = false; var responseMode = "ok"
        init {
            LegadoRuntime.setHostCallback { task, operation, raw ->
                if (operation == "task.cancel") { cancelled += task; release.countDown(); "{}" }
                else {
                    val input = parseObject(raw); calls += operation to input
                    if (operation == "cookie.owner.text") cookie(task, input).toString()
                    else {
                        if (operation == "state.commit") {
                            val header = input["changes"].asJsonObject.entrySet().firstOrNull { it.key.contains("loginHeader_") }
                            if (header != null) {
                                events += if (header.value.isJsonNull) "header:remove" else "header:put"
                                if (failHeaderCommit) return@setHostCallback failure("STATE_IO", "Owned header failure").toString()
                            }
                        }
                        state.dispatch(operation, input).toString()
                    }
                }
            }
        }
        @Synchronized private fun cookie(task: String, input: JsonObject): JsonObject {
            val action = input["action"].asString; val domain = input["domain"].asString
            events += "cookie:$action"
            if (action == "get") return jsonObject("cookie" to OriginalCookieTextOracle.mergeCookies(db[domain].orEmpty(), sessions[domain]))
            if (action == "session") return jsonObject("cookie" to sessions[input["url"].asString].orEmpty())
            if (action == "response") {
                if (responseMode == "io") return failure("STATE_IO", "Owned response write failure")
                if (responseMode != "ok") { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
                if (task in cancelled) return failure("STATE_IO", "Cancelled before fixture commit")
            }
            if (action == "remove" && failCookieRemove) return failure("STATE_IO", "Owned Cookie remove failure")
            val next = LinkedHashMap(db); val nextSessions = LinkedHashMap(sessions)
            when (action) {
                "set" -> next[domain] = input["cookie"].asString
                "replace" -> if (domain.isNotEmpty() && input["cookie"].asString.isNotEmpty()) next[domain] = OriginalCookieTextOracle.mergeCookieValues(next[domain].orEmpty(), input["cookie"].asString)
                "remove" -> { next.remove(domain); nextSessions.remove(domain) }
                "removeKey" -> {
                    val key = input["cookie"].asString
                    next[domain]?.let { original -> OriginalCookieTextOracle.mapToCookie(OriginalCookieTextOracle.cookieToMap(original).apply { remove(key) })?.let { next[domain] = it } }
                    nextSessions[domain]?.let { original -> OriginalCookieTextOracle.mapToCookie(OriginalCookieTextOracle.cookieToMap(original).apply { remove(key) })?.let { nextSessions[domain] = it } }
                }
                "response" -> {
                    val persistent = input["persistentText"].asString; val session = input["sessionText"].asString
                    if (persistent.isNotEmpty()) next[domain] = OriginalCookieTextOracle.mergeCookieValues(next[domain].orEmpty(), persistent)
                    nextSessions[domain] = if (nextSessions[domain].isNullOrEmpty()) session else OriginalCookieTextOracle.mergeCookies(nextSessions[domain], session).orEmpty()
                }
                else -> error("Unexpected Cookie fixture action $action")
            }
            if (next != db) {
                val staged = Files.createTempFile(directory, "cookie", ".pending")
                try { Files.writeString(staged, gson.toJson(next)); Files.move(staged, cookieFile, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
                finally { Files.deleteIfExists(staged) }
            }
            db.clear(); db.putAll(next); sessions.clear(); sessions.putAll(nextSessions)
            return jsonObject("committed" to true)
        }
        @Synchronized fun reopenCookieFile() { db.clear(); if (Files.exists(cookieFile)) parseObject(Files.readString(cookieFile)).entrySet().forEach { db[it.key] = it.value.asString }; sessions.clear() }
        fun session(source: JsonObject): String {
            val result = parseObject(LegadoRuntime.createSession(source.toString(), options.toString())); assertTrue(result.toString(), result["ok"].asBoolean)
            return result["sessionId"].asString.also { ids += it }
        }
        fun execute(id: String, operation: String, input: JsonObject): JsonObject = parseObject(LegadoRuntime.execute(id, "text-${UUID.randomUUID()}", operation, input.toString()))
        fun result(id: String, operation: String, input: JsonObject): JsonObject = execute(id, operation, input).let { assertTrue(it.toString(), it["ok"].asBoolean); it["result"].asJsonObject }
        override fun close() { release.countDown(); ids.forEach(LegadoRuntime::closeSession); LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
    }

    private data class Seen(val path: String, val cookie: String, val snapshot: String, val a: String, val b: String, val c: String)
    private class Peer : Closeable {
        val requests = CopyOnWriteArrayList<Seen>(); private val errors = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool()
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            this.executor = this@Peer.executor
            createContext("/") { e ->
                try {
                    requests += Seen(e.requestURI.path, e.requestHeaders.getFirst("Cookie").orEmpty(), e.requestHeaders.getFirst("X-Snapshot").orEmpty(), e.requestHeaders.getFirst("X-A").orEmpty(), e.requestHeaders.getFirst("X-B").orEmpty(), e.requestHeaders.getFirst("X-C").orEmpty())
                    if (e.requestURI.path == "/start") {
                        e.responseHeaders.add("Set-Cookie", "sid=redirect; Path=/; HttpOnly")
                        e.responseHeaders.add("Set-Cookie", "persist=durable; Path=/private; HttpOnly; Max-Age=3600")
                        e.responseHeaders.add("Location", "/search"); e.sendResponseHeaders(302, -1)
                    } else respond(e, when (e.requestURI.path) {
                        "/search" -> "<div class='book'><a href='/book'>Owned</a></div>"
                        "/book" -> "<h1>Owned</h1><a id='toc' href='/toc'>toc</a>"
                        "/toc" -> """{"chapters":[{"name":"One","url":"/c1"}],"next":["/toc2"]}"""
                        "/toc2" -> """{"chapters":[{"name":"Two","url":"/c2"}],"next":[]}"""
                        "/c1" -> "<div id='text'>first-page</div><a class='next' href='/c1p2'>next</a>"
                        "/c1p2" -> "<div id='text'>last-page</div><a class='next' href='/c2'>chapter</a>"
                        "/c2" -> "<div id='text'>second-chapter</div>"
                        else -> error("Unexpected owned request ${e.requestURI}")
                    })
                } catch (_: java.io.IOException) { } catch (error: Throwable) { errors += error } finally { e.close() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() { server.stop(0); executor.shutdownNow(); assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS)); if (errors.isNotEmpty()) throw AssertionError(errors.first()) }
    }
    companion object {
        private val options get() = jsonObject("httpTransport" to "jvm-okhttp", "sourceMode" to "original-traditional", "stateOwner" to "fixture-owner", "cookieAccess" to "app-owner-text")
        private fun failure(code: String, message: String) = jsonObject("ok" to false, "error" to jsonObject("code" to code, "message" to message))
        private fun source(origin: String, jar: Boolean) = jsonObject("bookSourceUrl" to origin, "bookSourceName" to "Owned original Cookie text", "enabledCookieJar" to jar, "searchUrl" to "$origin/start",
            "ruleSearch" to jsonObject("bookList" to ".book", "name" to "a@text", "bookUrl" to "a@href"),
            "ruleBookInfo" to jsonObject("name" to "h1@text", "tocUrl" to "#toc@href"),
            "ruleToc" to jsonObject("chapterList" to "$.chapters", "chapterName" to "$.name", "chapterUrl" to "$.url", "nextTocUrl" to "$.next"),
            "ruleContent" to jsonObject("content" to "#text@html", "nextContentUrl" to ".next@href"))
        private fun decode(value: String): String = URLDecoder.decode(value, Charsets.UTF_8)
        private fun parseObjectOrArrayDomain(key: String): String = com.google.gson.JsonParser.parseString(key).asJsonArray[1].asString
        private fun respond(e: HttpExchange, text: String) { val bytes = text.toByteArray(); e.sendResponseHeaders(200, bytes.size.toLong()); e.responseBody.use { it.write(bytes) } }
    }
}
