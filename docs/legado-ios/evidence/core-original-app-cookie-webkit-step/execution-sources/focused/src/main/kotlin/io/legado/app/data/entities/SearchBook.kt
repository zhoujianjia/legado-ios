package io.legado.app.data.entities

import io.yuedu.legado.originalrule.*

/** Retained SearchBook fields/conversion; transient environment storage, no Room/UI. */
data class SearchBook(
    @Transient internal val environment: RuleEnvironment,

    override var bookUrl: String = "",
    /** 书源 */
    var origin: String = "",
    var originName: String = "",
    /** BookType */
    var type: Int = 8,
    override var name: String = "",
    override var author: String = "",
    override var kind: String? = null,
    var coverUrl: String? = null,
    var intro: String? = null,
    override var wordCount: String? = null,
    var latestChapterTitle: String? = null,
    /** 目录页Url (toc=table of Contents) */
    var tocUrl: String = "",
    var time: Long = System.currentTimeMillis(),
    override var variable: String? = null,
    var originOrder: Int = 0,
    var chapterWordCountText: String? = null,

    var chapterWordCount: Int = -1,

    var respondTime: Int = -1
) : BaseBook, Comparable<SearchBook> {


    override var infoHtml: String? = null


    override var tocHtml: String? = null

    override fun equals(other: Any?) = other is SearchBook && other.bookUrl == bookUrl

    override fun hashCode() = bookUrl.hashCode()

    override fun compareTo(other: SearchBook): Int {
        return other.originOrder - this.originOrder
    }



    override val variableMap: HashMap<String, String> by lazy {
        GSON.fromJsonObject<HashMap<String, String>>(variable).getOrNull() ?: HashMap()
    }



    val origins: LinkedHashSet<String> by lazy { linkedSetOf(origin) }

    override fun putBigVariable(key: String, value: String?) = environment.state.putBook(bookUrl, key, value)
    override fun getBigVariable(key: String): String? = environment.state.getBook(bookUrl, key)

    fun addOrigin(origin: String) {
        origins.add(origin)
    }

    fun getDisplayLastChapterTitle(): String {
        latestChapterTitle?.let {
            if (it.isNotEmpty()) {
                return it
            }
        }
        return "无最新章节"
    }

    fun releaseHtmlData() {
        infoHtml = null
        tocHtml = null
    }

    fun primaryStr(): String {
        return origin + bookUrl
    }

    fun sameBookTypeLocal(bookType: Int): Boolean {
        return type and (4 or 8 or 32 or 64 or 128 or 256) == bookType and (4 or 8 or 32 or 64 or 128 or 256)
    }

    fun toBook() = Book(
        environment = environment,
        name = name,
        author = author,
        kind = kind,
        bookUrl = bookUrl,
        origin = origin,
        originName = originName,
        type = type,
        wordCount = wordCount,
        latestChapterTitle = latestChapterTitle,
        coverUrl = coverUrl,
        intro = intro,
        tocUrl = tocUrl,
        originOrder = originOrder,
        variable = variable
    ).apply {
        this.infoHtml = this@SearchBook.infoHtml
        this.tocHtml = this@SearchBook.tocHtml
    }
}