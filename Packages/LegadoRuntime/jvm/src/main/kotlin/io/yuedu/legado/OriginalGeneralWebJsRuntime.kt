package io.yuedu.legado

import com.google.gson.JsonObject
import org.apache.commons.text.StringEscapeUtils
import java.util.regex.Pattern

/** Transient policy of the existing session page lease, not a browser, parser,
 * data store or second execution owner. Only the private native policy lane
 * can configure interfaces or attest actual WK observations. */
internal class OriginalGeneralWebPolicy(
    val initialURL: String?,
    val html: String?,
    val js: String?,
    val isRule: Boolean,
    val cookieTag: String?,
    val deadlineEpochMs: Long,
    sourceRegex: String?,
    overrideUrlRegex: String?,
    delayTime: Long,
) {
    private val sourcePattern = sourceRegex?.takeUnless(String::isBlank)?.let(Pattern::compile)
    private val navigationPattern = overrideUrlRegex?.takeUnless(String::isBlank)?.let(Pattern::compile)
    val sniffer = sourcePattern != null || navigationPattern != null
    val initialDelayMs = (100L + if (js == null && delayTime == 0L) 900L else delayTime).coerceAtLeast(0)
    private var configured = false
    private var registeredSource = false
    private var retry = 0
    private var acceptedBody: String? = null
    private var acceptedKind: String? = null
    val cacheInstalled get() = configured && isRule && !html.isNullOrEmpty()
    val javaInstalled get() = cacheInstalled && registeredSource && cookieTag != null

    fun ensureDeadline() {
        if (System.currentTimeMillis() >= deadlineEpochMs)
            throw RuntimeFailure("WEBJS_TIMEOUT", "Original WebView exceeded its bounded deadline")
    }

    fun ensureConfigured() {
        ensureDeadline()
        if (!configured) throw RuntimeFailure("INVALID_WEBVIEW_POLICY", "Original WebView policy is not configured")
    }

    fun configure(registered: Boolean): JsonObject {
        ensureDeadline()
        if (configured) throw RuntimeFailure("INVALID_WEBVIEW_POLICY", "Original WebView policy is already configured")
        configured = true
        registeredSource = registered
        return string("configured")
    }

    fun checkBridge(method: String) {
        ensureConfigured()
        val allowed = if (method.startsWith("cache.")) cacheInstalled else javaInstalled
        if (!allowed) throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "This original page has no requested native interface")
    }

    fun evaluate(raw: String?): JsonObject {
        ensureConfigured()
        if (sniffer || acceptedKind != null)
            throw RuntimeFailure("INVALID_WEBVIEW_POLICY", "This original page cannot accept an evaluation result")
        if (!raw.isNullOrEmpty() && raw != "null") {
            val body = StringEscapeUtils.unescapeJson(raw).replace(quoteRegex, "")
            if (body.toByteArray(Charsets.UTF_8).size > 4 * 1024 * 1024)
                throw RuntimeFailure("STATE_LIMIT", "Original WebView result exceeds its byte budget")
            acceptedBody = body
            acceptedKind = "html"
            return string(jsonObject("retry" to false, "body" to body).toString())
        }
        if (retry > 30) throw RuntimeFailure("WEBJS_TIMEOUT", "Original WebView JavaScript did not produce a result")
        val delay = intervals[retry.coerceAtMost(intervals.lastIndex)]
        retry++
        return string(jsonObject("retry" to true, "delayMs" to delay).toString())
    }

    fun matchNavigation(url: String, guard: () -> Unit): JsonObject = match(navigationPattern, "navigation", url, guard)
    fun matchResource(url: String, guard: () -> Unit): JsonObject = match(sourcePattern, "resource", url, guard)

    private fun match(pattern: Pattern?, kind: String, url: String, guard: () -> Unit): JsonObject {
        ensureConfigured()
        if (acceptedKind != null) throw RuntimeFailure("INVALID_WEBVIEW_POLICY", "Original WebView has already completed")
        require(url.length < 65_536) { "Observed WebView URL exceeds its budget" }
        val matched = pattern?.matcher(CheckedCharacters(url, guard))?.matches() == true
        guard()
        if (matched) {
            acceptedBody = url
            acceptedKind = kind
        }
        return string(matched.toString())
    }

    fun validateTerminal(reply: JsonObject): String {
        ensureConfigured()
        val raw = reply["body"]
        if (acceptedKind == null || raw == null || !raw.isJsonPrimitive || !raw.asJsonPrimitive.isString || raw.asString != acceptedBody)
            throw RuntimeFailure("INVALID_WEBVIEW_RESULT", "Original WebView omitted its accepted policy result")
        if (acceptedKind != "html") {
            if (initialURL == null || reply["url"]?.asString != initialURL || reply["redirected"]?.asBoolean != false)
                throw RuntimeFailure("INVALID_WEBVIEW_RESULT", "Original sniffer response identity changed")
        }
        return acceptedBody!!
    }

    private fun string(value: String) = jsonObject("kind" to "string", "value" to value)

    /** Same Java Pattern/UTF16 semantics, with cancellation/deadline checks
     * during backtracking instead of a noninterruptible CharSequence read. */
    private class CheckedCharacters(private val text: String, private val check: () -> Unit) : CharSequence {
        override val length: Int get() { check(); return text.length }
        override fun get(index: Int): Char { check(); return text[index] }
        override fun subSequence(startIndex: Int, endIndex: Int): CharSequence {
            check(); return CheckedCharacters(text.substring(startIndex, endIndex), check)
        }
        override fun toString(): String { check(); return text }
    }

    companion object {
        const val DEFAULT_SCRIPT = "document.documentElement.outerHTML"
        private val quoteRegex = "^\"|\"$".toRegex()
        private val intervals = intArrayOf(200, 400, 600, 800, 1000)
    }
}
