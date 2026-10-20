package io.yuedu.legado

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.yuedu.legado.originalrule.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicLong
import io.legado.app.model.analyzeRule.AnalyzeRule
import com.sun.net.httpserver.HttpServer
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URLClassLoader
import java.nio.file.Path
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import io.legado.app.model.webBook.WebBook
import io.legado.app.data.entities.rule.TocRule
import io.legado.app.data.entities.rule.ContentRule
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class OriginalStatePersistenceTest {
    @Test(timeout = 20_000) fun liveSessionsReadSharedOwnerUpdatesWhileExplicitTypedMemoryRemainsLocal() {
        val directory = Files.createTempDirectory("owned-live-sessions-")
        val host = RulePersistenceHost(FileRulePersistenceAdapter(directory))
        LegadoRuntime.setHostCallback { _, op, raw -> host.dispatch(op, parseObject(raw)).toString() }
        val sessions = mutableListOf<String>()
        try {
            fun create(): String {
                val result = parseObject(LegadoRuntime.createSession(jsonObject("bookSourceUrl" to "https://owned.invalid", "mainJs" to "function search(){return []}").toString(),
                    jsonObject("stateOwner" to "owner").toString()))
                assertTrue(result.toString(), result["ok"].asBoolean)
                return result["sessionId"].asString.also(sessions::add)
            }
            fun evaluate(session: String, script: String): String {
                val result = parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), "evaluate", jsonObject("script" to script).toString()))
                assertTrue(result.toString(), result["ok"].asBoolean)
                return result["result"].asString
            }
            val a = create(); val b = create()
            evaluate(a, "cache.put('key','old');source.put('key','old');source.setVariable('[1]');source.putLoginHeader('{\"Authorization\":\"old\"}');'ok'")
            assertEquals("old|old|[1]|{\"Authorization\":\"old\"}", evaluate(a, "cache.get('key')+'|'+source.get('key')+'|'+source.getVariable()+'|'+source.getLoginHeader()"))
            evaluate(b, "cache.put('key','new');source.put('key','new');source.setVariable('[2]');source.putLoginHeader('{\"Authorization\":\"new\"}');'ok'")
            assertEquals("new|new|[2]|{\"Authorization\":\"new\"}", evaluate(a, "cache.get('key')+'|'+source.get('key')+'|'+source.getVariable()+'|'+source.getLoginHeader()"))
            evaluate(a, "cache.putMemory('key','shadow');cache.putMemory('typed',7);'ok'")
            evaluate(b, "cache.put('key','latest');'ok'")
            assertEquals("shadow|latest|7", evaluate(a, "cache.get('key')+'|'+cache.get('key',true)+'|'+cache.getFromMemory('typed')"))
            assertEquals("latest", evaluate(a, "cache.deleteMemory('key');cache.get('key')"))
            evaluate(b, "cache.delete('key');source.put('key','');source.setVariable('');'ok'")
            assertEquals("null||", evaluate(a, "cache.get('key')+'|'+source.get('key')+'|'+source.getVariable()"))
        } finally { sessions.forEach(LegadoRuntime::closeSession); LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
    }
    @Test(timeout = 15_000) fun refreshedTocRejectsOlderDownloadAtReusedIndexWithoutChangingBodyOrMetadata() {
        val directory = Files.createTempDirectory("owned-toc-refresh-")
        val binding = RulePersistenceBinding(FileRulePersistenceAdapter(directory), "owner", "source")
        try {
            RuleEnvironment(persistence = binding).use { env ->
                val book = Book(env, name = "Book", bookUrl = "book")
                val old = BookChapter(env, url = "chapter-A", title = "title-A", bookUrl = "book", index = 0, imgUrl = "image-A")
                env.webBook.publish(book.bookUrl, listOf(old))
                val token = env.webBook.contentSaveToken(book, old)
                assertTrue(env.webBook.saveContent(book, old, "already saved A", token))
                val current = BookChapter(env, url = "chapter-B", title = "title-B", bookUrl = "book", index = 0, imgUrl = "image-B")
                env.webBook.publish(book.bookUrl, listOf(current))
                val contentKey = binding.key("content", "book", "0")
                val before = binding.read(contentKey)!!
                assertFalse(env.webBook.saveContent(book, old, "late download A", token))
                assertArrayEquals(before, binding.read(contentKey))
                assertEquals("title-B", env.webBook.chapters("book").single().title)
                assertEquals("image-B", env.webBook.chapters("book").single().imgUrl)
                assertTrue(env.webBook.saveContent(book, current, "", env.webBook.contentSaveToken(book, current)))
                assertNull(env.webBook.getContent(book, current)) // An empty volume B must never inherit A's body.
            }
            RuleEnvironment(persistence = binding).use { env ->
                val restored = env.webBook.chapters("book").single()
                assertEquals("chapter-B", restored.url); assertEquals("title-B", restored.title); assertEquals("image-B", restored.imgUrl)
                assertNull(env.webBook.getContent(Book(env, name = "Book", bookUrl = "book"), restored))
            }
        } finally { directory.toFile().deleteRecursively() }
    }
    @Test(timeout = 15_000) fun cancelledStateReadCannotCommitOrPublishAfterTheHostReturns() {
        val directory = Files.createTempDirectory("owned-cancel-state-")
        val host = RulePersistenceHost(FileRulePersistenceAdapter(directory))
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val block = java.util.concurrent.atomic.AtomicBoolean(false)
        LegadoRuntime.setHostCallback { _, op, raw ->
            if (op == "task.cancel") "{}" else {
                if (op == "state.read" && block.get()) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
                host.dispatch(op, parseObject(raw)).toString()
            }
        }
        val source = jsonObject("bookSourceUrl" to "https://owned.invalid", "mainJs" to "function search(){return []}")
        val created = parseObject(LegadoRuntime.createSession(source.toString(), jsonObject("stateOwner" to "owner").toString()))
        val session = created["sessionId"].asString; val executor = Executors.newSingleThreadExecutor()
        try {
            val setup = parseObject(LegadoRuntime.execute(session, "setup", "evaluate", jsonObject("script" to "source.put('key','old')").toString()))
            assertTrue(setup.toString(), setup["ok"].asBoolean)
            block.set(true)
            val future = executor.submit<String> { LegadoRuntime.execute(session, "cancelled-state", "evaluate", jsonObject("script" to "source.put('key','late')").toString()) }
            assertTrue(entered.await(3, TimeUnit.SECONDS)); LegadoRuntime.cancel("cancelled-state"); release.countDown()
            val result = parseObject(future.get(3, TimeUnit.SECONDS))
            assertEquals("CANCELLED", result["error"].asJsonObject["code"].asString)
            block.set(false)
            val read = parseObject(LegadoRuntime.execute(session, "read", "evaluate", jsonObject("script" to "source.get('key')").toString()))
            assertTrue(read.toString(), read["ok"].asBoolean); assertEquals("old", read["result"].asString)
        } finally { release.countDown(); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)); LegadoRuntime.closeSession(session); LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
    }

    @Test(timeout = 15_000) fun malformedBackingPayloadFailsTypedAndCannotReplacePreviousState() {
        val directory = Files.createTempDirectory("owned-corrupt-state-")
        val adapter = FileRulePersistenceAdapter(directory)
        try {
            val owner = "owner"; val binding = RulePersistenceBinding(adapter, owner, "source")
            val key = binding.key("cache-text", "bad")
            binding.put(key, "{\"deadline\":0}".toByteArray())
            RuleEnvironment(persistence = binding).use { env -> assertThrows(RulePersistenceException::class.java) { env.cache.get("bad", true) } }
            val before = Files.readAllBytes(adapter.file(owner))
            Files.writeString(adapter.file(owner), "broken backing")
            assertThrows(RulePersistenceException::class.java) { binding.put(key, "replacement".toByteArray()) }
            assertEquals("broken backing", Files.readString(adapter.file(owner)))
            Files.write(adapter.file(owner), before)
            RuleEnvironment(persistence = binding).use { env -> assertThrows(RulePersistenceException::class.java) { env.cache.get("bad", true) } }
            val cookies = SessionCookies()
            cookies.persistent(binding, write = true) { cookies.setCookie("https://owned.invalid", "sid=old; Path=/") }
            binding.put(binding.key("cookies"), "[{\"origin\":\"https://owned.invalid\"}]".toByteArray())
            assertThrows(RulePersistenceException::class.java) { cookies.persistent(binding) { cookies.getCookie("https://owned.invalid") } }
            assertEquals("old", cookies.getKey("https://owned.invalid", "sid"))
            binding.put(binding.key("toc", "book"), "[{\"bookUrl\":\"book\",\"index\":0}]".toByteArray())
            RuleEnvironment(persistence = binding).use { env -> assertThrows(RulePersistenceException::class.java) { env.webBook.chapters("book") } }
        } finally { directory.toFile().deleteRecursively() }
    }
    @Test(timeout = 20_000) fun persistedTocAndNeedSaveTrueContentUseOriginalGenerationAndRestoreAfterSessionClose() {
        val directory = Files.createTempDirectory("owned-content-state-")
        val backend = AtomicReference<RulePersistenceAdapter>(FileRulePersistenceAdapter(directory))
        val requests = CopyOnWriteArrayList<String>()
        val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            createContext("/") { e ->
                requests += e.requestURI.path
                val body = if (e.requestURI.path == "/toc") "<a href='/c1'>one</a><a href='/c2'>two</a>" else "<div id='text'>owned body</div>"
                val bytes = body.toByteArray(); e.sendResponseHeaders(200, bytes.size.toLong()); e.responseBody.use { it.write(bytes) }; e.close()
            }; start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        LegadoRuntime.setHostCallback { _, op, raw -> RulePersistenceHost(backend.get()).dispatch(op, parseObject(raw)).toString() }
        fun owned(action: suspend (BookSource, Book, RuleEnvironment) -> Unit) {
            val session = RuntimeSession(UUID.randomUUID().toString(), jsonObject("bookSourceUrl" to origin), RuntimeSessionOptions("jvm-okhttp", stateOwner = "owner"))
            val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + 15_000)
            try { LegadoRuntime.originalRuleEnvironment(task).use { env -> runBlocking {
                val source = BookSource(env, origin, ruleToc = TocRule(chapterList = "a", chapterName = "text", chapterUrl = "href"), ruleContent = ContentRule(content = "#text@html"))
                action(source, Book(env, name = "Book", bookUrl = "$origin/book", tocUrl = "$origin/toc"), env)
            } } } finally { task.releasePersistentEnvironment(); task.job.cancel(); session.closed.set(true); session.http!!.close() }
        }
        try {
            owned { source, book, env ->
                val chapters = WebBook.getChapterListAwait(source, book).getOrThrow()
                assertEquals(2, chapters.size)
                val body = WebBook.getContentAwait(source, book, chapters[0])
                assertTrue(body, body.contains("owned body")); assertEquals(body, env.webBook.getContent(book, chapters[0]))
                val stale = env.webBook.contentSaveToken(book, chapters[0]); assertEquals(0L, stale.version)
                env.webBook.replaceContent(book, chapters[0], "user edit")
                assertFalse(env.webBook.saveContent(book, chapters[0], "old response", stale))
                assertEquals("user edit", WebBook.getContentAwait(source, book, chapters[0]))
                assertEquals(1, requests.count { it == "/c1" })
            }
            owned { source, book, env ->
                val chapters = env.webBook.chapters(book.bookUrl)
                assertEquals(listOf("one", "two"), chapters.map { it.title }); assertEquals(listOf(0, 1), chapters.map { it.index })
                assertEquals("user edit", WebBook.getContentAwait(source, book, chapters[0]))
                assertEquals(1, requests.count { it == "/c1" })
                val obstruction = Files.createTempFile(directory, "obstruction", ".file")
                backend.set(FileRulePersistenceAdapter(directory, obstruction))
                assertThrows(RulePersistenceException::class.java) { env.webBook.replaceContent(book, chapters[0], "failed edit") }
                assertEquals("user edit", env.webBook.getContent(book, chapters[0]))
            }
        } finally { LegadoRuntime.setHostCallback(null); server.stop(0); directory.toFile().deleteRecursively() }
    }
    @Test(timeout = 20_000) fun facadePersistentHostsUseCurrentTaskAndKeepCachedClosuresAcrossInvocations() {
        val directory = Files.createTempDirectory("owned-facade-state-")
        val host = RulePersistenceHost(FileRulePersistenceAdapter(directory))
        LegadoRuntime.setHostCallback { _, op, raw -> host.dispatch(op, parseObject(raw)).toString() }
        val sessions = mutableListOf<String>()
        try {
            fun create(): String {
                val source = jsonObject("bookSourceUrl" to "https://owned.invalid", "jsLib" to "/* explicit shared scope */", "mainJs" to "function search(){return []}")
                val result = parseObject(LegadoRuntime.createSession(source.toString(), jsonObject("stateOwner" to "owner").toString()))
                assertTrue(result.toString(), result["ok"].asBoolean); return result["sessionId"].asString.also(sessions::add)
            }
            fun evaluate(session: String, script: String) = parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), "evaluate", jsonObject("script" to script).toString()))
            val first = create()
            val initial = evaluate(first, "source.put('key','kept');source.setVariable('[1]');cache.put('key','text');cache.putMemory('typed',7);cookie.setCookie(baseUrl,'sid=synthetic; Path=/');globalThis.readSaved=function(){return source.get('key')+'|'+cache.get('key')+'|'+cache.getFromMemory('typed')+'|'+cookie.getKey(baseUrl,'sid')};true")
            assertTrue(initial.toString(), initial["ok"].asBoolean)
            val repeated = evaluate(first, "globalThis.readSaved()")
            assertTrue(repeated.toString(), repeated["ok"].asBoolean); assertEquals("kept|text|7|synthetic", repeated["result"].asString)
            val credential = evaluate(first, "source.putLoginInfo('must-not-persist-in-plaintext')")
            assertEquals("UNSUPPORTED_CAPABILITY", credential["error"].asJsonObject["code"].asString)
            LegadoRuntime.closeSession(first)
            val second = create()
            val cold = evaluate(second, "source.get('key')+'|'+source.getVariable()+'|'+cache.get('key',true)+'|'+cookie.getKey(baseUrl,'sid')+'|'+cache.getFromMemory('typed')")
            assertTrue(cold.toString(), cold["ok"].asBoolean); assertEquals("kept|[1]|text|synthetic|null", cold["result"].asString)
        } finally { sessions.forEach(LegadoRuntime::closeSession); LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
    }
    @Test(timeout = 25_000) fun productionHostAdapterRestoresHeadersAndSameHttpCookieJarAcrossNewSessions() {
        val directory = Files.createTempDirectory("owned-production-state-")
        val adapter = FileRulePersistenceAdapter(directory)
        val host = RulePersistenceHost(adapter)
        val seen = CopyOnWriteArrayList<Pair<String, String>>()
        val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            createContext("/") { e ->
                seen += e.requestHeaders.getFirst("Authorization").orEmpty() to e.requestHeaders.getFirst("Cookie").orEmpty()
                if (e.requestURI.path == "/path/set") e.responseHeaders.add("Set-Cookie", "server=kept; Path=/path; Max-Age=240; HttpOnly")
                val bytes = "owned".toByteArray(); e.sendResponseHeaders(200, bytes.size.toLong()); e.responseBody.use { it.write(bytes) }; e.close()
            }; start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        LegadoRuntime.setHostCallback { _, op, raw -> host.dispatch(op, parseObject(raw)).toString() }
        fun owned(action: (BookSource, RuleEnvironment) -> Unit) {
            val session = RuntimeSession(UUID.randomUUID().toString(), jsonObject("bookSourceUrl" to origin, "enabledCookieJar" to true), RuntimeSessionOptions("jvm-okhttp", stateOwner = "existing-app-owner"))
            val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + 15_000)
            LegadoRuntime.originalRuleEnvironment(task).use { env -> try { action(BookSource(env, origin), env) } finally { task.job.cancel(); session.closed.set(true); session.http!!.close() } }
        }
        try {
            owned { source, env ->
                source.putVariable("[\"array-remains-raw\"]")
                source.putLoginHeader("{\"Authorization\":\"Bearer synthetic\",\"Cookie\":\"login=1\"}")
                AnalyzeRule(source = source).use { assertEquals("owned", it.connect(origin + "/path/set").body()) }
                env.cookie.replaceCookie(origin + "/path/next", "server=updated")
            }
            owned { source, env ->
                assertEquals("[\"array-remains-raw\"]", source.getVariable())
                assertTrue(source.getLoginHeader().orEmpty().contains("Bearer synthetic"))
                AnalyzeRule(source = source).use { it.connect(origin + "/path/next"); it.connect(origin + "/other") }
                assertEquals("updated", env.cookie.getCookie(origin + "/path/next", "server"))
                assertEquals("", env.cookie.getCookie(origin + "/other", "server"))
            }
            assertEquals("Bearer synthetic", seen[1].first)
            assertTrue(seen[1].second, seen[1].second.contains("server=\"updated\"")); assertTrue(seen[1].second.contains("\$Path=\"/path\"")); assertTrue(seen[1].second.contains("login=1"))
            assertFalse(seen[2].second, seen[2].second.contains("server="))
        } finally { LegadoRuntime.setHostCallback(null); server.stop(0); directory.toFile().deleteRecursively() }
    }

    @Test(timeout = 15_000) fun failingLoginHeaderCommitKeepsBothOriginalHeaderAndCookie() {
        val directory = Files.createTempDirectory("owned-login-state-")
        val adapter = AtomicReference<RulePersistenceAdapter>(FileRulePersistenceAdapter(directory))
        LegadoRuntime.setHostCallback { _, op, raw -> RulePersistenceHost(adapter.get()).dispatch(op, parseObject(raw)).toString() }
        val session = RuntimeSession("session", jsonObject("bookSourceUrl" to "https://owned.invalid", "enabledCookieJar" to true), RuntimeSessionOptions("jvm-okhttp", stateOwner = "owner"))
        val task = RuntimeTask("task", session, Job(), System.currentTimeMillis() + 10_000)
        try {
            LegadoRuntime.originalRuleEnvironment(task).use { env ->
                val source = BookSource(env, "https://owned.invalid")
                val original = "{\"Authorization\":\"old\",\"Cookie\":\"token=old\"}"
                source.putLoginHeader(original)
                val obstruction = Files.createTempFile(directory, "obstruction", ".file")
                adapter.set(FileRulePersistenceAdapter(directory, obstruction))
                assertThrows(RulePersistenceException::class.java) { source.putLoginHeader("{\"Authorization\":\"new\",\"Cookie\":\"token=new\"}") }
                assertEquals(original, source.getLoginHeader()); assertEquals("old", env.cookie.getCookie(source.bookSourceUrl, "token"))
                assertThrows(RulePersistenceException::class.java) { source.removeLoginHeader() }
                assertEquals(original, source.getLoginHeader()); assertEquals("old", env.cookie.getCookie(source.bookSourceUrl, "token"))
            }
        } finally { task.job.cancel(); session.closed.set(true); session.http!!.close(); LegadoRuntime.setHostCallback(null); directory.toFile().deleteRecursively() }
    }

    @Test(timeout = 25_000) fun separateJavaProcessesRecoverActualFilesWithoutSharingMemory() {
        val directory = Files.createTempDirectory("owned-process-state-")
        try {
            val urls = generateSequence(javaClass.classLoader) { it.parent }.flatMap { (it as? URLClassLoader)?.urLs?.asSequence().orEmpty() }
                .map { Path.of(it.toURI()).toString() }.toList()
            val classpath = (System.getProperty("java.class.path").split(File.pathSeparator) + urls).distinct().joinToString(File.pathSeparator)
            val java = Path.of(System.getProperty("java.home"), "bin", if (System.getProperty("os.name").startsWith("Windows")) "java.exe" else "java")
            val pids = mutableSetOf<Long>()
            for (mode in listOf("write", "read")) {
                val process = ProcessBuilder(java.toString(), "-cp", classpath, StatePersistenceProcessProbe::class.java.name, directory.toString(), mode).redirectErrorStream(true).start()
                pids += process.pid()
                try {
                    assertTrue("Child JVM did not finish", process.waitFor(10, TimeUnit.SECONDS))
                    val text = process.inputStream.readBytes().toString(Charsets.UTF_8)
                    println("PERSISTENCE_CHILD pid=${process.pid()} mode=$mode $text")
                    assertEquals(text, 0, process.exitValue()); assertTrue(text, text.contains("PERSISTENCE_PROCESS_OK"))
                } finally { if (process.isAlive) process.destroyForcibly() }
            }
            assertEquals(2, pids.size)
        } finally { directory.toFile().deleteRecursively() }
    }
    @Test fun sourceBookChapterVariablesAndCacheRestoreThroughSameOwnerAdapter() {
        val directory = Files.createTempDirectory("owned-original-state-")
        try {
            val adapter = FileRulePersistenceAdapter(directory)
            fun environment(source: String = "source-a", owner: String = "owner") = RuleEnvironment(persistence = RulePersistenceBinding(adapter, owner, source))
            environment().use { env ->
                val source = BookSource(env, "source-a"); source.put("key", "value"); source.putVariable("[1,2]")
                val a = Book(env, bookUrl = "book-a"); val b = Book(env, bookUrl = "book-b")
                a.putVariable("key", "a"); b.putVariable("key", "b")
                a.putVariable("large", "字".repeat(10000))
                BookChapter(env, bookUrl = "book-a", url = "one").putVariable("key", "one")
                BookChapter(env, bookUrl = "book-a", url = "two").putVariable("key", "two")
                env.cache.put("same", "text"); env.cache.put("same", byteArrayOf(1, 2, 3))
            }
            environment().use { env ->
                assertEquals("value", BookSource(env, "source-a").get("key")); assertEquals("[1,2]", BookSource(env, "source-a").getVariable())
                assertEquals("a", Book(env, bookUrl = "book-a").getVariable("key")); assertEquals("b", Book(env, bookUrl = "book-b").getVariable("key"))
                assertEquals("字".repeat(10000), Book(env, bookUrl = "book-a").getVariable("large"))
                assertEquals("one", BookChapter(env, bookUrl = "book-a", url = "one").getVariable("key")); assertEquals("two", BookChapter(env, bookUrl = "book-a", url = "two").getVariable("key"))
                assertEquals("text", env.cache.get("same", true)); assertArrayEquals(byteArrayOf(1, 2, 3), env.cache.getByteArray("same"))
            }
            for ((owner, source) in listOf("owner" to "source-b", "other-owner" to "source-a")) environment(source, owner).use { env ->
                assertEquals("", BookSource(env, "source-a").get("key")); assertEquals("", Book(env, bookUrl = "book-a").getVariable("key")); assertNull(env.cache.get("same", true))
            }
        } finally { directory.toFile().deleteRecursively() }
    }

    @Test fun ttlTypedMemoryAndAtomicWriteFailureKeepPreviousDiskAndLiveState() {
        val directory = Files.createTempDirectory("owned-original-state-")
        try {
            val clock = AtomicLong(1000); val adapter = FileRulePersistenceAdapter(directory)
            RuleEnvironment(clock = clock::get, persistence = RulePersistenceBinding(adapter, "owner", "source")).use { env ->
                env.cache.put("text", "kept"); env.cache.putMemory("text", 7)
                assertEquals(7, env.cache.getInt("text")); assertEquals("kept", env.cache.get("text", true))
                env.cache.put("expires", "ttl", 2); env.cache.put("expires", byteArrayOf(9), 4)
            }
            clock.set(3000)
            RuleEnvironment(clock = clock::get, persistence = RulePersistenceBinding(adapter, "owner", "source")).use { env ->
                assertNull(env.cache.getFromMemory("text")); assertEquals("kept", env.cache.get("text", true))
                assertNull(env.cache.get("expires", true)); assertArrayEquals(byteArrayOf(9), env.cache.getByteArray("expires"))
            }
            val obstruction = Files.createTempFile(directory, "staging-obstruction", ".file")
            val failing = FileRulePersistenceAdapter(directory, obstruction)
            RuleEnvironment(persistence = RulePersistenceBinding(failing, "owner", "source")).use { env ->
                assertEquals("kept", env.cache.get("text"))
                assertThrows(RulePersistenceException::class.java) { env.cache.put("text", "lost") }
                assertEquals("kept", env.cache.get("text")); assertEquals("kept", env.cache.get("text", true))
                val book = Book(env, bookUrl = "book")
                assertThrows(RulePersistenceException::class.java) { book.putVariable("key", "lost") }
                assertEquals("", book.getVariable("key")); assertNull(book.variable)
            }
            RuleEnvironment(persistence = RulePersistenceBinding(adapter, "owner", "source")).use { env -> assertEquals("kept", env.cache.get("text", true)) }
        } finally { directory.toFile().deleteRecursively() }
    }
}

