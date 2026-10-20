package io.yuedu.legado.originalrule

import io.legado.app.data.entities.BookChapter
import java.util.concurrent.ConcurrentHashMap

/** Explicit transient substitute for chapter lookup only; never claims disk/Room persistence. */
class RuleWebBookState internal constructor(private val ensureOpen: () -> Unit) {
    private val chapters = ConcurrentHashMap<String, List<BookChapter>>()
    fun chapters(bookUrl: String): List<BookChapter> { ensureOpen(); return chapters[bookUrl].orEmpty() }
    internal fun publish(bookUrl: String, value: List<BookChapter>) { ensureOpen(); chapters[bookUrl] = value.toList() }
    internal fun clear() = chapters.clear()
    // Android default preferences are made explicit for this transient runtime.
    var threadCount: Int = 32
        set(value) { require(value > 0); field = value }
    var tocCountWords: Boolean = true
    var adaptSpecialStyle: Boolean = true
}
