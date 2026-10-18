package io.yuedu.legado

import com.google.gson.JsonObject
import java.lang.reflect.InvocationTargetException

/** CPU workloads/controllers are confined to explicitly opted-in test payloads. */
internal object CpuLoopDiagnosticBridge {
    fun run(task: RuntimeTask, operation: String, input: JsonObject): JsonObject {
        try {
            val probe = Class.forName("io.yuedu.legado.CpuLoopCapabilityProbe")
            val method = if (operation == "cpuLoopWorkload") "workload" else "run"
            return probe.getMethod(method, RuntimeTask::class.java, JsonObject::class.java)
                .invoke(null, task, input) as JsonObject
        } catch (error: InvocationTargetException) {
            throw error.targetException
        } catch (_: ClassNotFoundException) {
            throw RuntimeFailure("CPU_LOOP_PROBE_NOT_PACKAGED", "Build the diagnostic payload with -PincludeEngineTests=true")
        } catch (error: LinkageError) {
            throw RuntimeFailure("CPU_LOOP_PROBE_NOT_PACKAGED", "CPU probe dependency is unavailable: $error")
        }
    }
}
