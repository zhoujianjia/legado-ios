package io.yuedu.legado.originalrule

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Owned variables with optional embedding persistence; closing discards only transient views. */
class RuleStateStore internal constructor(private val ensureOpen: () -> Unit, private val persistence: RulePersistenceBinding? = null) {
    private data class Key(val kind: String, val owner: String, val chapter: String?, val name: String)
    private val bigVariables = ConcurrentHashMap<Key, String>()
    internal fun putBook(bookUrl: String, key: String, value: String?) = put(Key("book", bookUrl, null, key), value)
    internal fun getBook(bookUrl: String, key: String): String? = get(Key("book", bookUrl, null, key))
    internal fun putChapter(bookUrl: String, chapterUrl: String, key: String, value: String?) =
        put(Key("chapter", bookUrl, chapterUrl, key), value)
    internal fun getChapter(bookUrl: String, chapterUrl: String, key: String): String? =
        get(Key("chapter", bookUrl, chapterUrl, key))
    private fun storageKey(key: Key) = persistence!!.key("big-variable", key.kind, key.owner, key.chapter.orEmpty(), key.name)
    private fun put(key: Key, value: String?) {
        ensureOpen()
        persistence?.put(storageKey(key), value?.toByteArray(Charsets.UTF_8))
        if (value == null) bigVariables.remove(key) else bigVariables[key] = value
    }
    private fun get(key: Key): String? { ensureOpen(); return if (persistence != null) persistence.read(storageKey(key))?.toString(Charsets.UTF_8) else bigVariables[key] }
    internal fun restoreVariables(kind: String, owner: String, chapter: String, initial: String?): String? {
        ensureOpen()
        val restored = persistence?.read(persistence.key("variables", kind, owner, chapter))?.toString(Charsets.UTF_8) ?: return initial
        decodePersistent("entity variables") { requireNotNull(GSON.fromJsonObject<HashMap<String, String>>(restored).getOrThrow()) }
        return restored
    }
    /** Persist the small JSON map and the corresponding large value in one owner transaction. */
    internal fun putVariable(kind: String, owner: String, chapter: String, map: HashMap<String, String>, key: String, value: String?): Boolean {
        val store = persistence ?: error("No persistent variable adapter")
        ensureOpen()
        val smallKey = store.key("variables", kind, owner, chapter)
        val bigKey = store.key("big-variable", kind, owner, chapter, key)
        val (small, updateJson) = store.update(setOf(smallKey, bigKey)) { prior ->
            val small = prior[smallKey]?.toString(Charsets.UTF_8)?.let { decodePersistent("entity variables") { GSON.fromJsonObject<HashMap<String, String>>(it).getOrThrow() } } ?: HashMap(map)
            val existed = small.contains(key)
            val big = if (value != null && value.length >= 10000) value else null
            if (value == null || big != null) small.remove(key) else small[key] = value
            mapOf(smallKey to GSON.toJson(small).toByteArray(Charsets.UTF_8), bigKey to big?.toByteArray(Charsets.UTF_8)) to (small to ((value != null && value.length < 10000) || existed))
        }
        map.clear(); map.putAll(small)
        return updateJson
    }
    internal fun clear() = bigVariables.clear()
}

/** CacheManager's seconds/typed-memory rules; durable backing exists only when explicitly injected. */
class RuleCacheMemory internal constructor() {
    internal val values = LinkedHashMap<String, Any>(16, .75f, true)
    internal val explicit = HashSet<String>()
    internal var bytes = 0L
    internal fun clear() = synchronized(values) { values.clear(); explicit.clear(); bytes = 0 }
}

