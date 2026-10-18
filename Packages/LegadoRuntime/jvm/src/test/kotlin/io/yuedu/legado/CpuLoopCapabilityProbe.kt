package io.yuedu.legado

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.script.ScriptBindings
import com.script.rhino.RhinoScriptEngine
import kotlinx.coroutines.InternalCoroutinesApi
import org.htmlunit.corejs.javascript.BaseFunction
import org.htmlunit.corejs.javascript.Context
import org.htmlunit.corejs.javascript.Scriptable
import org.htmlunit.corejs.javascript.VarScope
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.LockSupport

/** No host override, network, JIT, or replacement instruction observer is used. */
internal object CpuLoopCapabilityProbe {
    const val ITERATIONS = 16_384
    val CHECKSUM = (0 until ITERATIONS).fold(0) { sum, value -> sum + (value xor 0x5a5a) }
    private const val CASE_MILLISECONDS = 5_000L
    private val workloads = ConcurrentHashMap<String, Workload>()
    private val runs = ConcurrentHashMap<String, RunState>()

    internal class RunState {
        val deadlineCpuSample = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val report = AtomicReference<JsonObject?>()
    }
    internal fun activeRun(taskId: String): RunState? = runs[taskId]

    private class Workload(val parentId: String, val taskId: String, val token: String, val parentDeadline: Long) {
        val signalled = CountDownLatch(1)
        val worker = AtomicReference<Thread?>()
        val signal = AtomicReference<JsonObject?>()
        @Volatile var deadline = 0L
        @Volatile var contextExited = false
    }

    @JvmStatic
    fun workload(task: RuntimeTask, input: JsonObject): JsonObject {
        val token = input["token"]?.asString ?: ""
        val state = workloads[token]
        if (state == null || state.taskId != task.id || task.deadlineEpochMs > state.parentDeadline) {
            throw RuntimeFailure("CPU_LOOP_PROBE_INVALID", "Workload lacks its unique controller registration or exceeds the parent deadline")
        }
        task.job.ensureActiveForRuntime()
        check(state.worker.compareAndSet(null, Thread.currentThread())) { "CPU workload cannot be reused" }
        state.deadline = task.deadlineEpochMs
        val scope = ScriptBindings().apply { chainTo(RhinoScriptEngine.newStandardTopLevel()) }
        scope.put("signal", scope, object : BaseFunction() {
            override fun call(cx: Context, scope: VarScope, thisObj: Scriptable, args: Array<Any>): Any {
                check(args.size == 3 && Context.toString(args[0]) == state.token)
                val count = Context.toNumber(args[1]).toLong()
                val checksum = Context.toNumber(args[2]).toLong()
                check(count == ITERATIONS.toLong() && checksum == CHECKSUM.toLong())
                check(state.signal.compareAndSet(null, jsonObject("token" to state.token,
                    "iterations" to count, "checksum" to checksum, "recordedNanoTime" to System.nanoTime())))
                // Nonblocking notification only. Success is NOT inferred here:
                // the controller must later sample this worker in interpretLoop.
                state.signalled.countDown()
                return 0
            }
        })
        val script = "var checksum=0; for(var i=0;i<$ITERATIONS;i++){checksum=(checksum+(i^0x5a5a))|0;}" +
            "signal(${gson.toJson(token)},i,checksum);" +
            // After the sole signal returns there are no host/Java calls. Once
            // sampled in this interpreter, cancellation cannot hit a host wait.
            "while(true){i=(i+1)|0;checksum=((checksum*3)^i)|0;}"
        try {
            RhinoScriptEngine.eval(script, scope, task.job)
            error("Unbounded CPU workload unexpectedly returned")
        } finally {
            state.contextExited = Context.getCurrentContext() == null
        }
    }

