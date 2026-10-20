package io.yuedu.legado

import com.google.gson.JsonObject
import com.script.ScriptBindings
import com.script.buildScriptBindings
import com.script.rhino.RhinoScriptEngine
import io.legado.app.data.entities.BookSource
import io.yuedu.legado.originalrule.GSON
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Retained original function bodies are the oracle, with the same Rhino/GSON
 * seam and synthetic credential peer. This does not execute Android UI or AES. */
class OriginalSourceLoginMapTest {
    @Test(timeout=30_000) fun staticDefaultsAndStoredValuesMatchLockedOriginalWithoutGenericSecretCache() {
        assertEquals(java.util.Map::class.java,BookSource::class.java.getMethod("getLoginInfoMap").returnType)
        val forms=listOf(
            Form(), Form(loginUi="  "), Form(loginUi="[]"),
            Form(loginUi="[{name:'user',default:'synthetic-user'},{name:'password',type:'password',default:123},{name:'empty'},{name:'dup',default:'old'},{name:'dup',default:'new'},{name:'button',type:'button',default:'never'},{name:'',type:'label',default:true}]"),
            Form(loginUi="[{name:'button',type:'button'}]"),
            Form(loginUi="[{name:'bad',style:[]}]"),
            Form(loginUi="[{name:'bad',chars:7}]"),
            Form(loginUi="not a form"), Form(loginUi="{version:2}"),
            Form(loginUi="{version:'2'}",stored="{\"kept\":\"synthetic-stored\"}"),
            Form(loginUi="@js:throw new Error('must not derive')",stored="not JSON"),
            Form(loginUi="@js:throw new Error('must not derive')",stored=""),
            Form(loginUi="[{name:'must-not-derive',default:'bad'}]",stored="[]")
        )
        Owned().use { owned -> for(form in forms) {
            owned.reset(form.stored)
            val reference=Reference(owned.source,form)
            val expected=reference.getLoginInfoMap()
            owned.call(form,comparison(expected))
            assertEquals(form.toString(),reference.stored,owned.stored())
            assertEquals(form.toString(),reference.writes,owned.putCount())
            assertTrue(owned.operations.all { it.startsWith("source.login-info:") })
        } }
    }

    @Test(timeout=30_000) fun dynamicDefaultsMatchLockedOriginalBindingsPrefixReentryAndDetachedJavaMap() {
        Owned().use { owned ->
            val forms=listOf(
                Form(loginUi="@js:[{name:'array',default:'synthetic-array'}]"),
                Form(loginUi="<js>JSON.stringify([{name:'string',default:'synthetic-string'}])</js>"),
                Form(loginUrl="@js:var prefixValue='synthetic-prefix';function login(){throw new Error('login must not run');}",
                    loginUi="""@js:
                    if(book!==null||chapter!==null)throw new Error('wrong nulls');
                    if(String(java.getKey())!==String(source.getKey())||String(sourceApi.getKey())!==String(baseUrl))throw new Error('wrong source Java');
                    result.put('probe','synthetic-result');
                    if(String(result.get('probe'))!=='synthetic-result')throw new Error('not Java Map');
                    if(Number(source.getLoginInfoMap().size())!==0)throw new Error('reentry not empty');
                    [{name:'prefix',default:prefixValue},{name:'result',default:String(result.get('probe'))}];
                    """.trimIndent()),
                Form(loginUrl="<js>var prefixValue='plain-prefixed';</js>",loginUi="@js:JSON.stringify([{name:'prefix',default:prefixValue}])"),
                Form(loginUrl=" var prefixValue='plain-script-prefix'; ",loginUi="@js:[{name:'prefix',default:prefixValue}]")
            )
            for(form in forms) {
                owned.reset(null)
                val reference=Reference(owned.source,form)
                val expected=reference.getLoginInfoMap()
                owned.call(form,comparison(expected))
                assertEquals(reference.stored,owned.stored());assertEquals(reference.writes,owned.putCount())
                owned.call(form,"var map=source.getLoginInfoMap();map.put('transient','must-not-store');if(source.getLoginInfoMap().containsKey('transient'))throw new Error('map mutation persisted');")
                assertEquals(reference.stored,owned.stored())
            }
            owned.reset(null)
            val bad=owned.call(Form(loginUi="@js:throw new Error('authored synthetic failure')"),"source.getLoginInfoMap();",success=false)
            assertEquals("SCRIPT_ERROR",bad["error"].asJsonObject["code"].asString)
            assertNull(owned.stored())
            val after=Form(loginUi="[{name:'after',default:'guard-cleaned'}]")
            owned.call(after,comparison(Reference(owned.source,after).getLoginInfoMap()))
        }
    }

