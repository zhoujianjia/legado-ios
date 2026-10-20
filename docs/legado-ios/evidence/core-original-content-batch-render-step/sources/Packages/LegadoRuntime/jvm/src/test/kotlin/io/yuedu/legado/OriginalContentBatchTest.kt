package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpServer
import io.legado.app.data.entities.*
import io.legado.app.data.entities.rule.ContentRule
import io.legado.app.exception.NoStackTraceException
import io.legado.app.model.BatchContentContext
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.webBook.WebBook
import io.yuedu.legado.originalrule.*
import io.yuedu.legado.reference.OriginalBatchContextOracle
import io.yuedu.legado.reference.ReferenceBatchBookHelp
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

/** Retained original batch body, same real task/HTTP/state host and temporary file owner. */
class OriginalContentBatchTest {

    @Test(timeout = 25_000) fun originalBatchMarkupAndMediaCallbacksPersistExactOutputWithoutExtraHttp() {
        Peer().use { peer -> Owned(peer.origin).use { o -> runBlocking {
            val chapters = o.chapters(3); o.environment.webBook.publish(o.book.bookUrl, chapters)
            val markup = "<usehtml><p>A &amp; B</p><img src='../one.png'><audio src='https://owned.invalid/a.m4a'></audio><iframe src='https://owned.invalid/player'></iframe></usehtml>\nEND"
            val audio = "https://owned.invalid/chapter.m4a,{\"headers\":{\"Referer\":\"https://owned.invalid/book\"}}"
            o.source.ruleContent = ContentRule(contentBatch = "java.cacheContent(chapters[0]," + GSON.toJson(markup) + ");java.cacheContent(chapters[1]," + GSON.toJson(audio) + ")")
            assertEquals(listOf(chapters[2]), WebBook.getContentBatchAwait(o.source, o.book, chapters))
            assertEquals(markup, o.environment.webBook.getContent(o.book, chapters[0]))
            assertEquals(audio, o.environment.webBook.getContent(o.book, chapters[1]))
            assertTrue(peer.requests.isEmpty()); assertTrue(o.session.requests.isEmpty())
            o.reopen { env, book ->
                val restored = env.webBook.chapters(book.bookUrl)
                assertEquals(markup, env.webBook.getContent(book, restored[0]))
                assertEquals(audio, env.webBook.getContent(book, restored[1]))
            }
        } } }
    }

    @Test(timeout = 25_000) fun pinnedBatchOracleKeepsMarkupAcrossSourceAndBookTypesAndOnlyAppliesConfiguredReplacement() {
        Peer().use { peer -> Owned(peer.origin).use { o -> runBlocking {
            val chapters = o.chapters(1); o.environment.webBook.publish(o.book.bookUrl, chapters)
            val captured = mutableListOf<String>()
            ReferenceBatchBookHelp.capture = { _,_,_,body,_ -> captured += body; true }
            try {
                for ((sourceType, bookType) in listOf(0 to 8, 1 to 32, 2 to 64, 4 to 4)) {
                    o.source.bookSourceType = sourceType; o.book.type = bookType
                    for (replace in listOf<String?>(null, "##DROP##")) {
                        o.source.ruleContent = ContentRule(replaceRegex = replace)
                        val tokens = chapters.associate { it.index to o.environment.webBook.contentSaveToken(o.book, it) }
                        val oracle = OriginalBatchContextOracle(o.source, o.book, chapters, coroutineContext, tokens)
                        val port = BatchContentContext(o.source, o.book, chapters, coroutineContext, tokens)
                        val raw = "  <usehtml><b>DROP &amp; prose</b><img src='../image.png'></usehtml>\nhttps://owned.invalid/a.m4a  "
                        assertEquals(oracle.applyContentReplace(chapters[0], raw), port.applyContentReplace(chapters[0], raw))
                        assertTrue(oracle.saveContent(chapters[0], raw)); assertTrue(port.saveContent(chapters[0], raw))
                        assertEquals(captured.last(), o.environment.webBook.getContent(o.book, chapters[0]))
                        if (replace == null) assertEquals(raw, captured.last())
                        oracle.close(); port.close()
                    }
                }
            } finally { ReferenceBatchBookHelp.capture = { _,_,_,_,_ -> true } }
            assertTrue(peer.requests.isEmpty())
        } } }
    }
    @Test(timeout = 25_000) fun realBatchSavesTwoChaptersReturnsOnlyMissingAndKeepsSameBookHttpAndCookieOwner() {
        Peer().use { peer -> Owned(peer.origin).use { o -> runBlocking {
            val chapters = o.chapters(3); o.environment.webBook.publish(o.book.bookUrl, chapters)
            o.source.ruleContent = ContentRule(contentBatch = """
                if(chapters.size()!=result.size() || chapter.index!=0) throw Error('bindings');
                if(!(book instanceof Packages.io.legado.app.data.entities.Book)) throw Error('book');
                java.put('batch','first-chapter'); book.putVariable('owner','same-book');
                chapters[0].imgUrl='new-not-toc-metadata';
                java.cacheContent(chapters[0],java.ajax(book.origin+'/c0'));
                java.cacheContent(chapters[1],java.ajax(book.origin+'/c1'));
            """.trimIndent(), replaceRegex = "##DROP##")
            val missing = WebBook.getContentBatchAwait(o.source, o.book, chapters)
            assertEquals(listOf(chapters[2]), missing); assertSame(chapters[2], missing.single())
            assertEquals("same-book", o.book.getVariable("owner")); assertEquals("first-chapter", chapters[0].getVariable("batch"))
            assertEquals("\u3000\u3000-A\n\u3000\u3000-B", o.environment.webBook.getContent(o.book, chapters[0]))
            assertEquals("\u3000\u3000-C", o.environment.webBook.getContent(o.book, chapters[1]))
            assertEquals(listOf("/c0", "/c1"), peer.requests.map { it.first })
            assertTrue(peer.requests[1].second.contains("owned=1"))
            assertEquals(2, o.session.requests.size)
            o.reopen { env, book ->
                val restored = env.webBook.chapters(book.bookUrl)
                assertEquals(3, restored.size)
                assertEquals("original-image-0", restored[0].imgUrl) // Original cacheContent does not update TOC metadata.
                assertEquals("\u3000\u3000-A\n\u3000\u3000-B", env.webBook.getContent(book, restored[0]))
                assertEquals("\u3000\u3000-C", env.webBook.getContent(book, restored[1]))
                assertNull(env.webBook.getContent(book, restored[2]))
            }
        } } }
    }

