package io.yuedu.legado

import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.yuedu.legado.originalrule.GSON
import io.yuedu.legado.originalrule.RulePersistenceHost
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Real public original invocation/Rhino and host protocol. Only synthetic
 * credentials enter this file-backed peer; native tests cover the App Keychain. */
class OriginalSourceLoginInfoTest {
    @Test(timeout = 20_000) fun nullableJavaStringBooleanAndVerbatimValuesSurviveSessionReopen() {
        assertEquals(String::class.java, BookSource::class.java.getMethod("getLoginInfo").returnType)
        assertEquals(Boolean::class.javaPrimitiveType, BookSource::class.java.getMethod("putLoginInfo", String::class.java).returnType)
        assertEquals(Void.TYPE, BookSource::class.java.getMethod("removeLoginInfo").returnType)
        Owned().use { owned ->
            val raw = "  not JSON \u4e2d\n"
            val literal = GSON.toJson(raw)
            owned.call("""
                if(source.getLoginInfo()!==null)throw new Error('missing is not null');
                if(source.putLoginInfo($literal)!=true)throw new Error('put result');
                var raw=source.getLoginInfo();
                if(String(raw)!==$literal)throw new Error('raw Java String');
            """.trimIndent())
            assertEquals(raw, owned.stored())
            owned.call("if(String(source.getLoginInfo())!==$literal)throw new Error('reopen');")
            owned.call("if(source.putLoginInfo('')!=true||String(source.getLoginInfo())!=='')throw new Error('empty');source.removeLoginInfo();if(source.getLoginInfo()!==null)throw new Error('remove');")
            assertNull(owned.stored())
            owned.call("if(source.getLoginInfo()!==null)throw new Error('cross-source');source.putLoginInfo('source-b');", source = owned.b)
            assertNull(owned.stored())
            assertEquals("source-b", owned.stored(owned.b))
            assertTrue(owned.operations.any { it == "source.login-info:put" })
            assertFalse(owned.stateKeys.any { "userInfo_" in it })
        }
    }

    @Test(timeout = 20_000) fun knownWriteFailureUnreadableOwnerAndMissingAuthorityNeverBecomeSuccess() {
        Owned().use { owned ->
            owned.call("source.putLoginInfo('kept');")
            owned.failWrite.set(true)
            owned.call("if(source.putLoginInfo('rejected')!=false)throw new Error('lost false');if(String(source.getLoginInfo())!=='kept')throw new Error('lost previous');")
            assertEquals("kept", owned.stored())
            owned.failRead.set(true)
            val failed = owned.call("var v=source.getLoginInfo();throw new Error('read failure became value');", success = false)
            assertEquals("STATE_IO", failed["error"].asJsonObject["code"].asString)
            val before = owned.operations.size
            val missing = owned.call("source.putLoginInfo('must-not-store');", owner = null, success = false)
            assertEquals("UNSUPPORTED_CAPABILITY", missing["error"].asJsonObject["code"].asString)
            assertEquals(before, owned.operations.size)
            assertEquals("kept", owned.stored())
        }
    }

    @Test(timeout = 20_000) fun cancelledAfterAcceptedSecretWriteRetainsEffectAndNeverRunsLaterStatements() {
        Owned().use { owned ->
            owned.holdAccepted.set(true)
            val task = "login-cancel-" + UUID.randomUUID()
            val worker = Executors.newSingleThreadExecutor()
            try {
                val pending = worker.submit<JsonObject> { owned.call("source.putLoginInfo('accepted');source.putLoginInfo('late');", task = task, success = false) }
                assertTrue(owned.accepted.await(5, TimeUnit.SECONDS))
                LegadoRuntime.cancel(task)
                val failed = pending.get(5, TimeUnit.SECONDS)
                assertEquals("CANCELLED", failed["error"].asJsonObject["code"].asString)
                assertTrue(failed["error"].asJsonObject["completedEffects"].asJsonArray.any { it.asString == "sourceLoginInfoCommitted" })
                assertEquals("accepted", owned.stored())
                assertEquals(1, owned.operations.count { it == "source.login-info:put" })
            } finally {
                owned.release.countDown(); worker.shutdownNow(); assertTrue(worker.awaitTermination(5, TimeUnit.SECONDS))
            }
        }
    }

