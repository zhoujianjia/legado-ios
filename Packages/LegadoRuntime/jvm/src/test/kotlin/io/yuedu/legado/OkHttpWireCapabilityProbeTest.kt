package io.yuedu.legado

import com.google.gson.JsonObject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class OkHttpWireCapabilityProbeTest {
    @Test(timeout = 60_000) fun facadeExecutesSevenRealRequestsAndKeepsOuterSessionUntouched() {
        val created = parseObject(LegadoRuntime.createSession(jsonObject("bookSourceUrl" to "https://outer.invalid",
            "mainJs" to "function search(){return [];}").toString()))
        val id = created["sessionId"].asString
        try {
            fun call(operation: String, input: JsonObject = JsonObject()): JsonObject = parseObject(
                LegadoRuntime.execute(id, UUID.randomUUID().toString(), operation, input.toString())).also {
                    assertTrue(it.toString(), it["ok"].asBoolean)
                }
            call("evaluate", jsonObject("script" to "source.putVariable('outer-state');cache.put('outer','keep');'ok'"))
            val before = call("snapshot")["result"]
            val envelope = LegadoRuntime.execute(id, UUID.randomUUID().toString(), "httpWireCapabilityProbe",
                jsonObject("timeoutMs" to 50_000).toString())
            val output = Path.of("build", "reports", "http-wire", "desktop-report.json")
            Files.createDirectories(output.parent)
            Files.writeString(output.resolveSibling("desktop-operation-envelope.json"), envelope)
            val operation = parseObject(envelope)
            assertTrue(operation.toString(), operation["ok"].asBoolean)
            val report = operation["result"].asJsonObject
            Files.createDirectories(output.parent); Files.writeString(output, report.toString())
            assertTrue(report.toString(), report["passed"].asBoolean)
            assertFalse(report["g4ValidationPassed"].asBoolean)
            assertEquals(report["parentDeadlineEpochMs"], report["childDeadlineEpochMs"])
            assertEquals(before, call("snapshot")["result"])
            val raw = report["wireSnapshot"].asJsonObject["requests"].asJsonArray
            assertEquals(7, raw.size())
            raw.forEach {
                val request = it.asJsonObject
                assertEquals("HTTP/1.1", request["httpVersion"].asString)
                assertTrue(request["responseWritten"].asBoolean)
                assertTrue(request.has("rawHeadBase64")); assertTrue(request.has("rawRequestSHA256"))
            }
            val chain = report["readingChain"].asJsonObject
            assertEquals(7, chain["snapshot"].asJsonObject["requests"].asJsonArray.size())
            assertEquals(1, chain["sharedCalls"].asInt)
            assertEquals(ReferenceLoopbackFixture.CONTENT_ONE, chain["content"].asString)
            assertEquals(listOf("login.begin", "login.returned", "search", "details", "toc", "content", "batch.returned"),
                report["steps"].asJsonArray.map { it.asString })
            val nullReadbacks = report["cacheReadbackBeforeBatch"].asJsonObject
            assertEquals(2, nullReadbacks.size()); assertTrue(nullReadbacks.entrySet().all { it.value.isJsonNull })
            assertTrue(report["cleanup"].asJsonObject["isolatedSessionClosed"].asBoolean)
            assertEquals(0, report["cleanup"].asJsonObject["errors"].asJsonArray.size())
        } finally { LegadoRuntime.closeSession(id) }
    }

    @Test(timeout = 15_000) fun cancellationWhileWaitingForResponseHeadersClosesRealCall() {
        exerciseCancellation(afterHeaders = false)
    }

    @Test(timeout = 15_000) fun cancellationAfterHeadersUnblocksBodyRead() {
        exerciseCancellation(afterHeaders = true)
    }

    private fun exerciseCancellation(afterHeaders: Boolean) {
        val server = ReferenceLoopbackFixture(if (afterHeaders) ReferenceLoopbackFixture.Mode.BLOCK_AFTER_HEADERS else ReferenceLoopbackFixture.Mode.BLOCK_BEFORE_HEADERS)
        val task = task(10_000)
        val clientHeaders = CountDownLatch(1)
        val transport = ProbeOkHttpTransport(task, server.origin) { clientHeaders.countDown() }
        val worker = Executors.newSingleThreadExecutor()
        try {
            val result = worker.submit<Throwable?> {
                try { transport.request(task, prepared(server.origin + "/blocked")); null } catch (error: Throwable) { error }
            }
            assertTrue("Peer must receive the real request", server.requestArrived.await(5, TimeUnit.SECONDS))
            if (afterHeaders) {
                assertTrue(server.headersSent.await(5, TimeUnit.SECONDS))
                assertTrue("Client must have returned headers while the body remains withheld", clientHeaders.await(5, TimeUnit.SECONDS))
            }
            task.job.cancel()
            val failure = result.get(3, TimeUnit.SECONDS)
            assertTrue(failure.toString(), failure is CancellationException)
        } finally {
            task.job.cancel(); transport.close(); server.close(); worker.shutdownNow()
            assertTrue(worker.awaitTermination(2, TimeUnit.SECONDS))
        }
        assertTrue(transport.cleanup().toString(), transport.cleanup()["passed"].asBoolean)
        assertTrue(server.cleanup().entrySet().all { it.value.asBoolean })
    }

    @Test(timeout = 10_000) fun absoluteDeadlineBoundsBlockedResponseWithoutResettingTask() {
        ReferenceLoopbackFixture(ReferenceLoopbackFixture.Mode.BLOCK_BEFORE_HEADERS).use { server ->
            val task = task(700)
            val started = System.nanoTime()
            val transport = ProbeOkHttpTransport(task, server.origin)
            try {
                val failure = try { transport.request(task, prepared(server.origin + "/blocked")); null } catch (error: IOException) { error }
                assertTrue(failure.toString(), failure is InterruptedIOException)
                assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 3_000)
                assertFalse(task.job.isCancelled)
            } finally { transport.close(); task.job.cancel() }
            assertTrue(transport.cleanup()["passed"].asBoolean)
        }
    }

    @Test(timeout = 10_000) fun responseDuplicatesAndEachSetCookieSurviveWithoutCommaJoining() {
        ReferenceLoopbackFixture(ReferenceLoopbackFixture.Mode.MULTI_COOKIE).use { server ->
            val task = task(8_000)
            ProbeOkHttpTransport(task, server.origin).use { transport ->
                val sessionTask = RuntimeTask(task.id, RuntimeSession("cookies", jsonObject("bookSourceUrl" to server.origin)),
                    task.job, task.deadlineEpochMs, transport)
                val java = SourceJavaHost(sessionTask) { t, operation, request ->
                    assertEquals("http.request", operation); transport.request(t, request)
                }
                assertEquals("cookies", java.connect(server.origin + "/cookies").body())
                assertEquals("one", sessionTask.session.cookies.getKey(server.origin, "first"))
                assertEquals("two", sessionTask.session.cookies.getKey(server.origin, "second"))
                val response = transport.responses()[0].asJsonObject
                val headers = response["headers"].asJsonObject
                assertEquals(listOf("first=one; Path=/", "second=two; Expires=Wed, 09 Jun 2038 10:18:14 GMT; Path=/"),
                    headers["Set-Cookie"].asJsonArray.map { it.asString })
                assertEquals(listOf("one", "two"), headers["X-Repeated"].asJsonArray.map { it.asString })
                assertEquals(2, response["headerEntries"].asJsonArray.count { it.asJsonObject["name"].asString.equals("Set-Cookie", true) })
            }
            task.job.cancel()
        }
    }

    @Test(timeout = 10_000) fun arbitraryHostAndOtherPortAreRejectedBeforeAnyWireRequest() {
        ReferenceLoopbackFixture().use { server ->
            val task = task(8_000)
            ProbeOkHttpTransport(task, server.origin).use { transport ->
                for (url in listOf("https://example.com/public", "http://127.0.0.1:1/other", "http://user@${URI_AUTHORITY(server.origin)}/bad")) {
                    try { transport.request(task, prepared(url)); fail("Must reject $url") } catch (_: IllegalArgumentException) { }
                }
                assertEquals(0, server.requests().size)
            }
            task.job.cancel()
        }
    }

    @Test(timeout = 10_000) fun unknownFixtureRouteIsFailureAndOwnedResourcesStillClose() {
        val server = ReferenceLoopbackFixture()
        val task = task(5_000)
        val transport = ProbeOkHttpTransport(task, server.origin)
        try {
            try { transport.request(task, prepared(server.origin + "/unexpected")); fail("Unexpected route cannot succeed") }
            catch (_: IOException) { }
            try { server.assertHealthy(); fail("Peer must retain its protocol failure") } catch (_: AssertionError) { }
        } finally { transport.close(); server.close(); task.job.cancel() }
        assertTrue(transport.cleanup()["passed"].asBoolean)
        assertTrue(server.cleanup().entrySet().all { it.value.asBoolean })
    }

    @Test(timeout = 10_000) fun alreadyCancelledTaskCannotIssueRequestOrLeaveCallsRegistered() {
        ReferenceLoopbackFixture().use { server ->
            val task = task(5_000).also { it.job.cancel() }
            ProbeOkHttpTransport(task, server.origin).use { transport ->
                try { transport.request(task, prepared(server.origin + "/login")); fail("Cancelled task cannot execute") }
                catch (_: CancellationException) { }
                assertEquals(0, server.requests().size)
            }
        }
    }

    private fun task(timeout: Long) = RuntimeTask(UUID.randomUUID().toString(), RuntimeSession("test", JsonObject()), Job(), System.currentTimeMillis() + timeout)
    private fun prepared(url: String) = LegadoHttpRequestPreprocessor.prepare(url, "GET", mapOf("Accept-Encoding" to "identity"), null, null)
        .apply { addProperty("timeoutMs", 30_000) }
    private fun URI_AUTHORITY(origin: String) = java.net.URI(origin).rawAuthority
}
