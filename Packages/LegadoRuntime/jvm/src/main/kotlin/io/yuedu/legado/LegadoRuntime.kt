package io.yuedu.legado

import com.google.gson.*
import com.script.ScriptBindings
import com.script.SharedGlobalStateHandle
import com.script.rhino.RhinoScriptEngine
import com.script.rhino.runScriptWithContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.htmlunit.corejs.javascript.Function
import org.htmlunit.corejs.javascript.ScriptableObject

/** Synchronous JNI facade. Call execute on a worker thread; cancel is safe on another thread. */
object LegadoRuntime {
    private val sessions = ConcurrentHashMap<String, RuntimeSession>()
    private val tasks = ConcurrentHashMap<String, RuntimeTask>()
    private val earlyCancellations = object : LinkedHashMap<String, Long>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?) = size > 1024
    }
    private val deadlines = ScheduledThreadPoolExecutor(1) { runnable ->
        Thread(runnable, "legado-deadlines").apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true }
    @Volatile private var host: HostCallback? = null

    fun interface HostCallback {
        fun dispatch(taskId: String, operation: String, requestJson: String): String
    }

    /** Desktop test/embedding hook. iOS uses the NativeHost registered native method. */
    @JvmStatic fun setHostCallback(callback: HostCallback?) { host = callback }

    @JvmStatic fun createSession(sourceJson: String): String = envelope {
        val source = parseObject(sourceJson)
        require(source["mainJs"]?.takeUnless { it.isJsonNull }?.asString?.isNotBlank() == true ||
            source.has("ruleSearch") || source.has("ruleContent")) {
            "Source requires mainJs or supported declarative rules"
        }
        val id = UUID.randomUUID().toString()
        sessions[id] = RuntimeSession(id, source)
        jsonObject("ok" to true, "sessionId" to id)
    }

    @JvmStatic fun execute(sessionId: String, taskId: String, operation: String, inputJson: String): String {
        val startedAt = System.nanoTime()
        var task: RuntimeTask? = null
        var timeout: java.util.concurrent.ScheduledFuture<*>? = null
        try {
            require(taskId.isNotBlank()) { "taskId must not be empty" }
            val session = sessions[sessionId] ?: throw RuntimeFailure("UNKNOWN_SESSION", "Session is closed or unknown")
            val input = parseObject(inputJson)
            val timeoutMs = input["timeoutMs"]?.asLong ?: 30_000L
            require(timeoutMs in 1..300_000) { "timeoutMs must be between 1 and 300000" }
            task = RuntimeTask(taskId, session, Job(), System.currentTimeMillis() + timeoutMs)
            synchronized(session) {
                if (session.closed.get()) throw RuntimeFailure("UNKNOWN_SESSION", "Session is closed")
                if (tasks.putIfAbsent(taskId, task) != null) {
                    throw RuntimeFailure("DUPLICATE_TASK", "taskId is already active")
                }
                synchronized(earlyCancellations) {
                    earlyCancellations.remove(taskId)?.let { cancelledAt ->
                        if (System.currentTimeMillis() - cancelledAt < 60_000) task.job.cancel()
                    }
                }
            }
            val current = task
            timeout = deadlines.schedule({
                current.timedOut.set(true)
                current.job.cancel(CancellationException("Execution deadline exceeded"))
                cancelHost(current.id)
            }, timeoutMs, TimeUnit.MILLISECONDS)
            val result = executeOperation(current, operation, input)
            current.job.ensureActiveForRuntime()
            return jsonObject("ok" to true, "taskId" to taskId, "result" to result,
                "metrics" to jsonObject("elapsedMs" to (System.nanoTime() - startedAt) / 1_000_000.0)).toString()
        } catch (error: Exception) {
            val hostFailure = generateSequence(error as Throwable?) { it.cause }
                .filterIsInstance<RuntimeFailure>().firstOrNull()
            val code = when {
                task?.timedOut?.get() == true -> "TIMEOUT"
                error is CancellationException || task?.job?.isCancelled == true -> "CANCELLED"
                hostFailure != null -> hostFailure.code
                error is IllegalArgumentException || error is JsonParseException -> "INVALID_ARGUMENT"
                else -> "SCRIPT_ERROR"
            }
            return failure(code, hostFailure?.message ?: error.message ?: error.javaClass.simpleName, taskId)
        } finally {
            timeout?.cancel(false)
            task?.let { if (tasks.remove(taskId, it)) it.job.complete() }
        }
    }

    @JvmStatic fun cancel(taskId: String): String {
        // A Swift Task can cancel between queueing execute and its JVM registration.
        val task = synchronized(earlyCancellations) {
            val active = tasks[taskId]
            if (active == null) earlyCancellations[taskId] = System.currentTimeMillis()
            active
        }
        task?.job?.cancel(CancellationException("Cancelled by caller"))
        if (task != null) cancelHost(taskId)
        return jsonObject("ok" to true, "taskId" to taskId, "cancelled" to (task != null)).toString()
    }

    @JvmStatic fun closeSession(sessionId: String): String {
        val session = sessions.remove(sessionId) ?: return jsonObject("ok" to true).toString()
        synchronized(session) { session.closed.set(true) }
        tasks.values.filter { it.session === session }.forEach { cancel(it.id) }
        session.sharedGlobal?.let(ScriptBindings::removeSharedGlobalState)
        session.variables.clear()
        session.cache.clear()
        session.contents.clear()
        return jsonObject("ok" to true).toString()
    }

    private fun executeOperation(task: RuntimeTask, operation: String, input: JsonObject): JsonElement {
        if (operation == "diagnostics") return jsonObject(
            "engine" to "htmlunit-core-js", "version" to "5.3.0-legado.4",
            "interpreted" to true, "requiredModules" to listOf("java.base", "java.xml", "java.desktop"),
            "javaVersion" to System.getProperty("java.version"),
            "vmVersion" to System.getProperty("java.vm.version"),
            "vmName" to System.getProperty("java.vm.name"),
            "supportedSourceTypes" to listOf("mainJs", "declarative subset"), "platformHosts" to "prototype subset"
        )
        if (operation == "semanticSuite") return EngineSemanticSuite.run(task)
        if (operation == "tlsCapabilityProbe") return TlsCapabilityProbe.run(task)
        if (operation == "httpWireCapabilityProbe") return HttpWireDiagnosticBridge.run(task, ::executeOperation)
        if (operation == "interopSuite") return runScriptWithContext(task.job) {
            gson.toJsonTree(InteropSemanticSuite.run())
        }
        if (operation == "snapshot") return jsonObject(
            "variables" to task.session.variables, "cache" to task.session.cache.snapshot(),
            "cookies" to task.session.cookies.snapshot(), "contents" to task.session.contents,
            // Copy JsonElements directly: Gson's List adapter would omit explicit
            // null request fields such as a GET's bodyBase64 from this evidence.
            "requests" to synchronized(task.session.requests) {
                JsonArray().apply { task.session.requests.forEach { add(it.deepCopy()) } }
            }
        )
        val source = task.session.source
        val javaHost = SourceJavaHost(task, ::dispatchHost)
        if (source["mainJs"]?.takeUnless { it.isJsonNull }?.asString.isNullOrBlank()) {
            return DeclarativeSource(task, javaHost).execute(operation, input)
        }
        val preparedInput = MainJsResultMarshaller.prepareInput(operation, input, source)
        val scope = ScriptBindings()
        // BaseSourceExtensions.getSharedGlobalStateKey returns a handle only for a
        // nonblank jsLib. Without it, explicit globals are invocation-local too.
        // A configured shared-global prototype retains its first parent, including
        // intrinsic mutations, just as upstream ScriptBindings does.
        scope.chainTo(RhinoScriptEngine.newStandardTopLevel(), task.session.sharedGlobal)
        scope["java"] = javaHost
        scope["source"] = SourceHost(task.session)
        scope["sourceApi"] = SourceHost(task.session)
        scope["cache"] = task.session.cache
        scope["cookie"] = task.session.cookies
        scope["baseUrl"] = source["bookSourceUrl"]?.asString.orEmpty()
        scope["__runtimeInputJSON"] = preparedInput.toString()
        RhinoScriptEngine.eval(
            "var __runtimeInput = JSON.parse(String(__runtimeInputJSON));" +
                "var key = __runtimeInput.key || ''; var page = __runtimeInput.page == null ? 1 : __runtimeInput.page;" +
                "var book = __runtimeInput.book || {}; var chapter = __runtimeInput.chapter || {};" +
                "var chapters = __runtimeInput.chapters || []; var url = __runtimeInput.url || '';" +
                "var nextChapterUrl = __runtimeInput.nextChapterUrl == null ? null : __runtimeInput.nextChapterUrl;",
            scope, task.job
        )
        source["jsLib"]?.takeIf { it.isJsonPrimitive && it.asString.isNotBlank() }?.let {
            if (it.asString.trim().startsWith("http")) {
                throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Remote jsLib loading has not been migrated")
            }
            RhinoScriptEngine.eval(it.asString, scope, task.job)
        }
        RhinoScriptEngine.eval(source["mainJs"].asString, scope, task.job)
        val expression = when (operation) {
            "search" -> "search(key, page)"
            "explore" -> "explore(url, page)"
            "details", "getBookInfo" -> if (ScriptableObject.getProperty(scope, "getBookInfo") is Function)
                "getBookInfo(book)" else "book"
            "toc", "getChapters" -> "getChapters(book)"
            "content", "getContent" -> "getContent(chapter, book, nextChapterUrl)"
            "batch", "getContentBatch" -> {
                javaHost.batchUrls = input["chapters"]?.asJsonArray?.mapNotNull { element ->
                    chapterUrl(element.asJsonObject)
                }?.toSet().orEmpty()
                if (ScriptableObject.getProperty(scope, "getContentBatch") !is Function) {
                    return jsonObject("exists" to false, "missing" to (input["chapters"] ?: JsonArray()))
                }
                "getContentBatch(chapters, book)"
            }
            "login" -> "login(__runtimeInput)"
            "evaluate" -> input["script"]?.asString
                ?: throw IllegalArgumentException("evaluate requires script")
            "semanticProbe" -> "({e4x:String((<root><text>ok</text></root>)..text)," +
                "indirect:(0,eval)('typeof java.ajax'),dynamicThis:(function(){return this.java===java})()," +
                "legacy:(0,eval)('if(true){const marker=42;} marker')})"
            else -> throw RuntimeFailure("UNSUPPORTED_OPERATION", "Unknown operation: $operation")
        }
        val raw = RhinoScriptEngine.eval(expression, scope, task.job)
        if (operation == "batch" || operation == "getContentBatch") {
            val missing = JsonArray()
            input["chapters"]?.asJsonArray?.forEach {
                if (!javaHost.savedUrls.contains(chapterUrl(it.asJsonObject))) missing.add(it)
            }
            return jsonObject("exists" to true, "saved" to javaHost.savedUrls.toList(), "missing" to missing)
        }
        scope["__runtimeResult"] = raw
        val json = RhinoScriptEngine.eval("JSON.stringify(__runtimeResult)", scope, task.job)?.toString()
        var result = json?.let { JsonParser.parseString(it) } ?: JsonNull.INSTANCE
        // The prototype carries a JSON book, rather than upstream's mutable Java
        // entity. Retain mutations for legacy sources that return no book; exact
        // Java Book reference semantics remain outside this finite DTO projection.
        if (operation in setOf("details", "getBookInfo") && result.isJsonNull) {
            result = JsonParser.parseString(RhinoScriptEngine.eval("JSON.stringify(book)", scope, task.job).toString())
        }
        return MainJsResultMarshaller.marshal(operation, result, preparedInput, source)
    }

    private fun dispatchHost(task: RuntimeTask, operation: String, request: JsonObject): JsonObject {
        task.job.ensureActiveForRuntime()
        request.addProperty("deadlineEpochMs", task.deadlineEpochMs)
        request.addProperty("remainingTimeoutMs", (task.deadlineEpochMs - System.currentTimeMillis()).coerceAtLeast(1))
        if (operation == "http.request") task.session.requests.add(request.deepCopy())
        val response = try {
            if (operation == "http.request" && task.diagnosticHttp != null) {
                task.diagnosticHttp.request(task, request).toString()
            } else host?.dispatch(task.id, operation, request.toString())
                ?: NativeHost.dispatch(task.id, operation, request.toString())
        } catch (_: UnsatisfiedLinkError) {
            throw RuntimeFailure("HOST_UNAVAILABLE", "No native host registered for $operation")
        }
        task.job.ensureActiveForRuntime()
        val parsed = parseObject(response)
        if (parsed["ok"]?.isJsonPrimitive == true && !parsed["ok"].asBoolean) {
            val detail = parsed["error"]?.asJsonObject
            throw RuntimeFailure(detail?.get("code")?.asString ?: "HOST_ERROR",
                detail?.get("message")?.asString ?: "Host operation failed")
        }
        return parsed
    }

    private fun cancelHost(taskId: String) {
        // Cancellation must remain effective when the host has already completed or is absent.
        try { host?.dispatch(taskId, "task.cancel", "{}") ?: NativeHost.dispatch(taskId, "task.cancel", "{}") }
        catch (_: Exception) { /* Best effort; Job cancellation remains authoritative. */ }
        catch (_: UnsatisfiedLinkError) { /* Pure JVM operations require no host. */ }
    }
}

