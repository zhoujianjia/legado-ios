package io.yuedu.legado.originalrule

import com.google.gson.JsonObject
import com.script.ScriptException
import com.script.rhino.ScriptExecutionGuard
import io.legado.app.data.entities.BaseSource
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.yuedu.legado.RuntimeFailure
import io.yuedu.legado.RuntimeTask
import io.yuedu.legado.SourceJavaHost
import io.yuedu.legado.StrResponse
import io.yuedu.legado.ensureActiveForRuntime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import org.htmlunit.corejs.javascript.WrappedException
import kotlin.coroutines.CoroutineContext

/**
 * First request boundary for the retained AnalyzeRule: one existing task, source
 * snapshot, cookie jar, deadline and ProductionHttpTransport. It deliberately
 * expands the retained finite AnalyzeUrl script stages, then reuses
 * SourceJavaHost's single request/options preparation. Unported options remain
 * explicit capability failures; this is not the complete AnalyzeUrl port.
 * No browser, persistent source state or App reader routing is implied here.
 */
@OptIn(InternalCoroutinesApi::class)
internal class ProductionRulePlatform(
    private val task: RuntimeTask,
    dispatch: (RuntimeTask, String, JsonObject) -> JsonObject,
    private val environment: () -> RuleEnvironment,
) : RulePlatform() {
    override val cookie: RuleCookieHost = object : RuleCookieHost() {
        override fun getCookie(url: String): String = cookieOperation { task.session.cookies.getRuleCookie(url) }
        override fun getCookie(url: String, key: String?): String = cookieOperation { task.session.cookies.getRuleCookie(url, key) }
        override fun setCookie(url: String, value: String): Unit = cookieOperation { task.session.cookies.setRuleCookie(url, value) }
        override fun replaceCookie(url: String, value: String): Unit = cookieOperation { task.session.cookies.replaceRuleCookie(url, value) }
        override fun removeCookie(url: String): Unit = cookieOperation { task.session.cookies.removeRuleCookie(url) }
    }

    // Qualification is private constructor state, never a script-visible
    // internal/public bypass method or setter on the ordinary mainJs host.
    private val javaHost = SourceJavaHost(task, expandedOriginalUrl = true) { current, operation, input ->
        check(current === task && operation == "http.request") { "Unexpected original-rule host operation" }
        ensureOwnerOpen()
        // Never fall back to a native/Swift transport after session shutdown.
        check(!task.session.closed.get()) { "Session is closed" }
        check(task.session.http != null) { "Original-rule requests require the JVM HTTP transport" }
        dispatch(current, operation, input)
    }

    override fun request(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext): StrResponse =
        requestOwned(url, headers, callTimeout, context, null)

    override fun request(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext,
                         requester: RuleJsExtensions): StrResponse {
        check(requester.getRuleEnvironment() === environment()) { "Original-rule requester belongs to another environment" }
        return requestOwned(url, headers, callTimeout, context, requester.getSource())
    }

    private fun requestOwned(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext,
                             source: BaseSource?): StrResponse {
        ensureOwnerOpen()
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
            // Reuse Rhino's existing instruction observer and task Job. The
            // optional guard checks the same deadline/owner without a new timer,
            // job, thread or cancellation authority (and without inheriting Job).
            val guard = ScriptExecutionGuard {
                ensureOwnerOpen()
                task.ensureActiveForRuntime()
            }
            val scriptContext = context.minusKey(Job) + task.job + guard
            // JsExtensions.ajax/connect pass no search key/page/book/baseUrl.
            // Never inherit a parent search's inputs into a nested URL request.
            val expanded = AnalyzeUrl(url, source = source, environment = environment(),
                coroutineContext = scriptContext).ruleUrl
            val response = javaHost.connect(expanded, headers, callTimeout)
            // Environment close rejects late publication; it does not abort an
            // already-running host call or cancel a shared session. That call is
            // still bounded by this task's existing deadline/transport timeout.
            ensureOwnerOpen()
            context.ensureActive()
            task.ensureActiveForRuntime()
            return response
        } catch (error: Exception) {
            // Library initialization and host callbacks can fail after close or
            // cancellation too. Preserve those authorities even on exceptional
            // exits so ajax cannot turn a closed-owner failure into body text.
            ensureOwnerOpen()
            context.ensureActive()
            task.ensureActiveForRuntime()
            rethrowControlFailure(error)
            throw error
        } finally {
            cancellation?.dispose()
        }
    }

    private fun rethrowControlFailure(error: Exception) {
        // Only unwrap the known Rhino evaluation/invocation wrappers of an
        // escaping host failure. JS try/catch has already run, so caught errors
        // stay caught; ordinary JS errors retain the existing ajax text policy.
        var current: Throwable = error
        repeat(32) {
            current = when (val failure = current) {
                is UnsupportedRuleCapability -> throw failure
                is CancellationException -> throw failure
                is RuntimeFailure -> {
                    if (failure.code == "UNSUPPORTED_CAPABILITY")
                        throw UnsupportedRuleCapability(failure.message.orEmpty())
                    return
                }
                is ScriptException -> failure.cause ?: return
                is WrappedException -> failure.wrappedException ?: return
                else -> return
            }
        }
    }

    private fun ensureOwnerOpen() {
        try {
            environment().ensureOpen()
        } catch (closed: IllegalStateException) {
            // ajax catches ordinary exceptions as response text; a closed owner
            // must never publish that text as a late successful result.
            throw CancellationException("Original-rule environment is closed").apply { initCause(closed) }
        }
    }

    private inline fun <T> cookieOperation(body: () -> T): T {
        // The existing jar monitor makes validation + mutation atomic relative
        // to transport Set-Cookie handling and other rule environments.
        synchronized(task.session.cookies) {
            ensureOwnerOpen()
            task.ensureActiveForRuntime()
            check(!task.session.closed.get()) { "Session is closed" }
            return try { body() } catch (invalid: IllegalArgumentException) {
                throw UnsupportedRuleCapability(invalid.message.orEmpty())
            }
        }
    }
}
