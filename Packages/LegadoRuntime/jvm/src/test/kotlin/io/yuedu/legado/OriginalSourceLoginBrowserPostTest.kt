package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpServer
import io.yuedu.legado.originalrule.RulePersistenceHost
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

/** Public execute/Rhino + actual loopback HTTP. The page callback is an explicit
 * wire fixture, never evidence of UIKit/WebKit execution. */
class OriginalSourceLoginBrowserPostTest {
    @Test(timeout=20_000) fun defaultTrueReusesSinglePostBodyAfterRedirectAndKeepsInitialUrlAndHeaders() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val header="@js: source.put('header-count',String(Number(source.get('header-count')||0)+1));JSON.stringify({'X-Initial':String(source.get('header-count'))});"
            val result=owned.call("var r=java.startBrowserAwait('${peer.post("/redirect")}','POST');if(String(r.body())!=='<html>prefetched-body</html>'||String(r.url())!=='${peer.origin}/redirect'||r.code()!==200||String(r.message())!=='OK'||r.headers().size()!==0||String(r.raw().protocol())!=='http/1.1')throw new Error('POST owner response changed');if(String(source.get('header-count'))!=='1')throw new Error('initial headers reevaluated');",header=header)
            assertEquals(listOf("POST /redirect","GET /landed"),peer.routes)
            assertEquals(listOf("field=synthetic",""),peer.bodies)
            assertEquals(listOf("1","1"),peer.headers)
            assertTrue(peer.contentTypes.first().startsWith("application/x-www-form-urlencoded"))
            val page=owned.pages.single();assertEquals(peer.origin+"/redirect",page["url"].asString)
            assertEquals("<html>prefetched-body</html>",page["prefetchedHTML"].asString)
            assertEquals("1",page["headers"].asJsonObject["X-Initial"].asString)
            val effects=result["completedEffects"].asJsonArray.map{it.asString}
            assertTrue(effects.contains("sourceBrowserPostMaySend"));assertTrue(effects.contains("sourceBrowserPostResponseReceived"))
            assertEquals(0,owned.credentials);assertEquals(0,owned.nativeHTTP)
        } }
    }
    @Test(timeout=20_000) fun falseReturnsDomAndNonawaitPresentsPrefetchedHtmlWithoutSecondPost() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            owned.mode="response"
            owned.call("var r=java.startBrowserAwait('${peer.post("/form")}','DOM',false);if(String(r.body())!=='<html>actual-dom</html>'||String(r.url())!=='${peer.origin}/dom-final')throw new Error('not DOM terminal');")
            owned.mode="presented"
            owned.call("java.startBrowser('${peer.post("/form")}','POST nonawait');")
            assertEquals(listOf("POST /form","POST /form"),peer.routes)
            assertTrue(owned.pages.all{it["prefetchedHTML"].asString=="<html>prefetched-body</html>"})
            assertEquals(0,owned.credentials);assertEquals(0,owned.nativeHTTP)
        } }
    }
    @Test(timeout=20_000) fun emptyPrefetchIsNotMissingAndOversizedBodyNeverReachesPage() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val empty=owned.call("java.startBrowserAwait('${peer.post("/empty")}','Empty');source.putLoginInfo('late');",success=false)
            assertEquals("BROWSER_EMPTY_RESULT",empty["error"].asJsonObject["code"].asString)
            assertTrue(owned.pages.single().has("prefetchedHTML"));assertEquals("",owned.pages.single()["prefetchedHTML"].asString)
            val large=owned.call("java.startBrowser('${peer.post("/large")}','Oversize');source.putLoginInfo('late');",success=false)
            assertEquals("STATE_LIMIT",large["error"].asJsonObject["code"].asString)
            assertEquals(1,owned.pages.size);assertEquals(listOf("POST /empty","POST /large"),peer.routes)
            assertEquals(0,owned.credentials);assertEquals(0,owned.nativeHTTP)
        } }
    }
    @Test(timeout=20_000) fun cancellationDuringRealPostRetainsMaySendButNeverPresentsOrWritesCredentials() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val task="post-cancel-${UUID.randomUUID()}";val worker=Executors.newSingleThreadExecutor()
            try {
                val pending=worker.submit<JsonObject>{owned.call("java.startBrowserAwait('${peer.post("/held")}','Held');source.putLoginInfo('late');",task=task,success=false)}
                assertTrue(peer.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val result=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",result["error"].asJsonObject["code"].asString)
                val effects=result["error"].asJsonObject["completedEffects"].asJsonArray.map{it.asString}
                assertTrue(effects.contains("sourceBrowserPostMaySend"));assertFalse(effects.contains("sourceBrowserPostResponseReceived"))
                assertEquals(listOf("POST /held"),peer.routes);assertTrue(owned.pages.isEmpty())
                assertEquals(0,owned.credentials);assertEquals(0,owned.nativeHTTP)
            } finally {peer.release.countDown();worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        } }
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            // The real POST has returned when the existing synchronous browser
            // Host is entered. This fixture cancels at its admission boundary,
            // before accepting/publishing any page, not after a synthetic ACK.
            val task="post-admission-${UUID.randomUUID()}";owned.cancelAtAdmission=task
            val result=owned.call("java.startBrowserAwait('${peer.post("/form")}','Admission');source.putLoginInfo('late');",task=task,success=false)
            assertEquals("CANCELLED",result["error"].asJsonObject["code"].asString)
            val effects=result["error"].asJsonObject["completedEffects"].asJsonArray.map{it.asString}
            assertTrue(effects.contains("sourceBrowserPostMaySend"));assertTrue(effects.contains("sourceBrowserPostResponseReceived"))
            assertEquals(listOf("POST /form"),peer.routes);assertTrue(owned.pages.isEmpty());assertEquals(0,owned.credentials)
        } }
    }
    private class Owned(val origin:String):Closeable {
        var mode="refetchConfirmed";val pages=mutableListOf<JsonObject>();var credentials=0;var nativeHTTP=0;var cancelAtAdmission:String?=null
        private val directory=Files.createTempDirectory("original-post-");private val state=RulePersistenceHost(FileRulePersistenceAdapter(directory))
        init {LegadoRuntime.setHostCallback{_,operation,raw ->
            if(operation=="task.cancel")"{}"else {
                val input=parseObject(raw);check(input["owner"].asString=="post-owner")
                when(operation){
                    "source.browser"->{
                        check(input["sourceURL"].asString==origin)
                        if(cancelAtAdmission!=null){
                            LegadoRuntime.cancel(cancelAtAdmission!!)
                            jsonObject("ok" to false,"error" to jsonObject("code" to "CANCELLED","message" to "Synthetic admission refused")).toString()
                        } else {
                        pages+=input.deepCopy()
                        val effects=listOf("sourceBrowserMayPresent","sourceBrowserPresented")
                        if(mode=="presented")jsonObject("presented" to true,"hostEffects" to effects).toString()
                        else jsonObject("mode" to mode,"body" to "<html>actual-dom</html>","finalURL" to "$origin/dom-final","hostEffects" to effects).toString()
                        }
                    }
                    "source.login-info"->{credentials++;error("POST browser must not implicitly write credentials")}
                    "http.request"->{nativeHTTP++;error("POST must retain JVM HTTP owner")}
                    else->state.dispatch(operation,input).toString()
                }
            }
        }}
        fun call(action:String,task:String="post-${UUID.randomUUID()}",success:Boolean=true,header:String="{\"X-Initial\":\"synthetic\"}"):JsonObject{
            val source=jsonObject("bookSourceUrl" to origin,"header" to header,"loginUi" to "[]","loginUrl" to "var postPrelude=true;","enabledCookieJar" to false,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "post-owner").toString()));assertTrue(created.toString(),created["ok"].asBoolean)
            val id=created["sessionId"].asString
            try {val reply=parseObject(LegadoRuntime.execute(id,task,"loginAction",jsonObject("action" to action,"credentials" to jsonObject(),"timeoutMs" to 20_000).toString()));assertEquals(reply.toString(),success,reply["ok"].asBoolean);return reply}
            finally {LegadoRuntime.closeSession(id)}
        }
        override fun close(){LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
    private class Peer:Closeable {
        val routes=CopyOnWriteArrayList<String>();val bodies=CopyOnWriteArrayList<String>();val headers=CopyOnWriteArrayList<String>();val contentTypes=CopyOnWriteArrayList<String>()
        val entered=CountDownLatch(1);val release=CountDownLatch(1);private val worker=Executors.newSingleThreadExecutor()
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply{
            executor=worker;createContext("/"){e -> try {
                routes+="${e.requestMethod} ${e.requestURI.path}";bodies+=e.requestBody.readAllBytes().toString(Charsets.UTF_8)
                headers+=e.requestHeaders.getFirst("X-Initial").orEmpty();contentTypes+=e.requestHeaders.getFirst("Content-Type").orEmpty()
                if(e.requestURI.path=="/held"){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
                if(e.requestURI.path=="/redirect"){e.responseHeaders.add("Location","/landed");e.sendResponseHeaders(302,-1)}else{
                    val body=when(e.requestURI.path){"/empty"->"";"/large"->"x".repeat(4*1024*1024+1);else->"<html>prefetched-body</html>"}
                    val bytes=body.toByteArray();e.responseHeaders.add("Content-Type","text/html; charset=utf-8");e.responseHeaders.add("X-Network","must-not-escape")
                    e.sendResponseHeaders(201,if(bytes.isEmpty())-1 else bytes.size.toLong());if(bytes.isNotEmpty())e.responseBody.write(bytes)
                }
            } finally {e.close()}};start()
        }
        val origin="http://127.0.0.1:${server.address.port}"
        fun post(path:String)="$origin$path,{\"method\":\"POST\",\"body\":\"field=synthetic\"}"
        override fun close(){release.countDown();server.stop(0);worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
    }
}
