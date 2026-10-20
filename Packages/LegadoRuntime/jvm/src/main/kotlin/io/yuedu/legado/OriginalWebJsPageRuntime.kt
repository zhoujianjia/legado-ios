package io.yuedu.legado

import com.google.gson.JsonArray
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.script.rhino.ScriptExecutionGuard
import com.script.rhino.runScriptWithContext
import io.legado.app.data.entities.BookSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.yuedu.legado.originalrule.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.DisposableHandle
import kotlinx.coroutines.Job
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Page contexts are transient children of the same session, never another
 * credential/cache/HTTP owner. No live parent Rhino Context crosses threads. */
@OptIn(InternalCoroutinesApi::class)
internal class OriginalWebJsPages(private val session: RuntimeSession) {
    private val pages = ConcurrentHashMap<String, Page>()
    fun register(parent: RuntimeTask): Page {
        parent.ensureActiveForRuntime()
        check(parent.session === session && parent.sourceBrowserAllowed)
        synchronized(pages) {
            if (pages.size >= 8) throw RuntimeFailure("STATE_LIMIT", "Too many local source pages")
            return Page(parent).also { pages[it.id] = it }
        }
    }
    fun request(task: RuntimeTask, input: JsonObject): JsonObject {
        require(input.keySet().all { it in setOf("pageId", "method", "params", "function", "requestId", "timeoutMs") })
        require((input["timeoutMs"]?.asLong ?: 30_000) in 1..30_000)
        val page = resolve(task, input)
        if (org.htmlunit.corejs.javascript.Context.getCurrentContext() != null)
            throw RuntimeFailure("INVALID_BROWSER_REENTRY", "A local source page child requires an independent worker context")
        return runBlocking(task.job) { page.request(task, input) }
    }
    fun close(task: RuntimeTask, input: JsonObject): JsonObject {
        require(input.keySet().all { it in setOf("pageId", "timeoutMs") })
        require((input["timeoutMs"]?.asLong ?: 30_000) in 1..30_000)
        check(task.session === session)
        val raw = input["pageId"]
        require(raw != null && raw.isJsonPrimitive && raw.asJsonPrimitive.isString && raw.asString.length <= 128)
        val page = pages[raw.asString] ?: return jsonObject("closed" to true)
        close(page)
        return jsonObject("closed" to true)
    }
    fun close(page: Page) {
        page.seal()
        runBlocking { page.drainAndClose() }
        pages.remove(page.id, page)
    }
    fun closeAll() { pages.values.toList().forEach(::close) }
    fun closeCancelledProducer(parent: RuntimeTask) {
        check(parent.session === session && parent.job.isCancelled)
        pages.values.filter { it.parentTaskId == parent.id }.forEach(::close)
    }
    private fun resolve(task: RuntimeTask, input: JsonObject): Page {
        check(task.session === session)
        val raw = input["pageId"]
        require(raw != null && raw.isJsonPrimitive && raw.asJsonPrimitive.isString)
        val id = raw.asString
        require(id.length <= 128)
        return pages[id] ?: throw RuntimeFailure("INVALID_BROWSER_PAGE", "The local source page is closed or unknown")
    }

