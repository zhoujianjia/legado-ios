package io.yuedu.legado.originalrule

import io.legado.app.data.entities.BaseSource
import com.script.CompiledScript
import com.script.ScriptBindings
import com.script.SharedGlobalStateHandle
import com.script.rhino.RhinoScriptEngine
import org.htmlunit.corejs.javascript.BaseFunction
import org.htmlunit.corejs.javascript.Context
import org.htmlunit.corejs.javascript.Scriptable
import org.htmlunit.corejs.javascript.ScriptableObject
import org.htmlunit.corejs.javascript.VarScope
import kotlinx.coroutines.DisposableHandle
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlin.coroutines.CoroutineContext

/** Same original library/CryptoJS scopes, bounded by the existing environment. */
internal class RuleScopes(private val ensureOpen: () -> Unit, private val cache: RuleCache?,
                          private val platform: RulePlatform?) : AutoCloseable {
    // Retain the existing standalone scope ABI without creating another cache,
    // transport or owner. Remote libraries require an explicitly supplied pair.
    constructor(ensureOpen: () -> Unit) : this(ensureOpen, null, null)
    private class CryptoKey(val owner: Any, val thread: Thread) {
        override fun hashCode() = 31 * System.identityHashCode(owner) + System.identityHashCode(thread)
        override fun equals(other: Any?) = other is CryptoKey && owner === other.owner && thread === other.thread
    }
    private class CreationLock {
        val monitor = java.lang.Object()
        var users = 0 // Protected by the RuleScopes metadata monitor.
        var owner: Thread? = null // Owner/depth are protected by monitor; scripts run outside it.
        var depth = 0
    }
    private val namespace = "originalrule:${UUID.randomUUID()}:"
    private val libraryScopes = object : LinkedHashMap<String, WeakReference<ScriptBindings>>(16, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, WeakReference<ScriptBindings>>) = size > 16
    }
    private val cryptoScopes = object : LinkedHashMap<CryptoKey, WeakReference<ScriptBindings>>(16, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<CryptoKey, WeakReference<ScriptBindings>>) = size > 16
    }
    private val handles = hashMapOf<String, SharedGlobalStateHandle>()
    private val libraryCreationLocks = hashMapOf<String, CreationLock>()
    private val cryptoCreationLocks = hashMapOf<CryptoKey, CreationLock>()
    private val secureRandom = SecureRandom()
    private val cryptoCompileLock = Any()
    @Volatile private var compiledCrypto: CompiledScript? = null

    @Synchronized fun sharedHandle(source: BaseSource?): SharedGlobalStateHandle? {
        ensureOpen()
        val library = source?.jsLib?.takeIf(String::isNotBlank) ?: return null
        val key = md5(library) + ":" + source.javaClass.name + ":" + md5(source.getKey())
        return handles.getOrPut(key) { ScriptBindings.getSharedGlobalStateHandle(namespace + key) }
    }

    fun getScope(jsLib: String?, context: CoroutineContext?): ScriptBindings? {
        ensureOpen()
        context?.ensureActive()
        if (jsLib.isNullOrBlank()) return null
        val key = md5(jsLib)
        synchronized(this) { ensureOpen(); libraryScopes[key]?.get() }?.let { return it }
        return withCreationLock(libraryCreationLocks, key, context) {
            synchronized(this) { ensureOpen(); libraryScopes[key]?.get() }
                ?: createCryptoScope(context).also { scope ->
                    evaluateLibrary(jsLib, scope, context)
                    scope.globalThis.preventExtensions()
                    synchronized(this) {
                        ensureOpen()
                        libraryScopes[key] = WeakReference(scope)
                    }
                }
        }
    }

    private fun libraryMap(jsLib: String): Map<String, String?>? =
        if (jsLib.isJsonObject()) GSON.fromJsonObject<Map<String, String?>>(jsLib).getOrNull() else null

    private fun libraryURL(value: String?): String? = value?.takeIf {
        it.startsWith("http://", true) || it.startsWith("https://", true)
    }

    private fun evaluateLibrary(jsLib: String, scope: ScriptBindings, context: CoroutineContext?) {
        val libraries = libraryMap(jsLib)
        if (libraries == null) {
            // A bare URL is not an upstream shorthand; non-map JS stays inline.
            RhinoScriptEngine.eval(jsLib, scope, context)
            return
        }
        libraries.values.forEach { value ->
            val url = libraryURL(value) ?: return@forEach
            ensureOpen(); context?.ensureActive()
            val key = md5(url)
            val owner = cache ?: unsupportedRule("remote/map jsLib needs its existing cache owner")
            val loader = platform ?: unsupportedRule("remote/map jsLib needs its existing HTTP platform")
            val script = owner.libraryText(key) ?: run {
                val downloaded = loader.downloadJsLibrary(url, context)
                    ?: throw io.legado.app.exception.NoStackTraceException("下载jsLib-${url}失败")
                ensureOpen(); context?.ensureActive()
                // Locked original writes downloaded text before evaluating it.
                // A later syntax error must not roll back this accepted cache.
                owner.storeLibraryText(key, downloaded)
                downloaded
            }
            ensureOpen(); context?.ensureActive()
            RhinoScriptEngine.eval(script, scope, context)
        }
    }

    fun getCryptoScope(owner: Any, context: CoroutineContext?): ScriptBindings {
        ensureOpen()
        context?.ensureActive()
        val key = CryptoKey(owner, Thread.currentThread())
        synchronized(this) { ensureOpen(); cryptoScopes[key]?.get() }?.let { return it }
        return withCreationLock(cryptoCreationLocks, key, context) {
            synchronized(this) { ensureOpen(); cryptoScopes[key]?.get() }
                ?: createCryptoScope(context).also {
                    it.globalThis.preventExtensions()
                    synchronized(this) {
                        ensureOpen()
                        cryptoScopes[key] = WeakReference(it)
                    }
                }
        }
    }

    private fun createCryptoScope(context: CoroutineContext?): ScriptBindings {
        val scope = RhinoScriptEngine.getRuntimeScope(ScriptBindings())
        val script = getCompiledCrypto()
        script.eval(scope, context)
        val function = object : BaseFunction() {
            override fun call(cx: Context, callScope: VarScope, thisObj: Scriptable, args: Array<Any>): Any = secureRandom.nextInt().toDouble()
        }.apply {
            parentScope = scope
            prototype = ScriptableObject.getFunctionPrototype(scope)
        }
        ScriptableObject.putProperty(scope, "__legadoSecureRandomInt", function)
        try {
            RhinoScriptEngine.eval(SECURE_RANDOM_PATCH, scope, context)
        } finally {
            scope.delete("__legadoSecureRandomInt")
        }
        return scope
    }

    private fun getCompiledCrypto(): CompiledScript {
        compiledCrypto?.let { return it }
        return synchronized(cryptoCompileLock) {
            ensureOpen()
            compiledCrypto ?: run {
                val text = javaClass.getResourceAsStream("/io/yuedu/legado/originalrule/cryptojs.min.js")
                    ?.use { it.readBytes().toString(Charsets.UTF_8) }
                    ?: throw IllegalStateException("Required original CryptoJS resource is missing")
                RhinoScriptEngine.compile(text).also { script ->
                    synchronized(this) { ensureOpen(); compiledCrypto = script }
                }
            }
        }
    }

    // As in SharedJsScope, only callers creating the same scope share an initialization monitor.
    // Never execute a library while holding the environment-wide cache/handle monitor.
    @OptIn(InternalCoroutinesApi::class)
    private fun <K, T> withCreationLock(locks: MutableMap<K, CreationLock>, key: K,
                                      context: CoroutineContext? = null, action: () -> T): T {
        val lock = synchronized(this) {
            ensureOpen()
            locks.getOrPut(key) { CreationLock() }.also { it.users++ }
        }
        var cancellation: DisposableHandle? = null
        var acquired = false
        return try {
            // Cancellation only wakes condition waiters. It never interrupts the initializer's
            // thread or executes under a monitor held by arbitrary JS/host code.
            cancellation = context?.get(Job)?.invokeOnCompletion(onCancelling = true, invokeImmediately = true) {
                synchronized(lock.monitor) { lock.monitor.notifyAll() }
            }
            synchronized(lock.monitor) {
                while (lock.owner != null && lock.owner !== Thread.currentThread()) {
                    ensureOpen()
                    context?.ensureActive()
                    try { lock.monitor.wait() }
                    catch (error: InterruptedException) {
                        Thread.currentThread().interrupt()
                        context?.ensureActive()
                        throw error
                    }
                }
                ensureOpen()
                context?.ensureActive()
                lock.owner = Thread.currentThread()
                lock.depth++ // Preserve the previous Java monitor's same-thread reentrancy.
                acquired = true
            }
            action()
        } finally {
            cancellation?.dispose()
            if (acquired) synchronized(lock.monitor) {
                lock.depth--
                if (lock.depth == 0) {
                    lock.owner = null
                    lock.monitor.notifyAll()
                }
            }
            synchronized(this) {
                lock.users--
                if (lock.users == 0 && locks[key] === lock) locks.remove(key)
            }
        }
    }

    @JvmOverloads fun remove(jsLib: String?, context: CoroutineContext? = null) {
        ensureOpen()
        if (jsLib.isNullOrBlank()) return
        val key = md5(jsLib)
        val prefix = "$key:"
        withCreationLock(libraryCreationLocks, key, context) {
            // Original remove deletes each URL first, then drops scope/global.
            // Failure leaves the old scope and any already completed deletions.
            libraryMap(jsLib)?.values?.forEach { value ->
                libraryURL(value)?.let { url ->
                    ensureOpen(); context?.ensureActive()
                    val owner = cache ?: unsupportedRule("remote/map jsLib needs its existing cache owner")
                    owner.removeLibraryText(md5(url))
                }
            }
            synchronized(this) {
                ensureOpen()
                libraryScopes.remove(key)
                handles.keys.filter { it.startsWith(prefix) }.forEach { handles.remove(it)?.let(ScriptBindings::removeSharedGlobalState) }
            }
        }
    }

    @Synchronized fun releaseOwner(owner: Any) { cryptoScopes.keys.removeIf { it.owner === owner } }
    override fun close() {
        val creations = synchronized(this) {
            handles.values.forEach(ScriptBindings::removeSharedGlobalState)
            handles.clear(); libraryScopes.clear(); cryptoScopes.clear(); compiledCrypto = null
            (libraryCreationLocks.values + cryptoCreationLocks.values).distinct()
        }
        // RuleEnvironment marks itself closed before calling here. Wake waiters without
        // holding the metadata monitor and without waiting for an initializer's host call.
        creations.forEach { lock -> synchronized(lock.monitor) { lock.monitor.notifyAll() } }
    }

    private fun md5(value: String): String = MessageDigest.getInstance("MD5")
        .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
    private companion object {
        // SharedJsScope.kt:303–313, unchanged script bytes except surrounding Kotlin indentation.
        const val SECURE_RANDOM_PATCH = """
        CryptoJS.lib.WordArray.random = (function(nextInt) {
            return function(nBytes) {
                var words = [];
                for (var i = 0; i < nBytes; i += 4) {
                    words.push(nextInt());
                }
                return CryptoJS.lib.WordArray.create(words, nBytes);
            };
        })(__legadoSecureRandomInt);
        """
    }
}
