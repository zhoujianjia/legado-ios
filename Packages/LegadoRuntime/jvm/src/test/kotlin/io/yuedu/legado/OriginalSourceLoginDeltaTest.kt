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

class OriginalSourceLoginDeltaTest {
    private fun snapshot(result:JsonObject):JsonObject = jsonObject("layout" to result["layout"].deepCopy(),"controls" to result["controlStates"].deepCopy())
    @Test(timeout=20_000) fun duplicateNamesMovePhysicalControlsAndRetainOldDefinitionsLabelsAndWorkingMapIdentity() {
        Owned().use { owned ->
            val first=owned.call("[{name:'same',default:'first',action:'oldWatcher()',viewName:\"'first label'\"},{name:'same',type:'password',action:'oldSecond()',viewName:\"'second label'\"},{name:'flag',type:'toggle',chars:['off','on'],action:'oldCycle()',viewName:\"'old flag'\"},{name:'button',type:'button',action:'oldButton()',viewName:\"'old button'\"}]",values=jsonObject("hidden" to "synthetic-hidden","same" to "working","flag" to "off"))["result"].asJsonObject
            val reuse=snapshot(first);val old=reuse["controls"].asJsonArray
            old[0].asJsonObject.addProperty("value","first edit");old[1].asJsonObject.addProperty("value","second edit")
            old[2].asJsonObject.addProperty("cycleValue","on");old[2].asJsonObject.addProperty("listenerMapIsCurrent",false)
            val moved=owned.call("[{name:'button',type:'password',default:'must-not-reset',action:'newButton()',viewName:\"throw new Error('must-not-evaluate-reused')\"},{name:'same',type:'button',viewName:\"throw new Error('must-not-evaluate-reused')\"},{name:'same',viewName:\"throw new Error('must-not-evaluate-reused')\"},{name:'flag',type:'toggle',chars:['changed'],default:'changed',action:'newCycle()',viewName:\"throw new Error('must-not-evaluate-reused')\"}]",values=first["values"].asJsonObject,reuse=reuse)["result"].asJsonObject
            val children=moved["layout"].asJsonObject["children"].asJsonArray
            assertEquals(listOf("original-row-3","original-row-0","original-row-1","original-row-2"),children.map{it.asJsonObject["id"].asString})
            assertEquals(listOf(0,1,2,3),children.map{it.asJsonObject["rowIndex"].asInt})
            assertEquals(listOf("button","text","password","toggle"),children.map{it.asJsonObject["row"].asJsonObject["type"].asString})
            assertEquals("oldButton()",children[0].asJsonObject["row"].asJsonObject["action"].asString)
            assertEquals(listOf("old button","first label","second label","old flag"),moved["labels"].asJsonArray.map{it.asString})
            val states=moved["controlStates"].asJsonArray
            assertEquals("first edit",states[1].asJsonObject["value"].asString);assertEquals("second edit",states[2].asJsonObject["value"].asString)
            assertEquals("on",states[3].asJsonObject["cycleValue"].asString);assertFalse(states[3].asJsonObject["listenerMapIsCurrent"].asBoolean)
            assertEquals(first["values"],moved["values"]);assertFalse(moved["workingMapChanged"].asBoolean);assertNull(owned.header());assertEquals(0,owned.secretWrites)
        }
    }
    @Test(timeout=20_000) fun unknownNameSlotsUseLockedPhysicalIndexAndTruncateRemovedChildrenWithoutInventingControls() {
        Owned().use { owned ->
            val first=owned.call("[{name:'unknown',type:'future'},{name:'a',viewName:\"'old a'\"},{name:'b',type:'button',viewName:\"'old b'\"}]",values=jsonObject("a" to "old-a","hidden" to "kept"))["result"].asJsonObject
            val next=owned.call("[{name:'a',viewName:\"throw new Error('must-not-evaluate-old-b')\"},{name:'b',type:'button',viewName:\"source.putLoginHeader('bad-binding-must-not-eval');'new'\"}]",values=first["values"].asJsonObject,reuse=snapshot(first))["result"].asJsonObject
            val layout=next["layout"].asJsonObject;assertEquals(listOf("a","b"),layout["names"].asJsonArray.map{it.asString})
            val children=layout["children"].asJsonArray
            assertEquals(2,children.size());assertEquals("original-row-2",children[0].asJsonObject["id"].asString)
            assertEquals("b",children[0].asJsonObject["row"].asJsonObject["name"].asString)
            assertTrue(children[1].asJsonObject["id"].asString.startsWith("control-"));assertEquals(1,children[1].asJsonObject["rowIndex"].asInt)
            assertEquals(listOf("old b","null"),next["labels"].asJsonArray.map{it.asString})
            assertTrue(children.none{it.asJsonObject["id"].asString=="original-row-1"});assertNull(owned.header());assertEquals(first["values"],next["values"])
        }
    }
    @Test(timeout=20_000) fun onlyNewControlsInitializeDefaultsAndEvaluateLabelsInOriginalRhinoWithRetainedVisibleEdits() {
        Owned().use { owned ->
            val first=owned.call("[{name:'x',viewName:\"'old x'\"}]",values=jsonObject("x" to "working-map","hidden" to "synthetic-hidden"))["result"].asJsonObject
            val reuse=snapshot(first);reuse["controls"].asJsonArray[0].asJsonObject.addProperty("value","visible-edit")
            val ui="""[{name:'x',viewName:"throw new Error('must-not-run')"},{name:'flag',type:'toggle',chars:['','on'],default:'',viewName:"(function(){if(java!==source||book!==null||chapter!==null)throw new Error('wrong bindings');return prefixValue+':'+String(result.get('x'))+':'+String(result.get('fresh'));})()"},{name:'fresh',default:'fresh-default',viewName:"'fresh'"}]"""
            val next=owned.call(ui,prelude="var prefixValue='prefix';function login(){throw new Error('must-not-submit');}",values=first["values"].asJsonObject,reuse=reuse)["result"].asJsonObject
            assertEquals(listOf("old x","prefix:visible-edit:fresh-default","fresh"),next["labels"].asJsonArray.map{it.asString})
            assertTrue(next["workingMapChanged"].asBoolean);assertEquals("",next["values"].asJsonObject["flag"].asString)
            assertEquals("working-map",next["values"].asJsonObject["x"].asString);assertFalse(next["values"].asJsonObject.has("fresh"))
            assertEquals("prefix:visible-edit:fresh-default",next["rows"].asJsonArray[1].asJsonObject["viewName"].asString)
            assertEquals("visible-edit",next["controlStates"].asJsonArray[0].asJsonObject["value"].asString)
            assertEquals("fresh-default",next["controlStates"].asJsonArray[2].asJsonObject["value"].asString);assertEquals(0,owned.secretWrites)
        }
    }
    @Test(timeout=20_000) fun invalidSnapshotsStayErrorsAndCancelledNewLabelKeepsPriorAcceptedEffectsWithoutPublishingNewLayout() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val first=owned.call("[{name:'x',viewName:\"'old'\"}]",values=jsonObject("x" to "working"))["result"].asJsonObject
            val invalid=snapshot(first);invalid["layout"].asJsonObject["children"].asJsonArray[0].asJsonObject.addProperty("id","not-a-known-control")
            val bad=owned.call("[{name:'x'}]",values=first["values"].asJsonObject,reuse=invalid,success=false)
            assertEquals("INVALID_ARGUMENT",bad["error"].asJsonObject["code"].asString)
            val overflow=snapshot(first)
            overflow["layout"].asJsonObject["children"].asJsonArray[0].asJsonObject.addProperty("rowIndex",4294967296L)
            assertEquals("INVALID_ARGUMENT",owned.call("[{name:'x'}]",values=first["values"].asJsonObject,reuse=overflow,success=false)["error"].asJsonObject["code"].asString)
            val stable=snapshot(first);val before=stable.deepCopy();val worker=Executors.newSingleThreadExecutor();val task="delta-cancel-${UUID.randomUUID()}"
            try {
                val pending=worker.submit<JsonObject>{owned.call("[{name:'x'},{name:'new',type:'button',viewName:\"java.ajax('${peer.origin}/held')\"}]",prelude="source.putLoginHeader('accepted-delta');",values=first["values"].asJsonObject,reuse=stable,task=task,success=false)}
                assertTrue(peer.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val failed=pending.get(5,TimeUnit.SECONDS)["error"].asJsonObject
                assertEquals("CANCELLED",failed["code"].asString);assertTrue(failed["completedEffects"].asJsonArray.any{it.asString=="sourceStateCommitted"})
                assertEquals("accepted-delta",owned.header());assertEquals(before,stable);assertEquals(0,owned.secretWrites)
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
        fun call(ui:String,prelude:String="",values:JsonObject?=null,reuse:JsonObject?=null,task:String="ui-${UUID.randomUUID()}",success:Boolean=true):JsonObject {
            val source=jsonObject("bookSourceUrl" to origin,"loginUi" to ui,"loginUrl" to prelude,"enabledCookieJar" to true,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "owned-ui").toString()));assertTrue(created.toString(),created["ok"].asBoolean);val id=created["sessionId"].asString
            try {val result=parseObject(LegadoRuntime.execute(id,task,"loginUi",jsonObject("values" to values,"reuseState" to reuse,"timeoutMs" to 20_000).toString()));assertEquals(result.toString(),success,result["ok"].asBoolean);return result}
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