    @Test(timeout = 25_000) fun originalWrappersAndBareJsUseSameCallbackAndOrdinaryErrorKeepsCommittedPrefixWithoutFallback() {
        Peer().use { peer -> Owned(peer.origin).use { o -> runBlocking {
            val chapters = o.chapters(2); o.environment.webBook.publish(o.book.bookUrl, chapters)
            o.source.ruleContent = ContentRule(contentBatch = "<js>java.cacheContent(chapters[0],'first')</js><js>java.cacheContent(chapters[1],'second')</js>")
            assertTrue(WebBook.getContentBatchAwait(o.source, o.book, chapters).isEmpty())
            o.source.ruleContent!!.contentBatch = "var literal='<js>'; java.cacheContent(chapters[0],literal+'bare')"
            assertEquals(listOf(chapters[1]), WebBook.getContentBatchAwait(o.source, o.book, chapters))
            assertEquals("<js>bare", o.environment.webBook.getContent(o.book, chapters[0]))
            o.source.ruleContent!!.contentBatch = "cache.putMemory('context',java.getBatchContext());java.cacheContent(chapters[0],'prefix');throw Error('actual-script-error')"
            try { WebBook.getContentBatchAwait(o.source, o.book, chapters); fail("ordinary script error must escape") }
            catch (e: Exception) { assertTrue(e.toString(), e.toString().contains("actual-script-error")) }
            val context = o.environment.cache.getFromMemory("context") as BatchContentContext
            assertEquals(1, context.savedCount()); assertEquals(listOf(chapters[1]), context.missingChapters())
            assertThrows(kotlinx.coroutines.CancellationException::class.java) { context.saveContent(chapters[1], "late") } // The failed invocation context is cancelled before its closed check, as upstream.
            assertEquals("prefix", o.environment.webBook.getContent(o.book, chapters[0]))
            assertEquals("second", o.environment.webBook.getContent(o.book, chapters[1]))
            assertTrue(peer.requests.isEmpty()) // Single-chapter fallback belongs to the original caller, not WebBook.
            o.reopen { env, book -> assertEquals("prefix", env.webBook.getContent(book, env.webBook.chapters(book.bookUrl)[0])) }
        } } }
    }

