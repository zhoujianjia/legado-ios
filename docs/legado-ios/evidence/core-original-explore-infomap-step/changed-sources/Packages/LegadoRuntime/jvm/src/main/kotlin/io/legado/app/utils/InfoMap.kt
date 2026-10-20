package io.legado.app.utils

import io.yuedu.legado.originalrule.GSON
import io.yuedu.legado.originalrule.OriginalExploreContexts
import io.yuedu.legado.originalrule.fromJsonObject
import java.util.Collections

/** Port of the locked utils/InfoMap.kt. Cache calls bind to the current original
 * invocation; the process LRU object never retains an old environment or owner.
 * save() marks only; original UI pause/savePending or explicit saveNow persists.
 * The live backing/view ABI remains java.util.Map. A checked String map is an
 * embedding boundary: erased raw Java maps cannot retain source/task objects. */
class InfoMap(val sourceUrl: String) : MutableMap<String, String> {
    private var actualMap: MutableMap<String, String>
    var needSave = false
    private var saveTime = 0
    init {
        val cache = OriginalExploreContexts.initialCache(sourceUrl).get("infoMap_${sourceUrl}")
        actualMap = checkedCopy(GSON.fromJsonObject<MutableMap<String, String>>(cache).getOrNull() ?: emptyMap())
    }
    @JvmOverloads fun save(time: Int = 0, need: Boolean = true) {
        OriginalExploreContexts.check(this)
        needSave = need; saveTime = time
    }
    fun saveNow() {
        OriginalExploreContexts.check(this)
        val json = GSON.toJson(actualMap)
        OriginalExploreContexts.cache(this).put("infoMap_${sourceUrl}", json, saveTime)
        needSave = false
    }
    fun get(): MutableMap<String, String> { OriginalExploreContexts.check(this); return actualMap }
    fun set(value: Map<String, String>) { OriginalExploreContexts.check(this); actualMap = checkedCopy(value) }
    private fun checkedCopy(value: Map<String, String>): MutableMap<String, String> =
        Collections.checkedMap(LinkedHashMap<String, String>(), String::class.java, String::class.java).also { it.putAll(value) }
    override fun get(key: String): String? { OriginalExploreContexts.check(this); return actualMap[key] }
    override fun put(key: String, value: String): String? { OriginalExploreContexts.check(this); return actualMap.put(key, value) }
    override fun remove(key: String): String? { OriginalExploreContexts.check(this); return actualMap.remove(key) }
    override fun putAll(from: Map<out String, String>) { OriginalExploreContexts.check(this); actualMap.putAll(from) }
    override fun containsKey(key: String): Boolean { OriginalExploreContexts.check(this); return actualMap.containsKey(key) }
    override fun containsValue(value: String): Boolean { OriginalExploreContexts.check(this); return actualMap.containsValue(value) }
    override val size: Int get() { OriginalExploreContexts.check(this); return actualMap.size }
    override val entries: MutableSet<MutableMap.MutableEntry<String, String>> get() { OriginalExploreContexts.check(this); return actualMap.entries }
    override val keys: MutableSet<String> get() { OriginalExploreContexts.check(this); return actualMap.keys }
    override val values: MutableCollection<String> get() { OriginalExploreContexts.check(this); return actualMap.values }
    override fun isEmpty(): Boolean { OriginalExploreContexts.check(this); return actualMap.isEmpty() }
    override fun clear() { OriginalExploreContexts.check(this); actualMap.clear() }
}
