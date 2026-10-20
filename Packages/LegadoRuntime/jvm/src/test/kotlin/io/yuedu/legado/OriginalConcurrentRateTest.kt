package io.yuedu.legado

import com.google.gson.JsonObject
import com.script.rhino.runScriptWithContext
import com.sun.net.httpserver.HttpServer
import io.legado.app.data.entities.*
import io.legado.app.data.entities.rule.ContentRule
import io.legado.app.help.ConcurrentRateLimiter
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.webBook.WebBook
import io.yuedu.legado.originalrule.*
import io.yuedu.legado.reference.OriginalConcurrentRateLimiterOracle
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Actual owned task/host/loopback; pinned original limiter is a test-only oracle. */
class OriginalConcurrentRateTest {
    @Test(timeout = 25_000) fun pinnedRateCounterBodiesMatchNullMalformedWindowParsingFrequencyAndReset() {
        Peer().use { peer -> Factory(peer.origin).use { f ->
            for (rate in listOf(null,"","0","bad","2/no","2/100000","3","0/9","-1","/100")) {
                f.revision++; f.rate = rate
                f.open(sourceID = UUID.randomUUID().toString()).use { o -> runBlocking {
                    val oracle = OriginalConcurrentRateLimiterOracle(o.source)
                    val actual = ConcurrentRateLimiter(o.source)
                    val expected = oracle.getConcurrentRecord(); val record = actual.getConcurrentRecord()
                    if(expected == null) assertNull(record)
                    else {
                        assertNotNull(record); record!!
                        assertEquals(expected.accessLimit,record.accessLimit); assertEquals(expected.interval,record.interval); assertEquals(expected.frequency,record.frequency)
                        if(rate == "2/100000") {
                            assertSame(expected,oracle.getConcurrentRecord()); assertSame(record,actual.getConcurrentRecord())
                            assertEquals(2,record.frequency); assertEquals(expected.frequency,record.frequency)
                        }
                        expected.time = 0; record.time = 0
                        val expectedReset = oracle.getConcurrentRecord()!!; val actualReset = actual.getConcurrentRecord()!!
                        assertEquals(expectedReset.frequency,actualReset.frequency)
                        assertEquals(1,actualReset.frequency)
                        actualReset.time = 0; actualReset.interval = 0
                    }
                } }
            }
            assertTrue(peer.requests.isEmpty())
        } }
    }

