package io.yuedu.legado

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import java.lang.reflect.InvocationTargetException

/** Only an explicitly created diagnostic task may override its own HTTP dispatcher. */
internal fun interface TaskHttpDispatcher {
    fun request(task: RuntimeTask, request: JsonObject): JsonObject
}

internal fun interface ProbeOperationRunner {
    fun execute(task: RuntimeTask, operation: String, input: JsonObject): JsonElement
}

/** OkHttp and the fixture remain in testRuntimeClasspath / opt-in probe payloads. */
internal object HttpWireDiagnosticBridge {
    fun run(task: RuntimeTask, runner: ProbeOperationRunner): JsonObject {
        try {
            val probe = Class.forName("io.yuedu.legado.OkHttpWireCapabilityProbe")
            return probe.getMethod("run", RuntimeTask::class.java, ProbeOperationRunner::class.java)
                .invoke(null, task, runner) as JsonObject
        } catch (error: InvocationTargetException) {
            throw error.targetException
        } catch (error: ClassNotFoundException) {
            throw RuntimeFailure("HTTP_WIRE_PROBE_NOT_PACKAGED", "Build the diagnostic payload with -PincludeEngineTests=true")
        } catch (error: LinkageError) {
            throw RuntimeFailure("HTTP_WIRE_PROBE_NOT_PACKAGED", "Wire probe dependency is unavailable: $error")
        }
    }
}