    inner class Page internal constructor(parent: RuntimeTask) {
        val id = UUID.randomUUID().toString()
        internal val parentTaskId = parent.id
        private val javaName = "lgrj" + UUID.randomUUID().toString().replace("-", "")
        private val cacheName = "lgrc" + UUID.randomUUID().toString().replace("-", "")
        private val resultName = "lgrr" + UUID.randomUUID().toString().replace("-", "")
        private val lifetime = Any()
        private val mutex = Mutex()
        private var admissionClosed = false
        private var bridgeEnabled = false
        private var closed = false
        private var requests = 0
        private val children = LinkedHashMap<RuntimeTask, CompletableDeferred<Unit>>()
        @Volatile private var active: RuntimeTask? = null
        private var environment: RuleEnvironment? = null
        private var source: BookSource? = null
        private var analysis: AnalyzeRule? = null
        private val parentCancellation: DisposableHandle = parent.job.invokeOnCompletion(onCancelling = true) { cause ->
            if (cause != null) seal()
        }
        fun metadata() = jsonObject("pageId" to id, "sessionId" to session.id,
            "parentTaskId" to parentTaskId, "javaName" to javaName, "cacheName" to cacheName, "resultName" to resultName)
        fun prepareHTML(html: String): String {
            val injection = "<script>${injection()}</script>"
            val head = html.indexOf("<head", ignoreCase = true)
            if (head >= 0) {
                val closing = html.indexOf('>', head)
                if (closing >= 0) return StringBuilder(html).insert(closing + 1, injection).toString()
            }
            return "<head>$injection</head>$html"
        }
        fun preparedBody(body: String) { synchronized(lifetime) { bridgeEnabled = body.isNotEmpty() } }
        private fun injection(): String = """
            const requestId = n => 'req_' + n + '_' + Date.now() + '_' + Math.random().toString(36).slice(-3);
            const JSBridgeCallbacks = {};
            const java = window.$javaName;
            delete window.$javaName;
            const cache = window.$cacheName;
            delete window.$cacheName;
            function run(jsCode) {
                return new Promise((resolve, reject) => {
                    const id = requestId("run");
                    JSBridgeCallbacks[id] = { resolve, reject };
                    java.request("run", [String(jsCode)], id);
                });
            };
            window.$resultName = function(id, success) {
                const callBack = JSBridgeCallbacks[id];
                if (callBack) {
                    const result = cache.getFromMemory(id);
                    cache.deleteMemory(id);
                    if (success) {
                        callBack.resolve(result);
                    } else {
                        callBack.reject(result);
                    }
                    delete JSBridgeCallbacks[id];
                }
            };
        """.trimIndent()
        fun seal() {
            val pending = synchronized(lifetime) { admissionClosed = true; children.keys.toList() }
            pending.forEach { it.job.cancel(CancellationException("Local source page closed")) }
        }
        suspend fun drainAndClose() {
            seal()
            val pending = synchronized(lifetime) { children.entries.map { it.key to it.value } }
            pending.forEach { LegadoRuntime.cancelOriginalPageChild(it.first) }
            pending.forEach { it.second.await() }
            mutex.withLock {
                if (!closed) {
                    closed = true
                    parentCancellation.dispose()
                    analysis?.close(); environment?.close()
                    analysis = null; source = null; environment = null
                }
            }
        }
        suspend fun request(task: RuntimeTask, input: JsonObject): JsonObject {
            val done = CompletableDeferred<Unit>()
            synchronized(lifetime) {
                if (admissionClosed || session.closed.get()) throw CancellationException("Local source page closed")
                if (!bridgeEnabled) unsupportedRule("original empty POST page has no WebJS bridge")
                if (children.size >= 32 || ++requests > 4096) throw RuntimeFailure("STATE_LIMIT", "Local source page request budget exceeded")
                children[task] = done
            }
            try {
                return mutex.withLock {
                    task.ensureActiveForRuntime()
                    synchronized(lifetime) { if (admissionClosed) throw CancellationException("Local source page closed") }
                    active = task
                    try {
                        if (environment == null) {
                            val env = LegadoRuntime.originalPageEnvironment(task) {
                                active ?: throw CancellationException("No active local source page request")
                            }
                            environment = env
                            source = LegadoRuntime.originalBookSource(task, env)
                            analysis = AnalyzeRule(source = source)
                        }
                        val context = currentCoroutineContext() + ScriptExecutionGuard {
                            task.ensureActiveForRuntime()
                            synchronized(lifetime) { if (admissionClosed) throw CancellationException("Local source page closed") }
                        }
                        analysis!!.setCoroutineContext(context)
                        runScriptWithContext(context) { execute(input) }
                    } finally { active = null }
                }
            } finally {
                LegadoRuntime.mergeOriginalPageEffects(session, parentTaskId, task.hostEffectsSnapshot())
                synchronized(lifetime) { children.remove(task) }
                done.complete(Unit)
            }
        }
        private fun execute(input: JsonObject): JsonObject {
            val method = input["method"]?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isString }?.asString
                ?: throw IllegalArgumentException("Page method must be a String")
            val raw = input["params"]
            require(raw != null && raw.isJsonArray && raw.asJsonArray.size() <= 64)
            if (method != "request") require(raw.asJsonArray.size() <= 6)
            val params = raw.asJsonArray.map { value ->
                require(value.isJsonNull || value.isJsonPrimitive && value.asJsonPrimitive.isString)
                if (value.isJsonNull) null else value.asString
            }.take(6) // Locked request() pads/truncates to its original six params.
            fun required(index: Int): String = params.getOrNull(index) ?: throw IllegalArgumentException("Missing page parameter")
            val cache = environment!!.cache
            if (method == "request") {
                val function = input["function"]?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isString }?.asString
                    ?: throw IllegalArgumentException("Missing page request function")
                val request = input["requestId"]?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isString }?.asString
                    ?: throw IllegalArgumentException("Missing page request id")
                require(request.length in 1..256 && request.all { it.isLetterOrDigit() && it.code < 128 || it == '_' || it == '-' })
                var success = true
                val value = try {
                    when (function) {
                        "run" -> analysis!!.evalJS(required(0)).toString()
                        "ajaxAwait" -> analysis!!.ajax(required(0), params.getOrNull(1)?.toLongOrNull()).toString()
                        "connectAwait" -> analysis!!.connect(required(0), params.getOrNull(1), params.getOrNull(2)?.toLongOrNull()).toString()
                        "getStringAwait" -> analysis!!.getString(params.getOrNull(0), params.getOrNull(1) as Any?)
                        else -> unsupportedRule("original WebJS request $function")
                    }
                } catch (error: Exception) {
                    active!!.ensureActiveForRuntime()
                    rethrowRuleControlFailure(error)
                    success = false
                    error.localizedMessage ?: "err"
                }
                active!!.ensureActiveForRuntime()
                if (value.toByteArray(Charsets.UTF_8).size > 4 * 1024 * 1024) throw RuntimeFailure("STATE_LIMIT", "WebJS result exceeds its byte budget")
                cache.putMemory(request, value)
                return jsonObject("kind" to "callback", "requestId" to request, "success" to success)
            }
            fun string(value: String?) = jsonObject("kind" to "string", "value" to value)
            fun nothing() = jsonObject("kind" to "void")
            return when (method) {
                "cache.getFromMemory" -> string(cache.getFromMemory(required(0))?.toString())
                "cache.deleteMemory" -> { cache.deleteMemory(required(0)); nothing() }
                "cache.putMemory" -> { cache.putMemory(required(0), required(1)); nothing() }
                "cache.get" -> string(cache.get(required(0), params.getOrNull(1)?.toBoolean() ?: false))
                "cache.put" -> { cache.put(required(0), required(1), params.getOrNull(2)?.toIntOrNull() ?: 0); nothing() }
                "cache.delete" -> { cache.delete(required(0)); nothing() }
                "java.put" -> string(source!!.put(required(0), required(1)))
                "java.get" -> { if (params.size != 1) unsupportedRule("original WebJS direct HTTP get"); string(source!!.get(required(0))) }
                "java.ajax" -> string(analysis!!.ajax(required(0), params.getOrNull(1)?.toLongOrNull() ?: 9000))
                "java.connect" -> string(analysis!!.connect(required(0), params.getOrNull(1), if (params.size > 2) params[2]?.toLongOrNull() else 9000).toString())
                "java.getString" -> string(analysis!!.getString(params.getOrNull(0), params.getOrNull(1) as Any?, params.getOrNull(2)?.toBoolean() ?: false))
                "java.getStringList" -> jsonObject("kind" to "stringList", "values" to analysis!!.getStringList(params.getOrNull(0), params.getOrNull(1), params.getOrNull(2)?.toBoolean() ?: false))
                "java.upConfig" -> nothing() // Activity has no Callback, unlike showBrowser.
                else -> unsupportedRule("original WebJS direct method $method")
            }
        }
    }
}
