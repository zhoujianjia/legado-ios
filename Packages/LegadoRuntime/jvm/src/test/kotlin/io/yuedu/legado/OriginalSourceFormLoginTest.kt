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
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.logging.Handler
import java.util.logging.Level
import java.util.logging.LogRecord
import java.util.logging.Logger

class OriginalSourceFormLoginTest {
    @Test(timeout=20_000) fun actualFormJavaMapPostsThroughOriginalHttpAndOnlyExplicitHeaderPersists() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val script="""
                function login(){
                    if(java===source||java.getSource()!==source||book!==null||chapter!==null||isLongClick!==false)throw new Error('wrong standalone login binding');
                    if(String(result.get('password'))!=='SYNTHETIC-PASSWORD-CANARY')throw new Error('not Java form Map');
                    var response=java.ajax('${peer.origin}/login,'+JSON.stringify({method:'POST',body:JSON.stringify({username:String(result.get('username')),password:String(result.get('password'))}),headers:{'Content-Type':'application/json'}}));
                    java.setContent(response);var token=java.getString('$.token');
                    source.putLoginHeader(JSON.stringify({Authorization:String(token)}));
                    return JSON.stringify({'X-Fake-Header':'must-not-infer'});
                }
            """.trimIndent()
            val reply=owned.call(script)["result"].asJsonObject
            assertTrue(reply["credentialsStored"].asBoolean);assertTrue(reply["executed"].asBoolean);assertFalse(reply["credentialsCleared"].asBoolean)
            assertEquals("SYNTHETIC-PASSWORD-CANARY",parseObject(owned.secret!!)["password"].asString)
            assertEquals("synthetic-server-token",parseObject(owned.header()!!)["Authorization"].asString)
            assertFalse(parseObject(owned.header()!!).has("X-Fake-Header"))
            assertEquals(1,peer.requests.size);assertEquals("POST",peer.requests.single().first)
            assertEquals("SYNTHETIC-PASSWORD-CANARY",parseObject(peer.requests.single().second)["password"].asString)
            assertTrue(owned.stateKeys.all { !it.contains("userInfo_") })
        } }
    }
    @Test(timeout=20_000) fun emptyRejectedAndMissingLoginFormsKeepOriginalSequentialFacts() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            owned.call("function login(){source.putLoginHeader('kept-header');}")
            val old=owned.secret;owned.reject=true
            val refused=owned.call("function login(){java.ajax('${peer.origin}/must-not-run');}")["result"].asJsonObject
            assertFalse(refused["credentialsStored"].asBoolean);assertFalse(refused["executed"].asBoolean);assertEquals(old,owned.secret)
            owned.reject=false
            val removed=owned.call("throw new Error('empty form must not run');",jsonObject())["result"].asJsonObject
            assertTrue(removed["credentialsCleared"].asBoolean);assertFalse(removed["executed"].asBoolean);assertNull(owned.secret);assertEquals("kept-header",owned.header())
            val noScript=owned.call("")["result"].asJsonObject
            assertTrue(noScript["credentialsStored"].asBoolean);assertFalse(noScript["executed"].asBoolean)
            val missing=owned.call("var noLoginFunction=true;",success=false)
            assertEquals("SCRIPT_ERROR",missing["error"].asJsonObject["code"].asString);assertNotNull(owned.secret)
            assertTrue(peer.requests.isEmpty())
        } }
    }
    @Test(timeout=20_000) fun sensitiveErrorsAndLogsDoNotExposeSubmittedCredentialsAndBrowserStaysTyped() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val messages=CopyOnWriteArrayList<String>()
            val loggers=listOf(Logger.getLogger("io.yuedu.legado.originalrule"),Logger.getLogger("io.legado.app.model.analyzeRule.AnalyzeByJSonPath"));val oldLevels=loggers.map{it.level}
            val handler=object:Handler(){override fun publish(record:LogRecord){messages+=java.util.logging.SimpleFormatter().format(record)};override fun flush(){};override fun close(){}}
            loggers.forEach{it.level=Level.ALL;it.addHandler(handler)}
            try {
                io.legado.app.model.analyzeRule.AnalyzeByJSonPath("{}").getString("$['SYNTHETIC-ORDINARY-DIAGNOSTIC']")
                assertTrue(messages.any{it.contains("SYNTHETIC-ORDINARY-DIAGNOSTIC")})
                messages.clear()
                val failed=owned.call("function login(){java.log(result.get('password'));source.log(result.get('password'));throw new Error(String(result.get('password')));}",success=false)
                assertEquals("SCRIPT_ERROR",failed["error"].asJsonObject["code"].asString)
                assertFalse(failed.toString().contains("SYNTHETIC-PASSWORD-CANARY"));assertTrue(messages.none{it.contains("SYNTHETIC-PASSWORD-CANARY")})
                assertNotNull(owned.secret)
                val direct=owned.call("function login(){source.log(source.getLoginInfoMap().get('password'));throw new Error(String(source.getLoginInfoMap().get('password')));}",success=false,direct=true)
                assertEquals("SCRIPT_ERROR",direct["error"].asJsonObject["code"].asString)
                assertFalse(direct.toString().contains("SYNTHETIC-PASSWORD-CANARY"));assertTrue(messages.none{it.contains("SYNTHETIC-PASSWORD-CANARY")})
                val parser=owned.call("""function login(){var pwd=String(result.get('password'));java.setContent('{}');java.getString("$['"+pwd+"']");java.getStringList("$['"+pwd+"']");java.getElements("$['"+pwd+"']");java.setContent('<a href="ftp://['+pwd+'">x</a>');java.setRedirectUrl('http://example.invalid/');java.getString('a@href',null,true);}""")
                assertTrue(parser["ok"].asBoolean);assertTrue(messages.none{it.contains("SYNTHETIC-PASSWORD-CANARY")})
                val prior=owned.secret
                val browser=owned.call("https://example.invalid/login",success=false)
                assertEquals("UNSUPPORTED_CAPABILITY",browser["error"].asJsonObject["code"].asString);assertEquals(prior,owned.secret)
                val ui=owned.call("function login(){java.startBrowserAwait('https://example.invalid','title');}",success=false)
                assertEquals("UNSUPPORTED_CAPABILITY",ui["error"].asJsonObject["code"].asString)
                assertTrue(ui["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceLoginInfoCommitted"})
                assertTrue(peer.requests.isEmpty())
            } finally {loggers.forEachIndexed{i,logger->logger.removeHandler(handler);logger.level=oldLevels[i]}}
        } }
    }
    @Test(timeout=20_000) fun cancelledActualLoginHttpDrainsAndPreservesCredentialEffectWithoutLateHeader() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val task="form-cancel-${UUID.randomUUID()}";val worker=Executors.newSingleThreadExecutor()
            try {
                val pending=worker.submit<JsonObject>{owned.call("function login(){java.ajax('${peer.origin}/held');source.putLoginHeader('must-not-write');}",task=task,success=false)}
                assertTrue(peer.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val failure=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",failure["error"].asJsonObject["code"].asString)
                assertTrue(failure["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceLoginInfoCommitted"})
                assertNotNull(owned.secret);assertNull(owned.header())
                assertFalse(failure.toString().contains("SYNTHETIC-PASSWORD-CANARY"))
            } finally {worker.shutdownNow();assertTrue(worker.awaitTermination(5,TimeUnit.SECONDS))}
        } }
    }
    private class Owned(private val origin:String):Closeable {
        var secret:String?=null;var reject=false
        val stateKeys=CopyOnWriteArrayList<String>()
        private val directory=Files.createTempDirectory("form-login-state-")
        private val adapter=FileRulePersistenceAdapter(directory)
        private val state=RulePersistenceHost(adapter)
        init {LegadoRuntime.setHostCallback {_,op,raw ->
            if(op=="task.cancel")"{}" else {
                val input=parseObject(raw)
                check(input["owner"].asString=="owned-form");check(input["deadlineEpochMs"].asLong>0)
                if(op=="source.login-info") {
                    check(input["sourceURL"].asString==origin)
                    when(input["action"].asString) {
                        "get" -> jsonObject("value" to secret).toString()
                        "remove" -> {secret=null;jsonObject("committed" to true).toString()}
                        "put" -> if(reject)jsonObject("committed" to false).toString() else {secret=input["value"].asString;jsonObject("committed" to true,"hostEffects" to listOf("sourceLoginInfoMayCommit","sourceLoginInfoCommitted")).toString()}
                        else -> error("Unexpected login owner action")
                    }
                } else {
                    input["keys"]?.asJsonArray?.forEach{stateKeys+=it.asString}
                    state.dispatch(op,input).toString()
                }
            }
        }}
        fun header():String? {
            val key=GSON.toJson(listOf(origin,"cache-text","loginHeader_$origin"))
            return adapter.read("owned-form",setOf(key)).values[key]?.let { bytes ->
                val record=parseObject(String(bytes,Charsets.UTF_8));String(Base64.getDecoder().decode(record["data"].asString),Charsets.UTF_8)
            }
        }
        fun call(login:String,credentials:JsonObject=jsonObject("username" to "synthetic-user","password" to "SYNTHETIC-PASSWORD-CANARY"),task:String="form-${UUID.randomUUID()}",success:Boolean=true,direct:Boolean=false):JsonObject {
            val source=jsonObject("bookSourceUrl" to origin,"enabledCookieJar" to false,"loginUrl" to login,"ruleContent" to if(direct)jsonObject("callBackJs" to "source.login();") else jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "owned-form").toString()))
            assertTrue(created.toString(),created["ok"].asBoolean);val id=created["sessionId"].asString
            try {val value=parseObject(LegadoRuntime.execute(id,task,if(direct)"sourceCallback" else "formLogin",if(direct)jsonObject("event" to "startShelfRefresh","timeoutMs" to 20_000).toString() else jsonObject("credentials" to credentials,"timeoutMs" to 20_000).toString()));assertEquals(value.toString(),success,value["ok"].asBoolean);return value}
            finally{LegadoRuntime.closeSession(id)}
        }
        override fun close(){LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
    private class Peer:Closeable {
        val entered=CountDownLatch(1);private val release=CountDownLatch(1)
        val requests=CopyOnWriteArrayList<Pair<String,String>>()
        private val workers=Executors.newFixedThreadPool(2)
        private val server=HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply{
            executor=workers;createContext("/"){e ->
                try {
                    requests+=e.requestMethod to e.requestBody.readBytes().toString(Charsets.UTF_8)
                    if(e.requestURI.path=="/held"){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
                    val body="{\"token\":\"synthetic-server-token\"}".toByteArray();e.sendResponseHeaders(200,body.size.toLong());e.responseBody.write(body)
                }catch(_:java.io.IOException){/* actual client cancellation closes this response socket */}finally{e.close()}
            };start()
        }
        val origin="http://127.0.0.1:${server.address.port}"
        override fun close(){release.countDown();server.stop(0);workers.shutdownNow();check(workers.awaitTermination(5,TimeUnit.SECONDS))}
    }
}
