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

class OriginalSourceLoginBrowserAwaitTest {
    @Test(timeout=20_000) fun domResponseUsesActualFinalUrlBodyAndOriginalSyntheticRawResponse() {
        Owned().use { owned ->
            owned.finalURL="https://synthetic-await.invalid/redirected?ready=1";owned.body="<html>DOM response</html>"
            val action="""var r=java.startBrowserAwait('https://synthetic-await.invalid/start','DOM',false);if(String(r.url())!=='${owned.finalURL}'||String(r.body())!=='<html>DOM response</html>'||r.code()!==200||String(r.message())!=='OK'||r.headers().size()!==0||String(r.raw().protocol())!=='http/1.1')throw new Error('not the original response constructor');"""
            val result=owned.call(action)
            assertTrue(result["result"].asJsonObject["executed"].asBoolean)
            assertEquals(1,owned.pages.size);assertFalse(owned.pages.single()["refetchAfterSuccess"].asBoolean)
            assertTrue(owned.pages.single()["awaitsResult"].asBoolean)
            assertTrue(result["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserCookieCaptureCompleted"})
            assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpHostCalls)
        }
    }
    @Test(timeout=20_000) fun defaultTrueRefetchUsesOriginalHttpAndFirstHeaderSnapshotButOwnerResponseIsSynthetic200() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            owned.mode="refetchConfirmed"
            val header="@js: source.put('header-count',String(Number(source.get('header-count')||0)+1));JSON.stringify({'X-Initial':String(source.get('header-count'))});"
            val action="""var r=java.startBrowserAwait('${peer.origin}/original','Refetch');if(String(r.body())!=='refetched-body'||String(r.url())!=='${peer.origin}/original'||r.code()!==200||String(r.message())!=='OK'||r.headers().size()!==0)throw new Error('owner response lost original synthetic semantics');if(String(source.get('header-count'))!=='1')throw new Error('header was reevaluated');"""
            owned.call(action,header=header)
            assertEquals(listOf("/original","/redirected"),peer.paths)
            assertEquals(listOf("1","1"),peer.initialHeaders)
            assertTrue(owned.pages.single()["refetchAfterSuccess"].asBoolean)
            assertEquals("1",owned.pages.single()["headers"].asJsonObject["X-Initial"].asString)
            assertEquals(0,owned.httpHostCalls);assertEquals(0,owned.credentialCalls)
        } }
    }
    @Test(timeout=20_000) fun presentationEmptyWrongModeAndExplicitUnsupportedNeverBecomeSuccessfulAwait() {
        Owned().use { owned ->
            for((mode,body,expected)in listOf(Triple("presented","DOM","INVALID_BROWSER_RESULT"),Triple("response","","BROWSER_EMPTY_RESULT"),Triple("refetchConfirmed","DOM","INVALID_BROWSER_RESULT"))){
                owned.mode=mode;owned.body=body
                val result=owned.call("java.startBrowserAwait('https://synthetic-await.invalid/page','Invalid',false);source.putLoginInfo('late');",success=false)
                assertEquals(result.toString(),expected,result["error"].asJsonObject["code"].asString)
                assertTrue(result["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserPresented"})
            }
            owned.failure="BROWSER_CANCELLED"
            val cancelled=owned.call("java.startBrowserAwait('https://synthetic-await.invalid/page','Cancelled',false);source.putLoginInfo('late');",success=false)
            assertEquals("BROWSER_CANCELLED",cancelled["error"].asJsonObject["code"].asString)
            assertFalse(cancelled.toString().contains("SYNTHETIC-AWAIT-PRIVATE"))
            owned.failure=null;val count=owned.pages.size
            for(script in listOf("java.startBrowserAwait('https://synthetic-await.invalid/page','HTML',false,'');","java.startBrowserAwait('https://synthetic-await.invalid/page,{\"method\":\"POST\",\"body\":\"a=b\"}','Post');")){
                assertEquals("UNSUPPORTED_CAPABILITY",owned.call(script,success=false)["error"].asJsonObject["code"].asString)
            }
            assertEquals(count,owned.pages.size);assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpHostCalls)
        }
    }
    @Test(timeout=20_000) fun taskCancellationBeforeAndAfterCookieCaptureRetainsFactsAndPreventsLaterWrites() {
        for(completed in listOf(false,true))Owned().use { owned ->
            owned.hold=true;owned.captureCompleted=completed;val task="await-cancel-${UUID.randomUUID()}";val worker=Executors.newSingleThreadExecutor()
            try {
                val pending=worker.submit<JsonObject>{owned.call("java.startBrowserAwait('https://synthetic-await.invalid/page','Held',false);source.putLoginInfo('late');",task=task,success=false)}
                assertTrue(owned.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val result=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",result["error"].asJsonObject["code"].asString)
                val effects=result["error"].asJsonObject["completedEffects"].asJsonArray.map{it.asString}
                assertTrue(effects.contains("sourceBrowserCookieCaptureIssued"));assertEquals(completed,effects.contains("sourceBrowserCookieCaptureCompleted"))
                assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpHostCalls)
            }finally{owned.release.countDown();worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    private class Owned(val origin:String="https://synthetic-await-owner-${UUID.randomUUID()}.invalid"):Closeable {
        var mode="response";var finalURL="https://synthetic-await.invalid/final";var body="DOM"
        var failure:String?=null;var hold=false;var captureCompleted=true
        val pages=mutableListOf<JsonObject>();var credentialCalls=0;var httpHostCalls=0
        val entered=CountDownLatch(1);val release=CountDownLatch(1);@Volatile private var cancelled=false
        private val directory=Files.createTempDirectory("original-await-");private val state=RulePersistenceHost(FileRulePersistenceAdapter(directory))
        private fun effects()=listOf("sourceBrowserMayPresent","sourceBrowserPresented","sourceBrowserCookieCaptureIssued")+(if(captureCompleted)listOf("sourceBrowserCookieCaptureCompleted")else emptyList())
        init{LegadoRuntime.setHostCallback{_,operation,raw->
            if(operation=="task.cancel"){cancelled=true;release.countDown();"{}"}else{
                val input=parseObject(raw);check(input["owner"].asString=="await-owner")
                when(operation){
                    "source.browser"->{
                        check(input["sourceURL"].asString==origin);pages+=input.deepCopy()
                        if(hold){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
                        if(cancelled||failure!=null)jsonObject("ok" to false,"error" to jsonObject("code" to(if(cancelled)"CANCELLED"else failure),"message" to "SYNTHETIC-AWAIT-PRIVATE","completedEffects" to effects())).toString()
                        else if(mode=="presented")jsonObject("presented" to true,"hostEffects" to effects()).toString()
                        else jsonObject("mode" to mode,"finalURL" to finalURL,"body" to body,"hostEffects" to effects()).toString()
                    }
                    "source.login-info"->{credentialCalls++;error("Await must not store credentials implicitly")}
                    "http.request"->{httpHostCalls++;error("Await refetch must use original JVM HTTP")}
                    else->state.dispatch(operation,input).toString()
                }
            }
        }}
        fun call(action:String,task:String="await-${UUID.randomUUID()}",success:Boolean=true,header:String="{\"X-Source\":\"source-value\"}"):JsonObject{
            val source=jsonObject("bookSourceUrl" to origin,"header" to header,"loginUi" to "[]","loginUrl" to "var awaitPrelude=true;","enabledCookieJar" to true,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "await-owner").toString()));assertTrue(created.toString(),created["ok"].asBoolean);val id=created["sessionId"].asString
            try{val reply=parseObject(LegadoRuntime.execute(id,task,"loginAction",jsonObject("action" to action,"credentials" to jsonObject(),"timeoutMs" to 20_000).toString()));assertEquals(reply.toString(),success,reply["ok"].asBoolean);return reply}finally{LegadoRuntime.closeSession(id)}
        }
        override fun close(){LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
    private class Peer:Closeable{
        val paths=CopyOnWriteArrayList<String>();val initialHeaders=CopyOnWriteArrayList<String>();private val worker=Executors.newSingleThreadExecutor()
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply{
            executor=worker;createContext("/"){e->try{
                paths+=e.requestURI.path;initialHeaders+=e.requestHeaders.getFirst("X-Initial").orEmpty()
                if(e.requestURI.path=="/original"){e.responseHeaders.add("Location","/redirected");e.sendResponseHeaders(302,-1)}else{
                    val bytes="refetched-body".toByteArray();e.responseHeaders.add("X-Peer","network-header-must-not-escape");e.sendResponseHeaders(201,bytes.size.toLong());e.responseBody.write(bytes)
                }
            }finally{e.close()}};start()
        }
        val origin="http://127.0.0.1:${server.address.port}"
        override fun close(){server.stop(0);worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
    }
}