class RuleCache internal constructor(private val ensureOpen: () -> Unit, private val clock: () -> Long,
                                     private val persistence: RulePersistenceBinding? = null,
                                     private val memoryState: RuleCacheMemory = RuleCacheMemory()) {
    private data class Entry(val value: Any, val deadline: Long)
    // CacheManager stores text in Room and binary values in ACache under independent keys.
    private val textBacking = ConcurrentHashMap<String, Entry>()
    private val binaryBacking = ConcurrentHashMap<String, Entry>()
    // CacheManager:17–20 uses a 50 MiB access-order cache, cost 40 + 2 * text.length.
    private val memory get() = memoryState.values
    private var memoryBytes: Long
        get() = memoryState.bytes
        set(value) { memoryState.bytes = value }
    @JvmOverloads @Synchronized fun put(key: String, value: Any, saveTime: Int = 0) {
        ensureOpen()
        val deadline = if (saveTime == 0) 0L else clock() + saveTime * 1000L
        if (value is ByteArray) {
            persist("binary", key, value, deadline)
            binaryBacking[key] = Entry(value.copyOf(), deadline)
        } else {
            val stored = value.toString()
            persist("text", key, stored.toByteArray(Charsets.UTF_8), deadline)
            textBacking[key] = Entry(stored, deadline)
            if (deadline == 0L) remember(key, stored, false) else deleteMemory(key)
        }
    }
    fun putMemory(key: String, value: Any) = remember(key, value, true)
    private fun remember(key: String, value: Any, explicit: Boolean) {
        ensureOpen()
        synchronized(memory) {
            memory.put(key, value)?.let { memoryBytes -= cost(it) }
            if (explicit) memoryState.explicit.add(key) else memoryState.explicit.remove(key)
            memoryBytes += cost(value)
            val iterator = memory.entries.iterator()
            while (memoryBytes > 50L * 1024 * 1024 && iterator.hasNext()) {
                val entry = iterator.next()
                memoryBytes -= cost(entry.value); memoryState.explicit.remove(entry.key); iterator.remove()
            }
        }
    }
    fun getFromMemory(key: String): Any? {
        ensureOpen()
        synchronized(memory) {
            val value = memory[key] ?: return null
            if (persistence == null || key in memoryState.explicit) return value
        }
        // Automatic text entries are only views of the shared owner. An explicit putMemory
        // remains a session-local shadow, but another session/JSC write must invalidate a view.
        val current = backingEntry("text", textBacking, key)?.takeIf { it.deadline == 0L }?.value
        return synchronized(memory) {
            if (key in memoryState.explicit) memory[key]
            else {
                if (current == null) deleteMemory(key) else remember(key, current, false)
                current
            }
        }
    }
    fun deleteMemory(key: String) { ensureOpen(); synchronized(memory) { memory.remove(key)?.let { memoryBytes -= cost(it) }; memoryState.explicit.remove(key) } }
    @Synchronized fun get(key: String): String? = get(key, false)
    @Synchronized fun get(key: String, onlyDisk: Boolean): String? {
        ensureOpen()
        if (!onlyDisk) (getFromMemory(key) as? String)?.let { return it }
        val entry = backingEntry("text", textBacking, key) ?: return null
        return (entry.value as? String)?.also { if (!onlyDisk && entry.deadline == 0L) remember(key, it, false) }
    }
    fun getInt(key: String): Int? = (getFromMemory(key) as? Int) ?: get(key, true)?.toIntOrNull()
    fun getLong(key: String): Long? = (getFromMemory(key) as? Long) ?: get(key, true)?.toLongOrNull()
    fun getDouble(key: String): Double? = (getFromMemory(key) as? Double) ?: get(key, true)?.toDoubleOrNull()
    fun getFloat(key: String): Float? = (getFromMemory(key) as? Float) ?: get(key, true)?.toFloatOrNull()
    fun getByteArray(key: String): ByteArray? { ensureOpen(); return (backingEntry("binary", binaryBacking, key)?.value as? ByteArray)?.copyOf() }
    @JvmOverloads fun putFile(key: String, value: String, saveTime: Int = 0): Nothing = unsupportedRule("cache.putFile requires a file-cache adapter")
    fun getFile(key: String): Nothing = unsupportedRule("cache.getFile requires a file-cache adapter")
    @Synchronized fun delete(key: String) {
        ensureOpen()
        persistence?.let { store ->
            val text = store.key("cache-text", key); val binary = store.key("cache-binary", key)
            store.update(setOf(text, binary)) { mapOf(text to null, binary to null) to Unit }
        }
        textBacking.remove(key); binaryBacking.remove(key); deleteMemory(key)
    }
    private data class StoredEntry(val deadline: Long, val data: String)
    internal fun textChange(key: String, value: String?): Map<String, ByteArray?> {
        val store = persistence ?: error("No persistent cache adapter")
        return if (value == null) mapOf(store.key("cache-text", key) to null, store.key("cache-binary", key) to null)
        else mapOf(store.key("cache-text", key) to GSON.toJson(StoredEntry(0, java.util.Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8)))).toByteArray(Charsets.UTF_8))
    }
    internal fun publishText(key: String, value: String?) {
        ensureOpen()
        if (value == null) { textBacking.remove(key); binaryBacking.remove(key); deleteMemory(key) }
        else { textBacking[key] = Entry(value, 0); remember(key, value, false) }
    }
    private fun persist(kind: String, key: String, value: ByteArray, deadline: Long) {
        persistence?.let { it.put(it.key("cache-$kind", key), GSON.toJson(StoredEntry(deadline, java.util.Base64.getEncoder().encodeToString(value))).toByteArray(Charsets.UTF_8)) }
    }
    private fun backingEntry(kind: String, backing: Map<String, Entry>, key: String): Entry? {
        val store = persistence ?: return liveEntry(backing, key)
        val bytes = store.read(store.key("cache-$kind", key)) ?: return null
        val stored = decodePersistent("cache entry") {
            val json = com.google.gson.JsonParser.parseString(bytes.toString(Charsets.UTF_8)).asJsonObject
            require(json.keySet() == setOf("deadline", "data") && json["data"].isJsonPrimitive && json["data"].asJsonPrimitive.isString)
            StoredEntry(java.math.BigDecimal(json["deadline"].asString).toBigIntegerExact().longValueExact(), json["data"].asString)
        }
        if (stored.deadline != 0L && stored.deadline <= clock()) return null
        val value = decodePersistent("cache payload") { java.util.Base64.getDecoder().decode(stored.data) }
        return Entry(if (kind == "text") value.toString(Charsets.UTF_8) else value, stored.deadline)
    }
    private fun liveEntry(backing: Map<String, Entry>, key: String): Entry? = backing[key]?.takeIf { it.deadline == 0L || it.deadline > clock() }
    private fun cost(value: Any): Long = 40L + 2L * value.toString().length
    internal fun clear(clearMemory: Boolean = true) { textBacking.clear(); binaryBacking.clear(); if (clearMemory) memoryState.clear() }
}

class RuleEnvironment(
    val platform: RulePlatform = RulePlatform(),
    clock: () -> Long = System::currentTimeMillis,
    internal val persistence: RulePersistenceBinding? = null,
    cacheMemory: RuleCacheMemory? = null,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    val state = RuleStateStore(::ensureOpen, persistence)
    val webBook = RuleWebBookState(::ensureOpen, persistence) { this }
    private val ownsCacheMemory = cacheMemory == null
    val cache = RuleCache(::ensureOpen, clock, persistence, cacheMemory ?: RuleCacheMemory())
    val cookie: RuleCookieHost get() { ensureOpen(); return platform.cookie }
    internal val scopes = RuleScopes(::ensureOpen)
    fun ensureOpen() { check(!closed.get()) { "Original-rule environment is closed" } }
    override fun close() {
        if (closed.compareAndSet(false, true)) { scopes.close(); cache.clear(ownsCacheMemory); state.clear(); webBook.clear() }
    }
}
