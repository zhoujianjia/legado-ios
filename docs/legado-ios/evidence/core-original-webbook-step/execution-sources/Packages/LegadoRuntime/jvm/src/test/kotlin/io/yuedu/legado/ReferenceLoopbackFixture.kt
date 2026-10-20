package io.yuedu.legado

import com.google.gson.JsonObject
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Test infrastructure port of LegadoGoldenTraceTest.kt:298-401, not a new HTTP
 * client. Reference responses/request parsing are retained; Android Base64 is
 * replaced with its equivalent JDK encoder. Extra modes exercise transport only.
 */
internal class ReferenceLoopbackFixture(private val mode: Mode = Mode.REFERENCE) : Closeable {
    enum class Mode { REFERENCE, BLOCK_BEFORE_HEADERS, BLOCK_AFTER_HEADERS, MULTI_COOKIE }
    data class Capture(val method: String, val target: String, val version: String,
                       val headers: List<Pair<String, String>>, val body: ByteArray,
                       val head: ByteArray, val origin: String) {
        @Volatile var responseHead: ByteArray? = null
        @Volatile var responseBody: ByteArray? = null
        @Volatile var responseWritten = false
        private val responseCompleted = CountDownLatch(1)
        fun completeResponse() { responseWritten = true; responseCompleted.countDown() }
        fun awaitResponse(timeoutMs: Long): Boolean = responseCompleted.await(timeoutMs, TimeUnit.MILLISECONDS)
        fun comparable() = jsonObject("method" to method, "url" to origin + target,
            "requestTarget" to target, "httpVersion" to version,
            "headers" to headers.map { mapOf("name" to it.first, "value" to it.second) },
            "bodyBase64" to b64(body))
        fun evidence() = comparable().apply {
            addProperty("rawHeadBase64", b64(head)); addProperty("rawRequestSHA256", sha256(head + body))
            addProperty("responseWritten", responseWritten)
            responseHead?.let { addProperty("rawResponseHeadBase64", b64(it)) }
            responseBody?.let { addProperty("responseBodyBase64", b64(it)); addProperty("responseBodySHA256", sha256(it)) }
        }
        fun header(name: String): String? = headers.firstOrNull { it.first.equals(name, true) }?.second
    }

