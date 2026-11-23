package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.yuedu.legado.originalrule.RuleEnvironment
import io.yuedu.legado.originalrule.RulePlatform
import io.yuedu.legado.originalrule.RulePersistenceHost
import io.yuedu.legado.originalrule.UnsupportedRuleCapability
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/** Real public runtime and loopback HTTP; no source fixtures or test-only URL interpreter. */
class OriginalStaticHttpUrlsTest {
    @Test(timeout = 15_000) fun trustedOptionIsStrictBooleanAndRequiresOriginalMode() {
        assertFalse(RuntimeSessionOptions.parse(JsonObject()).staticHttpUrlsOnly)
        assertTrue(RuntimeSessionOptions.parse(options(true)).staticHttpUrlsOnly)
        for (invalid in listOf("\"true\"", "1", "null", "{}")) {
            val input = options(false).apply { add("staticHttpUrlsOnly", com.google.gson.JsonParser.parseString(invalid)) }
            assertThrows(IllegalArgumentException::class.java) { RuntimeSessionOptions.parse(input) }
        }
        assertThrows(RuntimeFailure::class.java) {
            RuntimeSessionOptions.parse(jsonObject("staticHttpUrlsOnly" to true))
        }
    }

    @Test(timeout = 20_000) fun staticRelativeChapterAndFollowingPageCompleteWithoutSideEffects() {
        Peer { exchange ->
            when (exchange.requestURI.path) {
                "/pages/start" -> respond(exchange, "<div id='text'>First page</div><a class='next' href='next?part=2&amp;q=%E9%9D%92'>Next</a>")
                "/pages/next" -> respond(exchange, "<div id='text'>Second page</div>")
                else -> respond(exchange, "unexpected", 404)
            }
        }.use { peer ->
            Owned(source(peer.origin), true).use { owned ->
                val response = owned.content(peer.origin, "/pages/start")
                assertTrue(response.toString(), response["ok"].asBoolean)
                val content = response["result"].asJsonObject["content"].asString
                assertTrue(content, content.contains("First page") && content.contains("Second page"))
                assertEquals(listOf("/pages/start", "/pages/next"), peer.paths)
                assertTrue(peer.uris.last().contains("q=%E9%9D%92"))
                assertTrue(owned.hostOperations.all { it == "state.read" })
            }
        }
    }

    @Test(timeout = 30_000) fun maliciousReturnedPagesCannotRunScriptsWriteStateOrSendAnotherHttpRequest() {
        val next = arrayOf("")
        Peer { exchange ->
            if (exchange.requestURI.path == "/pages/start")
                respond(exchange, jsonObject("body" to "First page", "next" to next[0]).toString())
            else respond(exchange, "unexpected", 404)
        }.use { peer ->
            val effect = "source.put('attack','ran');java.put('attack','ran');java.ajax('${peer.origin}/attack');"
            val malicious = listOf(
                "${peer.origin}/next@js:${effect}'${peer.origin}/next'",
                "<js>${effect}'${peer.origin}/next'</js>",
                "${peer.origin}/{{${effect}'next'}}",
                "${peer.origin}/next," + jsonObject("js" to "${effect}result"),
            )
            for (url in malicious) {
                next[0] = url
                peer.clear()
                // Imported JSON cannot turn off its embedding owner's restriction.
                val rawSource = source(peer.origin).apply {
                    addProperty("staticHttpUrlsOnly", false)
                    add("ruleContent", jsonObject("content" to "$.body", "nextContentUrl" to "$.next"))
                }
                Owned(rawSource, true).use { owned ->
                    val response = owned.content(peer.origin, "/pages/start")
                    assertFalse(url, response["ok"].asBoolean)
                    assertEquals(response.toString(), "UNSUPPORTED_CAPABILITY", response["error"].asJsonObject["code"].asString)
                    assertEquals(url, listOf("/pages/start"), peer.paths)
                    assertTrue(url + owned.hostOperations, owned.hostOperations.all { it == "state.read" })
                }
            }
        }
    }

    @Test(timeout = 15_000) fun invalidFirstUrlIsRejectedBeforeItsDynamicHeaderCanRun() {
        Peer { respond(it, "unexpected", 404) }.use { peer ->
            val raw = source(peer.origin).apply {
                addProperty("header", "@js:source.put('header-ran','yes');java.ajax('${peer.origin}/header-effect');({})")
            }
            Owned(raw, true).use { owned ->
                val response = owned.content(peer.origin, "${peer.origin}/pages/start@js:java.put('url-ran','yes');result")
                assertFalse(response.toString(), response["ok"].asBoolean)
                assertEquals("UNSUPPORTED_CAPABILITY", response["error"].asJsonObject["code"].asString)
                assertTrue(peer.paths.isEmpty())
                assertTrue(owned.hostOperations.all { it == "state.read" })
            }
        }
    }

