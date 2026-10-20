package io.yuedu.legado

import com.google.gson.JsonParser
import com.jayway.jsonpath.InvalidJsonException
import io.legado.app.model.analyzeRule.AnalyzeByJSoup
import io.legado.app.model.analyzeRule.AnalyzeByXPath
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest

class StaticScalarSelectorRuleTest {
    @Test
    fun bothScalarOverloadsMatchAll28UnmodifiedOriginalAndroidObservations() {
        val bytes = requireNotNull(javaClass.getResourceAsStream("/fixtures/android-scalar-selector-golden.json"))
            .use { it.readBytes() }
        assertEquals("f7f56a6ebeeb381d997335230f6030cb730130e7669887bc7e0130e7e592c3b7", sha256(bytes))
        val golden = JsonParser.parseString(bytes.toString(Charsets.UTF_8)).asJsonObject
        assertEquals("original-archive-android-instrumentation", golden["referenceKind"].asString)
        assertEquals("ScalarSelectorRuleObservation", golden["suite"].asString)
        assertTrue(golden["passed"].asBoolean)
        assertEquals(28, golden["executed"].asInt)
        assertEquals(0, golden["failed"].asInt)
        assertEquals(0, golden["exceptionObservations"].asInt)
        val fixtureBytes = requireNotNull(javaClass.getResourceAsStream("/fixtures/scalar-selector-cases.json"))
            .use { it.readBytes() }
        assertEquals(golden["fixtureSHA256"].asString, sha256(fixtureBytes))
        val cases = JsonParser.parseString(fixtureBytes.toString(Charsets.UTF_8)).asJsonObject["cases"].asJsonArray
        val observations = golden["observations"].asJsonArray
        assertEquals(14, cases.size())
        assertEquals(28, observations.size())
        val seen = linkedSetOf<Pair<String, String>>()
        val apis = listOf("getString-unescape-false", "getString-default")
        for ((index, element) in observations.withIndex()) {
            val row = element.asJsonObject
            val input = cases[index / 2].asJsonObject
            val api = apis[index % 2]
            val caseId = input["caseId"].asString
            assertTrue(seen.add(caseId to api))
            assertEquals(api, row["api"].asString)
            for (field in listOf("caseId", "content", "context", "rule")) assertEquals(field, input[field], row[field])
            assertEquals("return", row["outcome"].asString)
            assertTrue(row["actual"].isJsonPrimitive && row["actual"].asJsonPrimitive.isString)
            assertEquals("java.lang.String", row["javaClass"].asString)
            assertTrue(row["exception"].isJsonNull)
            assertTrue(row["observationFailure"].isJsonNull)
            assertTrue(row["setupCompleted"].asBoolean && row["apiInvoked"].asBoolean && row["completed"].asBoolean)
            val context = input["context"].asJsonObject
            assertEquals(0, context["index"].asInt)
            val content = input["content"].asString
            val document: Any = when (context["kind"].asString) {
                "document" -> content
                // Retained original analyzers create real nodes, not serialized
                // stand-ins. The Android producer used public AnalyzeRule.getElements.
                "css-element" -> requireNotNull(AnalyzeByJSoup(content).getElements(context["rule"].asString).first())
                "xpath-node" -> requireNotNull(AnalyzeByXPath(content).getElements(context["rule"].asString)).first()
                else -> error("Unexpected reference context")
            }
            assertEquals(row["contextJavaClass"].asString, document.javaClass.name)
            val result = if (api == "getString-default") {
                StaticScalarSelectorRule.evaluate(document, input["rule"].asString)
            } else {
                StaticScalarSelectorRule.evaluate(document, input["rule"].asString, unescape = false)
            }
            // Exact String and Java class, including whitespace, newlines,
            // Unicode and one final HTML4 unescape; no output projection.
            assertEquals("$caseId/$api", row["actual"].asString, result)
            assertEquals(row["javaClass"].asString, result.javaClass.name)
        }
        assertEquals(28, seen.size)
    }

