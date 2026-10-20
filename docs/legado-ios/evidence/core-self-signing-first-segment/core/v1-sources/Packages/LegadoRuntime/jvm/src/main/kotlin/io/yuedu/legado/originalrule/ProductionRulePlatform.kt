package io.yuedu.legado.originalrule

import com.google.gson.JsonObject
import io.yuedu.legado.RuntimeFailure
import io.yuedu.legado.RuntimeTask
import io.yuedu.legado.SourceJavaHost
import io.yuedu.legado.StrResponse
import io.yuedu.legado.ensureActiveForRuntime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.CoroutineContext

/**
 * First request boundary for the retained AnalyzeRule: one existing task, source
 * snapshot, cookie jar, deadline and ProductionHttpTransport. It deliberately
 * reuses SourceJavaHost's finite request preparation, including its explicit
 * unsupported dynamic-URL/options checks; it is not a second AnalyzeUrl parser.
 * No browser, persistent source state or App reader routing is implied here.
 */
@OptIn(InternalCoroutinesApi::class)
internal class ProductionRulePlatform(
    private val task: RuntimeTask,
    dispatch: (RuntimeTask, String, JsonObject) -> JsonObject,
) : RulePlatform() {
    private val javaHost = SourceJavaHost(task) { current, operation, input ->
        check(current === task && operation == "http.request") { "Unexpected original-rule host operation" }
        // Never fall back to a native/Swift transport after session shutdown.
        check(!task.session.closed.get()) { "Session is closed" }
        check(task.session.http != null) { "Original-rule requests require the JVM HTTP transport" }
        dispatch(current, operation, input)
    }

    override fun request(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext): StrResponse {
        context.ensureActive()
        task.ensureActiveForRuntime()
        check(!task.session.closed.get()) { "Session is closed" }
        // AnalyzeRule may use a child caller context. Its cancellation must abort
        // the same task-owned OkHttp call, not turn into a successful stack body.
        // A normally completed context does not cancel the task.
        val caller = context[Job]
        val cancellation = caller?.takeUnless { it === task.job }?.invokeOnCompletion(
            onCancelling = true, invokeImmediately = true,
        ) { cause ->
            if (cause != null) task.job.cancel(CancellationException("Original-rule caller cancelled").apply { initCause(cause) })
        }
        try {
            context.ensureActive()
            task.ensureActiveForRuntime()
            val response = javaHost.connect(url, headers, callTimeout)
            context.ensureActive()
            task.ensureActiveForRuntime()
            return response
        } catch (error: RuntimeFailure) {
            // AnalyzeRule.ajax preserves this typed capability error. Without
            // translation it would mistake an unsupported rule for network text.
            if (error.code == "UNSUPPORTED_CAPABILITY") throw UnsupportedRuleCapability(error.message.orEmpty())
            throw error
        } finally {
            cancellation?.dispose()
        }
    }
}