    @Test(timeout=20_000) fun rejectedDefaultPutReturnsOriginalMapWhileStrictReadFailureDoesNotDerive() {
        Owned().use { owned ->
            val form=Form(loginUi="[{name:'password',type:'password',default:'synthetic-default'}]")
            val reference=Reference(owned.source,form,rejectWrite=true)
            owned.rejectWrite.set(true)
            owned.call(form,comparison(reference.getLoginInfoMap()))
            assertNull(owned.stored());assertNull(reference.stored);assertEquals(1,owned.putCount())
            owned.rejectWrite.set(false);owned.failRead.set(true)
            val failure=owned.call(form,"source.getLoginInfoMap();",success=false)
            assertEquals("STATE_IO",failure["error"].asJsonObject["code"].asString)
            assertEquals(1,owned.putCount());assertNull(owned.stored())
            val other=owned.source+"/other"
            owned.call(form,comparison(Reference(other,form).getLoginInfoMap()),source=other)
            assertNull(owned.stored());assertNotNull(owned.stored(other))
        }
    }

    @Test(timeout=20_000) fun cancellationAfterAcceptedPrefixKeepsEffectAndCleansTheSameThreadGuard() {
        Owned().use { owned ->
            val worker=Executors.newSingleThreadExecutor()
            val task="login-map-cancel-${UUID.randomUUID()}"
            val form=Form(loginUi="@js:source.putLoginInfo('synthetic-prefix-kept');[{name:'late',default:'must-not-store'}];")
            owned.holdAccepted.set(true)
            try {
                val pending=worker.submit<JsonObject>{owned.call(form,"source.getLoginInfoMap();",task=task,success=false)}
                assertTrue(owned.accepted.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val failure=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",failure["error"].asJsonObject["code"].asString)
                assertTrue(failure["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceLoginInfoCommitted"})
                assertEquals("synthetic-prefix-kept",owned.stored());assertEquals(1,owned.putCount())
                owned.reset(null)
                val next=Form(loginUi="[{name:'after',default:'same-thread-cleaned'}]")
                worker.submit<JsonObject>{owned.call(next,comparison(Reference(owned.source,next).getLoginInfoMap()))}.get(5,TimeUnit.SECONDS)
                assertNotNull(owned.stored())
            } finally {owned.release.countDown();worker.shutdownNow();assertTrue(worker.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }

    private fun comparison(expected:Map<String,String>):String {
        val expectedJSON=GSON.toJson(GSON.toJson(expected))
        return """
            var actual=source.getLoginInfoMap(), expected=JSON.parse($expectedJSON);
            if(Number(actual.size())!==Object.keys(expected).length)throw new Error('map size mismatch');
            Object.keys(expected).forEach(function(k){if(!actual.containsKey(k)||String(actual.get(k))!==String(expected[k]))throw new Error('map value mismatch: '+k);});
        """.trimIndent()
    }
    private data class Form(val loginUi:String?=null,val loginUrl:String?=null,val stored:String?=null)

    private class Reference(private val source:String,form:Form,private val rejectWrite:Boolean=false):LockedLoginMapReference() {
        override var loginUrl=form.loginUrl
        override var loginUi=form.loginUi
        var stored=form.stored
        var writes=0
        override fun getKey()=source
        override fun getLoginInfo()=stored
        override fun putLoginInfo(info:String):Boolean {writes++;if(rejectWrite)return false;stored=info;return true}
        override fun evalJS(js:String,bindingsConfig:ScriptBindings.()->Unit):Any? {
            val bindings=buildScriptBindings {
                it["java"]=this;it["source"]=this;it["sourceApi"]=this;it["baseUrl"]=source
                it.apply(bindingsConfig)
            }
            return RhinoScriptEngine.eval(js,bindings)
        }
    }
    private class Owned:Closeable {
        val source="https://login-map-${UUID.randomUUID()}.invalid"
        val operations=CopyOnWriteArrayList<String>()
        val rejectWrite=AtomicBoolean(false)
        val failRead=AtomicBoolean(false)
        val holdAccepted=AtomicBoolean(false)
        val accepted=CountDownLatch(1)
        val release=CountDownLatch(1)
        private val directory=Files.createTempDirectory("synthetic-login-map-")
        init {
            LegadoRuntime.setHostCallback {_,op,raw ->
                if(op=="task.cancel"){release.countDown();"{}"}
                else {
                    check(op=="source.login-info"){"Unexpected generic cache/network host: $op"}
                    val input=parseObject(raw);val origin=input["sourceURL"].asString
                    check(origin in listOf(source,source+"/other")&&input["owner"].asString=="owned:$origin")
                    check(input["deadlineEpochMs"].asLong>0&&input["remainingTimeoutMs"].asLong>0)
                    val action=input["action"].asString;operations+="$op:$action"
                    when(action) {
                        "get" -> if(failRead.getAndSet(false))jsonObject("ok" to false,"error" to jsonObject("code" to "STATE_IO","message" to "controlled unreadable owner")).toString()
                            else jsonObject("value" to stored(origin)).toString()
                        "put" -> if(rejectWrite.get())jsonObject("committed" to false).toString() else {
                            Files.writeString(file(origin),input["value"].asString)
                            if(holdAccepted.getAndSet(false)){accepted.countDown();check(release.await(5,TimeUnit.SECONDS))}
                            jsonObject("committed" to true,"hostEffects" to listOf("sourceLoginInfoMayCommit","sourceLoginInfoCommitted")).toString()
                        }
                        else -> error("Unexpected credential operation")
                    }
                }
            }
        }
        private fun file(origin:String)=directory.resolve(if(origin==source)"a-synthetic.txt" else "b-synthetic.txt")
        fun stored(origin:String=source)=file(origin).takeIf{Files.exists(it)}?.let{Files.readString(it)}
        fun putCount()=operations.count{it=="source.login-info:put"}
        fun reset(value:String?) {operations.clear();if(value==null)Files.deleteIfExists(file(source)) else Files.writeString(file(source),value)}
        fun call(form:Form,script:String,source:String=this.source,task:String="login-map-${UUID.randomUUID()}",success:Boolean=true):JsonObject {
            val snapshot=jsonObject("bookSourceUrl" to source,"enabledCookieJar" to false,"ruleContent" to jsonObject("callBackJs" to script))
            form.loginUi?.let{snapshot.addProperty("loginUi",it)};form.loginUrl?.let{snapshot.addProperty("loginUrl",it)}
            val created=parseObject(LegadoRuntime.createSession(snapshot.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "owned:$source").toString()))
            assertTrue(created.toString(),created["ok"].asBoolean);val id=created["sessionId"].asString
            try {
                val reply=parseObject(LegadoRuntime.execute(id,task,"sourceCallback",jsonObject("event" to "startShelfRefresh","timeoutMs" to 20_000).toString()))
                assertEquals(reply.toString(),success,reply["ok"].asBoolean);return reply
            }finally{LegadoRuntime.closeSession(id)}
        }
        override fun close(){release.countDown();LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
}
