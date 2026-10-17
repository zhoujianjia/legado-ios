package io.yuedu.legado

import com.google.gson.*
import com.google.gson.reflect.TypeToken
import java.net.URL

/**
 * Finite JSON DTO projection of the archive's JsSourceMarshaller/JsSourceBook.
 * It does not implement Room entities, computed fields, timestamps, or persistence.
 */
internal object MainJsResultMarshaller {
    private const val BOOK_TYPES = 236 // BookType.allBookType: video|text|audio|image|webFile.
    private const val WEB_FILE = 128
    private val bookOperations = setOf("details", "getBookInfo", "toc", "getChapters")

    // These two adapters are part of the original entity deserialization contract
    // (utils/GsonExtensions.kt), including their intentionally permissive coercions.
    private val dtoGson = GsonBuilder()
        .registerTypeAdapter(String::class.java, JsonDeserializer<String?> { value, _, _ ->
            when { value.isJsonNull -> null; value.isJsonPrimitive -> value.asString; else -> value.toString() }
        })
        .registerTypeAdapter(Int::class.java, JsonDeserializer<Int?> { value, _, _ ->
            value.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isNumber }?.asNumber?.toInt()
        })
        .disableHtmlEscaping().setPrettyPrinting().create()

    /** JsSourceBook resets the source type before passing the Book to the script. */
    fun prepareInput(operation: String, input: JsonObject, source: JsonObject): JsonObject {
        val prepared = input.deepCopy()
        if (operation !in bookOperations) return prepared
        val value = prepared["book"]
        if (value != null && !value.isJsonNull && !value.isJsonObject)
            throw RuntimeFailure("INVALID_ARGUMENT", "book 不是对象")
        val book = value?.takeIf { it.isJsonObject }?.asJsonObject ?: JsonObject()
        listOf("bookUrl", "tocUrl", "name", "author").forEach { field ->
            book.addProperty(field, originalString(book[field], ""))
        }
        val oldType = originalInt(book["type"], 8)
        book.addProperty("type", (oldType and BOOK_TYPES.inv()) or sourceType(source))
        prepared.add("book", book)
        return prepared
    }

    fun marshal(operation: String, result: JsonElement, input: JsonObject, source: JsonObject): JsonElement = when (operation) {
        "search", "explore" -> search(result, source)
        "details", "getBookInfo" -> details(result, prepareInput(operation, input, source), source)
        "toc", "getChapters" -> chapters(result, prepareInput(operation, input, source))
        else -> result
    }

    private fun search(result: JsonElement, source: JsonObject): JsonArray {
        if (isAbsent(result)) return JsonArray()
        val decoded = decode(result, "search/explore 返回值不是数组")
        if (!decoded.isJsonArray) throw RuntimeFailure("INVALID_RESULT", "search/explore 返回值不是数组")
        return JsonArray().apply {
            decoded.asJsonArray.forEach { value ->
                if (!value.isJsonObject) return@forEach
                val dto = runCatching { dtoGson.fromJson(value, SearchDto::class.java) }.getOrNull() ?: return@forEach
                // Archive JsSourceMarshaller:49 validates outside runCatching.
                // Gson can reflect an explicit JSON null into these non-null fields;
                // keep its failing isBlank call rather than silently dropping the row.
                if (dto.name.isBlank() || dto.bookUrl.isBlank()) return@forEach
                val output = dtoGson.toJsonTree(dto).asJsonObject
                output.addProperty("origin", originalString(source["bookSourceUrl"], ""))
                output.addProperty("originName", originalString(source["bookSourceName"], ""))
                output.addProperty("originOrder", originalInt(source["customOrder"], 0))
                output.addProperty("type", validType(value.asJsonObject["type"]) ?: sourceType(source))
                add(output)
            }
        }
    }

    private fun chapters(result: JsonElement, input: JsonObject): JsonArray {
        val decoded = if (isAbsent(result)) JsonArray() else decode(result, "getChapters 返回值不是数组")
        if (!decoded.isJsonArray)
            throw RuntimeFailure("INVALID_RESULT", "getChapters 返回值不是数组")
        val book = input["book"].asJsonObject
        val bookUrl = book["bookUrl"].asString
        val tocUrl = book["tocUrl"].asString
        val output = JsonArray()
        decoded.asJsonArray.forEach { value ->
            if (!value.isJsonObject) return@forEach
            val dto = runCatching { dtoGson.fromJson(value, ChapterDto::class.java) }.getOrNull() ?: return@forEach
            // Archive JsSourceMarshaller:148 has the same unguarded, short-circuit
            // validation: missing fields default to "", explicit null must fail.
            val title = dto.title
            val url = dto.url
            if (title.isBlank() || url.isBlank()) return@forEach
            dto.url = if (dto.isVolume && url == title) url else absoluteUrl(tocUrl, url)
            dto.bookUrl = bookUrl
            dto.baseUrl = tocUrl
            dto.index = output.size()
            output.add(dtoGson.toJsonTree(dto))
        }
        // JsSourceMarshaller returns []; its JsSourceBook caller raises TocEmptyException.
        if (output.size() == 0) throw RuntimeFailure("TOC_EMPTY", "目录列表为空")
        return output
    }

    private fun details(result: JsonElement, input: JsonObject, source: JsonObject): JsonObject {
        val book = input["book"].asJsonObject.deepCopy()
        val canReName = input["canReName"]?.takeUnless { it.isJsonNull }?.asBoolean ?: true
        if (!isAbsent(result)) {
            val decoded = decode(result, "getBookInfo 返回值不是对象")
            if (!decoded.isJsonObject) throw RuntimeFailure("INVALID_RESULT", "getBookInfo 返回值不是对象")
            decoded.asJsonObject.entrySet().forEach { (field, value) ->
                if (value.isJsonNull) return@forEach
                when (field) {
                    "name" -> if (canReName) book.addProperty(field, detailString(field, value))
                    "author" -> if (canReName || book["author"].asString.isEmpty()) book.addProperty(field, detailString(field, value))
                    "intro", "coverUrl", "kind", "wordCount", "latestChapterTitle", "tocUrl" ->
                        book.addProperty(field, detailString(field, value))
                    "type" -> validType(value)?.let { book.addProperty("type", it) }
                    "downloadUrls" -> downloadUrls(value, book["bookUrl"].asString)?.let { book.add(field, it) }
                    "variable" -> variable(value)?.let { book.addProperty(field, it) }
                }
            }
        }
        if (originalInt(source["bookSourceType"], 0) == 3)
            book.addProperty("type", book["type"].asInt or sourceType(source))
        val isWebFile = book["type"].asInt and WEB_FILE != 0
        if (!isWebFile && book["tocUrl"].asString.isBlank()) book.add("tocUrl", book["bookUrl"].deepCopy())
        if (isWebFile && (!book.has("downloadUrls") || book["downloadUrls"].isJsonNull ||
                book["downloadUrls"].asJsonArray.size() == 0))
            throw RuntimeFailure("DOWNLOAD_URLS_EMPTY", "下载链接为空")
        return book
    }

    private fun downloadUrls(value: JsonElement, bookUrl: String): JsonArray? = runCatching {
        val urls = value.asJsonArray.map { item ->
            require(item.isJsonPrimitive && item.asJsonPrimitive.isString)
            item.asString.trim()
        }.filter { it.isNotEmpty() && !it.startsWith("javascript", ignoreCase = true) }
            .map { absoluteUrl(bookUrl, it) }.filter { it.isNotEmpty() }.distinct()
        JsonArray().apply { urls.forEach(::add) }
    }.getOrNull()

    private fun variable(value: JsonElement): String? = runCatching {
        val mapType = TypeToken.getParameterized(Map::class.java, String::class.java, String::class.java).type
        val variables: Map<String, String>? = when {
            value.isJsonObject -> dtoGson.fromJson(value, mapType)
            value.isJsonPrimitive && value.asJsonPrimitive.isString -> dtoGson.fromJson(value.asString, mapType)
            else -> null
        }
        variables?.let { dtoGson.toJson(it) }
    }.getOrNull()

    private fun validType(value: JsonElement?): Int? = runCatching { value?.asInt }.getOrNull()
        ?.takeIf { it != 0 && it and BOOK_TYPES.inv() == 0 }

    private fun sourceType(source: JsonObject): Int = when (originalInt(source["bookSourceType"], 0)) {
        1 -> 32; 2 -> 64; 3 -> 136; 4 -> 4; else -> 8
    }

    private fun originalInt(value: JsonElement?, default: Int): Int = value?.takeUnless { it.isJsonNull }
        ?.let { dtoGson.fromJson(it, Int::class.java) } ?: default

    private fun originalString(value: JsonElement?, default: String): String = value?.takeUnless { it.isJsonNull }
        ?.let { dtoGson.fromJson(it, String::class.java) } ?: default

    private fun isAbsent(value: JsonElement) = value.isJsonNull ||
        (value.isJsonPrimitive && value.asJsonPrimitive.isString && value.asString.isBlank())

    private fun decode(value: JsonElement, message: String): JsonElement =
        if (!value.isJsonPrimitive || !value.asJsonPrimitive.isString) value else try {
            JsonParser.parseString(value.asString)
        } catch (_: Exception) { throw RuntimeFailure("INVALID_RESULT", message) }

    private fun detailString(field: String, value: JsonElement): String = try { value.asString }
    catch (error: Exception) {
        throw RuntimeFailure("INVALID_RESULT", "getBookInfo 字段 $field 无法读取为字符串: ${error.message}")
    }

    /** NetworkUtils.getAbsoluteURL's URL-constructor behavior, including comma options. */
    private fun absoluteUrl(base: String, relative: String): String {
        val trimmed = relative.trim()
        val parsed = runCatching { URL(base.substringBefore(',')) }.getOrNull() ?: return trimmed
        if (trimmed.startsWith("http://", true) || trimmed.startsWith("https://", true) ||
            Regex("^data:.*?;base64,(.*)").matches(trimmed)) return trimmed
        if (trimmed.startsWith("javascript")) return ""
        return runCatching { URL(parsed, relative).toString() }.getOrDefault(trimmed)
    }

    // Stable JSON fields of the corresponding entities; no generated time/computed properties.
    private data class SearchDto(
        var bookUrl: String = "", var name: String = "", var author: String? = "",
        var origin: String? = "", var originName: String? = "", var originOrder: Int = 0,
        var type: Int = 8, var tocUrl: String? = "", var kind: String? = null,
        var coverUrl: String? = null, var intro: String? = null, var wordCount: String? = null,
        var latestChapterTitle: String? = null, var variable: String? = null,
        var chapterWordCountText: String? = null, var chapterWordCount: Int = -1,
        var respondTime: Int = -1, var time: Long? = null,
        var infoHtml: String? = null, var tocHtml: String? = null,
    )

    private data class ChapterDto(
        var url: String = "", var title: String = "", var isVolume: Boolean = false,
        var baseUrl: String? = "", var bookUrl: String? = "", var index: Int = 0,
        var isVip: Boolean = false, var isPay: Boolean = false,
        var resourceUrl: String? = null, var tag: String? = null, var wordCount: String? = null,
        var start: Long? = null, var end: Long? = null, var startFragmentId: String? = null,
        var endFragmentId: String? = null, var variable: String? = null, var imgUrl: String? = null,
    )
}