internal class RuntimeSession(val id: String, val source: JsonObject) {
    val closed = AtomicBoolean(false)
    val sharedGlobal: SharedGlobalStateHandle? = source["jsLib"]
        ?.takeIf { it.isJsonPrimitive && it.asString.isNotBlank() }
        ?.let { ScriptBindings.getSharedGlobalStateHandle("ios:$id") }
    val variables = ConcurrentHashMap<String, String>()
    val cache = SessionCache()
    val cookies = SessionCookies()
    val contents = ConcurrentHashMap<String, String>()
    val requests = java.util.Collections.synchronizedList(mutableListOf<JsonObject>())
}

internal class RuntimeTask(val id: String, val session: RuntimeSession, val job: kotlinx.coroutines.CompletableJob,
    val deadlineEpochMs: Long, val diagnosticHttp: TaskHttpDispatcher? = null) {
    val timedOut = AtomicBoolean(false)
}

internal class RuntimeFailure(val code: String, message: String) : RuntimeException(message)
internal val gson = GsonBuilder().disableHtmlEscaping().create()
internal fun jsonObject(vararg entries: Pair<String, Any?>): JsonObject = JsonObject().apply {
    entries.forEach { (key, value) -> add(key, if (value is JsonElement) value else gson.toJsonTree(value)) }
}
internal fun parseObject(json: String): JsonObject {
    val parsed = JsonParser.parseString(json)
    require(parsed.isJsonObject) { "Expected a JSON object" }
    return parsed.asJsonObject
}
internal fun chapterUrl(chapter: JsonObject): String? =
    (chapter["url"] ?: chapter["chapterUrl"])?.takeUnless { it.isJsonNull }?.asString
internal fun failure(code: String, message: String, taskId: String? = null): String =
    jsonObject("ok" to false, "taskId" to taskId, "error" to jsonObject("code" to code, "message" to message)).toString()
internal inline fun envelope(body: () -> JsonObject): String = try { body().toString() }
catch (error: Exception) { failure(if (error is RuntimeFailure) error.code else "INVALID_ARGUMENT", error.message.orEmpty()) }
internal fun Job.ensureActiveForRuntime() {
    if (!isActive) throw CancellationException("Task cancelled")
}
