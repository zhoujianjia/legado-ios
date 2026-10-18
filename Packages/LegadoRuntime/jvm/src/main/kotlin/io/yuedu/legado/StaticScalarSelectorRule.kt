package io.yuedu.legado

import io.legado.app.model.analyzeRule.AnalyzeByJSonPath
import io.legado.app.model.analyzeRule.AnalyzeByJSoup
import io.legado.app.model.analyzeRule.AnalyzeByXPath
import org.apache.commons.text.StringEscapeUtils
import org.jsoup.nodes.Element
import org.seimicrawler.xpath.JXNode

/**
 * Finite non-URL scalar selection/replacement slice, not an AnalyzeRule port.
 * Original AnalyzeRule.kt SHA-256:
 * 5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9
 * Anchors: outer ASCII trim 629-633; selector trim and ## split 824-833;
 * nullable selection/replacement/final HTML4 unescape ordering 341-373.
 * Original GPL-3.0 license: vendor/LICENSE.
 */
internal object StaticScalarSelectorRule {
    fun evaluate(document: Any, rawRule: String, unescape: Boolean = true): String {
        val rule = rawRule.trim { it <= ' ' }
        if (DYNAMIC_TOKENS.any { rule.contains(it, ignoreCase = true) }) {
            unsupported("Dynamic expressions and state directives")
        }
        val prefix = PREFIXES.firstOrNull { rule.startsWith(it, ignoreCase = true) }
            ?: unsupported("Only explicit @CSS:, @XPath: and @Json: scalar selectors")
        val parts = rule.drop(prefix.length).split("##")
        if (parts.size < 2 || parts[0].trim().isEmpty() || parts[1].isEmpty()) {
            unsupported("Empty selector or replacement pattern")
        }
        // Original makeUpRule trims the selector only; these are deliberately
        // not trims of the pattern, replacement or eventual selected value.
        // CSS keeps its prefix through AnalyzeRule.SourceRule (665-667), so
        // only that helper can decide CSS versus legacy default syntax. Its
        // own parser also owns whitespace immediately following the prefix.
        val selector = if (prefix == "@CSS:") (prefix + parts[0]).trim() else parts[0].trim()
        if (CAPTURE_REFERENCE.containsMatchIn(selector)) {
            unsupported("Scalar regex and capture-list selection")
        }
        val selected: String? = when (prefix) {
            "@CSS:" -> {
                if (document !is String && document !is Element) unsupported("CSS context must be a String or Element")
                AnalyzeByJSoup(document).getString(selector)
            }
            "@XPath:" -> {
                if (document !is String && document !is JXNode) unsupported("XPath context must be a String or JXNode")
                AnalyzeByXPath(document).getString(selector)
            }
            else -> {
                if (document !is String) unsupported("JSON scalar context must be a String")
                AnalyzeByJSonPath(document).getString(selector)
            }
        }
        // A CSS miss is null and must skip replacement. XPath/JSON misses can
        // be non-null empty strings and must still allow a ^$ replacement.
        val replaced = selected?.let {
            StaticRuleReplacement.apply(it, StaticRuleReplacement.Spec(
                pattern = parts[1], replacement = parts.getOrElse(2) { "" },
                extractFirst = parts.size > 3,
            ))
        }.orEmpty()
        return if (unescape && '&' in replaced) StringEscapeUtils.unescapeHtml4(replaced) else replaced
    }

    private fun unsupported(feature: String): Nothing = throw RuntimeFailure(
        "UNSUPPORTED_CAPABILITY", "$feature are outside the static scalar selector slice",
    )

    private val PREFIXES = listOf("@CSS:", "@XPath:", "@Json:")
    private val DYNAMIC_TOKENS = listOf("@js:", "<js>", "@webjs:", "<webjs>", "@put:", "@get:", "{{")
    private val CAPTURE_REFERENCE = Regex("\\$[0-9]+")
}
