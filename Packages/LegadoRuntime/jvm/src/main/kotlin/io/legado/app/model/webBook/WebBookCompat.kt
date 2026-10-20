package io.legado.app.model.webBook

import io.legado.app.data.entities.BookSource
import io.yuedu.legado.originalrule.*
import java.text.DecimalFormat

/** Pure locked-ZIP helpers; no Android preference, database or UI adapter. */
internal object BookHelp {
    fun formatBookName(name: String) = name.replace(Regex("\\s+作\\s*者.*|\\s+\\S+\\s+著"), "").trim { it <= ' ' }
    fun formatBookAuthor(author: String) = author.replace(Regex("^\\s*作\\s*者[:：\\s]+|\\s+著"), "").trim { it <= ' ' }
}

internal fun wordCountFormat(wc: String?): String {
    if (wc == null) return ""
    if (!Regex("-?[0-9]+").matches(wc)) return wc
    val words = wc.toInt()
    if (words <= 0) return ""
    return if (words > 10000) DecimalFormat("#.#").format(words * 1.0f / 10000f.toDouble()) + "万字" else words.toString() + "字"
}

internal fun BookSource.getBookType(): Int = when (bookSourceType) { 3 -> 8 or 128; 2 -> 64; 1 -> 32; 4 -> 4; else -> 8 }
internal fun String?.isTrue(nullIsTrue: Boolean = false): Boolean {
    if (this.isNullOrBlank() || this == "null") return nullIsTrue
    return !this.trim().matches("(?i)^(?:false|no|not|0|0.0)$".toRegex())
}
internal object AppPattern {
    val wordCountRegex = Regex("(?:^|字数[：:、]?|\\s+)([0-9万千百\\.]{1,6}字)")
    val imgRegex = Regex("(.*)((?:data|https?):[\\s\\S]+)$")
    val useHtmlRegex = Regex("<usehtml>.*?</usehtml>", RegexOption.DOT_MATCHES_ALL)
    val LFRegex = Regex("\\n")
}
internal object Debug {
    fun log(source: String, message: String, enabled: Boolean = true, state: Int = 0) {
        if (enabled) io.yuedu.legado.originalrule.Debug.log("$source: $message")
    }
}
internal object DebugLog { fun e(message: String, error: Exception) { Debug.log("original", "$message: $error") } }

