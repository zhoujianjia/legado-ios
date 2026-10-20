package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.Job
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.charset.Charset
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import java.util.zip.GZIPOutputStream

/** Actual ordinary facade requests, with no HTTP dispatcher/probe replacement. */
class ProductionHttpTransportTest {
    private val sessions = mutableListOf<String>()
    @After fun closeSessions() { sessions.forEach(LegadoRuntime::closeSession); LegadoRuntime.setHostCallback(null) }

    @Test(timeout = 30_000) fun mainJsFullReadingChainUsesProductionClientAndPreservesOrderedWireHeaders() {
        LegadoRuntime.setHostCallback { _, operation, _ -> error("Unexpected native host: $operation") }
        ReferenceLoopbackFixture().use { peer ->
            val script = javaClass.getResourceAsStream("/fixtures/main-source.js")!!.bufferedReader().use { it.readText() }
            val source = jsonObject("bookSourceUrl" to peer.origin, "bookSourceName" to "Synthetic fixture",
                "mainJs" to script, "jsLib" to ReferenceLoopbackFixture.SHARED_JS_LIB,
                "header" to ReferenceLoopbackFixture.FIXED_HEADERS, "enabledCookieJar" to true)
            val session = create(source)
            assertTrue(call(session, "login").asBoolean)
            val book = call(session, "search", jsonObject("key" to "书", "page" to 1)).asJsonArray.single()
            val details = call(session, "details", jsonObject("book" to book))
            val chapters = call(session, "toc", jsonObject("book" to details)).asJsonArray
            assertEquals(ReferenceLoopbackFixture.CONTENT_ONE,
                call(session, "content", jsonObject("book" to details, "chapter" to chapters[0])).asString)
            assertEquals(0, call(session, "batch", jsonObject("book" to details, "chapters" to chapters)).asJsonObject["missing"].asJsonArray.size())
            assertEquals(7, peer.requests().size)
            peer.requests().forEach { request ->
                assertEquals(listOf("close", "Keep-Alive"), request.headers.filter { it.first.equals("Connection", true) }.map { it.second })
                assertEquals("300", request.header("Keep-Alive"))
                assertTrue(request.awaitResponse(2_000))
            }
            assertEquals("application/x-www-form-urlencoded; charset=utf-8", peer.requests()[0].header("Content-Type"))
            assertEquals("sid=fixture", peer.requests()[1].header("Cookie"))
            assertEquals("Bearer fixture", peer.requests()[1].header("Authorization"))
            peer.assertHealthy()
        }
    }

    @Test(timeout = 15_000) fun redirectCookiesAreSavedAtEachHopAndRespectPathAndDisabledJar() {
        WebPeer { exchange ->
            when (exchange.requestURI.path) {
                "/start" -> { exchange.responseHeaders.add("Set-Cookie", "first=a; Path=/"); exchange.responseHeaders.add("Location", "/cookie/path"); respond(exchange, "", status = 302) }
                "/cookie/path" -> { assertTrue(exchange.requestHeaders.getFirst("Cookie").orEmpty().contains("first=a")); exchange.responseHeaders.add("Set-Cookie", "scoped=b; Path=/cookie"); exchange.responseHeaders.add("Location", "/finish"); respond(exchange, "", status = 302) }
                "/finish" -> respond(exchange, exchange.requestHeaders.getFirst("Cookie").orEmpty())
                "/disabled" -> { exchange.responseHeaders.add("Set-Cookie", "disabled=yes; Path=/"); respond(exchange, "done") }
            }
        }.use { peer ->
            val session = create(peer.origin, enabledCookieJar = true)
            assertEquals("first=a", evaluate(session, "java.ajax(baseUrl+'/start')").asString)
            assertEquals("first=a", evaluate(session, "cookie.getCookie(baseUrl+'/finish')").asString)
            val disabled = create(peer.origin, enabledCookieJar = false)
            assertEquals("done", evaluate(disabled, "java.ajax(baseUrl+'/disabled')").asString)
            assertEquals("", evaluate(disabled, "cookie.getCookie(baseUrl)").asString)
            val noFollow = create(peer.origin, enabledCookieJar = true)
            assertEquals(302, evaluate(noFollow, "java.connect(baseUrl+'/start,{\"followRedirects\":false}').code()").asInt)
        }
    }

