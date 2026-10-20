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

class OriginalSourceLoginUITest {
    @Test(timeout=20_000) fun staticOriginalRowsReadOnlyStoredMapAndSkipUnrenderedTypesWithoutDerivingDefaults() {
        Owned().use { owned ->
            owned.secret="{\"username\":\"\",\"hidden\":\"synthetic-hidden\"}"
            val raw=owned.secret
            val reply=owned.call("[{name:'username',default:'must-not-replace-empty'},{name:'password',type:'password',default:123},{name:'choice',type:'select',chars:['a','b']},{name:'caption',type:'label',viewName:\"throw new Error('must-not-eval-label')\"},{name:'other',type:'unknown',viewName:\"throw new Error('must-not-eval-unknown')\"},{name:'nilSelect',type:'select'},{name:'nilToggle',type:'toggle'},{name:'emptySelect',type:'select',chars:[],default:'kept'}]")
            val result=reply["result"].asJsonObject
            assertEquals(8,result["rows"].asJsonArray.size());assertFalse(result["dynamic"].asBoolean)
            assertTrue(result["workingMapChanged"].asBoolean)
            assertEquals("123",result["rows"].asJsonArray[1].asJsonObject["default"].asString)
            assertEquals("",result["values"].asJsonObject["username"].asString)
            assertEquals("synthetic-hidden",result["values"].asJsonObject["hidden"].asString)
            assertEquals("a",result["values"].asJsonObject["choice"].asString)
            assertFalse(result["values"].asJsonObject.has("password"))
            assertEquals("chars",result["values"].asJsonObject["nilSelect"].asString)
            assertEquals("chars is null",result["values"].asJsonObject["nilToggle"].asString)
            assertEquals("kept",result["values"].asJsonObject["emptySelect"].asString)
            assertEquals(listOf("username","password","choice","caption","other","nilSelect","nilToggle","emptySelect"),result["labels"].asJsonArray.map{it.asString})
            assertEquals(raw,owned.secret);assertEquals(0,owned.secretWrites)
        }
    }
    @Test(timeout=20_000) fun dynamicCompletionAndPerLabelPreludeUseRealJavaMapAndOnlyWorkingEdits() {
        Owned().use { owned ->
            owned.secret="{\"hidden\":\"synthetic-hidden\"}"
            val prelude="var prefixValue='prefix';function login(){throw new Error('must-not-login');}"
            val ui="""@js:if(java!==source||book!==null||chapter!==null||String(result.get('hidden'))!=='synthetic-hidden')throw new Error('wrong original UI binding');result.put('temporary','not-persistent');var uiOnly='not-in-label-scope';[{name:'text',default:'display-default',viewName:"prefixValue+':'+String(result.get('text'))+':'+typeof uiOnly"},{name:'literal',type:'button',viewName:"'literal'"}];"""
            val rendered=owned.call(ui,prelude)["result"].asJsonObject
            assertTrue(rendered["dynamic"].asBoolean)
            assertFalse(rendered["workingMapChanged"].asBoolean)
            assertEquals(listOf("prefix:display-default:undefined","literal"),rendered["labels"].asJsonArray.map{it.asString})
            assertEquals(setOf("hidden"),rendered["values"].asJsonObject.keySet())
            assertEquals(0,owned.secretWrites)
            val edited=owned.call("[{name:'text',default:'default',viewName:\"String(result.get('text'))+':'+String(result.get('hidden'))\"}]",values=jsonObject("text" to "","hidden" to "synthetic-edit"))["result"].asJsonObject
            assertEquals(":synthetic-edit",edited["labels"].asJsonArray[0].asString)
            assertEquals("synthetic-hidden",parseObject(owned.secret!!)["hidden"].asString)
        }
    }
    @Test(timeout=20_000) fun renderFailuresAreTypedAndSensitiveWhileLabelFailureUsesOriginalNullBranch() {
        Owned().use { owned ->
            owned.secret="{\"password\":\"SYNTHETIC-UI-CANARY\"}"
            val messages=CopyOnWriteArrayList<String>();val logger=Logger.getLogger("io.yuedu.legado.originalrule");val old=logger.level
            val handler=object:Handler(){override fun publish(record:LogRecord){messages+=java.util.logging.SimpleFormatter().format(record)};override fun flush(){};override fun close(){}}
            logger.level=Level.ALL;logger.addHandler(handler)
            try {
                val labels=owned.call("[{name:'x',viewName:\"throw new Error(String(result.get('password')))\"},{name:'empty',viewName:'undefined'}]")["result"].asJsonObject["labels"].asJsonArray
                assertEquals(listOf("null","null"),labels.map{it.asString})
                val failed=owned.call("@js:java.log(result.get('password'));throw new Error(String(result.get('password')));",success=false)
                assertEquals("SCRIPT_ERROR",failed["error"].asJsonObject["code"].asString)
                assertFalse(failed.toString().contains("SYNTHETIC-UI-CANARY"));assertTrue(messages.none{it.contains("SYNTHETIC-UI-CANARY")})
                val invalid=owned.call("@js:'not an array';",success=false)
                assertEquals("INVALID_RESULT",invalid["error"].asJsonObject["code"].asString)
                // The same original GSON/version.asInt owner classifies V2.
                // This is an explicit protocol admission, never a generic fallback.
                for(marker in listOf("{version:2}", "{version:2.9}", "{version:'2'}")) {
                    val v2=owned.call(marker,prelude="throw new Error('admission must not evaluate');",success=false)
                    assertEquals("LOGIN_UI_V2",v2["error"].asJsonObject["code"].asString)
                }
                assertEquals(0,owned.secretWrites)
            } finally {logger.removeHandler(handler);logger.level=old}
        }
    }
    @Test(timeout=20_000) fun actualRenderHttpUsesExistingCookieHeaderOwnerAndCancellationPreventsLateWrites() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val first=owned.call("@js:var response=java.ajax('${peer.origin}/wire');[{name:'wire',viewName:\"String(cookie.getCookie(baseUrl,'ui-session'))\"}];")["result"].asJsonObject
            assertEquals("synthetic-cookie",first["labels"].asJsonArray[0].asString)
            val worker=Executors.newSingleThreadExecutor();val task="ui-cancel-${UUID.randomUUID()}"
            try {
                val pending=worker.submit<JsonObject>{owned.call("@js:source.putLoginHeader('accepted-ui-header');java.ajax('${peer.origin}/held');source.putLoginHeader('late-ui-header');[{name:'late'}];",task=task,success=false)}
                assertTrue(peer.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val failed=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",failed["error"].asJsonObject["code"].asString)
                assertTrue(failed["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceStateCommitted"})
                assertEquals("accepted-ui-header",owned.header());assertEquals(0,owned.secretWrites)
            } finally {worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        } }
    }
    private class Owned(private val origin:String="https://synthetic-ui.invalid"):Closeable {
        var secret:String?=null;var secretWrites=0
        private val directory=Files.createTempDirectory("original-ui-");private val adapter=FileRulePersistenceAdapter(directory);private val state=RulePersistenceHost(adapter)
        init {LegadoRuntime.setHostCallback {_,operation,raw ->
            if(operation=="task.cancel")"{}" else {
                val input=parseObject(raw);check(input["owner"].asString=="owned-ui")
                if(operation=="source.login-info") {
                    check(input["sourceURL"].asString==origin)
                    when(input["action"].asString){"get"->jsonObject("value" to secret).toString();"put"->{secret=input["value"].asString;secretWrites++;jsonObject("committed" to true).toString()};else->error("Unexpected raw credential mutation")}
                } else {
                    val result=state.dispatch(operation,input)
                    if(operation=="state.commit"&&result["committed"].asBoolean)result.add("hostEffects",GSON.toJsonTree(listOf("sourceStateMayCommit","sourceStateCommitted")))
                    result.toString()
                }
            }
        }}
        fun call(ui:String,prelude:String="",values:JsonObject?=null,task:String="ui-${UUID.randomUUID()}",success:Boolean=true):JsonObject {
            val source=jsonObject("bookSourceUrl" to origin,"loginUi" to ui,"loginUrl" to prelude,"enabledCookieJar" to true,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "owned-ui").toString()));assertTrue(created.toString(),created["ok"].asBoolean);val id=created["sessionId"].asString
            try {val result=parseObject(LegadoRuntime.execute(id,task,"loginUi",jsonObject("values" to values,"timeoutMs" to 20_000).toString()));assertEquals(result.toString(),success,result["ok"].asBoolean);return result}
            finally {LegadoRuntime.closeSession(id)}
        }
        fun header():String? {
            val key=GSON.toJson(listOf(origin,"cache-text","loginHeader_$origin"));return adapter.read("owned-ui",setOf(key)).values[key]?.let{String(Base64.getDecoder().decode(parseObject(String(it,Charsets.UTF_8))["data"].asString),Charsets.UTF_8)}
        }
        override fun close(){LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
    private class Peer:Closeable {
        val entered=CountDownLatch(1);private val release=CountDownLatch(1);private val workers=Executors.newFixedThreadPool(2)
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply{
            executor=workers;createContext("/"){e->try{if(e.requestURI.path=="/held"){entered.countDown();check(release.await(10,TimeUnit.SECONDS))};val body="wire".toByteArray();e.responseHeaders.add("Set-Cookie","ui-session=synthetic-cookie; Path=/");e.sendResponseHeaders(200,body.size.toLong());e.responseBody.write(body)}catch(_:java.io.IOException){}finally{e.close()}};start()
        }
        val origin="http://127.0.0.1:${server.address.port}"
        override fun close(){release.countDown();server.stop(0);workers.shutdownNow();check(workers.awaitTermination(5,TimeUnit.SECONDS))}
    }
}