    @Test(timeout = 20_000) fun pinnedContextOracleMatchesIndexUrlAmbiguityLiveCallbacksReplacementAndCloseContract() {
        Peer().use { peer -> Owned(peer.origin).use { o -> runBlocking {
            val chapters = o.chapters(3); chapters[1].url = chapters[0].url
            o.environment.webBook.publish(o.book.bookUrl, chapters)
            o.source.ruleContent = ContentRule(replaceRegex = "@js:result+'|'+chapter.index+'|'+baseUrl")
            val tokens = chapters.associate { it.index to o.environment.webBook.contentSaveToken(o.book, it) }
            val port = BatchContentContext(o.source, o.book, chapters, coroutineContext, tokens)
            val oracle = OriginalBatchContextOracle(o.source, o.book, chapters, coroutineContext, tokens)
            for (identifier in listOf(chapters[0], chapters[1], BookChapter(o.environment, index = 1), chapters[0].url,
                peer.origin + chapters[0].url, " " + chapters[2].url + " ", chapters[2].getAbsoluteURL(), 1, null, "/unknown")) {
                assertSame(oracle.resolveChapter(identifier), port.resolveChapter(identifier))
            }
            assertNull(port.resolveChapter(chapters[0].url))
            assertSame(chapters[1], port.resolveChapter(BookChapter(o.environment, index = 1)))
            assertEquals(oracle.applyContentReplace(chapters[2], "  A \n B "), port.applyContentReplace(chapters[2], "  A \n B "))
            val captured = mutableListOf<Pair<Int, String>>()
            ReferenceBatchBookHelp.capture = { _,_,chapter,body,_ -> captured += chapter.index to body; true }
            try {
                assertEquals(oracle.saveContent(chapters[0], "body"), port.saveContent(chapters[0], "body"))
                assertEquals(captured.single().second, o.environment.webBook.getContent(o.book, chapters[0]))
                oracle.markSaved(chapters[2]); port.markSaved(chapters[2])
                assertEquals(oracle.missingChapters(), port.missingChapters())
                assertEquals(oracle.savedCount(), port.savedCount())
                assertEquals(oracle.isSaved(chapters[2]), port.isSaved(chapters[2]))
                oracle.close(); port.close()
                assertFalse(oracle.saveContent(chapters[1], "late")); assertFalse(port.saveContent(chapters[1], "late"))
            } finally { ReferenceBatchBookHelp.capture = { _,_,_,_,_ -> true } }
        } } }
    }

    @Test(timeout = 20_000) fun ambiguousUrlsAndBlankCallbacksNeverMarkSavedAndSaveIoFailureReturnsFalseAndPreservesOldFile() {
        Peer().use { peer -> Owned(peer.origin).use { o -> runBlocking {
            val chapters = o.chapters(2); chapters[1].url = chapters[0].url
            o.environment.webBook.publish(o.book.bookUrl, chapters)
            o.source.ruleContent = ContentRule(contentBatch = "java.cacheContent(chapters[0].url,'wrong')")
            try { WebBook.getContentBatchAwait(o.source, o.book, chapters); fail("duplicate URL needs the chapter object") }
            catch (e: Exception) { assertTrue(e.toString(), e.toString().contains("cacheContent")) }
            o.source.ruleContent!!.contentBatch = "cache.putMemory('blank',java.cacheContent(chapters[0],'  '));cache.putMemory('attempt',java.cacheContent(chapters[1],'not-committed'));"
            val before = o.fileBytes(); o.failCommit.set(true)
            assertEquals(chapters, WebBook.getContentBatchAwait(o.source, o.book, chapters))
            assertEquals(false, o.environment.cache.getFromMemory("blank")); assertEquals(false, o.environment.cache.getFromMemory("attempt"))
            assertArrayEquals(before, o.fileBytes())
            o.failCommit.set(false)
            o.source.ruleContent!!.contentBatch = "java.cacheContent(chapters[0],'index-zero');java.cacheContent(chapters[1],'index-one')"
            assertTrue(WebBook.getContentBatchAwait(o.source, o.book, chapters).isEmpty())
            assertEquals("index-zero", o.environment.webBook.getContent(o.book, chapters[0]))
            assertEquals("index-one", o.environment.webBook.getContent(o.book, chapters[1]))
        } } }
    }