    @Test(timeout = 15_000) fun automaticLoginHeaderStaysOnItsSiteAndExplicitOverrideStillWorks() {
        WebPeer { exchange -> respond(exchange, exchange.requestHeaders.getFirst("Authorization").orEmpty()) }.use { peer ->
            val session = create(peer.origin)
            evaluate(session, "source.putLoginHeader('{\"Authorization\":\"Bearer source\"}')")
            assertEquals("Bearer source", evaluate(session, "java.ajax(baseUrl+'/same')").asString)
            assertEquals("", evaluate(session, "java.connect(baseUrl+'/same','{}').body()").asString)
            val other = peer.origin.replace("127.0.0.1", "localhost")
            assertEquals("", evaluate(session, "java.ajax('$other/other')").asString)
            assertEquals("Bearer explicit", evaluate(session, "java.connect('$other/explicit','{\"Authorization\":\"Bearer explicit\"}').body()").asString)
        }
        assertTrue(ProductionHttpTransport.sameLoginSite("https://www.example.co.uk", "https://cdn.example.co.uk/a"))
        assertFalse(ProductionHttpTransport.sameLoginSite("https://example.co.uk", "https://example.com"))
    }

    @Test(timeout = 15_000) fun transparentGzipDeflateAndBrotliAreDecodedButAuthoredEncodingOptsOut() {
        val expected = "hello world"
        val brotli = byteArrayOf(0x0b, 0x05, 0x80.toByte()) + expected.toByteArray() + byteArrayOf(0x03)
        val gzip = ByteArrayOutputStream().apply { GZIPOutputStream(this).use { it.write(expected.toByteArray()) } }.toByteArray()
        val deflate = ByteArrayOutputStream().apply { DeflaterOutputStream(this, Deflater(6, true)).use { it.write(expected.toByteArray()) } }.toByteArray()
        WebPeer { exchange ->
            val encoding = exchange.requestURI.path.drop(1)
            exchange.responseHeaders.add("Content-Encoding", encoding)
            respond(exchange, when (encoding) { "gzip" -> gzip; "deflate" -> deflate; else -> brotli })
        }.use { peer ->
            val session = create(peer.origin)
            for (encoding in listOf("gzip", "deflate", "br")) {
                assertEquals(encoding, expected, evaluate(session, "java.ajax(baseUrl+'/$encoding')").asString)
            }
            assertTrue(peer.requests.all { request -> request.headers.entries.first { it.key.equals("Accept-Encoding", true) }.value == listOf("gzip, deflate, br") })
            val directSession = RuntimeSession("explicit-encoding", jsonObject("bookSourceUrl" to peer.origin), RuntimeSessionOptions("jvm-okhttp"))
            try {
                val task = RuntimeTask("explicit-encoding", directSession, Job(), System.currentTimeMillis() + 5_000)
                val request = LegadoHttpRequestPreprocessor.prepare(peer.origin + "/gzip", "GET", mapOf("Accept-Encoding" to "gzip"), null, null, false)
                val response = directSession.http!!.request(task, request)
                assertArrayEquals(gzip, Base64.getDecoder().decode(response["bodyBase64"].asString))
            } finally { directSession.http!!.close() }
        }
    }

