package io.yuedu.legado

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.yuedu.legado.originalrule.RuleEnvironment
import io.yuedu.legado.originalrule.RuleSource
import io.yuedu.legado.originalrule.UnsupportedRuleCapability
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.coroutines.EmptyCoroutineContext

/** Real retained coordinator + ordinary production OkHttp; only an owned loopback peer. */
class OriginalRuleHttpPlatformTest {
    @Test(timeout = 15_000) fun retainedRuleCallsUseProductionHttpAndKeepJvmResponseTypes() {
        Peer { exchange -> respond(exchange, "正文", 207) }.use { peer ->
            Session(peer.origin).use { owned ->
                owned.environment().use { environment ->
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned fixture")).use { rule ->
                        val response = rule.connect(peer.origin + "/typed")
                        assertEquals("io.yuedu.legado.StrResponse", response.javaClass.name)
                        assertEquals("okhttp3.Response", response.raw().javaClass.name)
                        assertEquals("okhttp3.Headers", response.headers().javaClass.name)
                        assertEquals(207, response.code())
                        assertEquals("正文", response.body())
                        assertEquals(listOf("first", "second"), response.raw().headers.values("X-Owned"))
                        assertEquals("正文", rule.ajax(listOf(peer.origin + "/ajax", "unused")))
                        rule.setContent("<p>owned</p>", peer.origin)
                        assertEquals("正文", rule.getString("@js:java.connect(baseUrl + '/rule').body()", false))
                    }
                }
                assertEquals(listOf("/typed", "/ajax", "/rule"), peer.requests.map { it.path })
                assertEquals(3, owned.session.requests.size)
                owned.session.requests.forEach { request ->
                    assertEquals(owned.task.deadlineEpochMs, request["deadlineEpochMs"].asLong)
                    assertTrue(request["remainingTimeoutMs"].asLong > 0)
                }
            }
        }
    }

    @Test(timeout = 15_000) fun requestOptionsPreserveBodyBytesAndExplicitHeaderReplacement() {
        Peer { exchange -> respond(exchange, "ok") }.use { peer ->
            Session(peer.origin, headers = "{\"X-Source\":\"source\"}").use { owned ->
                owned.session.variables["@loginHeader"] = "{\"Authorization\":\"Bearer owned\"}"
                owned.environment().use { environment ->
                    val source = RuleSource(environment, peer.origin, "Owned fixture", header = "{\"X-Source\":\"source\"}")
                    source.putLoginHeader("{\"Authorization\":\"Bearer owned\"}")
                    AnalyzeRule(source = source).use { rule ->
                        val form = peer.origin + "/form," + jsonObject("method" to "POST", "body" to "name=书&plus=a+b",
                            "headers" to jsonObject("X-Option" to "option"))
                        assertEquals("ok", rule.connect(form, "{\"Connection\":\"close\",\"X-Explicit\":\"explicit\"}", 3_000L).body())
                        val structured = "{\"text\":\"书\"}"
                        val json = peer.origin + "/json," + jsonObject("method" to "POST", "body" to structured,
                            "headers" to jsonObject("Content-Type" to "application/json; charset=UTF-16LE"))
                        rule.connect(json)
                        rule.connect(peer.origin + "/head,{\"method\":\"HEAD\",\"followRedirects\":false}")
                        assertArrayEquals("name=%E4%B9%A6&plus=a%2Bb".toByteArray(), peer.requests[0].body)
                        assertEquals(listOf("close", "Keep-Alive"), peer.requests[0].header("Connection"))
                        assertEquals(listOf("explicit"), peer.requests[0].header("X-Explicit"))
                        assertEquals(listOf("option"), peer.requests[0].header("X-Option"))
                        assertTrue(peer.requests[0].header("X-Source").isEmpty())
                        assertTrue(peer.requests[0].header("Authorization").isEmpty())
                        assertArrayEquals(structured.toByteArray(Charsets.UTF_16LE), peer.requests[1].body)
                        assertEquals(listOf("source"), peer.requests[1].header("X-Source"))
                        assertEquals(listOf("Bearer owned"), peer.requests[1].header("Authorization"))
                        assertEquals("HEAD", peer.requests[2].method)
                        assertEquals(0, peer.requests[2].body.size)
                    }
                }
            }
        }
    }

    @Test(timeout = 15_000) fun unsupportedRulesStayTypedAndNeverReachTransport() {
        Peer { exchange -> respond(exchange, "unexpected") }.use { peer ->
            Session(peer.origin).use { owned ->
                owned.environment().use { environment ->
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned fixture")).use { rule ->
                        listOf(peer.origin + "/,{\"webView\":true}",
                            peer.origin + "/,{\"type\":\"binary\"}", peer.origin + "/,{\"serverID\":1}").forEach { url ->
                            assertThrows(UnsupportedRuleCapability::class.java) { rule.connect(url) }
                            assertThrows(UnsupportedRuleCapability::class.java) { rule.ajax(url) }
                        }
                        // Proxy is supported by the original HTTP path. Its real owned
                        // transport/credential/cancellation cases live in OriginalProxyExecutionTest.
                    }
                }
                assertTrue(peer.requests.isEmpty())
                assertTrue(owned.session.requests.isEmpty())
            }
        }
    }

    @Test(timeout = 15_000) fun ordinaryIoFailureReturnsStackResponseAndNextRequestRecovers() {
        Peer { exchange -> if (exchange.requestURI.path == "/disconnect") exchange.close() else respond(exchange, "recovered") }.use { peer ->
            Session(peer.origin).use { owned ->
                owned.environment().use { environment ->
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned fixture")).use { rule ->
                        val response = rule.connect(peer.origin + "/disconnect", null, 2_000L)
                        assertEquals(200, response.code())
                        assertTrue(response.body(), response.body().contains("java.io.IOException"))
                        assertEquals(200, response.raw().code)
                        assertEquals("OK", response.message())
                        assertEquals("recovered", rule.ajax(peer.origin + "/recover"))
                        assertTrue(owned.task.job.isActive)
                    }
                }
            }
        }
    }

    @Test(timeout = 15_000) fun taskAndCallerCancellationAbortHeldBodyWithoutReturningErrorText() {
        // Each case waits for actual response-body entry, not a settling delay.
        listOf(false, true).forEach { useCallerContext ->
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            Peer { exchange ->
                if (exchange.requestURI.path == "/held") {
                    exchange.sendResponseHeaders(200, 0)
                    exchange.responseBody.flush()
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS)) { "Owned body was not released" }
                } else respond(exchange, "recovered")
            }.use { peer ->
                Session(peer.origin).use { owned ->
                    val executor = Executors.newSingleThreadExecutor()
                    val caller = Job()
                    try {
                        owned.environment().use { environment ->
                            AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned fixture")).use { rule ->
                                if (useCallerContext) rule.setCoroutineContext(caller)
                                val result = executor.submit<String?> { rule.ajax(peer.origin + "/held") }
                                assertTrue("Real HTTP body did not enter", entered.await(3, TimeUnit.SECONDS))
                                if (useCallerContext) caller.cancel() else owned.task.job.cancel()
                                val failure = assertThrows(ExecutionException::class.java) { result.get(3, TimeUnit.SECONDS) }
                                assertTrue(failure.cause.toString(), failure.cause is CancellationException)
                                assertTrue(owned.task.job.isCancelled)
                            }
                        }
                        val next = RuntimeTask(UUID.randomUUID().toString(), owned.session, Job(), System.currentTimeMillis() + 5_000)
                        LegadoRuntime.originalRuleEnvironment(next).use { environment ->
                            AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned fixture")).use { rule ->
                                assertEquals("recovered", rule.ajax(peer.origin + "/recover"))
                            }
                        }
                    } finally {
                        release.countDown(); caller.cancel(); owned.task.job.cancel()
                        executor.shutdownNow()
                        check(executor.awaitTermination(3, TimeUnit.SECONDS))
                    }
                }
            }
        }
    }

    @Test(timeout = 15_000) fun taskDeadlineRemainsAuthoritativeDuringHeldResponse() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        Peer { exchange ->
            exchange.sendResponseHeaders(200, 0); exchange.responseBody.flush(); entered.countDown()
            check(release.await(5, TimeUnit.SECONDS))
        }.use { peer ->
            Session(peer.origin, timeoutMs = 700).use { owned ->
                val executor = Executors.newSingleThreadExecutor()
                try {
                    owned.environment().use { environment ->
                        AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned fixture")).use { rule ->
                            val result = executor.submit<String?> { rule.ajax(peer.origin + "/deadline") }
                            assertTrue(entered.await(3, TimeUnit.SECONDS))
                            val failure = assertThrows(ExecutionException::class.java) { result.get(3, TimeUnit.SECONDS) }
                            assertTrue(failure.cause.toString(), failure.cause is CancellationException)
                            assertTrue(owned.task.timedOut.get())
                        }
                    }
                } finally {
                    release.countDown(); owned.task.job.cancel(); executor.shutdownNow()
                    check(executor.awaitTermination(3, TimeUnit.SECONDS))
                }
            }
        }
    }

    @Test(timeout = 15_000) fun environmentCloseRejectsLatePublicationAndFinishedRequestDetachesCaller() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        Peer { exchange ->
            if (exchange.requestURI.path == "/held-close") {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            }
            respond(exchange, "owned result")
        }.use { peer ->
            Session(peer.origin).use { owned ->
                val executor = Executors.newSingleThreadExecutor()
                val caller = Job()
                try {
                    owned.environment().use { environment ->
                        AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned fixture")).use { rule ->
                            val result = executor.submit<String?> { rule.ajax(peer.origin + "/held-close") }
                            assertTrue(entered.await(3, TimeUnit.SECONDS))
                            environment.close()
                            assertTrue("Environment close must not cancel the shared task", owned.task.job.isActive)
                            release.countDown()
                            val failure = assertThrows(ExecutionException::class.java) { result.get(3, TimeUnit.SECONDS) }
                            assertTrue(failure.cause.toString(), failure.cause is CancellationException)
                            assertEquals("Original-rule environment is closed", failure.cause!!.message)
                            assertTrue(owned.task.job.isActive)
                        }
                    }
                    owned.environment().use { environment ->
                        AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned fixture")).use { rule ->
                            rule.setCoroutineContext(caller)
                            assertEquals("owned result", rule.ajax(peer.origin + "/finished"))
                            caller.cancel()
                            assertTrue("Finished request retained its caller cancellation handler", owned.task.job.isActive)
                            rule.setCoroutineContext(EmptyCoroutineContext)
                            assertEquals("owned result", rule.ajax(peer.origin + "/after-caller-cancel"))
                        }
                    }
                } finally {
                    release.countDown(); caller.cancel(); executor.shutdownNow()
                    check(executor.awaitTermination(3, TimeUnit.SECONDS))
                }
            }
        }
    }

    @Test(timeout = 15_000) fun missingTaskTransportAndClosedLifetimesStayFailClosed() {
        RuleEnvironment().use { environment ->
            AnalyzeRule(source = RuleSource(environment, "https://owned.invalid", "Owned fixture")).use { rule ->
                assertThrows(UnsupportedRuleCapability::class.java) { rule.connect("https://owned.invalid") }
            }
        }
        val prototype = RuntimeSession("owned-prototype", jsonObject("bookSourceUrl" to "https://owned.invalid"))
        val prototypeTask = RuntimeTask("owned-prototype", prototype, Job(), System.currentTimeMillis() + 5_000)
        assertThrows(IllegalArgumentException::class.java) { LegadoRuntime.originalRuleEnvironment(prototypeTask) }
        Session("https://owned.invalid").use { owned ->
            val environment = owned.environment()
            val rule = AnalyzeRule(source = RuleSource(environment, "https://owned.invalid", "Owned fixture"))
            environment.close()
            assertThrows(IllegalStateException::class.java) { rule.connect("https://owned.invalid") }
            rule.close()
            owned.session.closed.set(true)
            assertThrows(IllegalStateException::class.java) { owned.environment() }
            assertTrue(owned.session.requests.isEmpty())
        }
    }

    private class Session(origin: String, headers: String? = null, timeoutMs: Long = 10_000) : Closeable {
        val session = RuntimeSession(UUID.randomUUID().toString(), jsonObject("bookSourceUrl" to origin,
            "header" to headers), RuntimeSessionOptions("jvm-okhttp"))
        val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + timeoutMs)
        fun environment() = LegadoRuntime.originalRuleEnvironment(task)
        override fun close() { task.job.cancel(); session.closed.set(true); session.http!!.close() }
    }

    private data class Capture(val path: String, val method: String, val headers: Map<String, List<String>>, val body: ByteArray) {
        fun header(name: String) = headers.entries.firstOrNull { it.key.equals(name, true) }?.value.orEmpty()
    }
    private class Peer(handler: (HttpExchange) -> Unit) : Closeable {
        val requests = CopyOnWriteArrayList<Capture>()
        private val failures = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool { Thread(it, "original-rule-owned-peer").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = this@Peer.executor
            createContext("/") { exchange ->
                try {
                    requests += Capture(exchange.requestURI.toString(), exchange.requestMethod,
                        exchange.requestHeaders.mapValues { it.value.toList() }, exchange.requestBody.readBytes())
                    handler(exchange)
                } catch (error: Throwable) { failures += error } finally { exchange.close() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() {
            server.stop(0); executor.shutdownNow()
            check(executor.awaitTermination(3, TimeUnit.SECONDS))
            if (failures.isNotEmpty()) throw AssertionError("Owned peer failed", failures.first())
        }
    }
    companion object {
        private fun respond(exchange: HttpExchange, text: String, status: Int = 200) {
            exchange.responseHeaders.add("Content-Type", "text/plain; charset=utf-8")
            exchange.responseHeaders.add("X-Owned", "first"); exchange.responseHeaders.add("X-Owned", "second")
            if (exchange.requestMethod == "HEAD") exchange.sendResponseHeaders(status, -1)
            else {
                val bytes = text.toByteArray(Charsets.UTF_8)
                exchange.sendResponseHeaders(status, bytes.size.toLong()); exchange.responseBody.write(bytes)
            }
        }
    }
}
