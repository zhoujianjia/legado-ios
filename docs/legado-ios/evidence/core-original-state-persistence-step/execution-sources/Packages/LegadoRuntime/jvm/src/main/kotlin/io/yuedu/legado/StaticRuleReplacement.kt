package io.yuedu.legado

/**
 * Finite, static scalar slice of the pinned Legado AnalyzeRule implementation.
 * Source: app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt
 * SHA-256: 5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9
 * Anchors: splitSourceRule 629-633, SourceRule.makeUpRule 824-833,
 * replaceRegex 544-568. Original GPL-3.0 license: vendor/LICENSE.
 *
 * This helper does not select HTML/JSON nodes, evaluate JS or variables, unescape
 * HTML, or resolve URLs. DeclarativeSource uses it only through the finite
 * StaticScalarSelectorRule helper; the empty-selector parser remains separate.
 */
internal object StaticRuleReplacement {
    data class Spec(val pattern: String, val replacement: String, val extractFirst: Boolean)

    /** Parse only an empty-selector static replacement rule, not a full source rule. */
    fun parse(rule: String): Spec {
        // Original splitSourceRule trims ASCII control/space around each segment.
        val staticRule = rule.trim { it <= ' ' }
        require(listOf("@js:", "<js>", "@webjs:", "@get:", "@put:", "{{")
            .none { staticRule.contains(it, ignoreCase = true) }) {
            "Dynamic expressions are outside the static replacement slice"
        }
        // This is intentionally a plain split. RuleAnalyzer's bracket/quote-aware
        // selector segmentation is not used by the original replacement parser.
        val parts = staticRule.split("##")
        require(parts.size > 1 && parts[0].trim().isEmpty()) {
            "A static scalar replacement requires an empty selector and ##"
        }
        return Spec(parts[1], parts.getOrElse(2) { "" }, parts.size > 3)
    }

    fun evaluate(text: String, rule: String): String = apply(text, parse(rule))

    /**
     * AnalyzeRule.replaceRegex's behavior, including its asymmetric fallbacks.
     * Empty pattern is identity here; full AnalyzeRule with an empty selector
     * and pattern additionally runs its selector stage and has different output.
     */
    fun apply(text: String, spec: Spec): String {
        if (spec.pattern.isEmpty()) return text
        val regex = try {
            spec.pattern.toRegex()
        } catch (_: Exception) {
            null
        }
        if (spec.extractFirst) {
            if (regex != null) runCatching {
                val matcher = regex.toPattern().matcher(text)
                return if (matcher.find()) {
                    // Preserve re-applying the pattern within group(0), including
                    // lookbehind/zero-width patterns that now lack their context.
                    matcher.group(0)!!.replaceFirst(regex, spec.replacement)
                } else {
                    ""
                }
            }
            return spec.replacement
        }
        if (regex != null) runCatching {
            return text.replace(regex, spec.replacement)
        }
        return text.replace(spec.pattern, spec.replacement)
    }
}
