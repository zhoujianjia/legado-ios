package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpServer
import io.yuedu.legado.originalrule.RulePersistenceHost
import io.yuedu.legado.originalrule.GSON
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Public original operation, real retained Rhino/HTTP and real state protocol.
 * App UUID/CAS publication is separately exercised by the native fixture. */
class OriginalBookCallbackTest {
    @Test(timeout = 20_000) fun fourNotificationsUseSourceJavaNullableBindingsAndPersistentCompanions() {
        Peer().use { peer ->
            val script = """
                if (String(java.getKey()) !== String(source.getKey()) || String(sourceApi.getKey()) !== String(baseUrl)) throw new Error('wrong source java');
                if(Number(book.durChapterPos)!==17 || Number(book.durChapterTime)!==1234567890123 || Number(book.order)!==5 || String(book.getImageStyle())!=='FULL')throw new Error('lost actual book fields');
                var prior=String(book.getVariable('events'));
                book.putVariable('events',prior+(prior?'|':'')+event);
                book.putVariable('lastResult',String(result));
                if(chapter!==null) {
                    if(Number(book.durChapterIndex)!==Number(chapter.index))throw new Error('wrong progress');
                    chapter.putVariable('callback',event);
                    chapter.putVariable('large','L'.repeat(10000));
                }
                java.ajax('${peer.origin}/notify?event='+event+'&result='+String(result)+'&chapter='+(chapter===null?'null':chapter.index));
                event;
            """.trimIndent()
            Owned(peer.origin, script).use { owned ->
                for (event in listOf("startRead", "saveRead", "endRead", "addBookShelf")) {
                    val response = owned.call(event, if(event=="saveRead") "1234567890123" else null,
                        withChapter = event != "addBookShelf")
                    assertTrue(response.toString(), response["result"].asJsonObject["executed"].asBoolean)
                }
                val bookState=owned.variables("book","")
                val chapterState=owned.variables("chapter","${peer.origin}/chapter3")
                assertEquals("startRead|saveRead|endRead|addBookShelf", bookState["events"].asString)
                assertEquals("null",bookState["lastResult"].asString)
                assertEquals("endRead",chapterState["callback"].asString)
                assertEquals(10000,owned.large("chapter","${peer.origin}/chapter3","large").length)
                assertEquals(listOf("/notify?event=startRead&result=null&chapter=3", "/notify?event=saveRead&result=1234567890123&chapter=3",
                    "/notify?event=endRead&result=null&chapter=3", "/notify?event=addBookShelf&result=null&chapter=null"),peer.requests.toList())
                assertTrue(owned.hostCalls.all { it.second in setOf("state.read","state.commit") })
                assertTrue(owned.hostCalls.any { it.second=="state.commit" })
            }
        }
    }

    @Test(timeout = 15_000) fun nonListeningUnsupportedAndThrowingNotificationsNeverSilentlyRecover() {
        Peer().use { peer -> Owned(peer.origin,"throw new Error('authored failure')").use { owned ->
            val failure=owned.call("startRead",expectSuccess=false)
            assertEquals("SCRIPT_ERROR",failure["error"].asJsonObject["code"].asString)
            val unsupported=owned.call("delBookShelf",expectSuccess=false)
            assertEquals("UNSUPPORTED_CAPABILITY",unsupported["error"].asJsonObject["code"].asString)
            owned.withScript("book.putVariable('unexpected','bad')",listening=false).use {
                val reply=it.call("startRead")["result"].asJsonObject
                assertFalse(reply["executed"].asBoolean)
                assertTrue(it.hostCalls.isEmpty())
            }
            assertTrue(peer.requests.isEmpty())
        } }
    }

    @Test(timeout = 20_000) fun cancellingHeldNotificationDrainsAndDoesNotCommitItsLaterStatements() {
        Peer().use { peer -> Owned(peer.origin,"book.putVariable('before','kept');java.ajax('${peer.origin}/held');book.putVariable('late','bad')").use { owned ->
            val worker=Executors.newSingleThreadExecutor()
            val task="callback-cancel-${UUID.randomUUID()}"
            try {
                val future=worker.submit<JsonObject>{owned.call("saveRead",task=task,expectSuccess=false)}
                assertTrue("real callback HTTP was entered",peer.held.await(5,TimeUnit.SECONDS))
                LegadoRuntime.cancel(task)
                val failure=future.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",failure["error"].asJsonObject["code"].asString)
                val value=owned.variables("book","")
                assertEquals("kept",value["before"].asString); assertFalse(value.has("late"))
            } finally { worker.shutdownNow(); assertTrue(worker.awaitTermination(5,TimeUnit.SECONDS)) }
        } }
    }

