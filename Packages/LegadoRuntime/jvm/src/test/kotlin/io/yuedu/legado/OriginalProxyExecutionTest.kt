package io.yuedu.legado

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.yuedu.legado.originalrule.AnalyzeRule
import io.yuedu.legado.originalrule.RuleSource
import io.legado.app.model.analyzeRule.AnalyzeUrl
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import okhttp3.Credentials
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real public original-rule/host requests through the single JVM transport. */
class OriginalProxyExecutionTest {
    @Test(timeout = 15_000) fun sourceAndExplicitProxyDefaultsUseExistingHttpAndCookieOwner() {
        HttpPeer { e ->
            val combined = e.requestURI.path == "/combined-order"
            assertEquals(if (combined) "http://target.invalid/combined-order" else "http://target.invalid/result", e.requestURI.toString())
            assertEquals(if (combined) "url-option-literal" else null, e.requestHeaders.getFirst("proxy"))
            assertTrue(e.requestHeaders.getFirst("Cookie").split(';').map(String::trim).contains("original=kept"))
            e.responseHeaders.add("Set-Cookie", "updated=yes; Path=/")
            respond(e, "through-proxy")
        }.use { peer -> Session("http://target.invalid", "http://127.0.0.1:${peer.port}").use { owned ->
            owned.environment.cookie.setCookie("http://target.invalid", "original=kept")
            AnalyzeRule(source = owned.source).use { rule ->
                assertEquals("through-proxy", rule.connect("http://target.invalid/result").body())
                // Source proxy is captured/removed before option headers. The
                // option's lowercase proxy is a literal HTTP header, not a new
                // routing authority; both public gateways must retain this order.
                assertEquals("through-proxy", rule.connect("http://target.invalid/combined-order,{\"headers\":{\"proxy\":\"url-option-literal\"}}").body())
            }
            assertEquals("yes", owned.environment.cookie.getCookie("http://target.invalid", "updated"))
            // The mainJs gateway has its own finite prep, but the same transport.
            val gateway = SourceJavaHost(owned.task) { task, op, input ->
                assertEquals("http.request", op)
                owned.session.http!!.request(task, input)
            }
            assertEquals("through-proxy", gateway.connect("http://target.invalid/result",
                "{\"proxy\":\"http://127.0.0.1:${peer.port}\",\"Cookie\":\"original=kept\"}").body())
            assertEquals("through-proxy", gateway.connect("http://target.invalid/combined-order,{\"headers\":{\"proxy\":\"url-option-literal\"}}",
                "{\"proxy\":\"http://127.0.0.1:${peer.port}\",\"Cookie\":\"original=kept\"}").body())
            assertEquals(4, peer.requests.size)
        } }
    }

    @Test(timeout = 15_000) fun httpProxyChallengesAreBoundedAndDoNotAuthorizeLaterDirectRequest() {
        val credential = Credentials.basic("synthetic-user", "synthetic-pass")
        HttpPeer { e ->
            if (e.requestHeaders.getFirst("Proxy-Authorization") == null) {
                e.responseHeaders.add("Proxy-Authenticate", "Basic realm=\"owned\"")
                respond(e, "challenge", 407)
            } else {
                assertEquals(credential, e.requestHeaders.getFirst("Proxy-Authorization"))
                respond(e, "authenticated")
            }
        }.use { proxy -> HttpPeer { e ->
            assertNull(e.requestHeaders.getFirst("Proxy-Authorization"))
            respond(e, "direct")
        }.use { direct -> Session("http://target.invalid",
            "http://synthetic-user:synthetic-pass@127.0.0.1:${proxy.port}").use { owned ->
            AnalyzeRule(source = owned.source).use { rule ->
                assertEquals("authenticated", rule.connect("http://target.invalid/auth").body())
            }
            owned.source.header = "{}"
            AnalyzeRule(source = owned.source).use { rule ->
                assertEquals("direct", rule.connect("http://127.0.0.1:${direct.port}/after").body())
            }
            assertEquals(2, proxy.requests.size)
            assertEquals(1, direct.requests.size)
        } } }
        HttpPeer { e ->
            e.responseHeaders.add("Proxy-Authenticate", "Basic realm=\"reject\"")
            respond(e, "still denied", 407)
        }.use { proxy -> Session("http://target.invalid",
            "http://synthetic-user:synthetic-pass@127.0.0.1:${proxy.port}").use { owned ->
            AnalyzeRule(source = owned.source).use { rule ->
                assertEquals(407, rule.connect("http://target.invalid/rejected").code())
            }
            assertEquals("One challenge followed by one authorized attempt", 2, proxy.requests.size)
        } }
    }

