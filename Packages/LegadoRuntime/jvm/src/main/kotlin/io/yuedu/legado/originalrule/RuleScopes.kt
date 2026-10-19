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
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlin.coroutines.CoroutineContext

/** SharedJsScope's inline-library/CryptoJS subset, explicitly bounded by RuleEnvironment. */
internal class RuleScopes(private val ensureOpen: () -> Unit) : AutoCloseable {
    private class CryptoKey(val owner: Any, val thread: Thread) {
        override fun hashCode() = 31 * System.identityHashCode(owner) + System.identityHashCode(thread)
        override fun equals(other: Any?) = other is CryptoKey && owner === other.owner && thread === other.thread
    }
    private class CreationLock(val monitor: Any = Any(), var users: Int = 0)
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
        if (jsLib.isNullOrBlank()) return null
        // SharedJsScope classifies a map only after parsing succeeds; a valid JS block remains inline.
        val text = jsLib.trim()
        val isMap = text.startsWith("{") && text.endsWith("}") &&
            GSON.fromJsonObject<Map<String, String>>(text).isSuccess
        // Original JSON-map jsLib performs remote downloads; that capability is not silently skipped.
        if (text.startsWith("http://", true) || text.startsWith("https://", true) || isMap)
            unsupportedRule("remote/map jsLib loading")
        val key = md5(jsLib)
        synchronized(this) { ensureOpen(); libraryScopes[key]?.get() }?.let { return it }
        return withCreationLock(libraryCreationLocks, key) {
            synchronized(this) { ensureOpen(); libraryScopes[key]?.get() }
                ?: createCryptoScope(context).also { scope ->
                    RhinoScriptEngine.eval(jsLib, scope, context)
                    scope.globalThis.preventExtensions()
                    synchronized(this) {
                        ensureOpen()
                        libraryScopes[key] = WeakReference(scope)
                    }
                }
        }
    }

    fun getCryptoScope(owner: Any, context: CoroutineContext?): ScriptBindings {
        ensureOpen()
        val key = CryptoKey(owner, Thread.currentThread())
        synchronized(this) { ensureOpen(); cryptoScopes[key]?.get() }?.let { return it }
        return withCreationLock(cryptoCreationLocks, key) {
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
    private fun <K, T> withCreationLock(locks: MutableMap<K, CreationLock>, key: K, action: () -> T): T {
        val lock = synchronized(this) {
            ensureOpen()
            locks.getOrPut(key) { CreationLock() }.also { it.users++ }
        }
        return try {
            synchronized(lock.monitor) { ensureOpen(); action() }
        } finally {
            synchronized(this) {
                lock.users--
                if (lock.users == 0 && locks[key] === lock) locks.remove(key)
            }
        }
    }

    fun remove(jsLib: String?) {
        ensureOpen()
        if (jsLib.isNullOrBlank()) return
        val key = md5(jsLib)
        val prefix = "$key:"
        withCreationLock(libraryCreationLocks, key) {
            synchronized(this) {
                ensureOpen()
                libraryScopes.remove(key)
                handles.keys.filter { it.startsWith(prefix) }.forEach { handles.remove(it)?.let(ScriptBindings::removeSharedGlobalState) }
            }
        }
    }

    @Synchronized fun releaseOwner(owner: Any) { cryptoScopes.keys.removeIf { it.owner === owner } }
    @Synchronized override fun close() {
        handles.values.forEach(ScriptBindings::removeSharedGlobalState)
        handles.clear(); libraryScopes.clear(); cryptoScopes.clear(); compiledCrypto = null
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
