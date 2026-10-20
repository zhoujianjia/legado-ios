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

class OriginalSourcePersistLoginInfoTest {
    @Test(timeout=20_000) fun workingMapPersistsHiddenAndEmptyValuesWithoutEvaluatingAnyLoginScript() {
        Owned().use { owned ->
            val first=owned.call(jsonObject("hidden" to "synthetic-hidden","password" to ""),login="throw new Error('MUST-NOT-EVALUATE');function login(){source.putLoginInfo('wrong');}")["result"].asJsonObject
            assertTrue(first["credentialsStored"].asBoolean);assertFalse(first["credentialsCleared"].asBoolean);assertFalse(first["executed"].asBoolean)
            assertEquals(jsonObject("hidden" to "synthetic-hidden","password" to ""),parseObject(owned.secret!!))
            assertEquals(0,owned.reads);assertEquals(1,owned.writes);assertEquals(0,owned.otherHostCalls)
            val broken=owned.call(jsonObject("hidden" to "second"),login="function login( { broken syntax + source.putLoginHeader('wrong')")["result"].asJsonObject
            assertTrue(broken["credentialsStored"].asBoolean);assertFalse(broken["executed"].asBoolean)
            assertEquals("second",parseObject(owned.secret!!)["hidden"].asString)
        }
    }
    @Test(timeout=20_000) fun emptyMapRemovesOnlyLoginInfoAndKnownRejectionsNeverClaimAcknowledgement() {
        Owned().use { owned ->
            owned.headerSetup();assertEquals("kept-header",owned.header());owned.otherHostCalls=0
            owned.call(jsonObject("hidden" to "old"));owned.reject=true
            val rejected=owned.call(jsonObject("hidden" to "new"))["result"].asJsonObject
            assertFalse(rejected["credentialsStored"].asBoolean);assertFalse(rejected["credentialsCleared"].asBoolean);assertFalse(rejected["executed"].asBoolean)
            assertEquals("old",parseObject(owned.secret!!)["hidden"].asString)
            val removeRejected=owned.call(jsonObject(),success=false)["error"].asJsonObject
            assertEquals("STATE_IO",removeRejected["code"].asString);assertNotNull(owned.secret)
            owned.reject=false
            val removed=owned.call(jsonObject(),login="https://must-not-open.invalid/login")["result"].asJsonObject
            assertTrue(removed["credentialsCleared"].asBoolean);assertFalse(removed["credentialsStored"].asBoolean);assertFalse(removed["executed"].asBoolean)
            assertNull(owned.secret);assertEquals("kept-header",owned.header());assertEquals(0,owned.otherHostCalls)
        }
    }
    @Test(timeout=20_000) fun credentialIOErrorKeepsMayCommitAndSanitizesOwnerDiagnostics() {
        Owned().use { owned ->
            owned.secret="old-raw";owned.ioFailure=true
            val failed=owned.call(jsonObject("password" to "SYNTHETIC-DISMISS-CANARY"),success=false)["error"].asJsonObject
            assertEquals("STATE_IO",failed["code"].asString);assertEquals("old-raw",owned.secret)
            assertEquals(listOf("sourceLoginInfoMayCommit"),failed["completedEffects"].asJsonArray.map{it.asString})
            assertFalse(failed["message"].asString.contains("SYNTHETIC-DISMISS-CANARY"));assertEquals(0,owned.otherHostCalls)
            // Parsing can fail before a RuntimeTask/sensitive marker exists.
            val malformed=owned.malformedTimeout("SYNTHETIC-PRE-TASK-CANARY")
            assertEquals("INVALID_ARGUMENT",malformed["error"].asJsonObject["code"].asString)
            assertFalse(malformed.toString().contains("SYNTHETIC-PRE-TASK-CANARY"))
        }
    }
    @Test(timeout=20_000) fun cancellationBeforeAndAfterCheckedHostCommitRetainsDistinctRealEffects() {
        for(commitFirst in listOf(false,true)) Owned().use { owned ->
            owned.secret="old-raw";owned.hold=true;owned.commitBeforeHold=commitFirst
            val worker=Executors.newSingleThreadExecutor();val task="persist-cancel-${UUID.randomUUID()}"
            try {
                val pending=worker.submit<JsonObject>{owned.call(jsonObject("password" to "synthetic-new"),task=task,success=false)}
                assertTrue(owned.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val failed=pending.get(5,TimeUnit.SECONDS)["error"].asJsonObject
                assertEquals("CANCELLED",failed["code"].asString)
                val effects=failed["completedEffects"].asJsonArray.map{it.asString}
                assertTrue(effects.contains("sourceLoginInfoMayCommit"));assertEquals(commitFirst,effects.contains("sourceLoginInfoCommitted"))
                assertEquals(if(commitFirst)"synthetic-new"else null,owned.secret?.takeIf{it!="old-raw"}?.let{parseObject(it)["password"].asString})
                if(!commitFirst)assertEquals("old-raw",owned.secret)
                assertEquals(0,owned.otherHostCalls)
            } finally {owned.release.countDown();worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    private class Owned:Closeable {
        val origin="https://synthetic-dismiss-${UUID.randomUUID()}.invalid"
        var secret:String?=null;var reject=false;var ioFailure=false;var reads=0;var writes=0;var otherHostCalls=0
        var hold=false;var commitBeforeHold=false;@Volatile private var cancelled=false
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        private val directory=Files.createTempDirectory("persist-login-info-")
        private val adapter=FileRulePersistenceAdapter(directory);private val state=RulePersistenceHost(adapter)
        init {LegadoRuntime.setHostCallback {_,operation,raw ->
            if(operation=="task.cancel"){cancelled=true;release.countDown();"{}"} else {
                val input=parseObject(raw);check(input["owner"].asString=="owned-dismiss")
                if(operation=="source.login-info") {
                    check(input["sourceURL"].asString==origin)
                    val action=input["action"].asString
                    if(action=="get"){reads++;jsonObject("value" to secret).toString()}
                    else if(ioFailure)jsonObject("ok" to false,"error" to jsonObject("code" to "STATE_IO","message" to "SYNTHETIC-DISMISS-CANARY","completedEffects" to listOf("sourceLoginInfoMayCommit"))).toString()
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
        fun call(values:JsonObject,login:String="throw new Error('must-not-run');",task:String="persist-${UUID.randomUUID()}",success:Boolean=true):JsonObject {
            return invoke("persistLoginInfo",jsonObject("credentials" to values,"timeoutMs" to 20_000),login,task,success)
        }
        fun malformedTimeout(marker:String):JsonObject = invoke("persistLoginInfo",
            jsonObject("credentials" to jsonObject(),"timeoutMs" to marker),
            "throw new Error('must-not-run');","persist-invalid-${UUID.randomUUID()}",false)
        private fun invoke(operation:String,input:JsonObject,login:String,task:String,success:Boolean):JsonObject {
            val source=jsonObject("bookSourceUrl" to origin,"loginUrl" to login,"enabledCookieJar" to false,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "owned-dismiss").toString()));assertTrue(created["ok"].asBoolean);val id=created["sessionId"].asString
            try {val value=parseObject(LegadoRuntime.execute(id,task,operation,input.toString()));assertEquals(value.toString(),success,value["ok"].asBoolean);return value}
            finally {LegadoRuntime.closeSession(id)}
        }
        fun headerSetup(){invoke("loginAction",jsonObject("action" to "source.putLoginHeader('kept-header')","credentials" to jsonObject(),"isLongClick" to false,"timeoutMs" to 20_000),"var present=true;","setup-${UUID.randomUUID()}",true)}
        fun header():String? {
            val key=GSON.toJson(listOf(origin,"cache-text","loginHeader_$origin"));return adapter.read("owned-dismiss",setOf(key)).values[key]?.let{String(Base64.getDecoder().decode(parseObject(String(it,Charsets.UTF_8))["data"].asString),Charsets.UTF_8)}
        }
        override fun close(){release.countDown();LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
}
