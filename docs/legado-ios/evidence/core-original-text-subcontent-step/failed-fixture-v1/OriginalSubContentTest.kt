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
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Public original business calls, the existing persistence callback and real loopback HTTP. */
class OriginalSubContentTest {
    @Test(timeout = 20_000) fun pagedTextAppendsFirstPageRawSubContentOnceWithoutFetchingUrlLookingText() {
        Peer { e -> when (e.requestURI.path) {
            "/chapter" -> respond(e, "<div id='text'>FIRST</div><a class='next' href='/page2'>next</a>")
            "/page2" -> respond(e, "<div id='text'>SECOND</div>")
            else -> error("Sub-content must not introduce another request")
        } }.use { peer ->
            val raw = "  https://literal.invalid/副文 <b>&amp;</b>  "
            Owned(source(peer.origin, "@js:book.putVariable('sub','accepted');String(result).indexOf('FIRST')>=0?'$raw':'WRONG_PAGE'")).use { owned ->
                val result = owned.result()
                val content = result["content"].asString
                assertTrue(content, content.indexOf("FIRST") < content.indexOf("SECOND"))
                assertTrue(content, content.endsWith("\n$raw"))
                assertEquals(1, Regex("https://literal.invalid/").findAll(content).count())
                assertFalse(content.contains("WRONG_PAGE"))
                assertEquals("accepted", parseObject(result["book"].asJsonObject["variable"].asString)["sub"].asString)
                assertEquals(listOf("/chapter", "/page2"), peer.requests.toList())
            }
        }
    }

    @Test(timeout = 20_000) fun replacementSeesAppendedRawTextBeforeOriginalOnlineTextIndentationAndTitle() {
        Peer { respond(it, "<div id='text'>主REMOVE文</div>") }.use { peer ->
            val config = source(peer.origin, "@js:'   副REMOVE文  \\n尾行  '").apply {
                getAsJsonObject("ruleContent").addProperty("replaceRegex", "##REMOVE##")
                getAsJsonObject("ruleContent").addProperty("title", "@js:book.putVariable('afterSub','yes');'已处理'")
            }
            Owned(config).use { owned ->
                val result = owned.result(); val text = result["content"].asString
                assertEquals(listOf("　　主文", "　　副文", "　　尾行"), text.lines().filter { it.trim().isNotEmpty() })
                assertTrue(text, text.lines().all { it.startsWith("　　") })
                assertFalse(text.contains("REMOVE"))
                assertEquals("已处理", result["chapter"].asJsonObject["title"].asString)
                assertEquals("yes", parseObject(result["book"].asJsonObject["variable"].asString)["afterSub"].asString)
                assertEquals(listOf("/chapter"), peer.requests.toList())
            }
        }
    }

    @Test(timeout = 20_000) fun typedControlFailureDuringSubContentNeverPublishesPartialContent() {
        Peer { respond(it, "<div id='text'>PARTIAL</div>") }.use { peer ->
            val script = "@js:java.connect(source.getKey()+'/must-not-fetch,{\"webView\":true}');'ignored'"
            Owned(source(peer.origin, script)).use { owned ->
                val response = owned.response()
                assertFalse(response.toString(), response["ok"].asBoolean)
                assertEquals("UNSUPPORTED_CAPABILITY", response["error"].asJsonObject["code"].asString)
                assertFalse(response.has("result"))
                assertEquals(listOf("/chapter"), peer.requests.toList())
            }
        }
    }

    @Test(timeout = 20_000) fun absentEmptyAndBlankSubContentPreserveExistingTextWithoutReplacementIndentation() {
        Peer { respond(it, "<div id='text'>BODY</div>") }.use { peer ->
            val texts = listOf(null, "", " \r\n\t ").map { rule ->
                Owned(source(peer.origin, rule)).use { it.result()["content"].asString }
            }
            assertEquals(1, texts.toSet().size)
            assertTrue(texts.first().contains("BODY"))
            assertFalse(texts.first().contains("　　"))
            assertEquals(listOf("/chapter", "/chapter", "/chapter"), peer.requests.toList())
        }
    }

    private class Owned(config: JsonObject) : Closeable {
        private val root = Files.createTempDirectory("original-subcontent-")
        private val host = RulePersistenceHost(FileRulePersistenceAdapter(root))
        private val origin = config["bookSourceUrl"].asString
        private val id: String
        init {
            LegadoRuntime.setHostCallback { _, operation, raw ->
                if (operation == "task.cancel") "{}" else host.dispatch(operation, parseObject(raw)).toString()
            }
            val created = parseObject(LegadoRuntime.createSession(config.toString(),
                jsonObject("httpTransport" to "jvm-okhttp", "stateOwner" to "original-subcontent-owner", "sourceMode" to "original-traditional").toString()))
            check(created["ok"].asBoolean) { created.toString() }
            id = created["sessionId"].asString
        }
        fun response(): JsonObject {
            val bookURL = "$origin/book"
            val book = jsonObject("bookUrl" to bookURL, "origin" to origin, "tocUrl" to "$origin/toc", "type" to 8)
            val chapter = jsonObject("url" to "/chapter", "title" to "Original", "bookUrl" to bookURL, "baseUrl" to origin, "index" to 0)
            return parseObject(LegadoRuntime.execute(id, "original-subcontent-${UUID.randomUUID()}", "getContent",
                jsonObject("book" to book, "chapter" to chapter, "needSave" to false).toString()))
        }
        fun result(): JsonObject {
            val response = response()
            assertTrue(response.toString(), response["ok"].asBoolean)
            return response["result"].asJsonObject
        }
        override fun close() {
            LegadoRuntime.closeSession(id); LegadoRuntime.setHostCallback(null)
            check(root.toFile().deleteRecursively())
        }
    }
    private class Peer(handler: (HttpExchange) -> Unit) : Closeable {
        val requests = CopyOnWriteArrayList<String>()
        private val failures = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool()
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            this.executor = this@Peer.executor
            createContext("/") { exchange ->
                requests += exchange.requestURI.path
                try { handler(exchange) } catch (failure: Throwable) { failures += failure } finally { exchange.close() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() {
            server.stop(0); executor.shutdownNow()
            check(executor.awaitTermination(3, TimeUnit.SECONDS))
            if (failures.isNotEmpty()) throw AssertionError("Owned sub-content peer failed", failures.first())
        }
    }
    companion object {
        private fun source(origin: String, subContent: String?) = jsonObject("bookSourceUrl" to origin,
            "ruleContent" to jsonObject("content" to "#text@html", "nextContentUrl" to ".next@href").apply {
                if (subContent != null) addProperty("subContent", subContent)
            })
        private fun respond(exchange: HttpExchange, text: String) {
            val raw = text.toByteArray(Charsets.UTF_8)
            exchange.responseHeaders.add("Content-Type", "text/html; charset=utf-8")
            exchange.sendResponseHeaders(200, raw.size.toLong()); exchange.responseBody.write(raw)
        }
    }
}
