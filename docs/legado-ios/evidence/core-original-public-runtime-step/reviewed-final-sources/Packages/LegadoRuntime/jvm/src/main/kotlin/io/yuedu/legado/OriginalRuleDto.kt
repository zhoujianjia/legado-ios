package io.yuedu.legado

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.yuedu.legado.originalrule.RuleEnvironment

/** Business-only projection of the finite retained entities. Never reflects an environment or
 * lazy delegate over JNI, synthesizes App UUIDs, or claims the full Android entity ABI. */
internal object OriginalRuleDto {
    private val bookFields = setOf("bookUrl", "origin", "name", "author", "tocUrl", "kind", "wordCount", "variable", "infoHtml", "tocHtml",
        "originName", "originOrder", "type", "coverUrl", "intro", "latestChapterTitle", "latestChapterTime", "lastCheckTime", "lastCheckCount",
        "totalChapterNum", "durChapterTitle", "durChapterIndex", "reverseToc")
    private val chapterFields = setOf("url", "title", "isVolume", "baseUrl", "bookUrl", "index", "isVip", "isPay", "resourceUrl", "tag",
        "wordCount", "start", "end", "startFragmentId", "endFragmentId", "variable", "imgUrl", "titleMD5")

    fun book(value: JsonObject, environment: RuleEnvironment, sourceUrl: String): Book {
        require(value.keySet().all { it in bookFields }) { "Unknown original book field" }
        val url = value.requiredText("bookUrl"); require(url.isNotBlank()) { "book.bookUrl must not be blank" }
        require(value.requiredText("origin") == sourceUrl) { "Book origin belongs to another source" }
        if (value.int("type", 8) != 8) throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Public original mode requires a text Book DTO")
        val book = Book(environment, name = value.text("name") ?: "", author = value.text("author") ?: "", bookUrl = url,
            tocUrl = value.text("tocUrl") ?: "", origin = sourceUrl, kind = value.text("kind"), wordCount = value.text("wordCount"),
            variable = variable(value), infoHtml = value.text("infoHtml"), tocHtml = value.text("tocHtml"), originName = value.text("originName") ?: "",
            originOrder = value.int("originOrder", 0), type = value.int("type", 8), coverUrl = value.text("coverUrl"), intro = value.text("intro"),
            latestChapterTitle = value.text("latestChapterTitle"), latestChapterTime = value.long("latestChapterTime") ?: System.currentTimeMillis(),
            lastCheckTime = value.long("lastCheckTime") ?: System.currentTimeMillis(), lastCheckCount = value.int("lastCheckCount", 0),
            totalChapterNum = value.int("totalChapterNum", 0), durChapterTitle = value.text("durChapterTitle"), durChapterIndex = value.int("durChapterIndex", 0))
        book.setReverseToc(value.boolean("reverseToc", false))
        return book
    }

    fun chapter(value: JsonObject, environment: RuleEnvironment, book: Book): BookChapter {
        require(value.keySet().all { it in chapterFields }) { "Unknown original chapter field" }
        require(value.requiredText("bookUrl") == book.bookUrl) { "Chapter belongs to another book" }
        val url = value.requiredText("url"); require(url.isNotBlank()) { "chapter.url must not be blank" }
        val index = value.int("index"); require(index >= 0) { "chapter.index must not be negative" }
        return BookChapter(environment, url, value.requiredText("title"), value.boolean("isVolume", false), value.requiredText("baseUrl"),
            book.bookUrl, index, value.boolean("isVip", false), value.boolean("isPay", false), value.text("resourceUrl"), value.text("tag"),
            value.text("wordCount"), value.long("start"), value.long("end"), value.text("startFragmentId"), value.text("endFragmentId"),
            variable(value), value.text("imgUrl")).also { it.titleMD5 = value.text("titleMD5") }
    }

    fun book(book: Book): JsonObject = jsonObject(
        "bookUrl" to book.bookUrl, "origin" to book.origin, "name" to book.name, "author" to book.author, "tocUrl" to book.tocUrl,
        "kind" to book.kind, "wordCount" to book.wordCount, "variable" to book.variable, "infoHtml" to book.infoHtml, "tocHtml" to book.tocHtml,
        "originName" to book.originName, "originOrder" to book.originOrder, "type" to book.type, "coverUrl" to book.coverUrl, "intro" to book.intro,
        "latestChapterTitle" to book.latestChapterTitle, "latestChapterTime" to book.latestChapterTime, "lastCheckTime" to book.lastCheckTime,
        "lastCheckCount" to book.lastCheckCount, "totalChapterNum" to book.totalChapterNum, "durChapterTitle" to book.durChapterTitle,
        "durChapterIndex" to book.durChapterIndex, "reverseToc" to book.getReverseToc())

    fun chapter(chapter: BookChapter): JsonObject = jsonObject(
        "url" to chapter.url, "title" to chapter.title, "isVolume" to chapter.isVolume, "baseUrl" to chapter.baseUrl, "bookUrl" to chapter.bookUrl,
        "index" to chapter.index, "isVip" to chapter.isVip, "isPay" to chapter.isPay, "resourceUrl" to chapter.resourceUrl, "tag" to chapter.tag,
        "wordCount" to chapter.wordCount, "start" to chapter.start, "end" to chapter.end, "startFragmentId" to chapter.startFragmentId,
        "endFragmentId" to chapter.endFragmentId, "variable" to chapter.variable, "imgUrl" to chapter.imgUrl, "titleMD5" to chapter.titleMD5)

    private fun variable(value: JsonObject): String? = value.text("variable")?.also { raw ->
        val parsed = JsonParser.parseString(raw)
        require(parsed.isJsonObject && parsed.asJsonObject.entrySet().all { (_, item) -> item.isJsonPrimitive && item.asJsonPrimitive.isString }) {
            "Book/chapter variable must encode a string map"
        }
    }
    internal fun JsonObject.requiredObject(key: String): JsonObject = get(key)?.takeIf(JsonElement::isJsonObject)?.asJsonObject
        ?: throw IllegalArgumentException("$key must be an object")
    internal fun JsonObject.requiredText(key: String): String = text(key) ?: throw IllegalArgumentException("$key must be a string")
    internal fun JsonObject.text(key: String): String? = get(key)?.takeUnless(JsonElement::isJsonNull)?.let {
        require(it.isJsonPrimitive && it.asJsonPrimitive.isString) { "$key must be a string" }; it.asString
    }
    internal fun JsonObject.long(key: String): Long? = get(key)?.takeUnless(JsonElement::isJsonNull)?.let {
        require(it.isJsonPrimitive && it.asJsonPrimitive.isNumber) { "$key must be an integer" }
        try { java.math.BigDecimal(it.asString).toBigIntegerExact().longValueExact() }
        catch (_: ArithmeticException) { throw IllegalArgumentException("$key must be an Int64 integer") }
    }
    internal fun JsonObject.int(key: String, default: Int? = null): Int {
        val value = long(key) ?: return default ?: throw IllegalArgumentException("$key must be an integer")
        require(value in Int.MIN_VALUE..Int.MAX_VALUE) { "$key is outside Int32" }; return value.toInt()
    }
    internal fun JsonObject.boolean(key: String, default: Boolean): Boolean = get(key)?.let {
        require(it.isJsonPrimitive && it.asJsonPrimitive.isBoolean) { "$key must be a boolean" }; it.asBoolean
    } ?: default
}