    @Test(timeout = 30_000) fun cancellationDeadlineAndCloseKeepSavedPrefixButRejectSecondCallbackAndCloseItsContext() {
        for (reason in listOf("caller", "deadline", "environment")) Peer().use { peer ->
            Owned(peer.origin, if (reason == "deadline") 2_000 else 10_000).use { o ->
                val chapters = o.chapters(2); o.environment.webBook.publish(o.book.bookUrl, chapters)
                val entered = CountDownLatch(1); val release = CountDownLatch(1)
                o.environment.cache.putMemory("entered", entered); o.environment.cache.putMemory("release", release)
                o.source.ruleContent = ContentRule(contentBatch = "cache.putMemory('context',java.getBatchContext());java.cacheContent(chapters[0],'saved-before-cancel');cache.getFromMemory('entered').countDown();cache.getFromMemory('release').await();java.cacheContent(chapters[1],'forbidden-after-cancel')")
                o.source.evalJS("1") // Uses the same absolute task deadline, including library initialization.
                val caller = Job(); val pool = Executors.newSingleThreadExecutor()
                try {
                    val future = pool.submit<List<BookChapter>> { runBlocking(caller) { WebBook.getContentBatchAwait(o.source, o.book, chapters) } }
                    assertTrue(entered.await(3, TimeUnit.SECONDS))
                    val context = o.environment.cache.getFromMemory("context") as BatchContentContext
                    when(reason) {
                        "caller" -> caller.cancel()
                        "environment" -> o.environment.close()
                        else -> CountDownLatch(1).await(maxOf(1L, o.task.deadlineEpochMs - System.currentTimeMillis() + 30L), TimeUnit.MILLISECONDS)
                    }
                    release.countDown()
                    val failure = assertThrows(ExecutionException::class.java) { future.get(4, TimeUnit.SECONDS) }
                    assertTrue(failure.cause.toString(), failure.cause is kotlinx.coroutines.CancellationException)
                    assertEquals(1, context.savedCount()); assertEquals(listOf(chapters[1]), context.missingChapters())
                    o.reopen { env, book ->
                        val restored = env.webBook.chapters(book.bookUrl)
                        assertEquals("saved-before-cancel", env.webBook.getContent(book, restored[0]))
                        assertNull(env.webBook.getContent(book, restored[1]))
                    }
                } finally { release.countDown(); caller.cancel(); pool.shutdownNow(); check(pool.awaitTermination(3, TimeUnit.SECONDS)) }
            }
        }
    }

    @Test(timeout = 25_000) fun staleReplacementGenerationAndRefreshedTocRejectOlderBatchCallbackWithoutOverwritingCurrentState() {
        for (change in listOf("edit", "toc")) Peer().use { peer -> Owned(peer.origin).use { o ->
            val chapters = o.chapters(2); o.environment.webBook.publish(o.book.bookUrl, chapters)
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            o.environment.cache.putMemory("entered", entered); o.environment.cache.putMemory("release", release)
            o.source.ruleContent = ContentRule(contentBatch = "java.cacheContent(chapters[0],'prefix');cache.getFromMemory('entered').countDown();cache.getFromMemory('release').await();cache.putMemory('saved',java.cacheContent(chapters[1],'stale-network'))")
            val pool = Executors.newSingleThreadExecutor()
            try {
                val future = pool.submit<List<BookChapter>> { runBlocking { WebBook.getContentBatchAwait(o.source, o.book, chapters) } }
                assertTrue(entered.await(3, TimeUnit.SECONDS))
                o.reopen { env, book ->
                    val current = env.webBook.chapters(book.bookUrl)
                    if(change == "edit") env.webBook.replaceContent(book, current[1], "current-edit")
                    else { current[1].url = "/new-chapter"; current[1].title = "new-title"; env.webBook.publish(book.bookUrl, current) }
                }
                release.countDown()
                assertEquals(listOf(chapters[1]), future.get(4, TimeUnit.SECONDS))
                assertEquals(false, o.environment.cache.getFromMemory("saved"))
                o.reopen { env, book ->
                    val restored = env.webBook.chapters(book.bookUrl)
                    assertEquals("prefix", env.webBook.getContent(book, restored[0]))
                    if(change == "edit") assertEquals("current-edit", env.webBook.getContent(book, restored[1]))
                    else { assertEquals("/new-chapter", restored[1].url); assertEquals("new-title", restored[1].title); assertNull(env.webBook.getContent(book, restored[1])) }
                }
            } finally { release.countDown(); pool.shutdownNow(); check(pool.awaitTermination(3, TimeUnit.SECONDS)) }
        } }
    }