    @Test(timeout = 20_000) fun omittedAndFalseOptionsPreserveExistingDynamicPaginationAndIgnoreSourceActivation() {
        Peer { exchange ->
            when (exchange.requestURI.path) {
                "/pages/start" -> respond(exchange, jsonObject("body" to "First page", "next" to
                    "@js:source.put('legacy','yes');java.put('legacy','yes');'http://127.0.0.1:${exchange.localAddress.port}/pages/next'").toString())
                "/pages/next" -> respond(exchange, """{"body":"Second page","next":""}""")
                else -> respond(exchange, "unexpected", 404)
            }
        }.use { peer ->
            for (flag in listOf<Boolean?>(null, false)) {
                peer.clear()
                val raw = source(peer.origin).apply {
                    addProperty("staticHttpUrlsOnly", true)
                    add("ruleContent", jsonObject("content" to "$.body", "nextContentUrl" to "$.next"))
                }
                Owned(raw, flag).use { owned ->
                    val response = owned.content(peer.origin, "/pages/start")
                    assertTrue(response.toString(), response["ok"].asBoolean)
                    val result = response["result"].asJsonObject
                    assertTrue(result["content"].asString.contains("Second page"))
                    assertEquals("yes", parseObject(result["book"].asJsonObject["variable"].asString)["legacy"].asString)
                    assertTrue(owned.hostOperations.contains("state.commit"))
                    // The retained loop first records the authored JS URL, then
                    // the returned actual URL, before noticing its empty self-link.
                    assertEquals(listOf("/pages/start", "/pages/next", "/pages/next"), peer.paths)
                }
            }
        }
    }

    @Test(timeout = 15_000) fun staticGrammarRejectsDynamicBaseInvalidAuthorityAndControlBytesBeforeHeader() {
        val headerExecutions = AtomicInteger()
        RuleEnvironment(platform = object : RulePlatform() {
            override val staticHttpUrlsOnly = true
            override fun log(value: Any?): Any? { headerExecutions.incrementAndGet(); return value }
        }).use { environment ->
            val source = BookSource(environment, "https://static.invalid").apply {
                header = "@js:java.log('header-ran');({})"
            }
            val inputs = listOf(
                "https://static.invalid/chapter" to "https://static.invalid/@js:java.put('bad','yes')",
                "/chapter" to "",
                "https://user:pass@static.invalid/chapter" to "https://static.invalid",
                "https:///chapter" to "https://static.invalid",
                "file:///chapter" to "https://static.invalid",
                "https://static.invalid/chapter\n" to "https://static.invalid",
                "https://static.invalid/%0a" to "https://static.invalid",
                "https://static.invalid/<1,2>" to "https://static.invalid",
                "https://static.invalid/%GG" to "https://static.invalid",
            )
            for ((url, base) in inputs) assertThrows(url, UnsupportedRuleCapability::class.java) {
                AnalyzeUrl(url, baseUrl = base, source = source, environment = environment)
            }
            assertEquals(0, headerExecutions.get())
        }
    }

    private class Owned(source: JsonObject, flag: Boolean?) : Closeable {
        private val directory = Files.createTempDirectory("static-url-owner-")
        val hostOperations = CopyOnWriteArrayList<String>()
        val id: String
        init {
            val host = RulePersistenceHost(FileRulePersistenceAdapter(directory))
            LegadoRuntime.setHostCallback { _, operation, raw ->
                if (operation == "task.cancel") "{}" else {
                    hostOperations += operation
                    host.dispatch(operation, parseObject(raw)).toString()
                }
            }
            val created = parseObject(LegadoRuntime.createSession(source.toString(), options(flag).toString()))
            assertTrue(created.toString(), created["ok"].asBoolean)
            id = created["sessionId"].asString
        }
        fun content(origin: String, url: String): JsonObject = parseObject(LegadoRuntime.execute(id,
            "static-url-${UUID.randomUUID()}", "content", jsonObject(
                "book" to jsonObject("bookUrl" to "$origin/book", "origin" to origin, "tocUrl" to "$origin/toc"),
                "chapter" to jsonObject("bookUrl" to "$origin/book", "url" to url,
                    "title" to "Static chapter", "index" to 0, "baseUrl" to "$origin/pages/"),
                "nextChapterUrl" to "$origin/next-chapter", "needSave" to false, "timeoutMs" to 5_000).toString()))
        override fun close() {
            LegadoRuntime.closeSession(id)
            LegadoRuntime.setHostCallback(null)
            directory.toFile().deleteRecursively()
        }
    }

    private class Peer(handler: (HttpExchange) -> Unit) : Closeable {
        val paths = CopyOnWriteArrayList<String>()
        val uris = CopyOnWriteArrayList<String>()
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            createContext("/") { exchange ->
                paths += exchange.requestURI.path; uris += exchange.requestURI.toString()
                try { handler(exchange) } finally { exchange.close() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        fun clear() { paths.clear(); uris.clear() }
        override fun close() { server.stop(0) }
    }

    companion object {
        private fun options(flag: Boolean?) = jsonObject("httpTransport" to "jvm-okhttp", "stateOwner" to "static-owner",
            "sourceMode" to "original-traditional").apply { if (flag != null) addProperty("staticHttpUrlsOnly", flag) }
        private fun source(origin: String) = jsonObject("bookSourceUrl" to origin, "header" to "{}", "enabledCookieJar" to false,
            "ruleContent" to jsonObject("content" to "#text@html", "nextContentUrl" to ".next@href"))
        private fun respond(exchange: HttpExchange, text: String, status: Int = 200) {
            val bytes = text.toByteArray(Charsets.UTF_8)
            exchange.responseHeaders.add("Content-Type", "text/html; charset=UTF-8")
            exchange.sendResponseHeaders(status, bytes.size.toLong())
            exchange.responseBody.write(bytes)
        }
    }
}