    private val listener = ServerSocket().apply {
        bind(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0)); soTimeout = 1000
    }
    val origin = "http://127.0.0.1:${listener.localPort}"
    val requestArrived = CountDownLatch(1)
    val headersSent = CountDownLatch(1)
    val releaseBody = CountDownLatch(1)
    private val captures = arrayListOf<Capture>()
    private val error = AtomicReference<Throwable?>()
    private val active = AtomicReference<Socket?>()
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "legado-reference-http").apply { isDaemon = true }
    }
    private val work = executor.submit {
        try {
            while (!listener.isClosed) {
                val socket = try { listener.accept() } catch (_: SocketTimeoutException) { continue }
                active.set(socket)
                if (listener.isClosed) { socket.close(); break }
                socket.use { client ->
                    client.soTimeout = 10_000
                    val capture = readRequest(client.getInputStream())
                    synchronized(captures) { captures.add(capture) }
                    requestArrived.countDown()
                    if (mode == Mode.BLOCK_BEFORE_HEADERS) check(releaseBody.await(10, TimeUnit.SECONDS)) { "Fixture release deadline" }
                    if (listener.isClosed) return@use
                    val response = response(capture)
                    val body = response.first.toByteArray(Charsets.UTF_8)
                    val head = ("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" +
                        "Content-Length: ${body.size}\r\nConnection: close\r\n" + response.second + "\r\n").toByteArray(Charsets.ISO_8859_1)
                    capture.responseHead = head; capture.responseBody = body
                    client.getOutputStream().apply {
                        write(head); flush(); headersSent.countDown()
                        if (mode == Mode.BLOCK_AFTER_HEADERS) check(releaseBody.await(10, TimeUnit.SECONDS)) { "Fixture body release deadline" }
                        if (!listener.isClosed) { write(body); flush(); capture.completeResponse() }
                    }
                }
                active.set(null)
            }
        } catch (failure: Throwable) {
            if (!(listener.isClosed && (failure is SocketException || failure is InterruptedException))) error.compareAndSet(null, failure)
        }
    }

    fun requests(): List<Capture> = synchronized(captures) { captures.toList() }
    fun assertHealthy() { error.get()?.let { throw AssertionError("Loopback fixture failed", it) } }
    /** Nonblocking signal for cancellation handlers; joining belongs to close(). */
    fun abort() {
        try { listener.close() } finally {
            try { active.getAndSet(null)?.close() } finally { releaseBody.countDown() }
        }
    }
    override fun close() {
        try { abort() } finally {
            executor.shutdownNow()
            try { work.get(10, TimeUnit.SECONDS) } finally {
                check(executor.awaitTermination(2, TimeUnit.SECONDS)) { "Fixture worker did not terminate" }
            }
        }
    }
    fun cleanup(): JsonObject = jsonObject("listenerClosed" to listener.isClosed,
        "activeSocketClosed" to (active.get()?.isClosed != false), "workerStopped" to executor.isTerminated)

    private fun readRequest(input: InputStream): Capture {
        val head = ByteArrayOutputStream()
        var suffix = 0
        while (suffix != 0x0d0a0d0a) {
            val byte = input.read(); check(byte >= 0) { "HTTP request ended before headers" }
            head.write(byte); suffix = (suffix shl 8) or byte
            check(head.size() <= 65_536) { "HTTP headers exceed fixture limit" }
        }
        val lines = head.toByteArray().toString(Charsets.ISO_8859_1).split("\r\n")
        val start = lines.first().split(' ', limit = 3); check(start.size == 3) { "Invalid HTTP request line" }
        val headers = lines.drop(1).filter { it.isNotEmpty() }.map { line ->
            val colon = line.indexOf(':'); check(colon > 0) { "Invalid HTTP header" }
            line.substring(0, colon) to line.substring(colon + 1).trim()
        }
        check(headers.none { it.first.equals("Transfer-Encoding", true) }) { "Chunked requests are outside this fixture" }
        val length = headers.firstOrNull { it.first.equals("Content-Length", true) }?.second?.toInt() ?: 0
        check(length in 0..1_048_576) { "HTTP body exceeds fixture limit" }
        val body = ByteArray(length)
        var read = 0
        while (read < body.size) {
            val count = input.read(body, read, body.size - read); check(count > 0) { "Truncated HTTP request body" }; read += count
        }
        return Capture(start[0], start[1], start[2], headers, body, head.toByteArray(), origin)
    }

    private fun response(request: Capture): Pair<String, String> {
        if (mode == Mode.MULTI_COOKIE) {
            check(request.target == "/cookies")
            return "cookies" to "Set-Cookie: first=one; Path=/\r\nSet-Cookie: second=two; Expires=Wed, 09 Jun 2038 10:18:14 GMT; Path=/\r\nX-Repeated: one\r\nX-Repeated: two\r\n"
        }
        if (mode != Mode.REFERENCE) { check(request.target == "/blocked"); return "body" to "" }
        return when (request.target) {
            "/login" -> {
                check(request.method == "POST")
                check(request.body.toString(Charsets.UTF_8) == "name=reader&password=%E4%B9%A6")
                "ok" to "Set-Cookie: sid=fixture; Path=/; HttpOnly\r\n"
            }
            "/search?key=%E4%B9%A6&page=1" -> {
                check(request.header("Cookie").orEmpty().split(';').any { it.trim() == "sid=fixture" })
                check(request.header("Authorization") == "Bearer fixture")
                "{\"books\":[{\"name\":\"Fixture\",\"bookUrl\":\"$origin/book/1\"}]}" to ""
            }
            "/book/1" -> "<p id='intro'>Introduction</p><a id='toc' href='/toc/1'>TOC</a>" to ""
            "/toc/1" -> "[{\"index\":0,\"title\":\"One\",\"url\":\"$origin/chapter/1\"},{\"index\":1,\"title\":\"Two\",\"url\":\"$origin/chapter/2\"}]" to ""
            "/chapter/1" -> CONTENT_ONE to ""
            "/chapter/2" -> CONTENT_TWO to ""
            else -> error("Unexpected fixture request: ${request.target}")
        }
    }

    companion object {
        const val CONTENT_ONE = "第一章\ncontent one"
        const val CONTENT_TWO = "第二章\ncontent two"
        const val SHARED_JS_LIB = "/* Legado reference shared scope */"
        const val FIXED_HEADERS = "{\"User-Agent\":\"Legado-Reference-Fixture/1\",\"Accept\":\"*/*\",\"Accept-Encoding\":\"identity\",\"Connection\":\"close\"}"
        fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
        fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    }
}