    @Test(timeout = 15_000) fun authenticatedSocksUsesOriginalDomainProtocolAndOwnedCancellation() {
        RawPeer { socket ->
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            assertArrayEquals(byteArrayOf(5, 1, 2), read(input, 3))
            output.write(byteArrayOf(5, 2)); output.flush()
            assertEquals(1, input.read())
            assertEquals("synthetic+user", String(read(input, input.read()), Charsets.UTF_8))
            assertEquals("密", String(read(input, input.read()), Charsets.UTF_8))
            output.write(byteArrayOf(1, 0)); output.flush()
            assertArrayEquals(byteArrayOf(5, 1, 0, 3), read(input, 4))
            assertEquals("unresolved.invalid", String(read(input, input.read()), Charsets.UTF_8))
            assertArrayEquals(byteArrayOf(31, -69), read(input, 2)) // 8123, network byte order.
            output.write(byteArrayOf(5, 0, 0, 1, 0, 0, 0, 0, 0, 0)); output.flush()
            val headers = readHeaders(input)
            assertTrue(headers, headers.startsWith("GET /socks HTTP/1.1\r\n"))
            assertFalse(headers.contains("Proxy-Authorization", true))
            val body = "socks-body".toByteArray()
            output.write("HTTP/1.1 200 OK\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
            output.write(body); output.flush()
        }.use { proxy -> Session("http://unresolved.invalid:8123",
            "socks5://synthetic%2Buser:%E5%AF%86@127.0.0.1:${proxy.port}").use { owned ->
            AnalyzeRule(source = owned.source).use { rule ->
                assertEquals("socks-body", rule.connect("http://unresolved.invalid:8123/socks").body())
            }
            proxy.completed()
        } }
        val entered = CountDownLatch(1)
        val drained = CountDownLatch(1)
        RawPeer { socket ->
            assertArrayEquals(byteArrayOf(5, 1, 2), read(socket.getInputStream(), 3))
            entered.countDown()
            assertEquals("Cancellation must close the blocked SOCKS socket", -1, socket.getInputStream().read())
            drained.countDown()
        }.use { proxy -> Session("http://unresolved.invalid:8123",
            "socks5://synthetic-user:synthetic-pass@127.0.0.1:${proxy.port}").use { owned ->
            val executor = Executors.newSingleThreadExecutor()
            try {
                val future = executor.submit<String> {
                    AnalyzeRule(source = owned.source).use { it.connect("http://unresolved.invalid:8123/cancel").body() }
                }
                assertTrue(entered.await(3, TimeUnit.SECONDS))
                owned.task.job.cancel()
                val error = assertThrows(ExecutionException::class.java) { future.get(3, TimeUnit.SECONDS) }
                assertTrue(error.cause.toString(), error.cause is CancellationException)
                assertTrue(drained.await(3, TimeUnit.SECONDS))
                proxy.completed()
            } finally {
                owned.task.job.cancel(); executor.shutdownNow()
                assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS))
            }
        } }
    }

    @Test(timeout = 10_000) fun proxyDnsIpConflictIsRejectedBeforeAnyPeerRequest() {
        HttpPeer { error("Conflicting DNS/proxy must not contact the peer") }.use { proxy ->
            Session("http://target.invalid", "http://127.0.0.1:${proxy.port}").use { owned ->
                AnalyzeRule(source = owned.source).use { rule ->
                    val url = "http://target.invalid/conflict,{\"dnsIp\":\"127.0.0.1\"}"
                    val error = assertThrows(IllegalArgumentException::class.java) {
                        runBlocking(owned.task.job) {
                            AnalyzeUrl(url, source = owned.source, environment = owned.environment,
                                coroutineContext = owned.task.job).getStrResponseAwait()
                        }
                    }
                    assertEquals("dnsIp cannot be used together with a proxy", error.message)
                    // Locked JsExtensions240-252 catches execution failures;
                    // its StrResponse(url,errorText) constructor is raw200.
                    val response = rule.connect(url)
                    assertEquals(200, response.code())
                    assertTrue(response.body(), response.body().contains("java.lang.IllegalArgumentException: dnsIp cannot be used together with a proxy"))
                }
                assertTrue(proxy.requests.isEmpty())
            }
        }
    }

    private class Session(origin: String, proxy: String) : Closeable {
        val session = RuntimeSession(UUID.randomUUID().toString(), jsonObject("bookSourceUrl" to origin,
            "header" to jsonObject("proxy" to proxy).toString(), "enabledCookieJar" to true), RuntimeSessionOptions("jvm-okhttp"))
        val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + 10_000)
        val environment = LegadoRuntime.originalRuleEnvironment(task)
        val source = RuleSource(environment, origin, "Owned", header = jsonObject("proxy" to proxy).toString())
        override fun close() { environment.close(); task.job.cancel(); session.closed.set(true); session.http!!.close() }
    }
    private class HttpPeer(handler: (HttpExchange) -> Unit) : Closeable {
        val requests = CopyOnWriteArrayList<String>()
        private val failures = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool()
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = this@HttpPeer.executor
            createContext("/") { exchange ->
                try { requests += exchange.requestURI.toString(); handler(exchange) }
                catch (error: Throwable) { failures += error }
                finally { exchange.close() }
            }
            start()
        }
        val port: Int get() = server.address.port
        override fun close() {
            server.stop(0); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS))
            if (failures.isNotEmpty()) throw AssertionError("Owned HTTP proxy failed", failures.first())
        }
    }
    private class RawPeer(handler: (Socket) -> Unit) : Closeable {
        private val server = ServerSocket(0, 1, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
        private val executor = Executors.newSingleThreadExecutor()
        private val sockets = CopyOnWriteArrayList<Socket>()
        private val result = executor.submit<Unit> {
            server.accept().use { socket -> sockets += socket; socket.soTimeout = 5_000; handler(socket) }
        }
        val port: Int get() = server.localPort
        fun completed() { result.get(3, TimeUnit.SECONDS) }
        override fun close() {
            sockets.forEach(Socket::close); server.close(); executor.shutdownNow()
            check(executor.awaitTermination(3, TimeUnit.SECONDS))
        }
    }
    companion object {
        private fun respond(e: HttpExchange, body: String, code: Int = 200) {
            val bytes = body.toByteArray(Charsets.UTF_8)
            e.sendResponseHeaders(code, bytes.size.toLong()); e.responseBody.write(bytes)
        }
        private fun read(input: InputStream, count: Int): ByteArray {
            require(count >= 0)
            return ByteArray(count).also { bytes ->
                var offset = 0
                while (offset < count) {
                    val size = input.read(bytes, offset, count - offset)
                    check(size > 0) { "Incomplete owned SOCKS exchange" }; offset += size
                }
            }
        }
        private fun readHeaders(input: InputStream): String {
            val text = StringBuilder()
            while (!text.endsWith("\r\n\r\n")) {
                val char = input.read(); check(char >= 0 && text.length < 65_536)
                text.append(char.toChar())
            }
            return text.toString()
        }
    }
}
