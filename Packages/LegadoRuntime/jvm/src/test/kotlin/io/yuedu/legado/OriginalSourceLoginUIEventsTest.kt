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

class OriginalSourceLoginUIEventsTest {
    @Test(timeout=20_000) fun eventsAreOrderedEagerTaskScopedSnapshotsWithDistinctNullAndEmptyMap() {
        Owned().use { owned ->
            val task="events-${UUID.randomUUID()}"
            val reply=owned.call("result.put('nullable',null);java.upLoginData(result);result.put('a','later');java.upLoginData(result);result.clear();java.upLoginData(result);java.upLoginData(null);java.reLoginView();java.refreshExplore();",jsonObject("a" to "first","b" to "second"),task=task)
            val events=reply["loginUIEvents"].asJsonArray
            assertEquals(6,events.size());assertEquals(events,reply["result"].asJsonObject["loginUIEvents"])
            events.forEachIndexed{i,e->assertEquals(task,e.asJsonObject["taskId"].asString);assertEquals(i+1,e.asJsonObject["sequence"].asInt)}
            val first=events[0].asJsonObject["entries"].asJsonArray
            assertEquals(listOf("a","b","nullable"),first.map{it.asJsonObject["key"].asString})
            assertEquals("first",first[0].asJsonObject["value"].asString);assertTrue(first[2].asJsonObject["value"].isJsonNull)
            assertEquals("later",events[1].asJsonObject["entries"].asJsonArray[0].asJsonObject["value"].asString)
            assertEquals(0,events[2].asJsonObject["entries"].asJsonArray.size());assertTrue(events[3].asJsonObject["entries"].isJsonNull)
            assertEquals(listOf("updateData","updateData","updateData","updateData","render","render"),events.map{it.asJsonObject["kind"].asString})
            assertEquals(0,owned.secretReads);assertEquals(0,owned.secretWrites)
            assertFalse(owned.call("1;")["result"].asJsonObject.has("loginUIEvents"))
        }
    }
    @Test(timeout=20_000) fun callbacksBeforeThrowRetainEventsAndIndependentCommittedEffectsWithoutDiagnosticSecrets() {
        Owned().use { owned ->
            val messages=CopyOnWriteArrayList<String>();val logger=Logger.getLogger("io.yuedu.legado.originalrule");val old=logger.level
            val handler=object:Handler(){override fun publish(record:LogRecord){messages+=java.util.logging.SimpleFormatter().format(record)};override fun flush(){};override fun close(){}}
            logger.level=Level.ALL;logger.addHandler(handler)
            try {
                val failed=owned.call("source.putLoginHeader('accepted');java.upLoginData(result);java.reLoginView(false);java.log(result.get('password'));throw new Error(String(result.get('password')));",jsonObject("password" to "SYNTHETIC-UI-EVENT-CANARY"),success=false)["error"].asJsonObject
                assertEquals("SCRIPT_ERROR",failed["code"].asString);assertFalse(failed["message"].asString.contains("SYNTHETIC-UI-EVENT-CANARY"))
                assertTrue(messages.none{it.contains("SYNTHETIC-UI-EVENT-CANARY")})
                assertEquals(2,failed["loginUIEvents"].asJsonArray.size())
                assertEquals("SYNTHETIC-UI-EVENT-CANARY",failed["loginUIEvents"].asJsonArray[0].asJsonObject["entries"].asJsonArray[0].asJsonObject["value"].asString)
                assertTrue(failed["completedEffects"].asJsonArray.any{it.asString=="sourceStateCommitted"});assertEquals("accepted",owned.header())
                assertEquals(0,owned.secretWrites)
            } finally {logger.removeHandler(handler);logger.level=old}
        }
    }
    @Test(timeout=20_000) fun actualHttpCancellationAndDeadlinePreserveCallbackOnlyEventsWithoutLateWrites() {
        for(cancel in listOf(true,false)) Peer().use { peer -> Owned(peer.origin).use { owned ->
            val worker=Executors.newSingleThreadExecutor();val task="event-http-${UUID.randomUUID()}"
            try {
                val pending=worker.submit<JsonObject>{owned.call("java.upLoginData(result);java.ajax('${peer.origin}/held');source.putLoginHeader('must-not-write');",jsonObject("a" to "before-http"),task=task,success=false,timeoutMs=if(cancel)20_000 else 700)}
                assertTrue(peer.entered.await(5,TimeUnit.SECONDS));if(cancel)LegadoRuntime.cancel(task)
                val failed=pending.get(5,TimeUnit.SECONDS)["error"].asJsonObject
                assertEquals(if(cancel)"CANCELLED"else"TIMEOUT",failed["code"].asString);assertEquals(1,failed["loginUIEvents"].asJsonArray.size())
                assertFalse(failed.has("completedEffects"));assertNull(owned.header());assertEquals(0,owned.secretWrites)
            } finally {worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        } }
    }
    @Test(timeout=20_000) fun boundsDeltaAndNameBridgeRejectExplicitlyWhileRenderKeepsWorkingAndEvaluationMapsSeparate() {
        Owned().use { owned ->
            val count=owned.call("for(var i=0;i<129;i++)java.upLoginData(null);",success=false)["error"].asJsonObject
            assertEquals("STATE_LIMIT",count["code"].asString);assertEquals(128,count["loginUIEvents"].asJsonArray.size())
            val bytes=owned.call("java.upLoginData(null);result.put('huge',Array(530000).join('x'));java.upLoginData(result);",success=false)["error"].asJsonObject
            assertEquals("STATE_LIMIT",bytes["code"].asString);assertEquals(1,bytes["loginUIEvents"].asJsonArray.size())
            val delta=owned.call("java.upLoginData(null);java.reLoginView(true);",success=false)["error"].asJsonObject
            assertEquals("UNSUPPORTED_CAPABILITY",delta["code"].asString);assertEquals(1,delta["loginUIEvents"].asJsonArray.size())
            val alias=owned.call("result.put('e\u0301','second');java.upLoginData(result);",jsonObject("\u00e9" to "first"),success=false)["error"].asJsonObject
            assertEquals("UNSUPPORTED_CAPABILITY",alias["code"].asString);assertFalse(alias.has("loginUIEvents"))
            val rendered=owned.call(null,values=jsonObject("text" to "working"),evaluation=jsonObject("text" to "edited"),operation="loginUi",ui="""@js:if(String(result.get('text'))!=='edited')throw new Error('wrong evaluation Map');[{name:'text',default:'default'},{name:'button',type:'button',viewName:"'cooked'"},{name:'toggle',type:'toggle',chars:['a'],viewName:"''"}];""")["result"].asJsonObject
            assertEquals("working",rendered["values"].asJsonObject["text"].asString)
            assertEquals("cooked",rendered["rows"].asJsonArray[1].asJsonObject["viewName"].asString)
            assertEquals("''",rendered["rows"].asJsonArray[2].asJsonObject["viewName"].asString)
            assertEquals("toggle",rendered["toggleActionLabels"].asJsonArray[2].asString)
            assertTrue(rendered["toggleActionLabels"].asJsonArray[0].isJsonNull)
            assertTrue(rendered["toggleLabelSuffixes"].asJsonArray[2].asBoolean)
            assertFalse(rendered["toggleLabelSuffixes"].asJsonArray[0].asBoolean)
            assertEquals(0,owned.secretReads);assertEquals(0,owned.secretWrites)
        }
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
                 task:String="action-${UUID.randomUUID()}",success:Boolean=true,timeoutMs:Int=20_000,ui:String="[]",evaluation:JsonObject?=null,operation:String="loginAction"):JsonObject {
            val source=jsonObject("bookSourceUrl" to origin,"loginUi" to ui,"loginUrl" to prelude,"enabledCookieJar" to true,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "owned-action").toString()));assertTrue(created.toString(),created["ok"].asBoolean);val id=created["sessionId"].asString
            try {val result=parseObject(LegadoRuntime.execute(id,task,operation,(if(operation=="loginUi")jsonObject("values" to values,"evaluationValues" to evaluation,"timeoutMs" to timeoutMs)else jsonObject("action" to action,"credentials" to values,"isLongClick" to longClick,"timeoutMs" to timeoutMs)).toString()));assertEquals(result.toString(),success,result["ok"].asBoolean);return result}
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