    @JvmStatic
    @OptIn(InternalCoroutinesApi::class)
    fun run(parent: RuntimeTask, input: JsonObject): JsonObject {
        parent.job.ensureActiveForRuntime()
        if (parent.deadlineEpochMs - System.currentTimeMillis() < 12_000) {
            throw RuntimeFailure("CPU_LOOP_PROBE_BUDGET_TOO_SHORT", "CPU probe needs at least twelve seconds of the original parent deadline")
        }
        check(input.size() <= 1 && input.entrySet().all { it.key == "timeoutMs" }) { "CPU workload selection is fixed" }
        val started = System.nanoTime()
        val state = RunState()
        check(runs.putIfAbsent(parent.id, state) == null)
        val report = jsonObject("suite" to "CpuLoopCapabilityProbe", "passed" to false,
            "interpreted" to true, "fixtureOnly" to true, "g4ValidationPassed" to false,
            "parentDeadlineEpochMs" to parent.deadlineEpochMs)
        val cases = JsonArray()
        val errors = mutableListOf<String>()
        val children = ConcurrentHashMap.newKeySet<String>()
        val ownedTokens = ConcurrentHashMap.newKeySet<String>()
        val executor = Executors.newSingleThreadExecutor { Thread(it, "legado-cpu-loop-probe").apply { isDaemon = true } }
        val cancellation = parent.job.invokeOnCompletion(onCancelling = true, invokeImmediately = true) {
            children.forEach { LegadoRuntime.cancel(it) }
        }
        var sessionsClosed = true
        fun cleanup(action: () -> Unit) { try { action() } catch (error: Exception) { synchronized(errors) { errors += error.toString() } } }
        try {
            for (name in listOf("public-cancel", "absolute-deadline")) {
                parent.job.ensureActiveForRuntime()
                val token = UUID.randomUUID().toString()
                val taskId = "cpu:$name:" + UUID.randomUUID()
                val registered = Workload(parent.id, taskId, token, parent.deadlineEpochMs)
                check(workloads.putIfAbsent(token, registered) == null); ownedTokens.add(token)
                val sessionEnvelope = LegadoRuntime.createSession(jsonObject("bookSourceUrl" to "https://cpu-probe.invalid/$token",
                    "mainJs" to "function search(){return [];}").toString())
                val session = parseObject(sessionEnvelope).also { check(it["ok"].asBoolean) }["sessionId"].asString
                var future: Future<String>? = null
                val evidence = jsonObject("name" to name, "passed" to false, "taskId" to taskId,
                    "sessionId" to session, "token" to token, "sessionEnvelope" to sessionEnvelope)
                cases.add(evidence)
                try {
                    children.add(taskId)
                    future = executor.submit<String> {
                        parent.job.ensureActiveForRuntime()
                        // Leave a measured margin for dispatch/cleanup; workload
                        // independently rejects an actual deadline past parent.
                        val budget = minOf(CASE_MILLISECONDS, parent.deadlineEpochMs - System.currentTimeMillis() - 3_000)
                        check(budget >= 2_000) { "Parent deadline leaves no bounded CPU case window" }
                        LegadoRuntime.execute(session, taskId, "cpuLoopWorkload", jsonObject("token" to token, "timeoutMs" to budget).toString())
                    }
                    check(registered.signalled.await(minOf(7_000, remaining(parent)), TimeUnit.MILLISECONDS)) { "JS iteration signal was not reached" }
                    val sample = sampleInterpreter(parent, registered, future)
                    evidence.add("signal", registered.signal.get()?.deepCopy())
                    evidence.add("cpuSample", sample)
                    evidence.addProperty("childDeadlineEpochMs", registered.deadline)
                    if (name == "public-cancel") {
                        evidence.addProperty("cancelRequestedNanoTime", System.nanoTime())
                        val cancel = LegadoRuntime.cancel(taskId)
                        evidence.addProperty("cancelEnvelope", cancel)
                        check(parseObject(cancel)["cancelled"].asBoolean) { "Public cancel did not find an active CPU task" }
                    } else state.deadlineCpuSample.countDown()
                    val envelope = future.get(minOf(7_000, remaining(parent)), TimeUnit.MILLISECONDS)
                    evidence.addProperty("operationEnvelope", envelope)
                    val result = parseObject(envelope)
                    val expected = if (name == "public-cancel") "CANCELLED" else "TIMEOUT"
                    check(!result["ok"].asBoolean && result["error"].asJsonObject["code"].asString == expected) { envelope }
                    check(registered.contextExited) { "Rhino context was not exited on the CPU worker" }
                    children.remove(taskId)
                    val recoveryId = "cpu:recovery:" + UUID.randomUUID()
                    children.add(recoveryId)
                    val recovery = executor.submit<JsonObject> {
                        check(Context.getCurrentContext() == null)
                        val response = LegadoRuntime.execute(session, recoveryId, "evaluate",
                            jsonObject("script" to "6*7", "timeoutMs" to minOf(2_000, remaining(parent))).toString())
                        jsonObject("operationEnvelope" to response, "workerId" to Thread.currentThread().id,
                            "contextExited" to (Context.getCurrentContext() == null))
                    }.get(minOf(3_000, remaining(parent)), TimeUnit.MILLISECONDS)
                    children.remove(recoveryId)
                    evidence.add("recovery", recovery)
                    val recoveryResult = parseObject(recovery["operationEnvelope"].asString)
                    check(recoveryResult["ok"].asBoolean && recoveryResult["result"].asInt == 42)
                    check(recovery["workerId"].asLong == registered.worker.get()!!.id && recovery["contextExited"].asBoolean)
                    evidence.addProperty("contextExited", true)
                    evidence.addProperty("passed", true)
                } finally {
                    if (future?.isDone != true) cleanup { LegadoRuntime.cancel(taskId) }
                    future?.let { pending -> cleanup {
                        val envelope = pending.get(3, TimeUnit.SECONDS)
                        if (!evidence.has("operationEnvelope")) evidence.addProperty("operationEnvelope", envelope)
                    } }
                    registered.signal.get()?.let { evidence.add("signal", it.deepCopy()) }
                    if (registered.deadline > 0) evidence.addProperty("childDeadlineEpochMs", registered.deadline)
                    evidence.addProperty("contextExited", registered.contextExited)
                    children.remove(taskId)
                    workloads.remove(token, registered); ownedTokens.remove(token)
                    var closePassed = false
                    evidence.addProperty("sessionClosed", false)
                    cleanup {
                        val closed = LegadoRuntime.closeSession(session)
                        evidence.addProperty("closeEnvelope", closed)
                        check(parseObject(closed)["ok"].asBoolean) { closed }
                        closePassed = true
                        evidence.addProperty("sessionClosed", true)
                    }
                    sessionsClosed = sessionsClosed && closePassed
                }
            }
        } catch (error: Throwable) {
            if (error is VirtualMachineError || error is ThreadDeath) throw error
            synchronized(errors) { errors += error.stackTraceToString() }
        } finally {
            cancellation.dispose()
            children.forEach { cleanup { LegadoRuntime.cancel(it) } }
            executor.shutdownNow()
            var stopped = false
            cleanup { stopped = executor.awaitTermination(3, TimeUnit.SECONDS) }
            ownedTokens.forEach { workloads.remove(it) }
            val registryEmpty = workloads.values.none { it.parentId == parent.id }
            report.add("cases", cases)
            report.add("cleanup", jsonObject("workerStopped" to stopped, "sessionsClosed" to sessionsClosed,
                "registryEmpty" to registryEmpty, "errors" to synchronized(errors) { errors.toList() }))
            report.addProperty("passed", cases.size() == 2 && cases.all { it.asJsonObject["passed"].asBoolean } &&
                stopped && sessionsClosed && registryEmpty && errors.isEmpty())
            report.addProperty("totalMilliseconds", (System.nanoTime() - started) / 1_000_000.0)
            state.report.set(report.deepCopy()); runs.remove(parent.id, state); state.finished.countDown()
        }
        parent.job.ensureActiveForRuntime()
        return report
    }