    @Test(timeout = 20_000) fun originalDelayReallyBlocksCommonAjaxAndRedirectCountsAsOneAdmission() {
        Peer().use { peer -> Factory(peer.origin).use { f ->
            f.rate = "1/220"
            f.open().use { o -> runBlocking {
                val record = ConcurrentRateLimiter(o.source).getConcurrentRecord()!!
                val start = System.nanoTime()
                AnalyzeRule(source=o.source).use { assertTrue(it.connect(peer.origin+"/limited").body()!!.contains("body")) }
                val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-start)
                assertTrue("Actual original window delay elapsed="+elapsed,elapsed >= 140)
                assertEquals(listOf("/limited"),peer.requests.map { it.first })
                record.time = 0; record.interval = 0
            } }
            f.revision++; f.rate = "5/60000"; peer.requests.clear()
            f.open().use { o -> runBlocking {
                AnalyzeRule(source=o.source).use { rule ->
                    rule.connect(peer.origin+"/first")
                    rule.ajax(peer.origin+"/redirect")
                }
                val record = ConcurrentRateLimiter(o.source).getConcurrentRecord()!!
                assertEquals(3,record.frequency) // Two source requests plus this inspection; redirect uses same admission.
                assertEquals(listOf("/first","/redirect","/target"),peer.requests.map { it.first })
                record.time = 0; record.interval = 0
            } }
        } }
    }

    @Test(timeout = 25_000) fun batchAndNestedRequestsShareCounterWithWebBookAndExplicitSkipRateLimit() {
        Peer().use { peer -> Factory(peer.origin).use { f ->
            f.rate = "10/60000"
            f.open().use { o -> runBlocking {
                val chapters = listOf(o.chapter(0),o.chapter(1)); o.environment.webBook.publish(o.book.bookUrl,chapters)
                o.source.ruleContent = ContentRule(content="#text@text",contentBatch="java.cacheContent(chapters[0],java.ajax(book.origin+'/first'));java.cacheContent(chapters[1],java.ajax(book.origin+'/second'))")
                assertTrue(WebBook.getContentBatchAwait(o.source,o.book,chapters).isEmpty()) // Batch admission=1, ajax=2,3.
                WebBook.getContentAwait(o.source,o.book,o.chapter(2),needSave=false) // Admission4.
                val record = ConcurrentRateLimiter(o.source).getConcurrentRecord()!!; assertEquals(5,record.frequency)
                val before = f.scopeCalls.get()
                AnalyzeUrl(peer.origin+"/skip",source=o.source,environment=o.environment,coroutineContext=coroutineContext)
                    .getStrResponseAwait(skipRateLimit=true)
                assertEquals(before,f.scopeCalls.get())
                assertSame(record,ConcurrentRateLimiter(o.source).getConcurrentRecord()); assertEquals(6,record.frequency)
                assertEquals(4,peer.requests.size)
                record.time=0;record.interval=0
            } }
        } }
    }

    @Test(timeout = 25_000) fun waitingRateUsesActualCallerDeadlineRevokeAndOwnerCloseWithoutStartingHttp() {
        for(reason in listOf("caller","deadline","revoke","environment","session")) Peer().use { peer -> Factory(peer.origin).use { f ->
            f.rate = if(reason in listOf("caller","deadline")) "1/60000" else "1/300"
            f.open(timeoutMs=1_600).use { o ->
                val record = runBlocking { ConcurrentRateLimiter(o.source).getConcurrentRecord()!! }
                f.awaitScope = f.scopeCalls.get()+1
                val caller=Job();val pool=Executors.newSingleThreadExecutor()
                try {
                    val future=pool.submit<String> { runBlocking(caller) { WebBook.getContentAwait(o.source,o.book,o.chapter(0),needSave=false) } }
                    assertTrue(f.waiting.await(3,TimeUnit.SECONDS))
                    when(reason) {
                        "caller" -> caller.cancel()
                        "revoke" -> f.revoked = true
                        "environment" -> o.environment.close()
                        "session" -> o.session.closed.set(true)
                    }
                    val failure=assertThrows(ExecutionException::class.java) { future.get(4,TimeUnit.SECONDS) }
                    if(reason=="revoke") assertTrue(failure.cause.toString(),failure.cause is UnsupportedRuleCapability)
                    else assertTrue(failure.cause.toString(),failure.cause is kotlinx.coroutines.CancellationException)
                    assertEquals(reason=="deadline",o.task.timedOut.get())
                    assertTrue(peer.requests.isEmpty())
                } finally {
                    caller.cancel();o.task.job.cancel();pool.shutdownNow();check(pool.awaitTermination(3,TimeUnit.SECONDS))
                    record.time=0;record.interval=0
                }
            }
        } }
    }

    @Test(timeout = 20_000) fun stableBackingScopeSurvivesNewTaskGrantsButSourceRevisionAndInjectedOwnerStayIsolated() {
        Peer().use { peer -> Factory(peer.origin).use { f ->
            f.rate="9/60000"
            val first=f.open().use { o -> runBlocking { ConcurrentRateLimiter(o.source).getConcurrentRecord()!! } }
            f.open().use { o -> runBlocking {
                val second=ConcurrentRateLimiter(o.source).getConcurrentRecord()!!
                assertSame(first,second);assertEquals(2,second.frequency) // First task/grant is closed, so it cannot be a retained check authority.
            } }
            f.revision++
            val changed=f.open().use { o -> runBlocking { ConcurrentRateLimiter(o.source).getConcurrentRecord()!! } }
            assertNotSame(first,changed);assertEquals(1,changed.frequency)
            val otherSource=f.open(sourceID="different").use { o -> runBlocking { ConcurrentRateLimiter(o.source).getConcurrentRecord()!! } }
            assertNotSame(changed,otherSource)
            Factory(peer.origin).use { other ->
                other.rate=f.rate
                val otherBacking=other.open().use { o -> runBlocking { ConcurrentRateLimiter(o.source).getConcurrentRecord()!! } }
                assertNotSame(changed,otherBacking);otherBacking.time=0;otherBacking.interval=0
            }
            for(record in listOf(first,changed,otherSource)){record.time=0;record.interval=0}
            assertTrue(peer.requests.isEmpty())
        } }
    }

    @Test(timeout = 25_000) fun concurrentExpiryPruningAndSameOwnerAdmissionKeepOneOriginalWindow() {
        Peer().use { peer -> Factory(peer.origin).use { f ->
            f.rate="1/3600000"
            val pool=Executors.newFixedThreadPool(16)
            try { repeat(6) { round ->
                val id="raced-expiry-"+round
                val expired=f.open(sourceID=id).use { o -> runBlocking { ConcurrentRateLimiter(o.source).getConcurrentRecord()!! } }
                expired.time=0
                val start=CountDownLatch(1);val ready=CountDownLatch(16)
                val invocations=(0 until 16).map { index -> f.open(timeoutMs=600,sourceID=if(index<8)id else "raced-prune-$round-$index") }
                val futures=invocations.map { o -> pool.submit(Callable {
                    ready.countDown();check(start.await(3,TimeUnit.SECONDS))
                    try { runBlocking { ConcurrentRateLimiter(o.source).getConcurrentRecord() } }
                    catch(_:kotlinx.coroutines.CancellationException){null}
                }) }
                try {
                    check(ready.await(3,TimeUnit.SECONDS));start.countDown()
                    val outcomes=futures.map { it.get(3,TimeUnit.SECONDS) }
                    assertEquals("Pruning must not detach a row that is being reset/admitted",1,outcomes.take(8).count{it!=null})
                    assertTrue(outcomes.drop(8).all{it!=null})
                    for(record in outcomes.filterNotNull()){record.time=0;record.interval=0}
                } finally { start.countDown();invocations.forEach{it.close()};futures.forEach{it.cancel(true)};expired.time=0;expired.interval=0 }
            } } finally { pool.shutdownNow();check(pool.awaitTermination(3,TimeUnit.SECONDS)) }
            assertTrue(peer.requests.isEmpty())
        } }
    }

    @Test(timeout = 40_000) fun boundedActiveOwnerRegistryAndRawGlobalMapStayClosedWithoutEvictingLiveWindows() {
        Peer().use { peer -> Factory(peer.origin).use { f ->
            f.rate="1/3600000"
            val records=mutableListOf<AnalyzeUrl.ConcurrentRecord>()
            try {
                var limited=false
                for(index in 0..256) {
                    f.revision++
                    try {
                        val record=f.open(sourceID="capacity-"+index).use { o -> runBlocking { ConcurrentRateLimiter(o.source).getConcurrentRecord()!! } }
                        records+=record
                    } catch(error:UnsupportedRuleCapability) {
                        assertTrue(error.message.orEmpty(),error.message.orEmpty().contains("256"));limited=true;break
                    }
                }
                assertTrue(limited);assertTrue(records.isNotEmpty());assertTrue(records.size<=256)
                f.open(sourceID="no-unscoped-map").use { o -> runBlocking {
                    val escaped = o.environment.platform.runWebBook(coroutineContext) {
                        runScriptWithContext(currentCoroutineContext()) {
                            o.source.evalJS("var cls=Packages.io.legado.app.help.ConcurrentRateLimiter; var escaped=false; try{if(cls['access\$getRecords\$cp']() instanceof java.util.Map)escaped=true}catch(ignored){}; for(var name in cls){if(String(name).indexOf('access$')===0){try{if(cls[name]() instanceof java.util.Map)escaped=true}catch(ignored){}}}; escaped")
                        }
                    }
                    assertEquals("Compiler-generated static accessors must not expose a raw owner registry", false, escaped)
                    assertTrue(ConcurrentRateLimiter::class.java.methods.none { it.name.startsWith("access"+"$") && java.util.Map::class.java.isAssignableFrom(it.returnType) })
                    val registry=Class.forName("io.legado.app.help.OwnedConcurrentWindows")
                    assertTrue(registry.methods.none { java.util.Map::class.java.isAssignableFrom(it.returnType) })
                    try {
                        o.environment.platform.runWebBook(coroutineContext) {
                            runScriptWithContext(currentCoroutineContext()) {
                                o.source.evalJS("Packages.io.legado.app.help.ConcurrentRateLimiter.Companion.getConcurrentRecordMap()")
                            }
                        }
                        fail("Raw global registry must not be exposed to erased Java Map writes")
                    } catch(error:Exception) {
                        try { rethrowRuleControlFailure(error);throw error }
                        catch(_:UnsupportedRuleCapability) {}
                    }
                } }
                assertTrue(peer.requests.isEmpty())
            } finally {
                for(record in records){record.time=0;record.interval=0}
                // Original owned API reclaims expired records; no privileged clear/test hook.
                f.revision++;f.open(sourceID="after-expiry").use { o -> runBlocking {
                    val next=ConcurrentRateLimiter(o.source).getConcurrentRecord()!!;next.time=0;next.interval=0
                } }
            }
        } }
    }

    private class Factory(private val origin:String):Closeable {
        private val directory=Files.createTempDirectory("owned-original-rate-")
        private val adapter=FileRulePersistenceAdapter(directory)
        private val identity=UUID.randomUUID().toString()
        private data class Grant(val sourceURL:String,val revision:Int,val taskID:String)
        private val grants=ConcurrentHashMap<String,Grant>()
        var revision=0;var rate:String?=null
        @Volatile var revoked=false
        @Volatile var awaitScope=Int.MAX_VALUE
        val scopeCalls=AtomicInteger()
        val waiting=CountDownLatch(1)
        fun open(timeoutMs:Long=10_000,sourceID:String="main"):Invocation {
            val id=UUID.randomUUID().toString();val grant="rate-grant-"+UUID.randomUUID()
            val sourceURL=origin+"/source-"+sourceID
            grants[grant]=Grant(sourceURL,revision,id)
            val state=RulePersistenceHost(adapter)
            LegadoRuntime.setHostCallback { task,op,raw ->
                if(op=="task.cancel") "{}" else {
                    val input=parseObject(raw);val binding=grants[input["owner"].asString] ?: throw RuntimeFailure("UNSUPPORTED_CAPABILITY","Revoked actual controlled source grant")
                    check(binding.taskID==task && input.has("deadlineEpochMs"))
                    if(revoked) throw RuntimeFailure("UNSUPPORTED_CAPABILITY","Controlled existing source revision was revoked")
                    if(op=="explore.owner.scope") {
                        check(input["sourceURL"].asString==binding.sourceURL)
                        if(scopeCalls.incrementAndGet()==awaitScope)waiting.countDown()
                        jsonObject("scope" to GSON.toJson(listOf(identity,binding.sourceURL,binding.revision))).toString()
                    } else {
                        input.addProperty("owner",identity)
                        state.dispatch(op,input).toString()
                    }
                }
            }
            return Invocation(id,grant,sourceURL,timeoutMs)
        }
        inner class Invocation(id:String,private val grant:String,sourceURL:String,timeoutMs:Long):Closeable {
            val session=RuntimeSession(UUID.randomUUID().toString(),jsonObject("bookSourceUrl" to sourceURL,"concurrentRate" to rate,"enabledCookieJar" to true),
                RuntimeSessionOptions("jvm-okhttp",stateOwner=grant))
            val task=RuntimeTask(id,session,Job(),System.currentTimeMillis()+timeoutMs)
            val environment=LegadoRuntime.originalRuleEnvironment(task)
            val source=LegadoRuntime.originalBookSource(task,environment)
            val book=Book(environment,name="RateBook",author="Owned",bookUrl=origin+"/book",tocUrl=origin+"/toc",origin=origin)
            fun chapter(index:Int)=BookChapter(environment,url=origin+"/chapter-"+index,title="chapter-"+index,bookUrl=book.bookUrl,index=index,baseUrl=origin+"/toc")
            init { source.ruleContent=ContentRule(content="#text@text") }
            override fun close() { environment.close();task.job.cancel();session.closed.set(true);session.http!!.close();grants.remove(grant) }
        }
        override fun close() { LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively()) }
    }
    private class Peer:Closeable {
        val requests=CopyOnWriteArrayList<Pair<String,Long>>()
        private val executor=Executors.newCachedThreadPool()
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply {
            this.executor=this@Peer.executor
            createContext("/") { e ->
                requests+=e.requestURI.path to System.nanoTime()
                if(e.requestURI.path=="/redirect") {
                    e.responseHeaders.add("Location","/target");e.sendResponseHeaders(302,-1)
                } else {
                    val body="<div id='text'>body</div>".toByteArray(Charsets.UTF_8)
                    e.sendResponseHeaders(200,body.size.toLong());e.responseBody.use{it.write(body)}
                }
                e.close()
            };start()
        }
        val origin="http://127.0.0.1:"+server.address.port
        override fun close() { server.stop(0);executor.shutdownNow();check(executor.awaitTermination(3,TimeUnit.SECONDS)) }
    }
}
