package io.yuedu.legado.originalrule

import com.google.gson.JsonObject
import com.script.rhino.ScriptExecutionGuard
import io.legado.app.data.entities.BaseSource
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.analyzeRule.RuleDataInterface
import io.yuedu.legado.RuntimeTask
import io.yuedu.legado.RuntimeHttpRequestExecutor
import io.yuedu.legado.StrResponse
import io.yuedu.legado.ensureActiveForRuntime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import kotlin.coroutines.CoroutineContext

/**
 * First request boundary for the retained AnalyzeRule: one existing task, source
 * snapshot, cookie jar, deadline and ProductionHttpTransport. It deliberately
 * runs retained AnalyzeUrl header, URL and request stages, then reuses the
 * single HTTP dispatch/response boundary shared with mainJs. Unported options remain
 * explicit capability failures; this is not the complete AnalyzeUrl port.
 * No browser, persistent source state or App reader routing is implied here.
 */
@OptIn(InternalCoroutinesApi::class)
internal class ProductionRulePlatform(
    private val task: RuntimeTask,
    dispatch: (RuntimeTask, String, JsonObject) -> JsonObject,
    private val environment: () -> RuleEnvironment,
) : RulePlatform() {
    override val userAgent: String? get() = task.session.options.userAgent
    override val cookie: RuleCookieHost = object : RuleCookieHost() {
        override fun getCookie(url: String): String = cookieOperation { task.session.cookies.getRuleCookie(url) }
        override fun getCookie(url: String, key: String?): String = cookieOperation { task.session.cookies.getRuleCookie(url, key) }
        override fun setCookie(url: String, value: String): Unit = cookieOperation { task.session.cookies.setRuleCookie(url, value) }
        override fun replaceCookie(url: String, value: String): Unit = cookieOperation { task.session.cookies.replaceRuleCookie(url, value) }
        override fun removeCookie(url: String): Unit = cookieOperation { task.session.cookies.removeRuleCookie(url) }
    }

    private val http = RuntimeHttpRequestExecutor(task) { current, operation, input ->
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

    override fun ajax(url: String, context: CoroutineContext, requester: RuleJsExtensions,
                       ruleData: RuleDataInterface?): String? {
        check(requester.getRuleEnvironment() === environment()) { "Original-rule requester belongs to another environment" }
        return requestOwned(url, null, null, context, requester.getSource(), ruleData = ruleData).body()
    }

    override fun requestUrl(url: String, source: BaseSource?, baseUrl: String, context: CoroutineContext,
                            key: String?, page: Int?): StrResponse {
        check(source == null || source.getRuleEnvironment() === environment()) { "Original source belongs to another environment" }
        return requestOwned(url, null, null, context, source, baseUrl, key, page, recoverExecutionErrors = false)
    }

    private fun requestOwned(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext,
                             source: BaseSource?, baseUrl: String = "", key: String? = null, page: Int? = null,
                             ruleData: RuleDataInterface? = null, recoverExecutionErrors: Boolean = true): StrResponse {
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
            // JsExtensions default calls have no key/page/book/baseUrl. Only
            // AnalyzeRule's one-argument ajax override explicitly passes book.
            val explicitHeaders = GSON.fromJsonObject<Map<String, String>>(headers).getOrNull()
            val analyzed = AnalyzeUrl(url, key = key, page = page, baseUrl = baseUrl, source = source, ruleData = ruleData, environment = environment(),
                coroutineContext = scriptContext, headerMapF = explicitHeaders, callTimeout = callTimeout)
            // As in JsExtensions/AnalyzeRule, construction is outside recovery.
            // Only getStrResponse-equivalent execution errors become text.
            val response = try {
                val request = analyzed.prepareRequest { target -> task.session.cookies.getCookie(target.toHttpUrl().toString()) }
                http.execute(request, recoverIoFailure = false, transform = analyzed::transformResponse)
            } catch (error: Exception) {
                ensureOwnerOpen(); context.ensureActive(); task.ensureActiveForRuntime()
                rethrowRuleControlFailure(error)
                // WebBook owns login/error handling and must receive ordinary
                // execution errors; only JsExtensions-style calls recover here.
                if (!recoverExecutionErrors) throw error
                log("原规则请求执行失败: $error")
                val errorRequest = try { Request.Builder().url(analyzed.url).build() }
                    catch (_: Exception) { Request.Builder().url("http://localhost/").build() }
                val raw = Response.Builder().request(errorRequest).code(200).message("OK").protocol(Protocol.HTTP_1_1).build()
                StrResponse(raw.request.url.toString(), 200, error.stackTraceToString(), emptyMap(), raw)
            }
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
            rethrowRuleControlFailure(error)
            throw error
        } finally {
            cancellation?.dispose()
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
