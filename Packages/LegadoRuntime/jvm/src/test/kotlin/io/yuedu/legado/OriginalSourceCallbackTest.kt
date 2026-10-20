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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Public source-only notifications with retained Rhino, production HTTP and real file state.
 * App eventListener selection belongs to the caller; the original source method has no gate. */
class OriginalSourceCallbackTest {
    @Test(timeout = 20_000) fun shelfRefreshNotificationsUseNullEntitiesAndPersistSourceStateAcrossSessions() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val script = """
                if (!java.equals(source) || !source.equals(sourceApi) || String(source.getKey()) !== String(baseUrl)) throw new Error('wrong source bindings');
                if (book !== null || chapter !== null || result !== null) throw new Error('source callback received an entity');
                if (typeof infoMap !== 'undefined') throw new Error('source callback acquired an exploration map');
                var prior = String(source.get('events'));
                source.put('events', prior + (prior ? '|' : '') + String(event));
                if (String(java.ajax('${peer.origin}/notify?event=' + String(event))) !== 'source-callback-wire') throw new Error('wrong real HTTP response');
                ({toString: function() { throw new Error('authored return must be ignored'); }});
            """.trimIndent()
            for (event in listOf("startShelfRefresh", "endShelfRefresh")) {
                val response = owned.call(event, script)
                assertEquals(setOf("executed"), response["result"].asJsonObject.keySet())
                assertTrue(response.toString(), response["result"].asJsonObject["executed"].asBoolean)
            }
            assertEquals(2, owned.sessions.size)
            assertEquals(2, owned.sessions.toSet().size)
            assertEquals("startShelfRefresh|endShelfRefresh", owned.sourceValue("events"))
            assertEquals(listOf("/notify?event=startShelfRefresh", "/notify?event=endShelfRefresh"), peer.requests.toList())
            owned.assertOnlySourceStateRequests()
            assertTrue(owned.hostCalls.any { it.operation == "state.commit" })
        } }
    }

    @Test(timeout = 15_000) fun authoredFailureUnsupportedEventAndEmptyScriptKeepTheirOwnOutcomes() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val authored = owned.call("startShelfRefresh", "throw new Error('authored source failure')", expectSuccess = false)
            assertEquals("SCRIPT_ERROR", authored["error"].asJsonObject["code"].asString)
            val unsupported = owned.call("startRead", "source.put('unexpected','bad')", expectSuccess = false)
            assertEquals("UNSUPPORTED_CAPABILITY", unsupported["error"].asJsonObject["code"].asString)
            val injected = owned.call("startShelfRefresh", "source.put('unexpected','bad')", expectSuccess = false,
                extra = jsonObject("book" to jsonObject("bookUrl" to "${peer.origin}/book"), "chapter" to null, "result" to "forbidden"))
            assertEquals("INVALID_ARGUMENT", injected["error"].asJsonObject["code"].asString)
            val excessiveTimeout = owned.call("startShelfRefresh", "source.put('unexpected','bad')", expectSuccess = false,
                extra = jsonObject("timeoutMs" to 30_001))
            assertEquals("INVALID_ARGUMENT", excessiveTimeout["error"].asJsonObject["code"].asString)
            val beforeEmpty = owned.hostCalls.size
            val empty = owned.call("endShelfRefresh", "")["result"].asJsonObject
            assertEquals(setOf("executed"), empty.keySet())
            assertFalse(empty["executed"].asBoolean)
            assertEquals(beforeEmpty, owned.hostCalls.size)
            assertNull(owned.sourceValue("unexpected"))
            assertFalse(owned.hostCalls.any { it.operation == "state.commit" })
            assertTrue(peer.requests.isEmpty())
            owned.assertOnlySourceStateRequests()
        } }
    }

    @Test(timeout = 20_000) fun cancellingHeldSourceNotificationDrainsBeforeCheckingLaterStatements() {
        Peer().use { peer -> Owned(peer.origin).use { owned ->
            val script = "source.put('before','kept'); java.ajax('${peer.origin}/held'); source.put('late','bad');"
            val worker = Executors.newSingleThreadExecutor()
            val task = "source-callback-cancel-${UUID.randomUUID()}"
            try {
                val future = worker.submit<JsonObject> { owned.call("endShelfRefresh", script, task, expectSuccess = false) }
                assertTrue("real source callback HTTP was entered", peer.held.await(5, TimeUnit.SECONDS))
                val cancellation = parseObject(LegadoRuntime.cancel(task))
                assertTrue(cancellation.toString(), cancellation["ok"].asBoolean)
                val failure = future.get(5, TimeUnit.SECONDS)
                assertTrue("execute has reached its terminal response", future.isDone)
                assertEquals("CANCELLED", failure["error"].asJsonObject["code"].asString)
                peer.releaseHeld()
                assertTrue("the real HTTP handler drained", peer.heldFinished.await(5, TimeUnit.SECONDS))
                assertEquals("kept", owned.sourceValue("before"))
                assertNull(owned.sourceValue("late"))
                assertEquals(listOf("/held"), peer.requests.toList())
                owned.assertOnlySourceStateRequests()
                assertTrue(owned.cancelledTasks.contains(task))
            } finally {
                peer.releaseHeld()
                worker.shutdownNow()
                assertTrue(worker.awaitTermination(5, TimeUnit.SECONDS))
            }
        } }
    }

    private data class HostCall(val task: String, val operation: String, val request: JsonObject)

    private class Owned(private val origin: String) : Closeable {
        private val directory = Files.createTempDirectory("source-callback-original-")
        private val adapter = FileRulePersistenceAdapter(directory)
        private val state = RulePersistenceHost(adapter)
        private val owner = "actual-source-callback-owner"
        private val timeoutMs = 30_000L
        private val taskStarts = ConcurrentHashMap<String, Long>()
        val sessions = CopyOnWriteArrayList<String>()
        val hostCalls = CopyOnWriteArrayList<HostCall>()
        val cancelledTasks = CopyOnWriteArrayList<String>()

        init {
            LegadoRuntime.setHostCallback { task, operation, raw ->
                if (operation == "task.cancel") {
                    check(taskStarts.containsKey(task)) { "Cancellation left the actual callback task" }
                    cancelledTasks += task
                    "{}"
                } else {
                    val request = parseObject(raw)
                    check(operation in setOf("state.read", "state.commit")) { "Source callback acquired an unrelated host capability: $operation" }
                    check(request["owner"].asString == owner)
                    val started = requireNotNull(taskStarts[task]) { "State operation lost the actual callback task" }
                    val deadline = request["deadlineEpochMs"].asLong
                    val remaining = request["remainingTimeoutMs"].asLong
                    check(deadline >= started + timeoutMs && deadline <= System.currentTimeMillis() + timeoutMs)
                    check(remaining in 1..timeoutMs)
                    hostCalls += HostCall(task, operation, request.deepCopy())
                    state.dispatch(operation, request).toString()
                }
            }
        }

        fun call(event: String, script: String, task: String = "source-callback-${UUID.randomUUID()}",
                 expectSuccess: Boolean = true, extra: JsonObject? = null): JsonObject {
            // False deliberately proves that the public runtime does not invent an eventListener
            // gate absent from SourceCallBack.callBackSource; the App performs its own selection.
            val source = jsonObject("bookSourceUrl" to origin, "eventListener" to false, "enabledCookieJar" to false,
                "ruleContent" to jsonObject("callBackJs" to script))
            val created = parseObject(LegadoRuntime.createSession(source.toString(), jsonObject("sourceMode" to "original-traditional",
                "httpTransport" to "jvm-okhttp", "stateOwner" to owner).toString()))
            assertTrue(created.toString(), created["ok"].asBoolean)
            val session = created["sessionId"].asString
            sessions += session
            val request = jsonObject("event" to event, "timeoutMs" to timeoutMs)
            extra?.entrySet()?.forEach { (key, value) -> request.add(key, value) }
            taskStarts[task] = System.currentTimeMillis()
            return try {
                val reply = parseObject(LegadoRuntime.execute(session, task, "sourceCallback", request.toString()))
                assertEquals(reply.toString(), expectSuccess, reply["ok"].asBoolean)
                assertEquals(task, reply["taskId"].asString)
                reply
            } finally {
                val closed = parseObject(LegadoRuntime.closeSession(session))
                assertTrue(closed.toString(), closed["ok"].asBoolean)
            }
        }

        fun sourceValue(name: String): String? {
            val key = GSON.toJson(listOf(origin, "cache-text", "v_${origin}_$name"))
            val bytes = adapter.read(owner, setOf(key)).values[key] ?: return null
            val entry = parseObject(String(bytes, Charsets.UTF_8))
            assertEquals(0L, entry["deadline"].asLong)
            return String(Base64.getDecoder().decode(entry["data"].asString), Charsets.UTF_8)
        }

        fun assertOnlySourceStateRequests() {
            hostCalls.forEach { call ->
                assertTrue(taskStarts.containsKey(call.task))
                val request = call.request
                assertEquals(owner, request["owner"].asString)
                val keys = if (call.operation == "state.read") request["keys"].asJsonArray.map { it.asString }
                    else request["changes"].asJsonObject.keySet().toList()
                keys.forEach { key ->
                    val parts = GSON.fromJson(key, com.google.gson.JsonArray::class.java)
                    assertEquals(origin, parts[0].asString)
                    if (parts.size() == 2 && parts[1].asString == "cookies") {
                        // Production HTTP reads the same source Cookie owner even
                        // when this fixture has sending disabled and no cookies.
                        assertEquals("state.read", call.operation)
                    } else {
                        assertEquals("Only source cache keys may be requested: $key", 3, parts.size())
                        assertEquals("Entity and body permissions must remain absent: $key", "cache-text", parts[1].asString)
                        val sourceKey = parts[2].asString
                        if (sourceKey == "loginHeader_$origin") {
                            // BaseSource.getHeaderMap(true) reads its existing
                            // persisted login header before the real HTTP call.
                            assertEquals("state.read", call.operation)
                        } else assertTrue("Unexpected source cache key: $key", sourceKey.startsWith("v_${origin}_"))
                    }
                }
            }
        }

        override fun close() {
            LegadoRuntime.setHostCallback(null)
            check(directory.toFile().deleteRecursively())
        }
    }

    private class Peer : Closeable {
        val held = CountDownLatch(1)
        val heldFinished = CountDownLatch(1)
        private val release = CountDownLatch(1)
        val requests = CopyOnWriteArrayList<String>()
        private val workers = Executors.newFixedThreadPool(2)
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = workers
            createContext("/") { exchange ->
                val isHeld = exchange.requestURI.path == "/held"
                requests += exchange.requestURI.toString()
                try {
                    if (isHeld) { held.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
                    val bytes = "source-callback-wire".toByteArray(Charsets.UTF_8)
                    exchange.sendResponseHeaders(200, bytes.size.toLong())
                    exchange.responseBody.use { it.write(bytes) }
                } catch (_: java.io.IOException) { /* The cancelled production HTTP caller owns the socket. */ }
                finally { exchange.close(); if (isHeld) heldFinished.countDown() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        fun releaseHeld() = release.countDown()
        override fun close() {
            releaseHeld()
            server.stop(0)
            workers.shutdownNow()
            check(workers.awaitTermination(5, TimeUnit.SECONDS))
        }
    }
}
