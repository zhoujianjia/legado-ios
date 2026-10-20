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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.runBlocking
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
 * Additional finite platform methods below use the explicit App owner; they do
 * not grant a general browser/WebJS host or independent source authority.
 */
@OptIn(InternalCoroutinesApi::class)
internal class ProductionRulePlatform(
    private val initialTask: RuntimeTask,
    dispatch: (RuntimeTask, String, JsonObject) -> JsonObject,
    private val taskProvider: (() -> RuntimeTask)? = null,
    private val environment: () -> RuleEnvironment,
) : RulePlatform() {
    private val task: RuntimeTask get() = taskProvider?.invoke() ?: initialTask
    private val hostDispatch = dispatch
    override val userAgent: String? get() = task.session.options.userAgent
    override fun log(value: Any?): Any? = if (task.sensitiveSourceOperation) value else super.log(value)
    override fun ruleDiagnostic(error: Throwable, loggerName: String, message: String) {
        if (!task.sensitiveSourceOperation) super.ruleDiagnostic(error, loggerName, message)
    }
    override fun protectLoginDiagnostics(source: BaseSource) {
        check(source.getRuleEnvironment() === environment()) { "Login source belongs to another environment" }
        task.sensitiveSourceOperation = true
    }
    override fun updateLoginUI(source: BaseSource, data: Map<String, Any?>?) {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        check(source.getRuleEnvironment() === environment()) { "Login source belongs to another environment" }
        if (!task.loginUIEventsEnabled) unsupportedRule("this task cannot update login UI")
        val entries = data?.let { values ->
            require(values.size <= 4096) { "Login UI data contains too many entries" }
            io.yuedu.legado.requireRepresentableLoginUIKeys(values.keys)
            com.google.gson.JsonArray().apply {
                var capturedBytes = 0
                // Capture nullable toString values now; later Map mutations cannot
                // change an accepted event. Preserve original Map iteration order.
                values.forEach { (key, value) ->
                    task.ensureActiveForRuntime()
                    val text = value?.toString()
                    // Reject before accumulating a large Map/escaped JSON tree.
                    // The task also checks exact total bytes including envelope.
                    if (key.length > 512 * 1024 || (text?.length ?: 0) > 512 * 1024)
                        throw io.yuedu.legado.RuntimeFailure("STATE_LIMIT", "Login UI data exceeds its task budget")
                    val entry = io.yuedu.legado.jsonObject("key" to key, "value" to text)
                    val bytes = entry.toString().toByteArray(Charsets.UTF_8).size
                    if (bytes > 512 * 1024 - capturedBytes)
                        throw io.yuedu.legado.RuntimeFailure("STATE_LIMIT", "Login UI data exceeds its task budget")
                    capturedBytes += bytes
                    add(entry)
                }
            }
        }
        task.recordLoginUIEvent(io.yuedu.legado.jsonObject("kind" to "updateData", "entries" to entries))
    }
    override fun renderLoginUI(source: BaseSource, deltaUp: Boolean) {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        check(source.getRuleEnvironment() === environment()) { "Login source belongs to another environment" }
        task.recordLoginUIEvent(io.yuedu.legado.jsonObject("kind" to "render", "deltaUp" to deltaUp))
    }
    private data class PreparedLoginBrowser(val initialURL: String, val initialHeaders: Map<String, String>,
        val prefetchedHTML: String?, val input: JsonObject, val page: io.yuedu.legado.OriginalWebJsPages.Page?)
    private fun prepareLoginBrowser(source: BaseSource, url: String, title: String, html: String? = null): PreparedLoginBrowser {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        check(source.getRuleEnvironment() === environment()) { "Browser source belongs to another environment" }
        if (!task.sourceBrowserAllowed) unsupportedRule("original browser requires an explicit login task")
        require(url.length < 65_536 && title.toByteArray(Charsets.UTF_8).size <= 8_192) { "Browser request text exceeds its budget" }
        val owner = task.session.options.stateOwner ?: unsupportedRule("original browser requires the checked source owner")
        val page = html?.let { task.session.originalPages.register(task) }
        try {
        // Locked explicit HTML is injected before POST can overwrite the body.
        val preparedHTML = html?.let { page!!.prepareHTML(it) }
        // Locked WebViewModel74-78 captures URL/headers before the same
        // AnalyzeUrl performs POST. The initial HTML is not localHtml/WebJS.
        val analyze = AnalyzeUrl(url, source = source, environment = environment(), coroutineContext = source.getRuleCoroutineContext())
        val initialURL = analyze.url
        val initialHeaders = LinkedHashMap(analyze.headerMap)
        val parsed = java.net.URI(initialURL)
        if (parsed.scheme?.lowercase() !in setOf("http", "https")) unsupportedRule("original browser URL scheme")
        val prefetchedHTML = if (analyze.isPost()) {
            task.ensureActiveForRuntime()
            // Conservative fact: HTTP may escape before cancellation. It is
            // neither a successful response nor an accepted credential write.
            task.recordHostEffect("sourceBrowserPostMaySend")
            val fetched = runBlocking(source.getRuleCoroutineContext()) {
                analyze.getStrResponseAwait(useWebView = false)
            }
            task.recordHostEffect("sourceBrowserPostResponseReceived")
            fetched.body().also { body ->
                if (body.toByteArray(Charsets.UTF_8).size > 4 * 1024 * 1024)
                    throw io.yuedu.legado.RuntimeFailure("STATE_LIMIT", "Browser prefetch exceeds its byte budget")
            }
        } else preparedHTML
        if (prefetchedHTML != null && prefetchedHTML.toByteArray(Charsets.UTF_8).size > 4 * 1024 * 1024)
            throw io.yuedu.legado.RuntimeFailure("STATE_LIMIT", "Prepared browser HTML exceeds its byte budget")
        page?.preparedBody(prefetchedHTML.orEmpty())
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        val input = io.yuedu.legado.jsonObject("owner" to owner, "sourceURL" to source.getKey(),
            "url" to initialURL, "title" to title, "headers" to initialHeaders)
        // Absent GET versus present empty POST is observable in original
        // confirm(): only absent HTML permits the original HTTP refetch.
        if (prefetchedHTML != null) input.addProperty("prefetchedHTML", prefetchedHTML)
        if (page != null) input.add("localPage", page.metadata())
        return PreparedLoginBrowser(initialURL, initialHeaders, prefetchedHTML, input, page)
        } catch (error: Exception) {
            if (page != null) task.session.originalPages.close(page)
            throw error
        }
    }

    override fun startLoginBrowser(source: BaseSource, url: String, title: String) {
        startLoginBrowser(source, url, title, null)
    }
    override fun startLoginBrowser(source: BaseSource, url: String, title: String, html: String?) {
        val initial = prepareLoginBrowser(source, url, title, html)
        try {
            val reply = hostDispatch(task, "source.browser", initial.input)
            ensureOwnerOpen(); task.ensureActiveForRuntime()
            if (reply["presented"]?.let { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean && it.asBoolean } != true)
                throw io.yuedu.legado.RuntimeFailure("BROWSER_NOT_PRESENTED", "The original browser was not presented")
        } catch (error: Exception) {
            if (initial.page != null) task.session.originalPages.close(initial.page)
            throw error
        }
    }

    override fun awaitLoginBrowser(source: BaseSource, url: String, title: String, refetchAfterSuccess: Boolean): StrResponse {
        return awaitLoginBrowser(source, url, title, refetchAfterSuccess, null)
    }
    override fun awaitLoginBrowser(source: BaseSource, url: String, title: String, refetchAfterSuccess: Boolean, html: String?): StrResponse {
        val initial = prepareLoginBrowser(source, url, title, html)
        try {
        val input = initial.input
        input.addProperty("awaitsResult", true)
        input.addProperty("refetchAfterSuccess", refetchAfterSuccess)
        val reply = hostDispatch(task, "source.browser", input)
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        fun requiredText(name: String): String {
            val raw = reply[name]
            if (raw == null || !raw.isJsonPrimitive || !raw.asJsonPrimitive.isString)
                throw io.yuedu.legado.RuntimeFailure("INVALID_BROWSER_RESULT", "The awaited browser omitted its terminal result")
            return raw.asString
        }
        val mode = requiredText("mode")
        val body: String
        val responseURL: String
        if (refetchAfterSuccess) {
            if (mode != "refetchConfirmed")
                throw io.yuedu.legado.RuntimeFailure("INVALID_BROWSER_RESULT", "Awaited refetch needs an actual confirmation")
            // The synchronous Host has returned. Reuse the original AnalyzeUrl
            // and HTTP/Cookie owners on this same task, never reenter the App
            // source gate from a MainActor page callback. Locked owner behavior
            // snapshots the first headers, reparses the original input URL, and
            // returns its initial analyzed URL rather than HTTP redirect URL.
            body = initial.prefetchedHTML ?: runBlocking(source.getRuleCoroutineContext()) {
                AnalyzeUrl(url, source = source, environment = environment(),
                    coroutineContext = source.getRuleCoroutineContext(), headerMapF = initial.initialHeaders)
                    .getStrResponseAwait(useWebView = false).body()
            }
            responseURL = initial.initialURL.ifEmpty { url }
        } else {
            if (mode != "response")
                throw io.yuedu.legado.RuntimeFailure("INVALID_BROWSER_RESULT", "Awaited page needs its DOM response")
            body = requiredText("body")
            responseURL = requiredText("finalURL").ifEmpty { url }
        }
        if (body.isEmpty()) throw io.yuedu.legado.RuntimeFailure("BROWSER_EMPTY_RESULT", "The awaited browser returned an empty result")
        if (body.toByteArray(Charsets.UTF_8).size > 4 * 1024 * 1024 || responseURL.length >= 65_536)
            throw io.yuedu.legado.RuntimeFailure("STATE_LIMIT", "The awaited browser result exceeds its budget")
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        // JsExtensions426-428 uses the original StrResponse(url,body) owner
        // constructor: synthetic raw200/OK/HTTP1.1 and empty response headers.
        val request = try { Request.Builder().url(responseURL).build() }
            catch (_: IllegalArgumentException) { Request.Builder().url("http://localhost/").build() }
        val raw = Response.Builder().request(request).code(200).message("OK").protocol(Protocol.HTTP_1_1).build()
        return StrResponse(raw.request.url.toString(), 200, body, emptyMap(), raw)
        } finally {
            if (initial.page != null) task.session.originalPages.close(initial.page)
        }
    }
    private val fixedAppCookieOwner = if (initialTask.session.options.usesAppCookieOwner && taskProvider == null) AppCookieOwnerClient(initialTask, dispatch) else null
    private val appCookieOwner: AppCookieOwnerClient? get() {
        if (taskProvider == null) return fixedAppCookieOwner
        val current = task
        if (!current.session.options.usesAppCookieOwner) return null
        return current.appCookieOwner ?: AppCookieOwnerClient(current, hostDispatch).also { current.appCookieOwner = it }
    }
    init { if (fixedAppCookieOwner != null) initialTask.appCookieOwner = fixedAppCookieOwner }
    override val cookie: RuleCookieHost = object : RuleCookieHost() {
        override fun getCookie(url: String): String = readCookie(url)
        override fun getCookie(url: String, key: String?): String = readCookie(url, key)
        override fun setCookie(url: String, value: String?): Unit = cookieWrite("set", url, value.orEmpty()) { task.session.cookies.setRuleCookie(url, value.orEmpty()) }
        override fun replaceCookie(url: String, value: String): Unit = cookieWrite("replace", url, value) { task.session.cookies.replaceRuleCookie(url, value) }
        override fun removeCookie(url: String): Unit = cookieWrite("remove", url) { task.session.cookies.removeRuleCookie(url) }
        override fun setWebCookie(url: String, value: String) {
            ensureOwnerOpen(); task.ensureActiveForRuntime()
            val owner = appCookieOwner ?: unsupportedRule("original CookieStore.setWebCookie requires the explicit App owner")
            owner.setWebCookie(url, value)
        }
        override fun clear() {
            ensureOwnerOpen(); task.ensureActiveForRuntime()
            val owner = appCookieOwner ?: unsupportedRule("original CookieStore.clear requires the explicit App owner")
            owner.clear()
        }
    }

    override fun exploreOwnerScope(source: BaseSource): String {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        check(source.getRuleEnvironment() === environment()) { "Source belongs to another environment" }
        val owner = task.session.options.stateOwner ?: unsupportedRule("original explore needs the explicit source owner")
        val result = hostDispatch(task, "explore.owner.scope", io.yuedu.legado.jsonObject("owner" to owner, "sourceURL" to source.getKey()))
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        val scope = result["scope"]
        if (scope == null || !scope.isJsonPrimitive || !scope.asJsonPrimitive.isString || scope.asString.isEmpty()
            || scope.asString.toByteArray(Charsets.UTF_8).size > 32_768) throw RulePersistenceException("Original explore owner omitted its bounded stable scope")
        return scope.asString
    }

    override fun originalRateDelayBudgetMillis(source: BaseSource): Long {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        check(source.getRuleEnvironment() === environment()) { "Rate source belongs to another environment" }
        return (task.deadlineEpochMs - System.currentTimeMillis()).coerceAtLeast(1L)
    }

    override fun authorizeOriginalContentBatch(source: BaseSource, bookUrl: String, chapters: List<Pair<Int, String>>) {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        check(source.getRuleEnvironment() === environment()) { "Batch source belongs to another original owner" }
        val owner = task.session.options.stateOwner ?: unsupportedRule("original public batch requires its explicit App save owner")
        val result = hostDispatch(task, "content.batch.authorize", io.yuedu.legado.jsonObject("owner" to owner,
            "sourceURL" to source.getKey(), "bookURL" to bookUrl,
            "chapters" to com.google.gson.JsonArray().apply { chapters.forEach { (index, url) -> add(io.yuedu.legado.jsonObject("index" to index, "url" to url)) } }))
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        if(result["authorized"]?.isJsonPrimitive != true || !result["authorized"].asJsonPrimitive.isBoolean || !result["authorized"].asBoolean)
            unsupportedRule("App owner did not authorize the actual batch chapter generations")
    }

    private val http get() = RuntimeHttpRequestExecutor(task) { current, operation, input ->
        check(current === task && operation == "http.request") { "Unexpected original-rule host operation" }
        ensureOwnerOpen()
        // Never fall back to a native/Swift transport after session shutdown.
        check(!task.session.closed.get()) { "Session is closed" }
        check(task.session.http != null) { "Original-rule requests require the JVM HTTP transport" }
        hostDispatch(current, operation, input)
    }

    override suspend fun <T> runWebBook(context: CoroutineContext, action: suspend () -> T): T {
        ensureOwnerOpen(); context.ensureActive(); task.ensureActiveForRuntime()
        val cancellation = context[Job]?.takeUnless { it === task.job }?.invokeOnCompletion(
            onCancelling = true, invokeImmediately = true,
        ) { cause -> if (cause != null) task.job.cancel(CancellationException("Original WebBook caller cancelled").apply { initCause(cause) }) }
        try {
            val guard = ScriptExecutionGuard { ensureOwnerOpen(); task.ensureActiveForRuntime() }
            val result = withContext(context.minusKey(Job) + task.job + guard) { action() }
            ensureOwnerOpen(); context.ensureActive(); task.ensureActiveForRuntime()
            return result
        } catch (error: Exception) {
            ensureOwnerOpen(); context.ensureActive(); task.ensureActiveForRuntime()
            rethrowRuleControlFailure(error)
            throw error
        } finally { cancellation?.dispose() }
    }

    override fun executeUrl(analyzed: AnalyzeUrl): StrResponse {
        check(analyzed.getRuleEnvironment() === environment()) { "AnalyzeUrl belongs to another environment" }
        val context = analyzed.getRuleCoroutineContext()
        ensureOwnerOpen(); context.ensureActive(); task.ensureActiveForRuntime()
        return try {
            val request = analyzed.prepareRequest { target -> requestCookieHeader(target.toHttpUrl().toString()) }
            checkRequestCookieCapability(request)
            val result = http.execute(request, recoverIoFailure = false, transform = analyzed::transformResponse)
            ensureOwnerOpen(); context.ensureActive(); task.ensureActiveForRuntime()
            result
        } catch (error: Exception) {
            ensureOwnerOpen(); context.ensureActive(); task.ensureActiveForRuntime()
            rethrowRuleControlFailure(error)
            throw error
        }
    }

    override fun storeLoginHeader(source: BaseSource, value: String?): Boolean {
        val store = environment().persistence ?: return false
        check(source.getRuleEnvironment() === environment()) { "Source belongs to another environment" }
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        if (appCookieOwner != null && !task.session.options.writesAppCookieOwner)
            unsupportedRule("Login header mutation requires explicit app-owner-text mode")
        if (task.session.options.writesAppCookieOwner) {
            task.sensitiveSourceOperation = true
            if ((value?.toByteArray(Charsets.UTF_8)?.size ?: 0) > 65_536)
                throw RulePersistenceException("Login header exceeds its native bridge byte budget")
        }
        val cacheKey = "loginHeader_${source.getKey()}"
        val changes = environment().cache.textChange(cacheKey, value)
        val headers = GSON.fromJsonObject<Map<String, String>>(value).getOrNull()
        val cookie = headers?.get("Cookie") ?: headers?.get("cookie")
        val headerCookieOwner = appCookieOwner
        if (headerCookieOwner != null && task.session.options.writesAppCookieOwner) {
            // Locked BaseSource.kt:235-246 has immediate sequential effects,
            // with different order for put and remove. This is deliberately not
            // the outward state.commit atomic batch API.
            if (value == null) {
                commitAppLoginHeader(source, null)
                environment().cache.publishText(cacheKey, null)
                // Host facts describe an actual changed header. An already
                // absent header must not manufacture a removal-write effect
                // merely because the later Cookie owner fails.
                headerCookieOwner.mutate("remove", source.getKey())
            } else {
                cookie?.let { headerCookieOwner.mutate("replace", source.getKey(), it) }
                try {
                    commitAppLoginHeader(source, value)
                    environment().cache.publishText(cacheKey, value)
                }
                catch (error: CancellationException) {
                    if (!cookie.isNullOrEmpty()) throw RulePersistenceException.afterCancelledEffect("cookieText", "Cookie text was committed before the login header write was cancelled", error)
                    throw error
                }
                catch (error: Exception) {
                    if (!cookie.isNullOrEmpty()) throw RulePersistenceException.afterCommittedEffect("cookieText", "Cookie text was committed before the login header write failed; the original operation is sequential", error)
                    throw error
                }
            }
            return true
        }
        if (value != null && cookie.isNullOrEmpty()) {
            environment().cache.put(cacheKey, value)
            return true
        }
        task.session.cookies.persistent(store, write = true, extraChanges = changes) {
            if (value == null) task.session.cookies.removeRuleCookie(source.getKey())
            else cookie?.let { task.session.cookies.replaceRuleCookie(source.getKey(), it) }
        }
        environment().cache.publishText(cacheKey, value)
        return true
    }

    /** Only the existing first-party producer constructs this wire packet.
     * RhinoClassShutter denies NativeHost/RuntimeTask; source JSON does not
     * authorize a mode, task or App binding. Cookie/header effects stay ordered,
     * not an atomic transaction or a new credential/cache owner. */
    private fun commitAppLoginHeader(source: BaseSource, value: String?) {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        if (!task.session.options.writesAppCookieOwner)
            unsupportedRule("Login header mutation requires explicit app-owner-text mode")
        val owner = task.session.options.stateOwner ?: unsupportedRule("Login header needs its explicit App owner")
        val result = hostDispatch(task, "source.login-header", io.yuedu.legado.jsonObject(
            "owner" to owner, "sourceURL" to source.getKey(), "taskId" to task.id,
            "cookieAccess" to task.session.options.cookieAccess, "action" to if (value == null) "remove" else "put"
        ).apply { if (value != null) addProperty("value", value) })
        val accepted = result["committed"]
        if (accepted == null || !accepted.isJsonPrimitive || !accepted.asJsonPrimitive.isBoolean || !accepted.asBoolean)
            throw RulePersistenceException("The App login-header owner did not acknowledge its mutation")
        ensureOwnerOpen(); task.ensureActiveForRuntime()
    }

    override fun loginInfo(source: BaseSource): String? {
        val result = loginInfoCall(source, "get")
        val value = result["value"] ?: throw RulePersistenceException("App login-info owner omitted its nullable result")
        if (value.isJsonNull) return null
        if (!value.isJsonPrimitive || !value.asJsonPrimitive.isString || value.asString.toByteArray(Charsets.UTF_8).size > 65_536)
            throw RulePersistenceException("App login-info owner returned an invalid String")
        return value.asString
    }

    override fun storeLoginInfo(source: BaseSource, value: String?): Boolean {
        if ((value?.toByteArray(Charsets.UTF_8)?.size ?: 0) > 65_536)
            throw RulePersistenceException("Login-info exceeds its native bridge byte budget")
        val result = loginInfoCall(source, if (value == null) "remove" else "put", value)
        val accepted = result["committed"] ?: throw RulePersistenceException("App login-info owner omitted its mutation result")
        if (!accepted.isJsonPrimitive || !accepted.asJsonPrimitive.isBoolean)
            throw RulePersistenceException("App login-info owner returned an invalid Boolean")
        return accepted.asBoolean
    }

    private fun loginInfoCall(source: BaseSource, action: String, value: String? = null): JsonObject {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        check(source.getRuleEnvironment() === environment()) { "Login source belongs to another environment" }
        val owner = task.session.options.stateOwner ?: unsupportedRule("original login-info needs the explicit App credential owner")
        val result = hostDispatch(task, "source.login-info", io.yuedu.legado.jsonObject("owner" to owner,
            "sourceURL" to source.getKey(), "action" to action).apply { if (action == "put") addProperty("value", value) })
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        return result
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
                // Same original AnalyzeUrl execution as WebBook, including its
                // shared owner-scoped admission. Do not count redirects/retries
                // separately or install another HTTP/rate/task authority.
                runBlocking(scriptContext) { analyzed.getStrResponseAwait() }
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
            check(!task.session.closed.get()) { "Original-rule session is closed" }
        } catch (closed: IllegalStateException) {
            // ajax catches ordinary exceptions as response text; a closed owner
            // must never publish that text as a late successful result.
            throw CancellationException("Original-rule environment is closed").apply { initCause(closed) }
        }
    }

    private fun readCookie(url: String, key: String? = null): String {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        return appCookieOwner?.getCookie(url, key) ?: cookieOperation { task.session.cookies.getRuleCookie(url, key) }
    }
    private fun requestCookieHeader(url: String): String {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        return appCookieOwner?.requestHeader(url)
            ?: task.session.cookies.persistent(environment().persistence) { task.session.cookies.getCookie(url) }
    }
    private fun checkRequestCookieCapability(request: JsonObject) {
        if (appCookieOwner != null && !task.session.options.writesAppCookieOwner && request["enabledCookieJar"]?.asBoolean == true)
            unsupportedRule("CookieManager.loadRequest/saveResponse enabledCookieJar needs the App owner's response/session text transaction")
    }
    private fun cookieWrite(action: String, url: String, value: String? = null, body: () -> Unit) {
        ensureOwnerOpen(); task.ensureActiveForRuntime()
        val owner = appCookieOwner
        if (owner != null) { owner.mutate(action, url, value); return }
        cookieOperation(true, body)
    }

    private fun <T> cookieOperation(write: Boolean = false, body: () -> T): T {
        // The existing jar monitor makes validation + mutation atomic relative
        // to transport Set-Cookie handling and other rule environments.
        synchronized(task.session.cookies) {
            ensureOwnerOpen()
            task.ensureActiveForRuntime()
            check(!task.session.closed.get()) { "Session is closed" }
            return try { task.session.cookies.persistent(environment().persistence, write, action = body) } catch (invalid: IllegalArgumentException) {
                throw UnsupportedRuleCapability(invalid.message.orEmpty())
            }
        }
    }
}