    @Test
    fun dynamicImplicitRegexCaptureAndEmptyRulesAreExplicitlyUnsupported() {
        val rejected = listOf(
            "p@text##x##y", "//p/text()##x##y", "$.value##x##y", ":(.*)##x##y", "\$1##x##y",
            "##x##y", "@CSS:##x##y", "@XPath: \t##x##y", "@Json:$.value####y", "@CSS:p@text",
            "@CSS:p\$1@text##x##y", "@Json:$.\$12##x##y",
        ) + listOf("@js:result", "<js>result</js>", "@webJs:result", "<webJs>result</webJs>",
            "@put:{key:value}", "@get:{key}", "{{key}}"
        ).map { "@Json:$.value##x##$it" }
        for (rule in rejected) {
            val error = assertThrows(rule, RuntimeFailure::class.java) {
                StaticScalarSelectorRule.evaluate("{\"value\":\"x\"}", rule)
            }
            assertEquals(rule, "UNSUPPORTED_CAPABILITY", error.code)
        }
    }

    @Test
    fun nonStringJsonAndNonNodeHtmlContextsDoNotCoerceToStrings() {
        val node = requireNotNull(AnalyzeByJSoup("<article>value</article>").getElements("tag.article").first())
        val xpathNode = requireNotNull(AnalyzeByXPath("<article>value</article>").getElements("//article")).first()
        for (document in listOf(node, xpathNode, mapOf("value" to "x"), listOf("x"), 12)) {
            assertEquals("UNSUPPORTED_CAPABILITY", assertThrows(RuntimeFailure::class.java) {
                StaticScalarSelectorRule.evaluate(document, "@Json:$.value##x##y")
            }.code)
        }
        for (document in listOf(mapOf("value" to "x"), listOf("x"), 12)) {
            for (rule in listOf("@CSS:p@text##x##y", "@XPath://p/text()##x##y")) {
                assertEquals("UNSUPPORTED_CAPABILITY", assertThrows(RuntimeFailure::class.java) {
                    StaticScalarSelectorRule.evaluate(document, rule)
                }.code)
            }
        }
        // Cross-kind conversions are supported by some original helpers but
        // were not observed in this finite 28-row corpus; keep them closed.
        assertEquals("UNSUPPORTED_CAPABILITY", assertThrows(RuntimeFailure::class.java) {
            StaticScalarSelectorRule.evaluate(xpathNode, "@CSS:b@text##x##y")
        }.code)
        assertEquals("UNSUPPORTED_CAPABILITY", assertThrows(RuntimeFailure::class.java) {
            StaticScalarSelectorRule.evaluate(node, "@XPath://b/text()##x##y")
        }.code)
    }

    @Test
    fun replacementCaptureReferencesRemainAllowedAndSelectedWhitespaceIsUntouched() {
        assertEquals("  [12]  ", StaticScalarSelectorRule.evaluate(
            "{\"value\":\"  12  \"}", "@Json:$.value##([0-9]+)##[\$1]",
        ))
        assertEquals("&apos; &lt;", StaticScalarSelectorRule.evaluate(
            "{\"value\":\"word\"}", "@Json:$.value##word##&apos; &amp;lt;",
        ))
    }

    @Test
    fun explicitCssModeRetainsComplexSelectorsAndAtSignsInsideAttributes() {
        // SourceRule 665-667 preserves @CSS: for AnalyzeByJSoup.SourceRule
        // isCss. This is a direct helper regression beyond the 28-row golden.
        assertEquals("id[12]", StaticScalarSelectorRule.evaluate(
            "<section><a data-email='x@y' href='/a'>id12</a><a href='/b'>skip</a></section>",
            "@CSS:section > a[data-email='x@y']@text##([0-9]+)##[\$1]",
        ))
    }

    @Test
    fun malformedJsonConstructionDoesNotBecomeAMissingValueReplacement() {
        assertThrows(InvalidJsonException::class.java) {
            StaticScalarSelectorRule.evaluate("{\"value\":", "@Json:$.value##^$##invented")
        }
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