    private fun sampleInterpreter(parent: RuntimeTask, state: Workload, future: Future<String>): JsonObject {
        while (remaining(parent) > 0) {
            parent.job.ensureActiveForRuntime()
            check(!future.isDone) { "CPU task ended before a positive interpreter sample" }
            val stack = checkNotNull(state.worker.get()).stackTrace.toList()
            if (isCpuSample(stack)) return jsonObject("passed" to true, "sampledNanoTime" to System.nanoTime(),
                "workerId" to state.worker.get()!!.id, "stack" to stack.map { it.toString() })
            // Polls an external worker's actual execution frame, not a delay used
            // as proof. A positive sample is mandatory and bounded by deadline.
            LockSupport.parkNanos(1_000_000)
        }
        error("No positive interpreter sample before parent deadline")
    }

    internal fun isCpuSample(stack: List<StackTraceElement>): Boolean =
        stack.any { it.className == "org.htmlunit.corejs.javascript.Interpreter" && it.methodName == "interpretLoop" } &&
            stack.none { it.className.startsWith("io.yuedu.legado.CpuLoopCapabilityProbe\$workload\$") ||
                it.className.contains("NativeJavaMethod") || it.className == "io.yuedu.legado.SourceJavaHost" ||
                (it.className == "io.yuedu.legado.LegadoRuntime" && it.methodName == "dispatchHost") }

    private fun remaining(task: RuntimeTask): Long = (task.deadlineEpochMs - System.currentTimeMillis())
        .also { check(it > 0) { "Original parent deadline expired" } }
}
