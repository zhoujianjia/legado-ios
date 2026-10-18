package io.yuedu.legado

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.LockSupport

class CpuLoopCapabilityProbeTest {
    @Test(timeout = 40_000) fun publicCancelAndAbsoluteDeadlineInterruptVerifiedCpuLoopsAndRecoverOnSameWorker() {
        val session = session()
        try {
            val envelope = LegadoRuntime.execute(session, UUID.randomUUID().toString(), "cpuLoopCapabilityProbe", "{\"timeoutMs\":30000}")
            val output = Path.of("build/reports/cpu-loop/desktop-operation-envelope.json")
            Files.createDirectories(output.parent); Files.writeString(output, envelope)
            val operation = parseObject(envelope)
            assertTrue(envelope, operation["ok"].asBoolean)
            val report = operation["result"].asJsonObject
            assertTrue(report.toString(), report["passed"].asBoolean)
            assertFalse(report["g4ValidationPassed"].asBoolean)
            val cases = report["cases"].asJsonArray
            assertEquals(listOf("public-cancel", "absolute-deadline"), cases.map { it.asJsonObject["name"].asString })
            assertEquals(2, cases.map { it.asJsonObject["sessionId"].asString }.toSet().size)
            assertEquals(2, cases.map { it.asJsonObject["taskId"].asString }.toSet().size)
            cases.forEach { element ->
                val item = element.asJsonObject
                assertTrue(item["childDeadlineEpochMs"].asLong <= report["parentDeadlineEpochMs"].asLong)
                val signal = item["signal"].asJsonObject
                assertEquals(item["token"].asString, signal["token"].asString)
                assertEquals(CpuLoopCapabilityProbe.ITERATIONS, signal["iterations"].asInt)
                assertEquals(CpuLoopCapabilityProbe.CHECKSUM, signal["checksum"].asInt)
                val sample = item["cpuSample"].asJsonObject
                assertTrue(sample["passed"].asBoolean)
                assertTrue(sample["sampledNanoTime"].asLong >= signal["recordedNanoTime"].asLong)
                assertTrue(item["contextExited"].asBoolean && item["sessionClosed"].asBoolean)
                val recovery = item["recovery"].asJsonObject
                assertEquals(sample["workerId"], recovery["workerId"])
                assertEquals(42, parseObject(recovery["operationEnvelope"].asString)["result"].asInt)
                if (item["name"].asString == "public-cancel") {
                    assertTrue(item["cancelRequestedNanoTime"].asLong >= sample["sampledNanoTime"].asLong)
                }
            }
            assertCleanup(report)
        } finally { LegadoRuntime.closeSession(session) }
    }

    @Test(timeout = 20_000) fun parentPublicCancellationCancelsAlreadySampledChildAndStopsOwnedWorker() {
        val session = session()
        val task = "cpu-parent:" + UUID.randomUUID()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val future = executor.submit<String> { LegadoRuntime.execute(session, task, "cpuLoopCapabilityProbe", "{\"timeoutMs\":30000}") }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
            var run: CpuLoopCapabilityProbe.RunState? = null
            while (run == null && System.nanoTime() < deadline) {
                assertFalse("Controller returned before registration", future.isDone)
                run = CpuLoopCapabilityProbe.activeRun(task)
                if (run == null) LockSupport.parkNanos(1_000_000) // Polls actual controller registration.
            }
            val state = checkNotNull(run)
            assertTrue(state.deadlineCpuSample.await(8, TimeUnit.SECONDS))
            val cancel = parseObject(LegadoRuntime.cancel(task))
            assertTrue(cancel["cancelled"].asBoolean)
            val response = parseObject(future.get(4, TimeUnit.SECONDS))
            assertFalse(response["ok"].asBoolean)
            assertEquals("CANCELLED", response["error"].asJsonObject["code"].asString)
            assertTrue(state.finished.await(1, TimeUnit.SECONDS))
            val partial = checkNotNull(state.report.get())
            val output = Path.of("build/reports/cpu-loop/parent-cancel-partial.json")
            Files.createDirectories(output.parent); Files.writeString(output, partial.toString())
            val child = partial["cases"].asJsonArray.last().asJsonObject
            assertEquals("CANCELLED", parseObject(child["operationEnvelope"].asString)["error"].asJsonObject["code"].asString)
            val cleanup = partial["cleanup"].asJsonObject
            assertTrue(cleanup["workerStopped"].asBoolean && cleanup["sessionsClosed"].asBoolean && cleanup["registryEmpty"].asBoolean)
            assertNull(CpuLoopCapabilityProbe.activeRun(task))
        } finally {
            LegadoRuntime.cancel(task); LegadoRuntime.closeSession(session); executor.shutdownNow()
            assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS))
        }
    }

    @Test fun unregisteredWorkloadAndInsufficientParentBudgetCannotPass() {
        val session = session()
        try {
            val unregistered = parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), "cpuLoopWorkload", "{\"token\":\"unregistered\"}"))
            assertEquals("CPU_LOOP_PROBE_INVALID", unregistered["error"].asJsonObject["code"].asString)
            val short = parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), "cpuLoopCapabilityProbe", "{\"timeoutMs\":2000}"))
            assertEquals("CPU_LOOP_PROBE_BUDGET_TOO_SHORT", short["error"].asJsonObject["code"].asString)
        } finally { LegadoRuntime.closeSession(session) }
    }

    @Test fun hostAndSignalFramesCannotQualifyAsCpuEvidence() {
        val interpreter = StackTraceElement("org.htmlunit.corejs.javascript.Interpreter", "interpretLoop", "Interpreter.java", 1)
        assertTrue(CpuLoopCapabilityProbe.isCpuSample(listOf(interpreter)))
        for (name in listOf("io.yuedu.legado.CpuLoopCapabilityProbe\$workload\$1", "org.htmlunit.corejs.javascript.NativeJavaMethod", "io.yuedu.legado.SourceJavaHost")) {
            assertFalse(CpuLoopCapabilityProbe.isCpuSample(listOf(StackTraceElement(name, "call", "X.kt", 1), interpreter)))
        }
        assertFalse(CpuLoopCapabilityProbe.isCpuSample(emptyList()))
    }

    private fun session() = parseObject(LegadoRuntime.createSession("{\"bookSourceUrl\":\"https://cpu-controller.invalid\",\"mainJs\":\"function search(){return [];}\"}"))["sessionId"].asString
    private fun assertCleanup(report: com.google.gson.JsonObject) {
        val cleanup = report["cleanup"].asJsonObject
        assertTrue(cleanup.toString(), cleanup["workerStopped"].asBoolean && cleanup["sessionsClosed"].asBoolean && cleanup["registryEmpty"].asBoolean)
        assertEquals(0, cleanup["errors"].asJsonArray.size())
    }
}