    @Test(timeout = 20_000) fun missingRuleEmptyBatchAndPublicSaveAuthorityRemainExplicitWithoutRunningAuthoredScripts() {
        Peer().use { peer -> Owned(peer.origin).use { o -> runBlocking {
            try { WebBook.getContentBatchAwait(o.source, o.book, emptyList()); fail("rule validation precedes empty list") } catch (_: NoStackTraceException) {}
            o.source.ruleContent = ContentRule(contentBatch = "throw Error('must-not-run-empty')")
            assertTrue(WebBook.getContentBatchAwait(o.source, o.book, emptyList()).isEmpty())
            AnalyzeRule(o.book,o.source).use { rule ->
                assertThrows(NoStackTraceException::class.java) { rule.cacheContent(null,"outside-batch") }
            }
            val snapshot = jsonObject("bookSourceUrl" to peer.origin, "ruleContent" to jsonObject("contentBatch" to "throw Error('no-save-grant')"))
            val created = parseObject(LegadoRuntime.createSession(snapshot.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "not-an-App-body-grant").toString()))
            val session = created["sessionId"].asString
            try {
                val reply = parseObject(LegadoRuntime.execute(session,"no-body-grant","contentBatch","{}"))
                assertEquals("INVALID_ARGUMENT",reply["error"].asJsonObject["code"].asString)
            } finally { LegadoRuntime.closeSession(session) }
            assertTrue(peer.requests.isEmpty())
        } } }
    }

    private class Owned(val origin: String, timeoutMs: Long = 10_000) : Closeable {
        private val directory = Files.createTempDirectory("owned-original-batch-")
        private val adapter = FileRulePersistenceAdapter(directory)
        private val owner = "existing-batch-owner-" + UUID.randomUUID()
        val failCommit = AtomicBoolean(false)
        private val wrapped = object : RulePersistenceAdapter {
            override fun read(owner: String, keys: Set<String>) = adapter.read(owner,keys)
            override fun compareAndSet(owner: String, revision: Long, changes: Map<String,ByteArray?>): Boolean {
                if(failCommit.get()) throw RulePersistenceException("Actual controlled owner refused content commit")
                return adapter.compareAndSet(owner,revision,changes)
            }
        }
        val session: RuntimeSession
        val task: RuntimeTask
        val environment: RuleEnvironment
        val source: BookSource
        val book: Book
        init {
            val host = RulePersistenceHost(wrapped)
            LegadoRuntime.setHostCallback { _,op,raw -> if(op == "task.cancel") "{}" else host.dispatch(op,parseObject(raw)).toString() }
            session = RuntimeSession(UUID.randomUUID().toString(),jsonObject("bookSourceUrl" to origin,"enabledCookieJar" to true),
                RuntimeSessionOptions("jvm-okhttp",stateOwner = owner))
            task = RuntimeTask(UUID.randomUUID().toString(),session,Job(),System.currentTimeMillis()+timeoutMs)
            environment = LegadoRuntime.originalRuleEnvironment(task)
            source = LegadoRuntime.originalBookSource(task,environment)
            book = makeBook(environment)
        }
        private fun makeBook(env: RuleEnvironment) = Book(env,name="BatchBook",author="BatchAuthor",bookUrl=origin+"/book",tocUrl=origin+"/toc",origin=origin)
        fun chapters(count: Int) = (0 until count).map { BookChapter(environment,url="/c"+it,title="chapter-"+it,bookUrl=book.bookUrl,index=it,baseUrl=origin+"/toc",imgUrl="original-image-"+it) }
        fun fileBytes() = Files.readAllBytes(adapter.file(owner))
        fun reopen(action: (RuleEnvironment,Book)->Unit) {
            RuleEnvironment(persistence=RulePersistenceBinding(adapter,owner,origin)).use { action(it,makeBook(it)) }
        }
        override fun close() {
            environment.close(); task.job.cancel(); session.closed.set(true); session.http!!.close()
            LegadoRuntime.setHostCallback(null); check(directory.toFile().deleteRecursively())
        }
    }
    private class Peer : Closeable {
        val requests = CopyOnWriteArrayList<Pair<String,String>>()
        private val executor = Executors.newCachedThreadPool()
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply {
            this.executor = this@Peer.executor
            createContext("/") { e ->
                requests += e.requestURI.path to e.requestHeaders.getFirst("Cookie").orEmpty()
                if(e.requestURI.path == "/c0") e.responseHeaders.add("Set-Cookie","owned=1; Path=/")
                val text = if(e.requestURI.path == "/c0") "  DROP-A \n DROP-B " else "DROP-C"
                val bytes = text.toByteArray(Charsets.UTF_8)
                e.sendResponseHeaders(200,bytes.size.toLong()); e.responseBody.use { it.write(bytes) }; e.close()
            };start()
        }
        val origin = "http://127.0.0.1:"+server.address.port
        override fun close() { server.stop(0); executor.shutdownNow(); check(executor.awaitTermination(3,TimeUnit.SECONDS)) }
    }
}
