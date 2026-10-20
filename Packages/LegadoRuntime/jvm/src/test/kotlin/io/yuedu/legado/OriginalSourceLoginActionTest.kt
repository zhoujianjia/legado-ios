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
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import java.util.logging.Handler
import java.util.logging.LogRecord
import java.util.logging.Logger
import java.util.logging.Level

class OriginalSourceLoginActionTest {
    @Test(timeout=20_000) fun actionUsesOriginalJavaMapNullEntitiesLongFlagAndNeverImplicitlyStores() {
        Owned().use { owned ->
            owned.secret="{\"hidden\":\"persisted-hidden\",\"username\":\"persisted-user\"}"
            val raw=owned.secret
            val action="""if(java===source||book!==null||chapter!==null||isLongClick!==true)throw new Error('wrong action bindings');if(String(result.get('hidden'))!=='working-hidden'||String(result.get('username'))!=='')throw new Error('incomplete Map');java.setContent('<p>parsed</p>');if(String(java.getString('p@text'))!=='parsed')throw new Error('not original AnalyzeRule');result.put('temporary','not-persistent');JSON.stringify({Authorization:'must-not-be-header'});"""
            val reply=owned.call(action,jsonObject("hidden" to "working-hidden","username" to ""),
                prelude="function login(){throw new Error('action must not call login');}",longClick=true)
            assertTrue(reply["result"].asJsonObject["executed"].asBoolean)
            assertEquals(raw,owned.secret);assertEquals(0,owned.secretWrites);assertEquals(0,owned.secretReads)
            assertNull(owned.header())
        }
    }
    @Test(timeout=20_000) fun nullActionAndMissingLoginSkipWhileEmptyActionAndEmptyMapStillFollowOriginal() {
        Owned().use { owned ->
            owned.secret="unchanged-non-json-raw"
            assertFalse(owned.call(null,prelude="source.putLoginHeader('must-not-run')")["result"].asJsonObject["executed"].asBoolean)
            assertFalse(owned.call("throw new Error('must-not-run')",prelude="")["result"].asJsonObject["executed"].asBoolean)
            assertFalse(owned.call(null,prelude="source.putLoginHeader('unbound-null-action')",inputBindingFailed=true)["result"].asJsonObject["executed"].asBoolean)
            assertFalse(owned.call("throw new Error('unbound-missing-prefix')",prelude="",inputBindingFailed=true)["result"].asJsonObject["executed"].asBoolean)
            val unbound=owned.call("source.putLoginHeader('unbound-action-must-not-run')",prelude="source.putLoginHeader('unbound-prefix-must-not-run')",success=false,inputBindingFailed=true)
            assertEquals("UI_BINDING_ERROR",unbound["error"].asJsonObject["code"].asString)
            assertTrue(unbound["error"].asJsonObject["completedEffects"]?.asJsonArray?.isEmpty != false)
            assertNull(owned.header());assertEquals(0,owned.secretWrites);assertEquals(0,owned.secretReads)
            assertTrue(owned.call("",prelude="source.putLoginHeader('empty-action-prelude')")["result"].asJsonObject["executed"].asBoolean)
            assertEquals("empty-action-prelude",owned.header())
            assertTrue(owned.call("if(!result.isEmpty())throw new Error('expected actual empty Map');source.putLoginHeader('explicit-only')")["result"].asJsonObject["executed"].asBoolean)
            assertEquals("explicit-only",owned.header())
            assertEquals("unchanged-non-json-raw",owned.secret);assertEquals(0,owned.secretWrites)
            assertEquals(0,owned.secretReads)
        }
    }
    @Test(timeout=20_000) fun supportedCallbacksRetainOrderAndSensitiveErrorsRetainAcceptedEffects() {
        Owned().use { owned ->
            val messages=CopyOnWriteArrayList<String>();val logger=Logger.getLogger("io.yuedu.legado.originalrule");val old=logger.level
            val handler=object:Handler(){override fun publish(record:LogRecord){messages+=java.util.logging.SimpleFormatter().format(record)};override fun flush(){};override fun close(){}}
            logger.level=Level.ALL;logger.addHandler(handler)
            try {
                val failed=owned.call("java.log(result.get('password'));throw new Error(String(result.get('password')));",jsonObject("password" to "SYNTHETIC-ACTION-CANARY"),success=false)
                assertEquals("SCRIPT_ERROR",failed["error"].asJsonObject["code"].asString)
                assertFalse(failed.toString().contains("SYNTHETIC-ACTION-CANARY"));assertTrue(messages.none{it.contains("SYNTHETIC-ACTION-CANARY")})
                val supported=owned.call("java.upLoginData(result);java.upLoginData(null);java.reLoginView();java.refreshExplore();")
                assertEquals(listOf("updateData","updateData","render","render"),supported["loginUIEvents"].asJsonArray.map{it.asJsonObject["kind"].asString})
                val delta=owned.call("source.putLoginHeader('before-callback');java.reLoginView(true);source.putLoginHeader('after-callback');")
                assertTrue(delta["loginUIEvents"].asJsonArray[0].asJsonObject["deltaUp"].asBoolean)
                assertTrue(delta["completedEffects"].asJsonArray.any{it.asString=="sourceStateCommitted"})
                assertEquals("after-callback",owned.header())
                assertEquals(0,owned.secretWrites)
            } finally {logger.removeHandler(handler);logger.level=old}
        }
    }
    @Test(timeout=20_000) fun realHttpCookieOwnerAndCancelledActionDoNotPermitLateWrites() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            owned.call("java.ajax('${peer.origin}/wire');if(String(cookie.getCookie(baseUrl,'action-session'))!=='synthetic-cookie')throw new Error('wrong cookie owner');")
            val worker=Executors.newSingleThreadExecutor();val task="action-cancel-${UUID.randomUUID()}"
            try {
                val pending=worker.submit<JsonObject>{owned.call("source.putLoginHeader('accepted-action-header');java.ajax('${peer.origin}/held');source.putLoginHeader('late-action-header');",task=task,success=false)}
                assertTrue(peer.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val cancelled=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",cancelled["error"].asJsonObject["code"].asString)
                assertTrue(cancelled["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceStateCommitted"})
                assertEquals("accepted-action-header",owned.header());assertEquals(0,owned.secretWrites)
            } finally {worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        } }
    }
    private class Owned(private val origin:String="https://synthetic-action.invalid"):Closeable {
        var secret:String?=null;var secretWrites=0;var secretReads=0
        private val directory=Files.createTempDirectory("original-action-");private val adapter=FileRulePersistenceAdapter(directory);private val state=RulePersistenceHost(adapter)
        init {LegadoRuntime.setHostCallback {_,operation,raw ->
            if(operation=="task.cancel")"{}" else {
                val input=parseObject(raw);check(input["owner"].asString=="owned-action")
                if(operation=="source.login-info") {
                    check(input["sourceURL"].asString==origin)
                    when(input["action"].asString){"get"->{secretReads++;jsonObject("value" to secret).toString()};"put"->{secret=input["value"].asString;secretWrites++;jsonObject("committed" to true).toString()};else->error("Unexpected raw credential removal")}
                } else {
                    val result=state.dispatch(operation,input)
                    if(operation=="state.commit"&&result["committed"].asBoolean)result.add("hostEffects",GSON.toJsonTree(listOf("sourceStateMayCommit","sourceStateCommitted")))
                    result.toString()
                }
            }
        }}
        fun call(action:String?,values:JsonObject=jsonObject(),prelude:String="var actionPrelude='present';",longClick:Boolean=false,
                 task:String="action-${UUID.randomUUID()}",success:Boolean=true,inputBindingFailed:Boolean=false):JsonObject {
            val source=jsonObject("bookSourceUrl" to origin,"loginUi" to "[]","loginUrl" to prelude,"enabledCookieJar" to true,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "owned-action").toString()));assertTrue(created.toString(),created["ok"].asBoolean);val id=created["sessionId"].asString
            try {val result=parseObject(LegadoRuntime.execute(id,task,"loginAction",jsonObject("action" to action,"credentials" to values,"isLongClick" to longClick,"inputBindingFailed" to inputBindingFailed,"timeoutMs" to 20_000).toString()));assertEquals(result.toString(),success,result["ok"].asBoolean);return result}
            finally {LegadoRuntime.closeSession(id)}
        }
        fun header():String? {
            val key=GSON.toJson(listOf(origin,"cache-text","loginHeader_$origin"));return adapter.read("owned-action",setOf(key)).values[key]?.let{String(Base64.getDecoder().decode(parseObject(String(it,Charsets.UTF_8))["data"].asString),Charsets.UTF_8)}
        }
        override fun close(){LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
    private class Peer:Closeable {
        val entered=CountDownLatch(1);private val release=CountDownLatch(1);private val workers=Executors.newFixedThreadPool(2)
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply{
            executor=workers;createContext("/"){e->try{if(e.requestURI.path=="/held"){entered.countDown();check(release.await(10,TimeUnit.SECONDS))};val body="wire".toByteArray();e.responseHeaders.add("Set-Cookie","action-session=synthetic-cookie; Path=/");e.sendResponseHeaders(200,body.size.toLong());e.responseBody.write(body)}catch(_:java.io.IOException){}finally{e.close()}};start()
        }
        val origin="http://127.0.0.1:${server.address.port}"
        override fun close(){release.countDown();server.stop(0);workers.shutdownNow();check(workers.awaitTermination(5,TimeUnit.SECONDS))}
    }
}
