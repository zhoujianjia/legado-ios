package com.script.rhino

/** AndroidX LruCache's bounded, synchronized subset used by the original engine. */
internal class LruCache<K, V>(private val capacity: Int) {
    private val entries = object : LinkedHashMap<K, V>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?) = size > capacity
    }
    @Synchronized operator fun get(key: K): V? = entries[key]
    @Synchronized fun put(key: K, value: V): V? = entries.put(key, value)
}
