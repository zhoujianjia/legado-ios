package io.yuedu.legado.originalrule

import com.google.gson.Gson
import com.google.gson.JsonDeserializer
import com.google.gson.JsonDeserializationContext
import com.google.gson.JsonElement
import com.google.gson.JsonParseException
import com.google.gson.internal.LinkedTreeMap
import java.lang.reflect.Type
import kotlin.math.ceil
import com.google.gson.GsonBuilder
import com.google.gson.JsonSyntaxException
import com.google.gson.Strictness
import com.google.gson.ToNumberPolicy
import com.google.gson.reflect.TypeToken
import java.net.URL
import java.util.logging.Level
import java.util.logging.Logger

/** The pure utility subset used by the original AnalyzeRule, not the Android utility layer. */
internal val GSON: Gson = GsonBuilder()
    .registerTypeAdapter(object : TypeToken<Map<String?, Any?>?>() {}.type, MapDeserializerDoubleAsIntFix())
    .registerTypeAdapter(Int::class.java, IntJsonDeserializer())
    .registerTypeAdapter(String::class.java, StringJsonDeserializer())
    .disableHtmlEscaping().setPrettyPrinting()
    .setObjectToNumberStrategy(ToNumberPolicy.LONG_OR_DOUBLE).create()
internal val GSONStrict: Gson = GSON.newBuilder().setStrictness(Strictness.STRICT).create()
private val logger = Logger.getLogger("io.yuedu.legado.originalrule")

internal inline fun <reified T> Gson.fromJsonObject(json: String?): Result<T> = runCatching {
    if (json == null) throw JsonSyntaxException("解析字符串为空")
    fromJson(json, object : TypeToken<T>() {}.type) as T
}

internal inline fun <reified T> Gson.fromJsonArray(json: String?): Result<List<T>> = runCatching {
    if (json == null) throw JsonSyntaxException("解析字符串为空")
    val list = fromJson<List<T?>>(json, TypeToken.getParameterized(List::class.java, T::class.java).type)
    if (list.contains(null)) throw JsonSyntaxException("列表不能存在null元素，可能是json格式错误，通常为列表存在多余的逗号所致")
    @Suppress("UNCHECKED_CAST")
    list as List<T>
}

internal inline fun <K, V> MutableMap<K, V>.getOrPutLimit(key: K, maxSize: Int, defaultValue: () -> V): V {
    if (containsKey(key)) {
        @Suppress("UNCHECKED_CAST")
        return get(key) as V
    }
    return defaultValue().also { if (size < maxSize) put(key, it) }
}

internal fun String?.isJson(): Boolean = this?.trim()?.let {
    (it.startsWith("{") && it.endsWith("}")) || (it.startsWith("[") && it.endsWith("]"))
} ?: false
internal fun String?.isDataUrl(): Boolean = this?.let { AppPattern.dataUriRegex.matches(it) } ?: false
internal fun String.splitNotBlank(vararg delimiter: String, limit: Int = 0): Array<String> =
    split(*delimiter, limit = limit).map(String::trim).filterNot(String::isBlank).toTypedArray()
internal fun Throwable.printOnDebug() { logger.log(Level.FINE, "Original rule evaluation diagnostic", this) }
internal val Throwable.stackTraceStr: String get() = stackTraceToString()

internal object AppPattern {
    val JS_PATTERN = java.util.regex.Pattern.compile("<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", java.util.regex.Pattern.CASE_INSENSITIVE)
    val WebJS_PATTERN = java.util.regex.Pattern.compile("@webjs:([\\w\\W]{5,})", java.util.regex.Pattern.CASE_INSENSITIVE)
    val dataUriRegex = Regex("^data:.*?;base64,(.*)")
}

/** NetworkUtils:161–189 uses java.net.URL, including its javascript/data/blank cases. */
internal object NetworkUtils {
    fun getAbsoluteURL(baseURL: String?, relativePath: String): String {
        if (baseURL.isNullOrEmpty()) return relativePath.trim()
        val url = try { URL(baseURL.substringBefore(",")) } catch (error: Exception) {
            error.printOnDebug(); null
        }
        return getAbsoluteURL(url, relativePath)
    }
    fun getAbsoluteURL(baseURL: URL?, relativePath: String): String {
        val trimmed = relativePath.trim()
        if (baseURL == null) return trimmed
        if (trimmed.startsWith("http://", true) || trimmed.startsWith("https://", true) || trimmed.isDataUrl()) return trimmed
        if (trimmed.startsWith("javascript")) return ""
        return try { URL(baseURL, relativePath).toString() } catch (error: Exception) {
            error.printOnDebug(); trimmed
        }
    }
}

internal object Debug {
    fun log(message: String) { logger.fine(message) }
}
internal class NoStackTraceException(message: String) : RuntimeException(message, null, false, false)

// GsonExtensions.kt:140?249; Android rule-model and LocalDate adapters are outside this model boundary.
internal class StringJsonDeserializer : JsonDeserializer<String?> {

    override fun deserialize(
        json: JsonElement,
        typeOfT: Type,
        context: JsonDeserializationContext?
    ): String? {
        return when {
            json.isJsonPrimitive -> json.asString
            json.isJsonNull -> null
            else -> json.toString()
        }
    }

}

/**
 * int类型转化失败时跳过
 */
internal class IntJsonDeserializer : JsonDeserializer<Int?> {

    override fun deserialize(
        json: JsonElement,
        typeOfT: Type?,
        context: JsonDeserializationContext?
    ): Int? {
        return when {
            json.isJsonPrimitive -> {
                val prim = json.asJsonPrimitive
                if (prim.isNumber) {
                    prim.asNumber.toInt()
                } else {
                    null
                }
            }

            else -> null
        }
    }

}

/**
 * 修复Int变为Double的问题
 */
internal class MapDeserializerDoubleAsIntFix :
    JsonDeserializer<Map<String, Any?>?> {

    @Throws(JsonParseException::class)
    override fun deserialize(
        jsonElement: JsonElement,
        type: Type,
        jsonDeserializationContext: JsonDeserializationContext
    ): Map<String, Any?>? {
        @Suppress("unchecked_cast")
        return read(jsonElement) as? Map<String, Any?>
    }

    fun read(json: JsonElement): Any? {
        when {
            json.isJsonArray -> {
                val list: MutableList<Any?> = ArrayList()
                val arr = json.asJsonArray
                for (anArr in arr) {
                    list.add(read(anArr))
                }
                return list
            }

            json.isJsonObject -> {
                val map: MutableMap<String, Any?> =
                    LinkedTreeMap()
                val obj = json.asJsonObject
                val entitySet =
                    obj.entrySet()
                for ((key, value) in entitySet) {
                    map[key] = read(value)
                }
                return map
            }

            json.isJsonPrimitive -> {
                val prim = json.asJsonPrimitive
                when {
                    prim.isBoolean -> {
                        return prim.asBoolean
                    }

                    prim.isString -> {
                        return prim.asString
                    }

                    prim.isNumber -> {
                        val num: Number = prim.asNumber
                        // here you can handle double int/long values
                        // and return any type you want
                        // this solution will transform 3.0 float to long values
                        return if (ceil(num.toDouble()) == num.toLong().toDouble()) {
                            num.toLong()
                        } else {
                            num.toDouble()
                        }
                    }
                }
            }
        }
        return null
    }

}
