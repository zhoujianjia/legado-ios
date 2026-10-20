package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpServer
import io.yuedu.legado.originalrule.GSON
import io.yuedu.legado.originalrule.RulePersistenceHost
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

/** Public JSON execution and actual temporary file persistence host. This controlled
 * capability fixture does not grant any App UUID or claim Swift/JNI/WK execution. */
class OriginalContentBatchPublicTest {
    @Test(timeout=20_000) fun publicBatchRequiresExplicitHostAuthorizationBeforeStateHttpAndKeepsDefaultRoute() {
        Peer().use { peer -> Owner(peer.origin, "java.cacheContent(chapters[0],java.ajax(book.origin+'/zero'))").use { owner ->
            owner.authorized.set(false)
            val denied = owner.execute()
            assertEquals("UNSUPPORTED_CAPABILITY", denied["error"].asJsonObject["code"].asString)
            assertEquals(listOf("content.batch.authorize"), owner.operations)
            assertTrue(peer.requests.isEmpty())
            owner.authorized.set(true); owner.operations.clear()
            val invalid = owner.input().apply { add("chapters", com.google.gson.JsonArray().apply { add(owner.chapter(0)); add(owner.chapter(0)) }) }
            assertEquals("INVALID_ARGUMENT", owner.execute(invalid)["error"].asJsonObject["code"].asString)
            assertTrue(owner.operations.isEmpty())
            assertEquals("UNSUPPORTED_CAPABILITY", owner.execute(jsonObject("book" to owner.book(), "needSave" to true), "content")["error"].asJsonObject["code"].asString)
            assertTrue(owner.operations.isEmpty())
        } }
    }
    @Test(timeout=20_000) fun publicBatchReturnsOnlyMissingAndPersistsDuplicateUrlIndexesAcrossNewSessions() {
        Peer().use { peer -> Owner(peer.origin, "java.cacheContent(chapters[0],java.ajax(book.origin+'/zero'));java.cacheContent(chapters[1],java.ajax(book.origin+'/one'))").use { owner ->
            val response = owner.execute(); assertTrue(response.toString(), response["ok"].asBoolean)
            val result=response["result"].asJsonObject
            assertFalse(result.has("contents")); assertEquals(listOf(2), result["missingChapters"].asJsonArray.map { it.asJsonObject["index"].asInt })
            assertEquals("body-zero", owner.body(0)); assertEquals("body-one", owner.body(1)); assertNull(owner.body(2))
            assertEquals("content.batch.authorize", owner.operations.first())
            assertTrue(owner.requests.all { it["remainingTimeoutMs"].asLong>0 && it["deadlineEpochMs"].asLong>0 })
            assertEquals(listOf("/zero", "/one"),peer.requests.map { it.first }); assertTrue(peer.requests[1].second.contains("batch=one"))
            owner.reopen(); assertEquals("body-zero",owner.body(0)); assertEquals("body-one",owner.body(1))
        } }
    }
    @Test(timeout=20_000) fun ordinaryScriptErrorKeepsRealSavedPrefixAndDoesNotRetryMissingChapters() {
        Peer().use { peer -> Owner(peer.origin,"book.putVariable('state','committed');java.cacheContent(chapters[0],java.ajax(book.origin+'/zero'));throw Error('public-batch-failed')").use { owner ->
            owner.reportStateEffects.set(true)
            val response=owner.execute(); assertFalse(response.toString(),response["ok"].asBoolean)
            assertTrue(response.toString(),response.toString().contains("public-batch-failed"))
            val effects=response["error"].asJsonObject["completedEffects"].asJsonArray.map{it.asString}
            assertTrue(effects.toString(),effects.containsAll(listOf("bookVariablesMayCommit","bookVariablesCommitted","chapterContentMayCommit","chapterContentCommitted")))
            assertEquals("body-zero",owner.body(0)); assertNull(owner.body(1)); assertEquals(listOf("/zero"),peer.requests.map{it.first})
            owner.reopen(); assertEquals("body-zero",owner.body(0))
        } }
    }
    @Test(timeout=35_000) fun cancellationCloseAndDeadlineRejectLateSecondSaveButKeepCommittedPrefix() {
        for(mode in listOf("cancel","close","deadline")) Peer().use { peer ->
            Owner(peer.origin,"java.cacheContent(chapters[0],java.ajax(book.origin+'/zero'));java.cacheContent(chapters[1],java.ajax(book.origin+'/blocked'))").use { owner ->
                val pool=Executors.newSingleThreadExecutor()
                try {
                    val input=owner.input().apply{addProperty("timeoutMs",if(mode=="deadline")2500 else 9000)}
                    val future=pool.submit<String>{LegadoRuntime.execute(owner.id,"public-batch-$mode","contentBatch",input.toString())}
                    assertTrue(peer.entered.await(5,TimeUnit.SECONDS))
                    when(mode){"cancel"->LegadoRuntime.cancel("public-batch-$mode");"close"->LegadoRuntime.closeSession(owner.id)}
                    val response=parseObject(future.get(6,TimeUnit.SECONDS))
                    assertEquals(response.toString(),if(mode=="deadline")"TIMEOUT" else "CANCELLED",response["error"].asJsonObject["code"].asString)
                    peer.release.countDown();assertEquals("body-zero",owner.body(0));assertNull(owner.body(1))
                }finally{peer.release.countDown();pool.shutdownNow();check(pool.awaitTermination(3,TimeUnit.SECONDS))}
            }
        }
    }
    @Test(timeout=20_000) fun revokedSaveCapabilityPreservesTypedCompletedEffectsAndDoesNotCommitNextChapter() {
        Peer().use { peer -> Owner(peer.origin,"java.cacheContent(chapters[0],'prefix');java.cacheContent(chapters[1],'forbidden')").use { owner ->
            owner.revokeAfterFirstSave.set(true)
            val response=owner.execute();assertFalse(response.toString(),response["ok"].asBoolean)
            val error=response["error"].asJsonObject
            assertEquals("INVALID_STATE_OWNER",error["code"].asString)
            assertTrue(error.toString(),error["completedEffects"].asJsonArray.any{it.asString=="chapterContentCommitted"})
            assertEquals("prefix",owner.body(0));assertNull(owner.body(1));assertTrue(peer.requests.isEmpty())
        } }
    }
    private class Owner(val origin:String, script:String):Closeable {
        private val directory=Files.createTempDirectory("public-content-batch-")
        private val host=RulePersistenceHost(FileRulePersistenceAdapter(directory))
        val authorized=AtomicBoolean(true);val revokeAfterFirstSave=AtomicBoolean(false);val reportStateEffects=AtomicBoolean(false)
        val operations=CopyOnWriteArrayList<String>();val requests=CopyOnWriteArrayList<JsonObject>()
        private var bodyCommits=0
        private val source=jsonObject("bookSourceUrl" to origin,"bookSourceName" to "owned-public-batch","bookSourceType" to 0,"enabledCookieJar" to true,
            "ruleContent" to jsonObject("contentBatch" to script))
        private val options=jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "actual-test-owner")
        var id:String;private set
        init {
            LegadoRuntime.setHostCallback {task,operation,raw->
                if(operation=="task.cancel")"{}" else{
                    val input=parseObject(raw);operations+=operation;requests+=input
                    check(task.startsWith("public-batch"))
                    if(operation=="content.batch.authorize") {
                        check(input["bookURL"].asString==origin+"/book" && input["sourceURL"].asString==origin)
                        if(authorized.get())jsonObject("ok" to true,"authorized" to true).toString()
                        else jsonObject("ok" to false,"error" to jsonObject("code" to "UNSUPPORTED_CAPABILITY","message" to "No actual save grant")).toString()
                    }else{
                        val bodyCommit=operation=="state.commit" && input["changes"].asJsonObject.keySet().any{parseKey(it)[1]=="content"}
                        if(bodyCommit && revokeAfterFirstSave.get() && bodyCommits>0)jsonObject("ok" to false,"error" to jsonObject("code" to "INVALID_STATE_OWNER","message" to "Current App generation revoked","completedEffects" to listOf("chapterContentCommitted"))).toString()
                        else host.dispatch(operation,input).also{result->
                            if(operation=="state.commit" && result["committed"].asBoolean){
                                if(bodyCommit)bodyCommits++
                                if(reportStateEffects.get()){
                                    val bookCommit=input["changes"].asJsonObject.keySet().any{key->val parts=parseKey(key);parts[1]=="variables" && parts[2]=="book"}
                                    val prefix=if(bodyCommit)"chapterContent" else if(bookCommit)"bookVariables" else null
                                    if(prefix!=null)result.add("hostEffects",GSON.toJsonTree(listOf(prefix+"MayCommit",prefix+"Committed")))
                                }
                            }
                        }.toString()
                    }
                }
            }
            id=create()
        }
        private fun create():String{val r=parseObject(LegadoRuntime.createSession(source.toString(),options.toString()));assertTrue(r.toString(),r["ok"].asBoolean);return r["sessionId"].asString}
        fun reopen(){LegadoRuntime.closeSession(id);id=create()}
        fun book()=jsonObject("bookUrl" to origin+"/book","origin" to origin,"name" to "Owned","author" to "Author","type" to 8)
        fun chapter(index:Int)=jsonObject("bookUrl" to origin+"/book","url" to origin+"/duplicate","title" to "Chapter $index","baseUrl" to origin,"index" to index)
        fun input()=jsonObject("book" to book(),"chapters" to com.google.gson.JsonArray().apply{repeat(3){add(chapter(it))}})
        fun execute(input:JsonObject=input(),operation:String="contentBatch")=parseObject(LegadoRuntime.execute(id,"public-batch-main",operation,input.toString()))
        fun body(index:Int):String?{
            val key=GSON.toJson(listOf(origin,"content",origin+"/book",index.toString()))
            val r=host.dispatch("state.read",jsonObject("owner" to "actual-test-owner","keys" to listOf(key)))
            val value=r["values"].asJsonObject[key]?:return null
            if(value.isJsonNull)return null
            return parseObject(String(java.util.Base64.getDecoder().decode(value.asString),Charsets.UTF_8))["body"].asString
        }
        override fun close(){LegadoRuntime.closeSession(id);LegadoRuntime.setHostCallback(null);directory.toFile().deleteRecursively()}
        private fun parseKey(raw:String)=com.google.gson.JsonParser.parseString(raw).asJsonArray.map{it.asString}
    }
    private class Peer:Closeable {
        val requests=CopyOnWriteArrayList<Pair<String,String>>();val entered=CountDownLatch(1);val release=CountDownLatch(1)
        private val errors=CopyOnWriteArrayList<Throwable>();private val executor=Executors.newCachedThreadPool()
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply{
            this.executor=this@Peer.executor
            createContext("/"){exchange->try{
                val path=exchange.requestURI.path;requests+=path to exchange.requestHeaders.getFirst("Cookie").orEmpty()
                if(path=="/blocked"){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
                if(path=="/zero")exchange.responseHeaders.add("Set-Cookie","batch=one; Path=/")
                val bytes=(if(path=="/one")"body-one" else "body-zero").toByteArray()
                exchange.sendResponseHeaders(200,bytes.size.toLong());exchange.responseBody.use{it.write(bytes)}
            }catch(error:java.io.IOException){/* Real cancellation closes the HTTP peer. */}catch(error:Throwable){errors+=error}finally{exchange.close()}}
            start()
        }
        val origin="http://127.0.0.1:${server.address.port}"
        override fun close(){release.countDown();server.stop(0);executor.shutdownNow();check(executor.awaitTermination(3,TimeUnit.SECONDS));assertTrue(errors.toString(),errors.isEmpty())}
    }
}
