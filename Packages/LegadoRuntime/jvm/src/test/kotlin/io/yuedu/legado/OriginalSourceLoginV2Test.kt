package io.yuedu.legado

import com.google.gson.JsonObject
import io.yuedu.legado.originalrule.GSON
import io.yuedu.legado.originalrule.RulePersistenceHost
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.nio.file.Files
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class OriginalSourceLoginV2Test {
    @Test(timeout=20_000) fun realRhinoRenderAndActionKeepV2ArgumentsDistinctAndRenderNeverSaves() {
        Owned().use { owned ->
            owned.secret="""{"username":"stored-user","hidden":"stored-hidden"}"""
            val script="""function loginUi(s){if(java!==source||book!==null||chapter!==null||s.step!==2||s.nested.ok!==true)throw new Error('wrong render bindings');return {rows:[{name:'User',key:'username',hint:'hint',value:'render-user'},{name:'Kind',type:'select',key:'kind',options:['a','b']},{name:'Remember',type:'toggle',key:'remember',value:true,action:'toggle'},{name:'Instructions',type:'label'},{name:'Submit',type:'button',action:'submit',countdown:3}]};}function loginAction(a,s,f){if(java!==source||book!==null||chapter!==null||a!==String.fromCharCode(115,117,98,109,105,116,39,10)||s.step!==2||f.password!=='SYNTHETIC-PASSWORD'||f.empty!=='')throw new Error('wrong action bindings');return {state:{step:3},error:{captcha:'retry'},login:{token:f.password,nested:{enabled:true}},close:true,futureCommand:'ignored'};}"""
            val render=owned.callUI(script,"""{"step":2,"nested":{"ok":true}}""")["result"].asJsonObject
            assertEquals(5,render["rows"].asJsonArray.size());assertEquals("true",render["rows"].asJsonArray[2].asJsonObject["value"].asString)
            assertEquals("stored-hidden",render["storedValues"].asJsonObject["hidden"].asString)
            assertEquals(0,owned.writes);assertEquals(1,owned.reads)
            val command=owned.callAction(script,action="submit'\n",state="""{"step":2}""",form=jsonObject("password" to "SYNTHETIC-PASSWORD","empty" to ""))["result"].asJsonObject
            assertTrue(command["loginStored"].asBoolean);assertTrue(command["close"].asBoolean)
            assertEquals(3,parseObject(command["stateJSON"].asString)["step"].asInt)
            assertEquals("retry",command["errors"].asJsonObject["captcha"].asString)
            assertEquals(listOf("futureCommand"),command["unknownKeys"].asJsonArray.map{it.asString})
            assertEquals("SYNTHETIC-PASSWORD",parseObject(owned.secret!!)["token"].asString)
            assertTrue(parseObject(owned.secret!!)["nested"].asJsonObject["enabled"].asBoolean);assertEquals(1,owned.writes)
        }
    }
    @Test(timeout=20_000) fun originalValidationRejectsMalformedRowsAndWholeCommandsBeforeAnyReturnedSave() {
        Owned().use { owned ->
            val invalidRows=listOf("[]","[{name:'',key:'x'}]","[{name:'a',key:'same'},{name:'b',key:'same'}]","[{name:'a',type:'button',action:'same'},{name:'b',type:'toggle',key:'b',action:'same'}]","[{name:'a',type:'select',key:'a',options:[]}]","[{name:'a',type:'toggle',key:'a',value:'yes'}]")
            for(rows in invalidRows){val failed=owned.callUI("function loginUi(){return {rows:$rows};}",success=false);assertEquals("INVALID_RESULT",failed["error"].asJsonObject["code"].asString)}
            for(command in listOf("{login:{x:'not-saved'},state:[]}","{login:{x:'not-saved'},error:[]}","{login:{x:'not-saved'},close:'true'}","[]")){
                val failed=owned.callAction("function loginAction(){return $command;}",success=false)
                assertEquals("INVALID_RESULT",failed["error"].asJsonObject["code"].asString);assertFalse(failed.has("result"))
            }
            val empty=owned.callAction("function loginAction(){return null;}")["result"].asJsonObject
            assertFalse(empty["close"].asBoolean);assertFalse(empty["loginStored"].asBoolean);assertTrue(empty["stateJSON"]?.isJsonNull != false)
            val stateOnly=owned.callAction("function loginAction(){return {state:{next:true},error:{attempts:2}};}")["result"].asJsonObject
            assertEquals("2",stateOnly["errors"].asJsonObject["attempts"].asString);assertFalse(stateOnly["loginStored"].asBoolean)
            assertEquals(0,owned.writes);assertNull(owned.secret)
        }
    }
    @Test(timeout=20_000) fun checkedLoginRejectionIOAndSensitiveFailuresNeverAuthorizeCloseOrCandidateState() {
        val script="function loginAction(){return {login:{password:'synthetic-new'},close:true,state:{next:true}};}"
        Owned().use { owned ->
            owned.secret="old-raw";owned.reject=true
            val rejected=owned.callAction(script,success=false)
            assertEquals("STATE_REJECTED",rejected["error"].asJsonObject["code"].asString);assertFalse(rejected.has("result"));assertEquals("old-raw",owned.secret)
            owned.reject=false;owned.ioFailure=true
            val io=owned.callAction(script,success=false)
            assertEquals("STATE_IO",io["error"].asJsonObject["code"].asString)
            assertTrue(io["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceLoginInfoMayCommit"})
            assertFalse(io.toString().contains("SYNTHETIC-V2-CANARY"));assertEquals("old-raw",owned.secret)
            val malformed=owned.malformedTimeout("SYNTHETIC-V2-PRE-TASK-CANARY")
            assertEquals("INVALID_ARGUMENT",malformed["error"].asJsonObject["code"].asString);assertFalse(malformed.toString().contains("SYNTHETIC-V2-PRE-TASK-CANARY"))
            val thrown=owned.callAction("function loginAction(a,s,f){throw new Error(f.password);}",form=jsonObject("password" to "SYNTHETIC-V2-SCRIPT-CANARY"),success=false)
            assertEquals("SCRIPT_ERROR",thrown["error"].asJsonObject["code"].asString);assertFalse(thrown.toString().contains("SYNTHETIC-V2-SCRIPT-CANARY"));assertEquals(0,owned.writes)
        }
    }
    @Test(timeout=20_000) fun cancellationBeforeAndAfterExplicitLoginCommitKeepsEffectsAndCannotReturnClose() {
        for(commitFirst in listOf(false,true)) Owned().use { owned ->
            owned.secret="old-raw";owned.hold=true;owned.commitBeforeHold=commitFirst
            val worker=Executors.newSingleThreadExecutor();val task="v2-cancel-${UUID.randomUUID()}"
            try {
                val pending=worker.submit<JsonObject>{owned.callAction("function loginAction(){return {login:{password:'synthetic-new'},close:true,state:{next:true}};}",task=task,success=false)}
                assertTrue(owned.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val failed=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",failed["error"].asJsonObject["code"].asString);assertFalse(failed.has("result"))
                val effects=failed["error"].asJsonObject["completedEffects"].asJsonArray.map{it.asString}
                assertTrue(effects.contains("sourceLoginInfoMayCommit"));assertEquals(commitFirst,effects.contains("sourceLoginInfoCommitted"))
                assertEquals(if(commitFirst)"synthetic-new"else null,owned.secret?.takeIf{it!="old-raw"}?.let{parseObject(it)["password"].asString})
                if(!commitFirst)assertEquals("old-raw",owned.secret)
            } finally {owned.release.countDown();worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    private class Owned:Closeable {
        val origin="https://synthetic-v2-${UUID.randomUUID()}.invalid"
        var secret:String?=null;var reject=false;var ioFailure=false;var reads=0;var writes=0;var otherHostCalls=0
        var hold=false;var commitBeforeHold=false;@Volatile private var cancelled=false
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        private val directory=Files.createTempDirectory("persist-login-info-")
        private val adapter=FileRulePersistenceAdapter(directory);private val state=RulePersistenceHost(adapter)
        init {LegadoRuntime.setHostCallback {_,operation,raw ->
            if(operation=="task.cancel"){cancelled=true;release.countDown();"{}"} else {
                val input=parseObject(raw);check(input["owner"].asString=="owned-v2")
                if(operation=="source.login-info") {
                    check(input["sourceURL"].asString==origin)
                    val action=input["action"].asString
                    if(action=="get"){reads++;jsonObject("value" to secret).toString()}
                    else if(ioFailure)jsonObject("ok" to false,"error" to jsonObject("code" to "STATE_IO","message" to "SYNTHETIC-V2-CANARY","completedEffects" to listOf("sourceLoginInfoMayCommit"))).toString()
                    else if(reject)jsonObject("committed" to false).toString()
                    else {
                        fun commit(){secret=if(action=="remove")null else input["value"].asString;writes++}
                        if(!hold||commitBeforeHold)commit()
                        if(hold){entered.countDown();check(release.await(5,TimeUnit.SECONDS))}
                        val effects=if(!hold||commitBeforeHold)listOf("sourceLoginInfoMayCommit","sourceLoginInfoCommitted")else listOf("sourceLoginInfoMayCommit")
                        if(cancelled&&!commitBeforeHold)jsonObject("ok" to false,"error" to jsonObject("code" to "CANCELLED","message" to "cancelled before commit","completedEffects" to effects)).toString()
                        else jsonObject("committed" to true,"hostEffects" to effects).toString()
                    }
                } else {otherHostCalls++;state.dispatch(operation,input).toString()}
            }
        }}
        fun callUI(login:String,state:String="{}",success:Boolean=true):JsonObject = invoke("loginV2UI",jsonObject("stateJSON" to state,"timeoutMs" to 20_000),login,"v2-render-${UUID.randomUUID()}",success)
        fun callAction(login:String,action:String="submit",state:String="{}",form:JsonObject=jsonObject(),task:String="v2-action-${UUID.randomUUID()}",success:Boolean=true):JsonObject = invoke("loginV2Action",jsonObject("action" to action,"stateJSON" to state,"form" to form,"timeoutMs" to 20_000),login,task,success)
        fun malformedTimeout(marker:String):JsonObject = invoke("loginV2Action",jsonObject("action" to "submit","stateJSON" to "{}","form" to jsonObject(),"timeoutMs" to marker),"throw new Error('must-not-evaluate');","v2-invalid-${UUID.randomUUID()}",false)
        private fun invoke(operation:String,input:JsonObject,login:String,task:String,success:Boolean):JsonObject {
            val source=jsonObject("bookSourceUrl" to origin,"loginUrl" to login,"loginUi" to "{\"version\":2}","enabledCookieJar" to false,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "owned-v2").toString()));assertTrue(created["ok"].asBoolean);val id=created["sessionId"].asString
            try {val value=parseObject(LegadoRuntime.execute(id,task,operation,input.toString()));assertEquals(value.toString(),success,value["ok"].asBoolean);return value}
            finally {LegadoRuntime.closeSession(id)}
        }
        override fun close(){release.countDown();LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
}
