package io.yuedu.legado

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.rule.*
import io.legado.app.model.webBook.WebBook
import io.yuedu.legado.originalrule.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
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

/** Actual original four-stage orchestration and owned HTTP. No invented Android observation. */
class OriginalWebBookExecutionTest {
    @Test(timeout = 20_000) fun cssSearchXpathDetailsJsonTocAndPagedContentUseSameEntitiesAndTransport() {
        Peer { e -> when (e.requestURI.path) {
            "/search" -> { e.responseHeaders.add("Set-Cookie", "owned=1; Path=/"); respond(e, "<div class='book'><a href='/book'>原书</a><b>作者：甲</b></div>") }
            "/book" -> respond(e, "<h1>新书名</h1><h2>作者：乙</h2><a id='toc' href='/toc'>目录</a><p id='intro'>简介<br>第二行</p>")
            "/toc" -> respond(e, """{"chapters":[{"name":"第一章","url":"/c1"}],"next":["/toc2"]}""")
            "/toc2" -> respond(e, """{"chapters":[{"name":"第二章","url":"/c2"}],"next":[]}""")
            "/c1" -> respond(e, "<div id='text'><p>首页&amp;正文</p></div><a class='next' href='/c1p2'>下一页</a>")
            "/c1p2" -> respond(e, "<div id='text'><p>末页REMOVE</p><img src='image.png'></div><a class='next' href='/c2'>下一章</a>")
            "/c2" -> respond(e, "<div id='text'><p>第二章正文</p></div>")
            else -> error("Unexpected path ${e.requestURI}")
        } }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val s = owned.source
            s.searchUrl = "/search?q={{key}}&p={{page}}"
            s.header = "@js:({'X-Phase':source.get('phase')||'search'})"
            s.ruleSearch = SearchRule(bookList = ".book", name = "a@text", author = "b@text", bookUrl = "a@href")
            s.ruleBookInfo = BookInfoRule(name = "@XPath://h1/text()", author = "@XPath://h2/text()", intro = "#intro@html", tocUrl = "#toc@href", canReName = "yes")
            s.ruleToc = TocRule(preUpdateJs = "if(!(book instanceof Packages.io.legado.app.data.entities.Book))throw new Error('book'); java.put('toc','ready')", chapterList = "$.chapters", chapterName = "$.name", chapterUrl = "$.url", nextTocUrl = "$.next")
            s.ruleContent = ContentRule(content = "#text@html", nextContentUrl = ".next@href", replaceRegex = "##REMOVE##", title = "@js:String(chapter.title)+'!' ")
            val found = WebBook.searchBookAwait(s, "中文", 2)
            assertEquals(1, found.size); assertEquals("原书", found[0].name); assertEquals("甲", found[0].author)
            assertEquals("io.legado.app.data.entities.SearchBook", found[0].javaClass.name)
            val book = found[0].toBook(); s.put("phase", "details")
            assertSame(book, WebBook.getBookInfoAwait(s, book)); assertEquals("新书名", book.name); assertEquals("乙", book.author)
            assertEquals(peer.origin + "/toc", book.tocUrl)
            val chapters = WebBook.getChapterListAwait(s, book, runPerJs = true).getOrThrow()
            assertEquals(listOf("第一章", "第二章"), chapters.map { it.title }); assertEquals(listOf(0, 1), chapters.map { it.index })
            assertEquals("ready", book.getVariable("toc")); assertEquals(2, book.totalChapterNum)
            assertEquals("第二章", book.latestChapterTitle); assertSame(chapters[0], owned.environment.webBook.chapters(book.bookUrl)[0])
            val first = WebBook.getContentAwait(s, book, chapters[0], needSave = false)
            assertEquals("首页&正文\n\n末页\n<img src=\"${peer.origin}/image.png\">\n", first)
            assertFalse(first, first.contains("REMOVE")); assertEquals("第一章!", chapters[0].title)
            assertEquals(0, peer.requests.count { it.path == "/c2" }) // Default transient TOC lookup prevents crossing chapter boundary.
            assertTrue(WebBook.getContentAwait(s, book, chapters[1], needSave = false).contains("第二章正文"))
            assertTrue(peer.requests.first().uri.contains("p=2")); assertTrue(peer.requests.first().uri.contains("%E4%B8%AD"))
            assertTrue(peer.requests.drop(1).all { it.header("Cookie").contains("owned=1") })
            assertTrue(peer.requests.drop(1).all { it.header("X-Phase") == "details" })
            assertEquals(7, owned.session.requests.size)
        } } }
    }

    @Test(timeout = 15_000) fun originalRegexSearchGroupsFilterBreakAndReverseAreNotReparsedByNewCode() {
        Peer { respond(it, "BOOK[同名|作者：甲|/one]BOOK[同名|作者：乙|/two]BOOK[同名|作者：乙|/two]") }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val source = owned.source
            source.searchUrl = "/regex"
            source.ruleSearch = SearchRule(bookList = "-:BOOK\\[([^|]*)\\|([^|]*)\\|([^\\]]*)\\]", name = "\$1", author = "\$2", bookUrl = "\$3")
            val all = WebBook.searchBookAwait(source, "x")
            assertEquals(listOf(peer.origin + "/two", peer.origin + "/one"), all.map { it.bookUrl })
            val selected = WebBook.searchBookAwait(source, "x", filter = { _, author, _ -> author == "乙" }, shouldBreak = { it == 1 })
            assertEquals(1, selected.size); assertEquals("乙", selected[0].author)
        } } }
    }

    @Test(timeout = 15_000) fun tocDuplicateSelectionReverseAndPersistentFormatBindingsMatchOriginalOrder() {
        Peer { error("Cached TOC must not fetch") }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val book = Book(owned.environment, bookUrl = peer.origin + "/book", tocUrl = peer.origin + "/book")
            book.tocHtml = "<a href='/a'>old</a><a href='/b'>middle</a><a href='/a'>new</a>"
            owned.source.ruleToc = TocRule(chapterList = "a", chapterName = "text", chapterUrl = "href", formatJs = "gInt++; String(title)+'-'+gInt+'-'+index")
            val chapters = WebBook.getChapterListAwait(owned.source, book).getOrThrow()
            assertEquals(listOf("middle-1-1", "new-2-2"), chapters.map { it.title })
            assertEquals(listOf("/b", "/a"), chapters.map { it.url }); assertTrue(peer.requests.isEmpty())
            book.setReverseToc(true)
            val reversed = WebBook.getChapterListAwait(owned.source, book).getOrThrow()
            assertEquals(listOf("new-1-1", "middle-2-2"), reversed.map { it.title })
        } } }
    }

    @Test(timeout = 15_000) fun multiPageFanoutPreservesDeclaredOrderAndDoesNotRecurse() {
        Peer { e -> when (e.requestURI.path) {
            "/chapter" -> respond(e, "<div id='text'>zero</div><a class='next' href='/slow'>a</a><a class='next' href='/fast'>b</a>")
            "/slow" -> { Thread.sleep(80); respond(e, "<div id='text'>one</div><a class='next' href='/never'>next</a>") }
            "/fast" -> respond(e, "<div id='text'>two</div><a class='next' href='/never'>next</a>")
            else -> error("Unexpected fanout recursion")
        } }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val book = Book(owned.environment, bookUrl = peer.origin + "/book", tocUrl = peer.origin + "/toc")
            val chapter = BookChapter(owned.environment, url = "/chapter", baseUrl = peer.origin)
            owned.source.ruleContent = ContentRule(content = "#text@html", nextContentUrl = ".next@href")
            val text = WebBook.getContentAwait(owned.source, book, chapter, needSave = false)
            assertEquals(listOf("zero", "one", "two"), text.lines().map { it.trim() }.filter { it.isNotEmpty() })
            assertEquals(3, peer.requests.size)
        } } }
    }

    @Test(timeout = 15_000) fun infoHtmlFallbackAndEmptyContentRuleVolumeShortcutsIssueNoHttp() {
        Peer { error("Cached/shortcut must not fetch") }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val book = Book(owned.environment, bookUrl = peer.origin + "/book", infoHtml = "<h1>缓存书</h1>")
            owned.source.ruleBookInfo = BookInfoRule(name = "h1@text")
            assertSame(book, WebBook.getBookInfoAwait(owned.source, book)); assertEquals("缓存书", book.name)
            assertEquals(book.bookUrl, book.tocUrl); assertEquals(book.infoHtml, book.tocHtml)
            val chapter = BookChapter(owned.environment, url = "卷0", title = "卷", isVolume = true)
            assertEquals("", WebBook.getContentAwait(owned.source, book, chapter, needSave = false))
            chapter.isVolume = false; chapter.url = "/chapter"
            assertEquals("/chapter", WebBook.getContentAwait(owned.source, book, chapter, needSave = false))
            assertTrue(peer.requests.isEmpty())
        } } }
    }

    @Test(timeout = 15_000) fun loginCheckReceivesOriginalRawResponseAndCanRecoverOnlyExecutionErrors() {
        Peer { respond(it, "<a href='/book'>Book</a>") }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val source = owned.source; source.searchUrl = "/search"
            source.ruleSearch = SearchRule(bookList = "a", name = "text", bookUrl = "href")
            source.loginCheckJs = "source.put('code',String(result.code())); source.put('class',String(result instanceof Packages.io.yuedu.legado.StrResponse)); result"
            assertEquals(1, WebBook.searchBookAwait(source, "x").size)
            assertEquals("200", source.get("code")); assertEquals("true", source.get("class"))
            source.searchUrl = "/search,{\"bodyJs\":\"throw new Error('body-failure')\"}"
            source.loginCheckJs = "source.put('error',String(result.code())+'|'+result.raw().message()); java.connect(source.getKey()+'/recover')"
            assertEquals(1, WebBook.searchBookAwait(source, "x").size)
            assertTrue(source.get("error"), source.get("error").startsWith("500|"))
            source.searchUrl = "/search,{\"js\":\"throw new Error('constructor')\"}"
            source.put("error", "untouched")
            assertThrows(Exception::class.java) { runBlocking { WebBook.searchBookAwait(source, "x") } }
            assertEquals("untouched", source.get("error"))
        } } }
    }

    @Test(timeout = 15_000) fun unsupportedSavingBatchAndNestedCapabilitiesAreTypedWithoutPublication() {
        Peer { respond(it, "<a href='/book'>Book</a>") }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val source = owned.source; val book = Book(owned.environment); val chapter = BookChapter(owned.environment)
            assertThrows(UnsupportedRuleCapability::class.java) { runBlocking { WebBook.getContentAwait(source, book, chapter) } }
            assertThrows(UnsupportedRuleCapability::class.java) { runBlocking { WebBook.getContentBatchAwait(source, book, listOf(chapter)) } }
            source.searchUrl = "/search"; source.ruleSearch = SearchRule(bookList = "a", name = "text", author = "@js:java.connect(source.getKey()+'/bad,{\"webView\":true}'); 'ignored'", bookUrl = "href")
            assertThrows(UnsupportedRuleCapability::class.java) { runBlocking { WebBook.searchBookAwait(source, "x") } }
            assertEquals(1, peer.requests.size)
            source.ruleSearch!!.author = "text"; source.loginCheckJs = "java.connect(source.getKey()+'/bad,{\"webView\":true}'); result"
            assertThrows(UnsupportedRuleCapability::class.java) { runBlocking { WebBook.searchBookAwait(source, "x") } }
            assertEquals(2, peer.requests.size)
            source.searchUrl = "/search,{\"bodyJs\":\"throw new Error('ordinary-body-error')\"}"
            source.loginCheckJs = "java.connect(source.getKey()+'/bad,{\"webView\":true}'); result"
            assertThrows(UnsupportedRuleCapability::class.java) { runBlocking { WebBook.searchBookAwait(source, "x") } }
            assertEquals(3, peer.requests.size)
        } } }
    }

    @Test(timeout = 15_000) fun tocSerialPageKeepsOriginalNextUrlBaseDespiteRedirect() {
        Peer { e -> when (e.requestURI.path) {
            "/toc" -> respond(e, "<a class='chapter' href='/first'>first</a><a class='next' href='/toc2'>next</a>")
            "/toc2" -> { e.responseHeaders.add("Location", "/moved/toc"); e.sendResponseHeaders(302, -1) }
            "/moved/toc" -> respond(e, "<a class='chapter' href='relative'>second</a>")
            else -> error("Unexpected TOC path")
        } }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val book = Book(owned.environment, bookUrl = peer.origin + "/book", tocUrl = peer.origin + "/toc")
            owned.source.ruleToc = TocRule(chapterList = ".chapter", chapterName = "text", chapterUrl = "href", nextTocUrl = ".next@href")
            val chapters = WebBook.getChapterListAwait(owned.source, book).getOrThrow()
            assertEquals(2, chapters.size)
            assertEquals(peer.origin + "/toc2", chapters[1].baseUrl)
            assertEquals(peer.origin + "/relative", chapters[1].getAbsoluteURL())
            assertEquals(listOf("/toc", "/toc2", "/moved/toc"), peer.requests.map { it.path })
        } } }
    }

    @Test(timeout = 15_000) fun tocFanoutUsesResponseRedirectBaseAndEmissionOrderWithoutFollowingMorePages() {
        Peer { e -> when (e.requestURI.path) {
            "/toc" -> respond(e, "<a class='chapter' href='/zero'>zero</a><a class='next' href='/slow'>a</a><a class='next' href='/fast'>b</a>")
            "/slow" -> { Thread.sleep(80); e.responseHeaders.add("Location", "/moved/slow"); e.sendResponseHeaders(302, -1) }
            "/moved/slow" -> respond(e, "<a class='chapter' href='relative'>one</a><a class='next' href='/never'>n</a>")
            "/fast" -> respond(e, "<a class='chapter' href='/two'>two</a><a class='next' href='/never'>n</a>")
            else -> error("Unexpected fanout recursion")
        } }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val book = Book(owned.environment, bookUrl = peer.origin + "/book", tocUrl = peer.origin + "/toc")
            owned.source.ruleToc = TocRule(chapterList = ".chapter", chapterName = "text", chapterUrl = "href", nextTocUrl = ".next@href")
            val chapters = WebBook.getChapterListAwait(owned.source, book).getOrThrow()
            assertEquals(listOf("zero", "one", "two"), chapters.map { it.title })
            assertEquals(peer.origin + "/moved/relative", chapters[1].getAbsoluteURL())
            assertEquals(4, peer.requests.size)
        } } }
    }

    @Test(timeout = 15_000) fun tocTruthValuesEmptyExceptionsAndRawFormatterFollowLockedOriginalHelpers() {
        Peer { error("Cached pages must not fetch") }.use { peer -> Owned(peer.origin).use { owned -> runBlocking {
            val book = Book(owned.environment, bookUrl = peer.origin + "/book", tocUrl = peer.origin + "/book", tocHtml = """{"rows":[{"name":"一","url":"/a","vip":"yes","pay":"NOT","volume":"0.0"},{"name":"卷","url":"","volume":"卷"}]}""")
            owned.source.ruleToc = TocRule(chapterList = "$.rows", chapterName = "$.name", chapterUrl = "$.url", isVip = "$.vip", isPay = "$.pay", isVolume = "$.volume")
            val list = WebBook.getChapterListAwait(owned.source, book).getOrThrow()
            assertTrue(list[0].isVip); assertFalse(list[0].isPay); assertFalse(list[0].isVolume); assertTrue(list[1].isVolume)
            assertEquals("卷1", list[1].url); assertEquals(peer.origin + "/book", list[1].getAbsoluteURL())
            book.tocHtml = "<div></div>"; owned.source.ruleToc!!.chapterList = "a"
            val failure = WebBook.getChapterListAwait(owned.source, book).exceptionOrNull()
            assertEquals("io.legado.app.exception.TocEmptyException", failure?.javaClass?.name)
            assertTrue(failure!!.stackTrace.isEmpty())
            assertEquals("a\nb", io.legado.app.utils.HtmlFormatter.formatIntro("<p>a</p><p>b</p>"))
            assertTrue(peer.requests.isEmpty())
        } } }
    }

    @Test(timeout = 15_000) fun closingOwnerDuringJavaParserCallbackRejectsLateSuccessfulPublication() {
        for (owner in listOf("environment", "session")) Peer { respond(it, "<a href='/book'>Book</a>") }.use { peer -> Owned(peer.origin).use { owned ->
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            owned.environment.cache.putMemory("entered", entered); owned.environment.cache.putMemory("release", release)
            owned.source.searchUrl = "/search"
            owned.source.ruleSearch = SearchRule(bookList = "a", name = "@js:cache.getFromMemory('entered').countDown();cache.getFromMemory('release').await();'late'", bookUrl = "href")
            val executor = Executors.newSingleThreadExecutor()
            try {
                val future = executor.submit<Any> { runBlocking { WebBook.searchBookAwait(owned.source, "x") } }
                assertTrue(entered.await(3, TimeUnit.SECONDS))
                if (owner == "environment") owned.environment.close() else owned.session.closed.set(true)
                assertFalse(future.isDone) // Arbitrary in-flight Java remains caller-controlled.
                release.countDown()
                val error = assertThrows(ExecutionException::class.java) { future.get(3, TimeUnit.SECONDS) }
                assertTrue(error.cause.toString(), error.cause is CancellationException)
            } finally { release.countDown(); owned.task.job.cancel(); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)) }
        } }
    }

    @Test(timeout = 20_000) fun entireParserStageObservesActualCallerCancellationAndAbsoluteDeadline() {
        for (reason in listOf("caller", "deadline")) Peer { respond(it, "<a href='/book'>Book</a>") }.use { peer -> Owned(peer.origin, if (reason == "deadline") 1200 else 10_000).use { owned ->
            val entered = CountDownLatch(1); owned.environment.cache.putMemory("entered", entered)
            owned.source.searchUrl = "/search"; owned.source.ruleSearch = SearchRule(bookList = "a", name = "@js:cache.getFromMemory('entered').countDown();while(true){}", bookUrl = "href")
            owned.source.evalJS("1")
            val caller = Job(); val executor = Executors.newSingleThreadExecutor()
            try {
                val future = executor.submit<Any> { runBlocking(caller) { WebBook.searchBookAwait(owned.source, "x") } }
                assertTrue(entered.await(3, TimeUnit.SECONDS)); if (reason == "caller") caller.cancel()
                val error = assertThrows(ExecutionException::class.java) { future.get(3, TimeUnit.SECONDS) }
                assertTrue(error.cause.toString(), error.cause is CancellationException)
                assertEquals(reason == "deadline", owned.task.timedOut.get())
            } finally { caller.cancel(); owned.task.job.cancel(); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)) }
        } }
    }

    @Test(timeout = 15_000) fun sourceSnapshotDecodesOriginalStringRulesAndKeepsEnvironmentOwnership() {
        Peer { respond(it, "<a href='/book'>Book</a>") }.use { peer ->
            val snapshot = jsonObject("bookSourceUrl" to peer.origin, "bookSourceName" to "Decoded", "searchUrl" to "/search", "ruleSearch" to "{\"bookList\":\"a\",\"name\":\"text\",\"bookUrl\":\"href\"}")
            Owned(peer.origin, source = snapshot).use { owned -> runBlocking {
                assertEquals("Decoded", owned.source.bookSourceName)
                assertEquals("Book", WebBook.searchBookAwait(owned.source, "x").single().name)
                RuleEnvironment().use { foreign -> assertThrows(IllegalStateException::class.java) { runBlocking { WebBook.getBookInfoAwait(owned.source, Book(foreign)) } } }
            } }
        }
    }

    private class Owned(origin: String, timeoutMs: Long = 10_000, source: JsonObject = jsonObject("bookSourceUrl" to origin, "bookSourceName" to "Owned", "enabledCookieJar" to true)) : Closeable {
        val session = RuntimeSession(UUID.randomUUID().toString(), source, RuntimeSessionOptions("jvm-okhttp", "owned-agent"))
        val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + timeoutMs)
        val environment = LegadoRuntime.originalRuleEnvironment(task)
        val source = LegadoRuntime.originalBookSource(task, environment)
        override fun close() { environment.close(); task.job.cancel(); session.closed.set(true); session.http!!.close() }
    }
    private data class Capture(val path: String, val uri: String, val headers: Map<String, List<String>>) {
        fun header(name: String) = headers.entries.firstOrNull { it.key.equals(name, true) }?.value.orEmpty().joinToString("; ")
    }
    private class Peer(handler: (HttpExchange) -> Unit) : Closeable {
        val requests = CopyOnWriteArrayList<Capture>(); private val errors = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool { Thread(it, "original-webbook-peer").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = this@Peer.executor
            createContext("/") { e -> try { requests += Capture(e.requestURI.path, e.requestURI.toString(), e.requestHeaders.mapValues { it.value.toList() }); handler(e) } catch (t: Throwable) { errors += t } finally { e.close() } }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() { server.stop(0); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)); if (errors.isNotEmpty()) throw AssertionError("Owned peer failed", errors.first()) }
    }
    companion object {
        private fun respond(e: HttpExchange, text: String) { val bytes = text.toByteArray(Charsets.UTF_8); e.responseHeaders.add("Content-Type", "text/html; charset=utf-8"); e.sendResponseHeaders(200, bytes.size.toLong()); e.responseBody.write(bytes) }
    }
}
