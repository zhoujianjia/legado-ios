package io.yuedu.legado.reference

import io.yuedu.legado.originalrule.GSON
import io.yuedu.legado.originalrule.fromJsonObject


/**
 * 发现按钮信息
 */
class OriginalInfoMapOracle(val sourceUrl: String): MutableMap<String, String> {
    private var actualMap: MutableMap<String, String>
    var needSave = false
    private var saveTime = 0

    init {
        val cache = ReferenceInfoMapCache.get("infoMap_${sourceUrl}")
        actualMap = GSON.fromJsonObject<MutableMap<String, String>>(cache).getOrNull() ?: mutableMapOf()
    }

    /**
     * time 保存时间 单位为秒
     */
    @JvmOverloads
    fun save(time: Int = 0, need: Boolean = true) {
        needSave = need
        saveTime = time
    }

    fun saveNow() {
        val json = GSON.toJson(actualMap)
        ReferenceInfoMapCache.put("infoMap_${sourceUrl}", json, saveTime)
        needSave = false
    }

    fun get(): MutableMap<String, String> {
        return actualMap
    }

    fun set(value: Map<String, String>) {
        actualMap = value.toMutableMap()
    }

    override fun get(key: String) = actualMap[key]
    override fun put(key: String, value: String) = actualMap.put(key, value)
    override fun remove(key: String) = actualMap.remove(key)
    override fun putAll(from: Map<out String, String>) = actualMap.putAll(from)
    override fun containsKey(key: String) = actualMap.containsKey(key)
    override fun containsValue(value: String) = actualMap.containsValue(value)
    override val size get() = actualMap.size
    override val entries get() = actualMap.entries
    override val keys get() = actualMap.keys
    override val values get() = actualMap.values
    override fun isEmpty() = actualMap.isEmpty()
    override fun clear() = actualMap.clear()
}
// Controlled cache captures parameters of the unchanged locked InfoMap bodies;
// no Android Room/WebKit execution or independent CacheManager port is claimed.
internal object ReferenceInfoMapCache {
    val values = linkedMapOf<String, String>()
    val writes = mutableListOf<Triple<String, String, Int>>()
    var fail = false
    fun get(key: String): String? = values[key]
    fun put(key: String, value: String, time: Int) {
        if (fail) throw java.io.IOException("Owned original oracle cache write failed")
        values[key] = value; writes += Triple(key, value, time)
    }
    fun reset() { values.clear(); writes.clear(); fail = false }
}