    @Test(timeout = 15_000) fun responseCharsetUsesHeaderThenHtmlMetaThenOriginalDetectorAndRemovesUtf8Bom() {
        val expected = "中文正文，这是中文书籍的章节内容。"
        WebPeer { exchange ->
            when (exchange.requestURI.path) {
                "/header" -> respond(exchange, expected.toByteArray(Charset.forName("GB18030")), "text/plain; charset=GB18030")
                "/meta" -> respond(exchange, "<head><meta charset='GB18030'></head><body>$expected</body>".toByteArray(Charset.forName("GB18030")), "text/html")
                "/bom" -> respond(exchange, byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) + expected.toByteArray(), "text/plain; charset=UTF-8")
                else -> respond(exchange, expected.toByteArray(), "text/plain")
            }
        }.use { peer ->
            val session = create(peer.origin)
            for (path in listOf("header", "bom", "detector")) assertEquals(path, expected, evaluate(session, "java.ajax(baseUrl+'/$path')").asString)
            assertTrue(evaluate(session, "java.ajax(baseUrl+'/meta')").asString.endsWith("<body>$expected</body>"))
        }
    }

    @Test(timeout = 15_000) fun cancellationAfterHeadersAndCloseSessionUnblockBodyWithoutClearingLiveStateEarly() {
        for (close in listOf(false, true)) ReferenceLoopbackFixture(ReferenceLoopbackFixture.Mode.BLOCK_AFTER_HEADERS).use { peer ->
            val session = create(peer.origin)
            val taskId = UUID.randomUUID().toString()
            val worker = Executors.newSingleThreadExecutor()
            try {
                val result = worker.submit<String> { LegadoRuntime.execute(session, taskId, "evaluate",
                    jsonObject("script" to "java.ajax(baseUrl+'/blocked')", "timeoutMs" to 10_000).toString()) }
                assertTrue(peer.headersSent.await(5, TimeUnit.SECONDS))
                if (close) LegadoRuntime.closeSession(session) else LegadoRuntime.cancel(taskId)
                assertEquals("CANCELLED", parseObject(result.get(3, TimeUnit.SECONDS))["error"].asJsonObject["code"].asString)
                if (close) assertEquals("UNKNOWN_SESSION", parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), "snapshot", "{}"))["error"].asJsonObject["code"].asString)
                else assertEquals(42, evaluate(session, "42").asInt)
            } finally { worker.shutdownNow(); assertTrue(worker.awaitTermination(2, TimeUnit.SECONDS)) }
        }
    }

    @Test(timeout = 10_000) fun expiredAbsoluteDeadlineCannotBecomeSuccessfulNetworkErrorText() {
        val session = RuntimeSession("deadline", jsonObject("bookSourceUrl" to "http://127.0.0.1:1"), RuntimeSessionOptions("jvm-okhttp"))
        val task = RuntimeTask("deadline", session, Job(), System.currentTimeMillis() - 1)
        try {
            val host = SourceJavaHost(task) { t, _, input -> session.http!!.request(t, input) }
            assertThrows(kotlinx.coroutines.CancellationException::class.java) { host.ajax("http://127.0.0.1:1/") }
            assertTrue(task.timedOut.get())
        } finally { session.http!!.close() }
        ReferenceLoopbackFixture(ReferenceLoopbackFixture.Mode.BLOCK_BEFORE_HEADERS).use { peer ->
            val runtimeSession = create(peer.origin)
            val response = parseObject(LegadoRuntime.execute(runtimeSession, UUID.randomUUID().toString(), "evaluate",
                jsonObject("script" to "java.ajax(baseUrl+'/blocked')", "timeoutMs" to 300).toString()))
            assertEquals("TIMEOUT", response["error"].asJsonObject["code"].asString)
        }
    }

    @Test fun explicitSessionOptionsDoNotPolluteSourceAndUnsupportedHostsOrUrlOptionsFailBeforeNetwork() {
        val source = jsonObject("bookSourceUrl" to "https://fixture.invalid", "mainJs" to "function search(){return [];}")
        val before = source.deepCopy()
        val session = create(source)
        assertEquals(before, source)
        for (script in listOf("java.get(baseUrl,null)", "java.head(baseUrl,null)", "java.post(baseUrl,'x',null)", "java.ajax(baseUrl+', {\"webView\":true}')", "java.ajax(baseUrl+', {\"dnsIp\":\"127.0.0.1\"}')")) {
            val response = parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), "evaluate", jsonObject("script" to script).toString()))
            assertEquals(script, "UNSUPPORTED_CAPABILITY", response["error"].asJsonObject["code"].asString)
        }
        val bad = parseObject(LegadoRuntime.createSession(source.toString(), "{\"httpTransport\":\"unknown\"}"))
        assertFalse(bad["ok"].asBoolean)
    }

    @Test(timeout = 10_000) fun statusRetryAndEarlyCancellationUseOrdinaryFacadeWithoutNativeHost() {
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        WebPeer { exchange -> respond(exchange, "attempt", if (attempts.incrementAndGet() < 3) 500 else 200) }.use { peer ->
            val session = create(peer.origin)
            val taskId = UUID.randomUUID().toString()
            LegadoRuntime.cancel(taskId)
            val cancelled = parseObject(LegadoRuntime.execute(session, taskId, "evaluate", jsonObject("script" to "java.ajax(baseUrl)").toString()))
            assertEquals("CANCELLED", cancelled["error"].asJsonObject["code"].asString)
            assertEquals(0, attempts.get())
            assertEquals("attempt", evaluate(session, "java.ajax(baseUrl+', {\"retry\":2}')").asString)
            assertEquals(3, attempts.get())
        }
    }

    @Test fun delayedDeadlineSchedulerCannotTurnAnIOExceptionIntoSuccessfulStackText() {
        val session = RuntimeSession("delayed-timer", jsonObject("bookSourceUrl" to "https://fixture.invalid"), RuntimeSessionOptions("jvm-okhttp"))
        val task = RuntimeTask("delayed-timer", session, Job(), System.currentTimeMillis() + 30)
        try {
            // There is intentionally no scheduled cancellation for this task.
            // The synchronous check must enforce the parent deadline itself.
            val host = SourceJavaHost(task) { _, _, _ -> Thread.sleep(60); throw java.net.SocketTimeoutException("request failed after parent deadline") }
            assertThrows(kotlinx.coroutines.CancellationException::class.java) { host.ajax("https://fixture.invalid/") }
            assertTrue(task.timedOut.get())
        } finally { session.http!!.close() }
    }

    @Test fun legacyConstructorKeepsItsExplicitPlatformInjectionPath() {
        var count = 0
        LegadoRuntime.setHostCallback { _, operation, _ -> assertEquals("http.request", operation); count++; jsonObject("status" to 200, "body" to "platform").toString() }
        val result = parseObject(LegadoRuntime.createSession(jsonObject("bookSourceUrl" to "https://fixture.invalid", "mainJs" to "function search(){return [];}").toString()))
        val session = result["sessionId"].asString.also(sessions::add)
        assertEquals("platform", evaluate(session, "java.ajax(baseUrl)").asString)
        assertEquals(1, count)
    }

    @Test(timeout = 10_000) fun connectReturnsRealJvmHeadersAndRawResponseMetadataWithoutLosingDuplicates() {
        WebPeer { exchange ->
            exchange.responseHeaders.add("Set-Cookie", "one=a; Path=/")
            exchange.responseHeaders.add("Set-Cookie", "two=b; Path=/")
            respond(exchange, "body")
        }.use { peer ->
            val session = create(peer.origin)
            val result = evaluate(session, "var response=java.connect(baseUrl); ({code:response.raw().code(),cookies:response.headers().values('Set-Cookie').size(),ok:response.isSuccessful(),body:response.body()})").asJsonObject
            assertEquals(200, result["code"].asInt)
            assertEquals(2, result["cookies"].asInt)
            assertTrue(result["ok"].asBoolean)
            assertEquals("body", result["body"].asString)
        }
    }

    private fun create(origin: String, enabledCookieJar: Boolean = false) = create(jsonObject("bookSourceUrl" to origin,
        "enabledCookieJar" to enabledCookieJar, "mainJs" to "function search(){return [];}"))
    private fun create(source: JsonObject): String {
        val response = parseObject(LegadoRuntime.createSession(source.toString(), "{\"httpTransport\":\"jvm-okhttp\"}"))
        assertTrue(response.toString(), response["ok"].asBoolean)
        return response["sessionId"].asString.also(sessions::add)
    }
    private fun call(session: String, operation: String, input: JsonObject = JsonObject()) =
        parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), operation, input.toString())).let {
            assertTrue(it.toString(), it["ok"].asBoolean); it["result"]
        }
    private fun evaluate(session: String, script: String) = call(session, "evaluate", jsonObject("script" to script))

    private data class RequestCapture(val path: String, val headers: Map<String, List<String>>)
    private class WebPeer(private val handler: (HttpExchange) -> Unit) : Closeable {
        val requests = CopyOnWriteArrayList<RequestCapture>()
        private val executor = Executors.newCachedThreadPool { Thread(it, "production-http-test-peer").apply { isDaemon = true } }
        private val failures = CopyOnWriteArrayList<Throwable>()
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = this@WebPeer.executor
            createContext("/") { exchange ->
                requests += RequestCapture(exchange.requestURI.toString(), exchange.requestHeaders.mapValues { it.value.toList() })
                try { handler(exchange) } catch (error: Throwable) { failures += error } finally { exchange.close() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() {
            server.stop(0); executor.shutdownNow(); check(executor.awaitTermination(2, TimeUnit.SECONDS))
            if (failures.isNotEmpty()) throw AssertionError("Peer failed", failures.first())
        }
    }
    companion object {
        private fun respond(exchange: HttpExchange, body: String, status: Int = 200) = respond(exchange, body.toByteArray(), status = status)
        private fun respond(exchange: HttpExchange, body: ByteArray, contentType: String = "text/plain; charset=utf-8", status: Int = 200) {
            exchange.responseHeaders.add("Content-Type", contentType)
            exchange.sendResponseHeaders(status, if (body.isEmpty()) -1 else body.size.toLong())
            if (body.isNotEmpty()) exchange.responseBody.write(body)
        }
    }
}
