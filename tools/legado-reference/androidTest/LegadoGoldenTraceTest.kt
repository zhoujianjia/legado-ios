package io.legado.app.reference

import android.os.Build
import android.os.Bundle
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import io.legado.app.constant.PreferKey
import io.legado.app.data.appDb
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.help.CacheManager
import io.legado.app.help.book.BookHelp
import io.legado.app.help.config.AppConfig
import io.legado.app.help.http.CookieStore
import io.legado.app.model.webBook.WebBook
import io.legado.app.utils.GSON
import io.legado.app.utils.putPrefBoolean
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Copy only this test into the unmodified archive's app/src/androidTest/java.
 * Stage the shared fixture as androidTest/assets/legado-reference/main-source.js.
 * Run only this class with the archive's AndroidJUnitRunner and original App.
 * This executes real original WebBook/JS/HTTP/Cookie/Room/file-cache paths.
 */
class LegadoGoldenTraceTest {
    @Test
    fun originalMainJsReadingChain() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val applicationMinSdkVersion = context.applicationInfo.minSdkVersion
        val referenceRunId = InstrumentationRegistry.getArguments().getString("referenceRunId")
        // Preserve explicit BookHelp null readbacks in this test's evidence.
        // The original business serializers and model conversions stay intact.
        val reportGson = GSON.newBuilder().serializeNulls().create()
        val reportFile = File(context.filesDir, REPORT_PATH)
        val report = linkedMapOf<String, Any?>(
            "schemaVersion" to 1,
            "referenceKind" to "original-archive-android-instrumentation",
            "referenceRunId" to referenceRunId,
            "passed" to false,
            "iosValidationPassed" to false,
            "instrumentationRunner" to "androidx.test.runner.AndroidJUnitRunner",
            "applicationClass" to context.applicationContext.javaClass.name,
            "applicationMinSdkVersion" to applicationMinSdkVersion,
            "androidApi" to Build.VERSION.SDK_INT,
            "androidRelease" to Build.VERSION.RELEASE,
            "normalization" to "Only the loopback origin and its Host authority are replaced by https://fixture.invalid/fixture.invalid in canonicalTrace. Raw wire bytes are retained separately.",
        )
        val outputs = linkedMapOf<String, Any?>()
        val rawModels = linkedMapOf<String, Any?>()
        val steps = arrayListOf<String>()
        val wireEvidence = arrayListOf<Map<String, Any?>>()
        val canonical = linkedMapOf<String, Any?>("outputs" to outputs, "steps" to steps, "exceptions" to emptyList<Any>())
        var origin: String? = null
        var server: FixtureServer? = null
        try {
            require(!referenceRunId.isNullOrBlank()) { "The referenceRunId instrumentation argument is required" }
            require(UUID.fromString(referenceRunId).toString() == referenceRunId) { "referenceRunId must be a canonical UUID" }
            assertEquals("Reference APK must declare the external minimum-SDK override", 26, applicationMinSdkVersion)
            // This is test configuration, not an alternative Application or host.
            // A fresh emulator also defaults to this original OkHttp path.
            context.putPrefBoolean(PreferKey.cronet, false)
            assertFalse(AppConfig.isCronet)
            val script = instrumentation.context.assets.open(FIXTURE_ASSET)
                .bufferedReader(Charsets.UTF_8).use { it.readText() }
            report["fixtureSHA256"] = sha256(script.toByteArray(Charsets.UTF_8))
            report["originalArchiveSHA256"] = InstrumentationRegistry.getArguments().getString("archiveSHA256")
            report["testConfiguration"] = mapOf("Cronet" to false,
                "minimumSdk" to "External reference.init.gradle raises only :app from 23 to 26 via androidComponents.finalizeDsl; original Gradle and business source files are unchanged",
                "httpServer" to "loopback ServerSocket; no HTTP interceptor or native-host replacement")

            server = FixtureServer()
            origin = server.origin
            val source = BookSource(
                bookSourceUrl = origin,
                bookSourceName = "Synthetic fixture",
                enabledCookieJar = true,
                header = FIXED_HEADERS,
                mainJs = script,
            )
            canonical["sourceInput"] = mapOf("bookSourceUrl" to origin,
                "bookSourceName" to source.bookSourceName, "enabledCookieJar" to true,
                "header" to FIXED_HEADERS, "mainJsSHA256" to report["fixtureSHA256"])
            source.removeLoginInfo()
            source.removeLoginHeader()
            source.putVariable(null)
            CacheManager.delete("lastKey")
            appDb.bookSourceDao.insert(source)

            steps.add("login.begin")
            // BaseSource.login supplies the original login.apply(this) semantics.
            source.login()
            val loginInfo = source.getLoginInfo()
            val loginHeader = source.getLoginHeader()
            assertEquals("{\"name\":\"reader\"}", loginInfo)
            assertEquals("{\"Authorization\":\"Bearer fixture\"}", loginHeader)
            assertEquals("logged-in", source.getVariable())
            assertEquals("fixture", CookieStore.getKey(origin, "sid"))
            outputs["login"] = mapOf("loginInfo" to loginInfo, "loginHeader" to loginHeader,
                "variable" to source.getVariable(), "cookie" to CookieStore.getCookie(origin))
            steps.add("login.returned")

            val search = WebBook.searchBookAwait(source, "书", 1)
            rawModels["search"] = GSON.toJsonTree(search)
            assertEquals(1, search.size)
            assertEquals("Fixture", search.single().name)
            assertEquals("$origin/book/1", search.single().bookUrl)
            outputs["search"] = search.map { mapOf("name" to it.name, "bookUrl" to it.bookUrl) }
            steps.add("search.returned")

            val book = search.single().toBook()
            WebBook.getBookInfoAwait(source, book)
            rawModels["details"] = GSON.toJsonTree(book)
            assertEquals("Introduction", book.intro)
            assertEquals("$origin/toc/1", book.tocUrl)
            outputs["details"] = mapOf("name" to book.name, "bookUrl" to book.bookUrl,
                "intro" to book.intro, "tocUrl" to book.tocUrl)
            // Preserve real persistence: the original startup maintenance must
            // see a valid shelf book if it enumerates cache folders concurrently.
            appDb.bookDao.insert(book)
            steps.add("details.returned")

            val chapters = WebBook.getChapterListAwait(source, book).getOrThrow()
            assertEquals(2, chapters.size)
            assertEquals(listOf("One", "Two"), chapters.map { it.title })
            assertEquals(listOf(0, 1), chapters.map { it.index })
            rawModels["toc"] = GSON.toJsonTree(chapters)
            outputs["toc"] = chapters.map { mapOf("index" to it.index, "title" to it.title,
                "url" to it.url, "bookUrl" to it.bookUrl, "baseUrl" to it.baseUrl) }
            appDb.bookChapterDao.insert(*chapters.toTypedArray())
            steps.add("toc.returned")

            val content = WebBook.getContentAwait(source, book, chapters[0],
                nextChapterUrl = chapters[1].url, needSave = false)
            assertEquals(CONTENT_ONE, content)
            outputs["content"] = content
            steps.add("content.returned")

            val cacheBefore = cachedContents(book, chapters)
            assertTrue(cacheBefore.values.all { it == null })
            val missing = WebBook.getContentBatchAwait(source, book, chapters)
            val cacheAfter = cachedContents(book, chapters)
            assertTrue(missing.isEmpty())
            assertEquals(CONTENT_ONE, cacheAfter[chapters[0].url])
            assertEquals(CONTENT_TWO, cacheAfter[chapters[1].url])
            outputs["batch"] = mapOf("missingIndexes" to missing.map { it.index },
                "cacheBefore" to cacheBefore, "cacheAfter" to cacheAfter)
            steps.add("batch.returned")

            val calls = source.evalJS("globalThis.calls")
            assertTrue("Original source shared state must survive calls", calls is Number)
            assertEquals(1, (calls as Number).toInt())
            outputs["state"] = mapOf("loginInfo" to source.getLoginInfo(),
                "loginHeader" to source.getLoginHeader(), "variable" to source.getVariable(),
                "lastKey" to CacheManager.get("lastKey"), "cookie" to CookieStore.getCookie(origin),
                "calls" to calls.toInt())
            assertEquals("书", CacheManager.get("lastKey"))
            server.assertHealthy()
            val captures = server.requests()
            assertEquals("Exactly the seven fixture HTTP requests must execute", 7, captures.size)
            canonical["requests"] = captures.map { it.comparable() }
            wireEvidence.addAll(captures.map { it.evidence() })
            report["passed"] = true
        } catch (failure: Throwable) {
            report["failure"] = mapOf("type" to failure.javaClass.name, "message" to failure.message,
                "stackTrace" to failure.stackTraceToString())
            canonical["exceptions"] = listOf(mapOf("type" to failure.javaClass.name, "message" to failure.message))
            throw failure
        } finally {
            // Export partial evidence on assertion failure as well as on success.
            server?.let { running ->
                if (wireEvidence.isEmpty()) wireEvidence.addAll(running.requests().map { it.evidence() })
                if (canonical["requests"] == null) canonical["requests"] = running.requests().map { it.comparable() }
                running.close()
            }
            report["canonicalTrace"] = replaceOrigin(reportGson.toJsonTree(canonical), origin)
            report["rawOriginalModels"] = rawModels
            report["rawWireEvidence"] = wireEvidence
            report["physicalOrigin"] = origin
            report["coverageLimits"] = "One synthetic mainJs source. Semantic projections are explicit; complete original models and raw HTTP bytes are retained. This does not validate declarative rules, WebView, cancellation, concurrent sources, all host APIs, or iOS execution."
            check(reportFile.parentFile?.mkdirs() == true || reportFile.parentFile?.isDirectory == true)
            reportFile.writeText(reportGson.toJson(report), Charsets.UTF_8)
            instrumentation.sendStatus(0, Bundle().apply {
                putString("legadoReferenceReportPath", "files/$REPORT_PATH")
                putString("legadoReferenceReportSHA256", sha256(reportFile.readBytes()))
                putString("legadoReferencePassed", report["passed"].toString())
            })
        }
    }

    private fun cachedContents(book: Book, chapters: List<BookChapter>): Map<String, String?> =
        chapters.associate { it.url to BookHelp.getContent(book, it) }

    private fun replaceOrigin(value: JsonElement, origin: String?): JsonElement {
        if (origin == null || value.isJsonNull) return value
        return when {
            value.isJsonObject -> JsonObject().apply {
                value.asJsonObject.entrySet().forEach { (key, child) -> add(key.replace(origin, CANONICAL_ORIGIN), replaceOrigin(child, origin)) }
            }
            value.isJsonArray -> com.google.gson.JsonArray().apply { value.asJsonArray.forEach { add(replaceOrigin(it, origin)) } }
            value.isJsonPrimitive && value.asJsonPrimitive.isString -> {
                val text = value.asString
                GSON.toJsonTree(if (text == origin.substringAfter("://")) CANONICAL_ORIGIN.substringAfter("://")
                    else text.replace(origin, CANONICAL_ORIGIN))
            }
            else -> value
        }
    }

    private data class Capture(val method: String, val target: String, val version: String,
                               val headers: List<Pair<String, String>>, val body: ByteArray,
                               val head: ByteArray, val origin: String) {
        fun comparable(): Map<String, Any?> = mapOf("method" to method, "url" to origin + target,
            "requestTarget" to target, "httpVersion" to version,
            "headers" to headers.map { mapOf("name" to it.first, "value" to it.second) },
            "bodyBase64" to Base64.encodeToString(body, Base64.NO_WRAP))
        fun evidence(): Map<String, Any?> = mapOf("method" to method, "url" to origin + target,
            "rawHeadBase64" to Base64.encodeToString(head, Base64.NO_WRAP),
            "bodyBase64" to Base64.encodeToString(body, Base64.NO_WRAP),
            "rawRequestSHA256" to sha256(head + body))
        fun header(name: String): String? = headers.firstOrNull { it.first.equals(name, true) }?.second
    }

    /** A real HTTP/1.1 fixture bound exclusively to emulator loopback. */
    private class FixtureServer : Closeable {
        private val listener = ServerSocket().apply {
            bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0))
            soTimeout = 1000
        }
        val origin = "http://127.0.0.1:${listener.localPort}"
        private val captures = arrayListOf<Capture>()
        private val error = AtomicReference<Throwable?>()
        private val active = AtomicReference<Socket?>()
        private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "legado-reference-http").apply { isDaemon = true } }
        private val work = executor.submit {
            try {
                while (!listener.isClosed) {
                    val socket = try { listener.accept() } catch (_: SocketTimeoutException) { continue }
                    active.set(socket)
                    socket.use { client ->
                        client.soTimeout = 10_000
                        val capture = readRequest(client.getInputStream())
                        synchronized(captures) { captures.add(capture) }
                        val response = response(capture)
                        val body = response.first.toByteArray(Charsets.UTF_8)
                        val header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.size}\r\nConnection: close\r\n" + response.second + "\r\n"
                        client.getOutputStream().apply { write(header.toByteArray(Charsets.ISO_8859_1)); write(body); flush() }
                    }
                    active.set(null)
                }
            } catch (failure: Throwable) {
                if (!(listener.isClosed && failure is SocketException)) error.compareAndSet(null, failure)
            }
        }

        fun requests(): List<Capture> = synchronized(captures) { captures.toList() }
        fun assertHealthy() { error.get()?.let { throw AssertionError("Loopback fixture failed", it) } }

        private fun readRequest(input: InputStream): Capture {
            val head = ByteArrayOutputStream()
            var suffix = 0
            while (suffix != 0x0d0a0d0a) {
                val byte = input.read()
                check(byte >= 0) { "HTTP request ended before headers" }
                head.write(byte)
                suffix = (suffix shl 8) or byte
                check(head.size() <= 65_536) { "HTTP headers exceed fixture limit" }
            }
            val lines = head.toByteArray().toString(Charsets.ISO_8859_1).split("\r\n")
            val start = lines.first().split(' ', limit = 3)
            check(start.size == 3) { "Invalid HTTP request line" }
            val headers = lines.drop(1).filter { it.isNotEmpty() }.map { line ->
                val colon = line.indexOf(':')
                check(colon > 0) { "Invalid HTTP header" }
                line.substring(0, colon) to line.substring(colon + 1).trim()
            }
            check(headers.none { it.first.equals("Transfer-Encoding", true) }) { "Chunked requests are outside this fixture" }
            val length = headers.firstOrNull { it.first.equals("Content-Length", true) }?.second?.toInt() ?: 0
            check(length in 0..1_048_576) { "HTTP body exceeds fixture limit" }
            val body = ByteArray(length)
            var read = 0
            while (read < body.size) {
                val count = input.read(body, read, body.size - read)
                check(count > 0) { "Truncated HTTP request body" }
                read += count
            }
            return Capture(start[0], start[1], start[2], headers, body, head.toByteArray(), origin)
        }

        private fun response(request: Capture): Pair<String, String> = when (request.target) {
            "/login" -> {
                assertEquals("POST", request.method)
                assertEquals("name=reader&password=%E4%B9%A6", request.body.toString(Charsets.UTF_8))
                "ok" to "Set-Cookie: sid=fixture; Path=/; HttpOnly\r\n"
            }
            "/search?key=%E4%B9%A6&page=1" -> {
                assertTrue(request.header("Cookie").orEmpty().split(';').any { it.trim() == "sid=fixture" })
                assertEquals("Bearer fixture", request.header("Authorization"))
                "{\"books\":[{\"name\":\"Fixture\",\"bookUrl\":\"$origin/book/1\"}]}" to ""
            }
            "/book/1" -> "<p id='intro'>Introduction</p><a id='toc' href='/toc/1'>TOC</a>" to ""
            "/toc/1" -> "[{\"index\":0,\"title\":\"One\",\"url\":\"$origin/chapter/1\"},{\"index\":1,\"title\":\"Two\",\"url\":\"$origin/chapter/2\"}]" to ""
            "/chapter/1" -> CONTENT_ONE to ""
            "/chapter/2" -> CONTENT_TWO to ""
            else -> error("Unexpected fixture request: ${request.target}")
        }

        override fun close() {
            listener.close()
            active.getAndSet(null)?.close()
            executor.shutdownNow()
            work.get(10, TimeUnit.SECONDS)
        }
    }

    companion object {
        const val FIXTURE_ASSET = "legado-reference/main-source.js"
        const val REPORT_PATH = "legado-reference/android-golden.json"
        private const val CANONICAL_ORIGIN = "https://fixture.invalid"
        private const val CONTENT_ONE = "第一章\ncontent one"
        private const val CONTENT_TWO = "第二章\ncontent two"
        private const val FIXED_HEADERS = "{\"User-Agent\":\"Legado-Reference-Fixture/1\",\"Accept\":\"*/*\",\"Accept-Encoding\":\"identity\",\"Connection\":\"close\"}"
        private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
