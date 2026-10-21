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

/** Public V2 dispatcher and actual HTTP; source.browser is a wire fixture,
 * never evidence of an executed UIKit page. No implicit credential authority. */
class OriginalSourceLoginV2BrowserTest {
    @Test(timeout=20_000) fun v2UsesSameSourceApiForDefaultGetPostAndNonawaitUi() {
        Peer().use { peer -> Owned(peer).use { owned ->
            owned.action("var r=java.startBrowserAwait('${peer.origin}/get','GET');if(String(r.body())!=='<html>network</html>'||String(r.url())!=='${peer.origin}/get'||r.code()!==200||String(r.message())!=='OK'||r.headers().size()!==0)throw Error('wrong StrResponse');")
            owned.action("var r=source.startBrowserAwait('${peer.post("/post")}','POST',true,null);if(String(r.body())!=='<html>network</html>')throw Error('POST body not reused');")
            owned.mode="presented"
            owned.action("source.startBrowser('${peer.origin}/nonawait','Nonawait',null);")
            owned.ui("java.startBrowser('${peer.origin}/ui','UI');")
            assertEquals(listOf("GET /get","POST /post"),peer.routes)
            assertEquals(listOf(false,true,false,false),owned.pages.map{it.has("prefetchedHTML")})
            assertTrue(owned.pages.all{it["sourceURL"].asString==peer.origin && it["owner"].asString=="v2-browser-owner"})
            assertEquals(0,owned.credentials);assertEquals(0,owned.nativeHTTP)
        } }
    }
    @Test(timeout=20_000) fun falseReturnsAtomicDomForBothHttpMethods() {
        Peer().use { peer -> Owned(peer).use { owned ->
            owned.mode="response"
            for(url in listOf(peer.origin+"/get",peer.post("/post")))
                owned.action("var r=java.startBrowserAwait('$url','DOM',false);if(String(r.body())!=='<html>dom</html>'||String(r.url())!=='${peer.origin}/dom-final')throw Error('wrong DOM');")
            assertEquals(listOf("POST /post"),peer.routes)
            assertEquals(listOf(false,true),owned.pages.map{it.has("prefetchedHTML")})
            assertTrue(owned.pages.all{!it["refetchAfterSuccess"].asBoolean})
            assertEquals(listOf("synthetic"),peer.headers);assertEquals(listOf("field=synthetic"),peer.bodies)
            assertEquals(0,owned.credentials);assertEquals(0,owned.nativeHTTP)
        } }
    }
    @Test(timeout=20_000) fun acceptedBrowserEffectsSurviveScriptFailureAndHtmlRemainsUnsupported() {
        Peer().use { peer -> Owned(peer).use { owned ->
            owned.mode="presented"
            val failed=owned.action("java.startBrowser('${peer.origin}/accepted','Accepted');throw Error('SYNTHETIC-V2-PRIVATE');",success=false)
            assertEquals("SCRIPT_ERROR",failed["error"].asJsonObject["code"].asString)
            assertTrue(failed["error"].asJsonObject["completedEffects"].asJsonArray.map{it.asString}.contains("sourceBrowserPresented"))
            assertFalse(failed.toString().contains("SYNTHETIC-V2-PRIVATE"))
            // The already-accepted script failure above remains an error with
            // its Presented effect. Explicit local HTML is now a real branch.
            owned.action("java.startBrowser('${peer.origin}/local','Local','<html>x</html>');")
            owned.mode="response"
            owned.action("var r=source.startBrowserAwait('${peer.origin}/local','Local',false,'');if(String(r.body())!=='<html>dom</html>')throw Error('lost DOM');")
            assertEquals(3,owned.pages.size)
            assertTrue(owned.pages[1]["prefetchedHTML"].asString.contains("<html>x</html>"))
            assertTrue(owned.pages.drop(1).all{it.has("localPage")&&it["prefetchedHTML"].asString.isNotEmpty()})
            assertFalse(owned.pages.last()["refetchAfterSuccess"].asBoolean)
            for(script in listOf("java.showBrowser('${peer.origin}/blocked');", "source.startBrowser('file:///private/synthetic','Not web');")) {
                val rejected=owned.action(script,success=false)
                assertEquals("UNSUPPORTED_CAPABILITY",rejected["error"].asJsonObject["code"].asString)
            }
            assertEquals(3,owned.pages.size);assertTrue(peer.routes.isEmpty());assertEquals(0,owned.credentials);assertEquals(0,owned.nativeHTTP)
        } }
    }
    @Test(timeout=20_000) fun cancellationDrainsCurrentTaskAndRetainsActualPostFacts() {
        Peer().use { peer -> Owned(peer).use { owned ->
            val worker=Executors.newSingleThreadExecutor();val task="v2-post-${UUID.randomUUID()}"
            try {
                val pending=worker.submit<JsonObject>{owned.action("java.startBrowserAwait('${peer.post("/held")}','Held');source.putLoginInfo('late');",task=task,success=false)}
                assertTrue(peer.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val failed=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",failed["error"].asJsonObject["code"].asString)
                val effects=failed["error"].asJsonObject["completedEffects"].asJsonArray.map{it.asString}
                assertTrue(effects.contains("sourceBrowserPostMaySend"));assertFalse(effects.contains("sourceBrowserPostResponseReceived"))
                assertTrue(owned.pages.isEmpty());assertEquals(0,owned.credentials)
            } finally {peer.release.countDown();worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        } }
    }
    @Test(timeout=20_000) fun sensitiveSearchNeverInheritsPreviousOrFutureLoginAdmission() {
        Peer().use { peer -> Owned(peer, searchProbe=true).use { owned ->
            val before=owned.search();assertEquals("UNSUPPORTED_CAPABILITY",before["error"].asJsonObject["code"].asString)
            owned.mode="presented";owned.action("java.startBrowser('${peer.origin}/admitted','Login');")
            val after=owned.search();assertEquals("UNSUPPORTED_CAPABILITY",after["error"].asJsonObject["code"].asString)
            assertEquals(1,owned.pages.size);assertTrue(peer.routes.isEmpty());assertEquals(0,owned.credentials)
        } }
    }
    @Test(timeout=20_000) fun concurrentTaskCannotBorrowActiveLoginBrowserAdmission() {
        Peer().use { peer -> Owned(peer, searchProbe=true).use { owned ->
            owned.mode="presented";owned.holdPage=true
            val worker=Executors.newSingleThreadExecutor()
            try {
                val pending=worker.submit<JsonObject>{owned.action("java.startBrowser('${peer.origin}/held-page','Login');")}
                assertTrue(owned.pageEntered.await(5,TimeUnit.SECONDS))
                val denied=owned.search();assertEquals("UNSUPPORTED_CAPABILITY",denied["error"].asJsonObject["code"].asString)
                owned.pageRelease.countDown();assertTrue(pending.get(5,TimeUnit.SECONDS)["ok"].asBoolean)
                assertEquals(1,owned.pages.size);assertTrue(peer.routes.isEmpty());assertEquals(0,owned.credentials)
            } finally {owned.pageRelease.countDown();worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        } }
    }
    private class Owned(val peer:Peer,searchProbe:Boolean=false):Closeable {
        var mode="refetchConfirmed";var holdPage=false;val pageEntered=CountDownLatch(1);val pageRelease=CountDownLatch(1)
        val pages=CopyOnWriteArrayList<JsonObject>();var credentials=0;var nativeHTTP=0
        private val directory=Files.createTempDirectory("original-v2-browser-");private val state=RulePersistenceHost(FileRulePersistenceAdapter(directory))
        private val source=jsonObject("bookSourceUrl" to peer.origin,"loginUi" to "{\"version\":2}","loginUrl" to "function login(){};function loginUi(s){if(java!==source)throw Error('binding');eval(s.script);return {rows:[{name:'Ready',type:'label'}]};}function loginAction(a,s,f){if(java!==source)throw Error('binding');eval(a);return {state:{done:true}};}","enabledCookieJar" to false,"ruleContent" to jsonObject(),"searchUrl" to "${peer.origin}/search","ruleSearch" to jsonObject("bookList" to "class.none"),"header" to if(searchProbe)"@js: if(typeof v2SearchProbe!=='undefined'){source.login();source.startBrowser('${peer.origin}/forbidden','Not login');}JSON.stringify({'X-Initial':'synthetic'});" else "{\"X-Initial\":\"synthetic\"}")
        private val id:String
        init {
            // Search's existing URL JS evaluates its own privacy-protecting
            // source.login() on this same task. It must not grant browser UI.
            if(searchProbe)source.addProperty("searchUrl","@js: var v2SearchProbe=true;source.login();source.startBrowser('${peer.origin}/forbidden','Not login');'${peer.origin}/search';")
            LegadoRuntime.setHostCallback{_,operation,raw ->
                if(operation=="task.cancel")"{}"else {
                    val input=parseObject(raw);check(input["owner"].asString=="v2-browser-owner")
                    when(operation){
                        "source.browser"->{pages+=input.deepCopy();if(holdPage){pageEntered.countDown();check(pageRelease.await(5,TimeUnit.SECONDS))};val effects=listOf("sourceBrowserMayPresent","sourceBrowserPresented");if(mode=="presented")jsonObject("presented" to true,"hostEffects" to effects).toString() else jsonObject("mode" to mode,"body" to "<html>dom</html>","finalURL" to "${peer.origin}/dom-final","hostEffects" to effects).toString()}
                        "source.login-info"->{if(input["action"].asString=="get")jsonObject("value" to null).toString() else {credentials++;error("Unexpected credential mutation")}}
                        "http.request"->{nativeHTTP++;error("Unexpected generic HTTP owner")}
                        else->state.dispatch(operation,input).toString()
                    }
                }
            }
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "v2-browser-owner").toString()));check(created["ok"].asBoolean);id=created["sessionId"].asString
        }
        fun action(script:String,task:String="v2-${UUID.randomUUID()}",success:Boolean=true):JsonObject=call("loginV2Action",jsonObject("action" to script,"stateJSON" to "{}","form" to jsonObject(),"timeoutMs" to 15_000),task,success)
        fun ui(script:String):JsonObject=call("loginV2UI",jsonObject("stateJSON" to jsonObject("script" to script).toString(),"timeoutMs" to 15_000),"v2-ui-${UUID.randomUUID()}",true)
        fun search():JsonObject=call("search",jsonObject("key" to "synthetic","page" to 1,"timeoutMs" to 15_000),"v2-search-${UUID.randomUUID()}",false)
        private fun call(op:String,input:JsonObject,task:String,success:Boolean):JsonObject {val reply=parseObject(LegadoRuntime.execute(id,task,op,input.toString()));assertEquals(reply.toString(),success,reply["ok"].asBoolean);return reply}
        override fun close(){pageRelease.countDown();LegadoRuntime.closeSession(id);LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
    private class Peer:Closeable {
        val routes=CopyOnWriteArrayList<String>();val bodies=CopyOnWriteArrayList<String>();val headers=CopyOnWriteArrayList<String>();val entered=CountDownLatch(1);val release=CountDownLatch(1)
        private val worker=Executors.newSingleThreadExecutor()
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply {executor=worker;createContext("/"){e->try {
            routes+="${e.requestMethod} ${e.requestURI.path}";bodies+=e.requestBody.readAllBytes().toString(Charsets.UTF_8);headers+=e.requestHeaders.getFirst("X-Initial").orEmpty()
            if(e.requestURI.path=="/held"){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
            val bytes="<html>network</html>".toByteArray();e.responseHeaders.add("Content-Type","text/html; charset=utf-8");e.sendResponseHeaders(201,bytes.size.toLong());e.responseBody.write(bytes)
        }finally{e.close()}};start()}
        val origin="http://127.0.0.1:${server.address.port}"
        fun post(path:String)="$origin$path,{\"method\":\"POST\",\"body\":\"field=synthetic\"}"
        override fun close(){release.countDown();server.stop(0);worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
    }
}
