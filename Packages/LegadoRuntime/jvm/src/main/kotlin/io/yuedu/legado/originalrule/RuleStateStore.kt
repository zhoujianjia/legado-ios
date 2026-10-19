package io.yuedu.legado.originalrule

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Explicitly owned, in-memory backing storage. Closing the environment discards it. */
class RuleStateStore internal constructor(private val ensureOpen: () -> Unit) {
    private data class Key(val kind: String, val owner: String, val chapter: String?, val name: String)
    private val bigVariables = ConcurrentHashMap<Key, String>()
    internal fun putBook(bookUrl: String, key: String, value: String?) = put(Key("book", bookUrl, null, key), value)
    internal fun getBook(bookUrl: String, key: String): String? = get(Key("book", bookUrl, null, key))
    internal fun putChapter(bookUrl: String, chapterUrl: String, key: String, value: String?) =
        put(Key("chapter", bookUrl, chapterUrl, key), value)
    internal fun getChapter(bookUrl: String, chapterUrl: String, key: String): String? =
        get(Key("chapter", bookUrl, chapterUrl, key))
    private fun put(key: Key, value: String?) { ensureOpen(); if (value == null) bigVariables.remove(key) else bigVariables[key] = value }
    private fun get(key: Key): String? { ensureOpen(); return bigVariables[key] }
    internal fun clear() = bigVariables.clear()
}

/** CacheManager's API/seconds/typed-memory rules; backing data is not persisted to disk. */
class RuleCache internal constructor(private val ensureOpen: () -> Unit, private val clock: () -> Long) {
    private data class Entry(val value: Any, val deadline: Long)
    // CacheManager stores text in Room and binary values in ACache under independent keys.
    private val textBacking = ConcurrentHashMap<String, Entry>()
    private val binaryBacking = ConcurrentHashMap<String, Entry>()
    // CacheManager:17–20 uses a 50 MiB access-order cache, cost 40 + 2 * text.length.
    private val memory = LinkedHashMap<String, Any>(16, .75f, true)
    private var memoryBytes = 0L
    @JvmOverloads @Synchronized fun put(key: String, value: Any, saveTime: Int = 0) {
        ensureOpen()
        val deadline = if (saveTime == 0) 0L else clock() + saveTime * 1000L
        if (value is ByteArray) {
            binaryBacking[key] = Entry(value.copyOf(), deadline)
        } else {
            val stored = value.toString()
            textBacking[key] = Entry(stored, deadline)
            if (deadline == 0L) putMemory(key, stored) else deleteMemory(key)
        }
    }
    fun putMemory(key: String, value: Any) {
        ensureOpen()
        synchronized(memory) {
            memory.put(key, value)?.let { memoryBytes -= cost(it) }
            memoryBytes += cost(value)
            val iterator = memory.entries.iterator()
            while (memoryBytes > 50L * 1024 * 1024 && iterator.hasNext()) {
                memoryBytes -= cost(iterator.next().value); iterator.remove()
            }
        }
    }
    fun getFromMemory(key: String): Any? { ensureOpen(); return synchronized(memory) { memory[key] } }
    fun deleteMemory(key: String) { ensureOpen(); synchronized(memory) { memory.remove(key)?.let { memoryBytes -= cost(it) } } }
    @Synchronized fun get(key: String): String? = get(key, false)
    @Synchronized fun get(key: String, onlyDisk: Boolean): String? {
        ensureOpen()
        if (!onlyDisk) (getFromMemory(key) as? String)?.let { return it }
        val entry = liveEntry(textBacking, key) ?: return null
        return (entry.value as? String)?.also { if (!onlyDisk && entry.deadline == 0L) putMemory(key, it) }
    }
    fun getInt(key: String): Int? = (getFromMemory(key) as? Int) ?: get(key, true)?.toIntOrNull()
    fun getLong(key: String): Long? = (getFromMemory(key) as? Long) ?: get(key, true)?.toLongOrNull()
    fun getDouble(key: String): Double? = (getFromMemory(key) as? Double) ?: get(key, true)?.toDoubleOrNull()
    fun getFloat(key: String): Float? = (getFromMemory(key) as? Float) ?: get(key, true)?.toFloatOrNull()
    fun getByteArray(key: String): ByteArray? { ensureOpen(); return (liveEntry(binaryBacking, key)?.value as? ByteArray)?.copyOf() }
    @JvmOverloads fun putFile(key: String, value: String, saveTime: Int = 0): Nothing = unsupportedRule("cache.putFile requires a file-cache adapter")
    fun getFile(key: String): Nothing = unsupportedRule("cache.getFile requires a file-cache adapter")
    @Synchronized fun delete(key: String) { ensureOpen(); textBacking.remove(key); binaryBacking.remove(key); deleteMemory(key) }
    private fun liveEntry(backing: Map<String, Entry>, key: String): Entry? = backing[key]?.takeIf { it.deadline == 0L || it.deadline > clock() }
    private fun cost(value: Any): Long = 40L + 2L * value.toString().length
    internal fun clear() { textBacking.clear(); binaryBacking.clear(); synchronized(memory) { memory.clear(); memoryBytes = 0 } }
}

class RuleEnvironment(
    val platform: RulePlatform = RulePlatform(),
    clock: () -> Long = System::currentTimeMillis,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    val state = RuleStateStore(::ensureOpen)
    val cache = RuleCache(::ensureOpen, clock)
    val cookie: RuleCookieHost get() { ensureOpen(); return platform.cookie }
    internal val scopes = RuleScopes(::ensureOpen)
    fun ensureOpen() { check(!closed.get()) { "Original-rule environment is closed" } }
    override fun close() {
        if (closed.compareAndSet(false, true)) { scopes.close(); cache.clear(); state.clear() }
    }
}