    private class Owned(val origin:String,script:String,listening:Boolean=true,
        private val directory:java.nio.file.Path=Files.createTempDirectory("callback-original-"),
        private val adapter:FileRulePersistenceAdapter=FileRulePersistenceAdapter(directory),
        private val deleteOnClose:Boolean=true):Closeable {
        val hostCalls=CopyOnWriteArrayList<Pair<String,String>>()
        private val id:String
        init {
            val state=RulePersistenceHost(adapter)
            LegadoRuntime.setHostCallback { task,op,raw ->
                if(op=="task.cancel") "{}" else {
                    hostCalls += task to op
                    val request=parseObject(raw)
                    check(request["deadlineEpochMs"].asLong>0 && request["remainingTimeoutMs"].asLong>0)
                    state.dispatch(op,request).toString()
                }
            }
            val source=jsonObject("bookSourceUrl" to origin,"eventListener" to listening,"enabledCookieJar" to false,
                "ruleContent" to jsonObject("callBackJs" to script))
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional",
                "httpTransport" to "jvm-okhttp","stateOwner" to "actual-owned-callback").toString()))
            assertTrue(created.toString(),created["ok"].asBoolean);id=created["sessionId"].asString
        }
        fun withScript(script:String,listening:Boolean=true)=Owned(origin,script,listening,directory,adapter,false)
        fun variables(kind:String,chapter:String):JsonObject {
            val key=GSON.toJson(listOf(origin,"variables",kind,"$origin/book",chapter))
            return parseObject(String(requireNotNull(adapter.read("actual-owned-callback",setOf(key)).values[key]),Charsets.UTF_8))
        }
        fun large(kind:String,chapter:String,name:String):String {
            val key=GSON.toJson(listOf(origin,"big-variable",kind,"$origin/book",chapter,name))
            return String(requireNotNull(adapter.read("actual-owned-callback",setOf(key)).values[key]),Charsets.UTF_8)
        }
        fun call(event:String,result:String?=null,withChapter:Boolean=true,task:String="callback-${UUID.randomUUID()}",expectSuccess:Boolean=true):JsonObject {
            val book=jsonObject("bookUrl" to "$origin/book","origin" to origin,"tocUrl" to "$origin/toc","durChapterIndex" to 3,
                "durChapterPos" to 17,"durChapterTime" to 1234567890123L,"order" to 5,"imageStyle" to "FULL")
            val chapter=if(withChapter) jsonObject("bookUrl" to "$origin/book","url" to "$origin/chapter3","index" to 3,"title" to "Actual chapter","baseUrl" to "$origin/toc") else null
            val reply=parseObject(LegadoRuntime.execute(id,task,"bookCallback",jsonObject("event" to event,"book" to book,
                "chapter" to chapter,"result" to result,"timeoutMs" to 60000).toString()))
            assertEquals(reply.toString(),expectSuccess,reply["ok"].asBoolean);return reply
        }
        override fun close(){LegadoRuntime.closeSession(id);if(deleteOnClose){LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}}
    }
    private class Peer:Closeable {
        val held=CountDownLatch(1)
        private val release=CountDownLatch(1)
        val requests=CopyOnWriteArrayList<String>()
        private val workers=Executors.newFixedThreadPool(2)
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply {
            executor=workers
            createContext("/"){e ->
                requests += e.requestURI.toString()
                try {
                    if(e.requestURI.path=="/held"){held.countDown();check(release.await(10,TimeUnit.SECONDS))}
                    val body="callback-wire".toByteArray();e.sendResponseHeaders(200,body.size.toLong());e.responseBody.write(body)
                } catch(_:java.io.IOException) { /* caller cancellation owns this socket */ }
                finally{e.close()}
            };start()
        }
        val origin="http://127.0.0.1:${server.address.port}"
        override fun close(){release.countDown();server.stop(0);workers.shutdownNow();check(workers.awaitTermination(5,TimeUnit.SECONDS))}
    }
}