/** Test-only child entry. Ordinary payload audit excludes this class and the file backend. */
object StatePersistenceProcessProbe {
    @JvmStatic fun main(arguments: Array<String>) {
        val adapter = FileRulePersistenceAdapter(Path.of(arguments[0]))
        RuleEnvironment(persistence = RulePersistenceBinding(adapter, "owner", "source")).use { env ->
            if (arguments[1] == "write") {
                BookSource(env, "source").putVariable("[1,2]")
                Book(env, bookUrl = "book").putVariable("key", "value")
                BookChapter(env, bookUrl = "book", url = "chapter").putVariable("large", "文".repeat(10000))
                env.cache.put("key", byteArrayOf(1, 2, 3)); env.cache.put("key", "separate-text")
                val book = Book(env, bookUrl = "book")
                val chapter = BookChapter(env, bookUrl = "book", url = "chapter", title = "title")
                env.webBook.publish("book", listOf(chapter)); env.webBook.replaceContent(book, chapter, "durable body")
            } else {
                check(BookSource(env, "source").getVariable() == "[1,2]")
                check(Book(env, bookUrl = "book").getVariable("key") == "value")
                check(BookChapter(env, bookUrl = "book", url = "chapter").getVariable("large") == "文".repeat(10000))
                check(env.cache.getByteArray("key")!!.contentEquals(byteArrayOf(1, 2, 3))); check(env.cache.get("key", true) == "separate-text")
                val chapter = env.webBook.chapters("book").single()
                check(chapter.title == "title"); check(env.webBook.getContent(Book(env, bookUrl = "book"), chapter) == "durable body")
            }
        }
        println("PERSISTENCE_PROCESS_OK")
    }
}
