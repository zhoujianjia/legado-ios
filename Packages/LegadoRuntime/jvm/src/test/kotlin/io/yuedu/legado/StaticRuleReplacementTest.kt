package io.yuedu.legado

import com.google.gson.JsonParser
import org.junit.Assert.*
import org.junit.Test

class StaticRuleReplacementTest {
    @Test fun sharedFixtureExercisesPinnedReplacementBranchesWithoutAndroidOutputInvented() {
        // Expected values follow the cited original branches, and stay outside
        // the shared input fixture. The Android harness records its own actuals.
        val expected = linkedMapOf(
            "replace-all-number-groups" to "ab[12]cd[34]",
            "extract-first-match" to "[12]",
            "extract-first-no-match" to "",
            "invalid-pattern-literal-fallback" to "a<x>b<x>c",
            "invalid-pattern-extract-fallback" to "<x>",
            "invalid-group-literal-fallback" to "\$2 \$2",
            "invalid-group-extract-fallback" to "\$2",
            "missing-replacement-deletes" to "ab",
            "named-capture-replacement" to "42:isbn",
            "linebreak-unicode-preservation" to "第一{12}章\n🙂{34}尾",
            "zero-width-boundaries" to "!ab!",
            "escaped-literal-dollar" to "\$\$",
            "escaped-literal-backslash" to "\\\\",
            "extract-zero-width-reapplies-in-match" to "",
            "extract-lookbehind-reapplies-in-match" to "a",
            "fourth-segment-enables-extraction" to "12",
            "explicit-empty-replacement" to "ab",
            "regex-case-sensitive" to "xA"
        )
        val fixture = javaClass.getResourceAsStream("/fixtures/rule-replacement-cases.json")!!
            .bufferedReader(Charsets.UTF_8).use { JsonParser.parseReader(it).asJsonObject }
        assertEquals("legado-static-rule-replacement-v1", fixture["caseSetVersion"].asString)
        val cases = fixture["cases"].asJsonArray
        assertEquals(expected.size, cases.size())
        val observed = linkedSetOf<String>()
        for (item in cases) {
            val case = item.asJsonObject
            val caseId = case["caseId"].asString
            assertTrue("Duplicate/unrecognized fixture case: $caseId", observed.add(caseId) && expected.containsKey(caseId))
            assertFalse("The shared fixture must contain no invented Android output", case.has("actual"))
            assertFalse(case.has("expected"))
            val spec = StaticRuleReplacement.parse(case["rule"].asString)
            assertTrue("Shared Android cases require a nonempty pattern", spec.pattern.isNotEmpty())
            assertEquals(caseId, expected.getValue(caseId), StaticRuleReplacement.apply(case["text"].asString, spec))
        }
        assertEquals(expected.keys, observed)
    }

    @Test fun parseUsesPlainDelimiterAndOnlyFourthSegmentPresenceForExtractFirst() {
        assertEquals(StaticRuleReplacement.Spec("x", "y", false), StaticRuleReplacement.parse("##x##y"))
        assertEquals(StaticRuleReplacement.Spec("x", "y", true), StaticRuleReplacement.parse("##x##y##"))
        assertEquals(StaticRuleReplacement.Spec("x", "y", true), StaticRuleReplacement.parse("##x##y##ignored##more"))
        assertEquals(StaticRuleReplacement.Spec(" x ", " y", false), StaticRuleReplacement.parse(" \t## x ## y \n"))
    }

    @Test fun emptyPatternIsOnlyTheReplacementKernelIdentity() {
        // AnalyzeRule:545 returns before regex compilation. This is not an
        // assertion about full getString("####...") selector-stage behavior.
        assertEquals("content", StaticRuleReplacement.apply("content", StaticRuleReplacement.Spec("", "replacement", true)))
        assertEquals("content", StaticRuleReplacement.evaluate("content", "####replacement"))
    }

    @Test fun staticSliceRejectsSelectorsAndRuntimeExpressionsExplicitly() {
        listOf("tag.p@text##x##y", "plain text", "##x##@get:{token}", "##x##{{token}}", "##x##@js:result", "##x##<js>result</js>")
            .forEach { rule -> assertThrows("Must reject unsupported full rule: $rule", IllegalArgumentException::class.java) {
                StaticRuleReplacement.parse(rule)
            } }
    }

    @Test fun malformedReplacementDoesNotEscapeAsExceptionButKeepsOriginalLiteralFallback() {
        // Original replaceRegex:563-566 catches group expansion errors, then
        // literally replaces the pattern text; the ### branch instead returns
        // its replacement (551-560). Neither fallback is a regex retry.
        assertEquals("\$2", StaticRuleReplacement.evaluate("(a)", "##(a)##\$2"))
        assertEquals("\$2", StaticRuleReplacement.evaluate("not matched", "##[##\$2###"))
    }
}
