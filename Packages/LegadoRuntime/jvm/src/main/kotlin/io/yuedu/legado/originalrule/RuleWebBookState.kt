package io.yuedu.legado.originalrule

import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.Book
import java.util.concurrent.ConcurrentHashMap

/** Owned chapter/content state; an injected adapter never creates a parallel App/Room database. */
class RuleWebBookState internal constructor(private val ensureOpen: () -> Unit,
                                           private val persistence: RulePersistenceBinding? = null,
                                           private val environment: () -> RuleEnvironment) {
    private val chapters = ConcurrentHashMap<String, List<BookChapter>>()
    fun chapters(bookUrl: String): List<BookChapter> {
        ensureOpen()
        chapters[bookUrl]?.let { return it }
        val store = persistence ?: return emptyList()
        val bytes = store.read(store.key("toc", bookUrl)) ?: return emptyList()
        val loaded = decodeChapters(bookUrl, bytes).map { it.restore(environment()) }
        chapters[bookUrl] = loaded
        return loaded
    }
    internal fun publish(bookUrl: String, value: List<BookChapter>) {
        ensureOpen()
        require(value.all { it.bookUrl == bookUrl && it.environment === environment() }) { "Chapter belongs to another book/owner" }
        persistence?.let { it.put(it.key("toc", bookUrl), encodeChapters(value)) }
        chapters[bookUrl] = value.toList()
    }

    internal data class ContentSaveToken(val bookUrl: String, val index: Int, val chapterUrl: String,
                                         val name: String, val author: String, val version: Long)
    private data class ContentRecord(val version: Long, val bookUrl: String, val index: Int, val chapterUrl: String, val name: String, val author: String,
                                     val title: String, val imgUrl: String?, val body: String)
    private fun store() = persistence ?: unsupportedRule("original WebBook persistent content cache")
    private fun contentKey(bookUrl: String, index: Int) = store().key("content", bookUrl, index.toString())
    private fun record(bytes: ByteArray?): ContentRecord? = bytes?.let { decodePersistent("chapter content") {
        val json = com.google.gson.JsonParser.parseString(it.toString(Charsets.UTF_8)).asJsonObject
        require(json.keySet().containsAll(setOf("version", "bookUrl", "index", "chapterUrl", "name", "author", "title", "body")))
        GSON.fromJson(json, ContentRecord::class.java).also { row -> require(row.version >= 0 && row.index >= 0); requireNotNull(row.body); requireNotNull(row.chapterUrl); requireNotNull(row.name); requireNotNull(row.author); requireNotNull(row.title) }
    } }
    internal fun contentSaveToken(book: Book, chapter: BookChapter): ContentSaveToken {
        ensureOpen(); require(book.environment === environment() && chapter.environment === environment())
        val row = record(store().read(contentKey(book.bookUrl, chapter.index)))
        return ContentSaveToken(book.bookUrl, chapter.index, chapter.url, book.name, book.author, row?.version ?: 0)
    }
    internal fun getContent(book: Book, chapter: BookChapter, token: ContentSaveToken = contentSaveToken(book, chapter)): String? {
        ensureOpen()
        if (!matches(book, chapter, token)) return null
        val row = record(store().read(contentKey(book.bookUrl, chapter.index))) ?: return null
        if (row.bookUrl != book.bookUrl || row.index != chapter.index || row.chapterUrl != chapter.url || row.title != chapter.title || row.name != book.name || row.author != book.author) return null
        return row.body.takeIf(String::isNotEmpty)
    }
    private fun matches(book: Book, chapter: BookChapter, token: ContentSaveToken): Boolean =
        token.bookUrl == book.bookUrl && token.index == chapter.index && token.chapterUrl == chapter.url && token.name == book.name && token.author == book.author

    /** Retained ContentSaveFence writeIfCurrent: a normal download does not advance the edit generation. */
    internal fun saveContent(book: Book, chapter: BookChapter, content: String, token: ContentSaveToken): Boolean {
        ensureOpen()
        if (!matches(book, chapter, token)) return false
        val store = store(); val contentKey = contentKey(book.bookUrl, chapter.index); val tocKey = store.key("toc", book.bookUrl)
        val saved = store.update(setOf(contentKey, tocKey)) { prior ->
            val old = record(prior[contentKey])
            if ((old?.version ?: 0) != token.version) return@update emptyMap<String, ByteArray?>() to false
            // A refreshed TOC may reuse the index for a different chapter while this download is
            // in flight. Check the current durable identity in the same CAS as the body/metadata.
            val toc = prior[tocKey]?.let { decodeChapters(book.bookUrl, it) }
            if (toc != null && toc.none { it.index == chapter.index && it.url == chapter.url })
                return@update emptyMap<String, ByteArray?>() to false
            val sameContent = old?.takeIf { it.bookUrl == book.bookUrl && it.index == chapter.index && it.chapterUrl == chapter.url &&
                it.name == book.name && it.author == book.author && it.title == chapter.title }
            val row = ContentRecord(token.version, book.bookUrl, chapter.index, chapter.url, book.name, book.author, chapter.title, chapter.imgUrl, content.ifEmpty { sameContent?.body.orEmpty() })
            val changes = mutableMapOf<String, ByteArray?>(contentKey to GSON.toJson(row).toByteArray(Charsets.UTF_8))
            toc?.let { list ->
                changes[tocKey] = GSON.toJson(list.map { if (it.index == chapter.index && it.url == chapter.url) it.copy(title = chapter.title, imgUrl = chapter.imgUrl) else it }).toByteArray(Charsets.UTF_8)
            }
            changes to true
        }
        if (saved) chapters[book.bookUrl]?.firstOrNull { it.index == chapter.index && it.url == chapter.url }?.let { it.title = chapter.title; it.imgUrl = chapter.imgUrl }
        return saved
    }
    /** Successful atomic owner replacement invalidates older network save tokens. */
    internal fun replaceContent(book: Book, chapter: BookChapter, content: String) {
        ensureOpen(); val store = store(); val key = contentKey(book.bookUrl, chapter.index)
        store.update(setOf(key)) { prior ->
            val version = Math.addExact(record(prior[key])?.version ?: 0, 1)
            mapOf(key to GSON.toJson(ContentRecord(version, book.bookUrl, chapter.index, chapter.url, book.name, book.author, chapter.title, chapter.imgUrl, content)).toByteArray(Charsets.UTF_8)) to Unit
        }
    }
    private data class StoredChapter(val url: String, val title: String, val isVolume: Boolean, val baseUrl: String,
        val bookUrl: String, val index: Int, val isVip: Boolean, val isPay: Boolean, val resourceUrl: String?, val tag: String?,
        val wordCount: String?, val start: Long?, val end: Long?, val startFragmentId: String?, val endFragmentId: String?, val variable: String?, val imgUrl: String?) {
        fun restore(env: RuleEnvironment) = BookChapter(env, url, title, isVolume, baseUrl, bookUrl, index, isVip, isPay, resourceUrl, tag,
            wordCount, start, end, startFragmentId, endFragmentId, variable, imgUrl)
    }
    private fun encodeChapters(value: List<BookChapter>) = GSON.toJson(value.map { c -> StoredChapter(c.url, c.title, c.isVolume, c.baseUrl,
        c.bookUrl, c.index, c.isVip, c.isPay, c.resourceUrl, c.tag, c.wordCount, c.start, c.end, c.startFragmentId, c.endFragmentId, c.variable, c.imgUrl) }).toByteArray(Charsets.UTF_8)
    private fun decodeChapters(bookUrl: String, bytes: ByteArray): List<StoredChapter> = decodePersistent("chapter list") {
        val json = com.google.gson.JsonParser.parseString(bytes.toString(Charsets.UTF_8)).asJsonArray
        json.forEach { item ->
            val row = item.asJsonObject
            require(listOf("url", "title", "baseUrl", "bookUrl").all { key -> row[key]?.let { it.isJsonPrimitive && it.asJsonPrimitive.isString } == true })
            require(java.math.BigDecimal(row["index"].asString).toBigIntegerExact().intValueExact() >= 0)
        }
        GSON.fromJson(json, Array<StoredChapter>::class.java).toList().also { list ->
            require(list.all { it.bookUrl == bookUrl })
        }
    }
    internal fun clear() = chapters.clear()
    // Android default preferences are made explicit for this transient runtime.
    var threadCount: Int = 32
        set(value) { require(value > 0); field = value }
    var tocCountWords: Boolean = true
    var adaptSpecialStyle: Boolean = true
}
