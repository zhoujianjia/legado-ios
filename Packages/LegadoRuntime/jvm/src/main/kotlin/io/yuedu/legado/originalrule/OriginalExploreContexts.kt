package io.yuedu.legado.originalrule

import io.legado.app.utils.InfoMap
import com.script.ScriptException
import org.htmlunit.corejs.javascript.WrappedException
import kotlinx.coroutines.ThreadContextElement
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Same process-lifetime LRU(99) as the original ExploreAdapter. The Host's
 * scope identifies its actual backing/source/revision; it grants no cache/file
 * permission. Every persisted access still uses this invocation's RuleCache.
 * Entries retain no RuntimeTask, RuleEnvironment, coroutine or old grant. */
internal object OriginalExploreContexts {
    private class Entry(val sourceURL: String) {
        val mutex = Mutex()
        var map: InfoMap? = null
    }
    private val maps = LinkedHashMap<String, Entry>(16, .75f, true)
    private val current = ThreadLocal<Access?>()
    private class Access(val sourceURL: String, val cache: RuleCache, val check: () -> Unit, val entry: Entry) :
        ThreadContextElement<Access?>, AbstractCoroutineContextElement(Key) {
        companion object Key : CoroutineContext.Key<Access>
        override fun updateThreadContext(context: CoroutineContext): Access? = current.get().also { current.set(this) }
        override fun restoreThreadContext(context: CoroutineContext, oldState: Access?) {
            if (oldState == null) current.remove() else current.set(oldState)
        }
    }
    suspend fun <T> withScope(scope: String, sourceURL: String, environment: RuleEnvironment,
                              create: Boolean, action: suspend (InfoMap?) -> T): T {
        require(scope.isNotEmpty() && scope.toByteArray(Charsets.UTF_8).size <= 32_768) { "Invalid original explore owner scope" }
        val entry = synchronized(maps) {
            val existing = maps[scope]
            if (existing != null) {
                kotlin.check(existing.sourceURL == sourceURL) { "Explore scope belongs to another source" }
                existing
            } else if (create) {
                Entry(sourceURL).also {
                    maps[scope] = it
                    while (maps.size > 99) maps.remove(maps.keys.first())
                }
            } else Entry(sourceURL) // An unopened original explore really has no InfoMap.
        }
        return entry.mutex.withLock {
            environment.ensureOpen()
            withContext(Access(sourceURL, environment.cache, environment::ensureOpen, entry)) {
                if (create && entry.map == null) entry.map = InfoMap(sourceURL)
                try { action(entry.map) }
                catch (error: Exception) { rethrowMapTypeFailure(error); throw error }
            }
        }
    }
    /** Translate only escaping checked-Java-Map type failures in this original
     * context. JS may still catch them; no global Rhino/mainJs policy changes. */
    internal fun rethrowMapTypeFailure(error: Exception) {
        var current: Throwable = error
        repeat(32) {
            current = when (val failure = current) {
                is ClassCastException -> {
                    if (failure.stackTrace.any { it.className.startsWith("java.util.Collections\$Checked") || it.className == InfoMap::class.java.name })
                        unsupportedRule("Original exploration Java Map accepts String keys and String values; object values cannot retain old tasks")
                    return
                }
                is ScriptException -> failure.cause ?: return
                is WrappedException -> failure.wrappedException ?: return
                else -> return
            }
        }
    }
    internal fun initialCache(sourceURL: String): RuleCache {
        val access = current.get() ?: unsupportedRule("InfoMap needs its active original exploration context")
        access.check()
        kotlin.check(access.sourceURL == sourceURL) { "InfoMap belongs to another source" }
        return access.cache
    }
    internal fun check(map: InfoMap) {
        val access = current.get() ?: unsupportedRule("InfoMap needs its active original exploration context")
        access.check()
        kotlin.check(access.sourceURL == map.sourceUrl && access.entry.map === map) { "InfoMap belongs to another active exploration context" }
    }
    internal fun cache(map: InfoMap): RuleCache { check(map); return current.get()!!.cache }
    internal fun peek(): InfoMap? { current.get()?.let { it.check(); return it.entry.map }; return null }
}