    private class Owned : Closeable {
        val a = "https://login-a-${UUID.randomUUID()}.invalid"
        val b = "https://login-b-${UUID.randomUUID()}.invalid"
        val operations = CopyOnWriteArrayList<String>()
        val stateKeys = CopyOnWriteArrayList<String>()
        val failWrite = AtomicBoolean(false)
        val failRead = AtomicBoolean(false)
        val holdAccepted = AtomicBoolean(false)
        val accepted = CountDownLatch(1)
        val release = CountDownLatch(1)
        private val directory = Files.createTempDirectory("synthetic-login-info-")
        private val state = RulePersistenceHost(FileRulePersistenceAdapter(directory.resolve("state")))
        init {
            LegadoRuntime.setHostCallback { _, operation, raw ->
                if (operation == "task.cancel") { release.countDown(); "{}" }
                else {
                    val input = parseObject(raw)
                    assertTrue(input["deadlineEpochMs"].asLong > 0)
                    if (operation != "source.login-info") {
                        input["keys"]?.asJsonArray?.forEach { stateKeys += it.asString }
                        state.dispatch(operation, input).toString()
                    } else {
                        val source = input["sourceURL"].asString
                        check(source in listOf(a,b) && input["owner"].asString == "owned:$source")
                        val action = input["action"].asString
                        operations += "$operation:$action"
                        when (action) {
                            "get" -> if (failRead.getAndSet(false)) jsonObject("ok" to false,"error" to jsonObject("code" to "STATE_IO","message" to "controlled locked owner")).toString()
                                else jsonObject("value" to stored(source)).toString()
                            "put" -> {
                                if (failWrite.getAndSet(false)) jsonObject("committed" to false).toString()
                                else {
                                    Files.writeString(file(source), input["value"].asString)
                                    if (holdAccepted.getAndSet(false)) { accepted.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
                                    jsonObject("committed" to true,"hostEffects" to listOf("sourceLoginInfoMayCommit","sourceLoginInfoCommitted")).toString()
                                }
                            }
                            "remove" -> { Files.deleteIfExists(file(source)); jsonObject("committed" to true).toString() }
                            else -> error("Unexpected action")
                        }
                    }
                }
            }
        }
        private fun file(source:String):Path = directory.resolve(if(source==a) "a-synthetic.txt" else "b-synthetic.txt")
        fun stored(source:String=a):String? = file(source).takeIf(Files::exists)?.let(Files::readString)
        fun call(script:String, source:String=a, owner:String?="owned:$source", task:String="login-${UUID.randomUUID()}", success:Boolean=true):JsonObject {
            val sourceJSON=jsonObject("bookSourceUrl" to source,"eventListener" to true,"enabledCookieJar" to false,
                "ruleContent" to jsonObject("callBackJs" to script))
            val options=jsonObject("sourceMode" to "original-traditional", "httpTransport" to "jvm-okhttp")
            if(owner!=null)options.addProperty("stateOwner",owner)
            val created=parseObject(LegadoRuntime.createSession(sourceJSON.toString(), options.toString()))
            if(owner==null && !success) { assertFalse(created.toString(),created["ok"].asBoolean); return created }
            assertTrue(created.toString(), created["ok"].asBoolean)
            val id=created["sessionId"].asString
            try {
                val reply=parseObject(LegadoRuntime.execute(id,task,"bookCallback",jsonObject("event" to "addBookShelf",
                    "book" to jsonObject("bookUrl" to "$source/book","origin" to source),"timeoutMs" to 60000).toString()))
                assertEquals(reply.toString(),success,reply["ok"].asBoolean); return reply
            } finally { LegadoRuntime.closeSession(id) }
        }
        override fun close() { release.countDown();LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively()) }
    }
}
