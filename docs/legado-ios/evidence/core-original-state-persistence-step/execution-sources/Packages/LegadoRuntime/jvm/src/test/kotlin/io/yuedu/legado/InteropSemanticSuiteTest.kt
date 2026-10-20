package io.yuedu.legado

import com.google.gson.JsonParser
import io.yuedu.legado.interop.InteropFixture
import org.htmlunit.corejs.javascript.Context
import org.htmlunit.corejs.javascript.ContextFactory
import org.htmlunit.corejs.javascript.WrapFactory
import org.junit.Assert.*
import org.junit.Test

class InteropSemanticSuiteTest {
    @Test fun nullOverloadAmbiguityMatchesTheLockedEnginesDefaultWrapper() {
        // This factory does not install RhinoWrapFactory, CatchableJavaFunction or
        // the Legado Context subclass. It isolates the engine's overload decision.
        val factory = object : ContextFactory() {
            override fun makeContext(): Context = super.makeContext().apply {
                languageVersion = Context.VERSION_ES6
                setInterpretedMode(true)
            }
        }
        val context = factory.enterContext()
        try {
            assertEquals(WrapFactory::class.java, context.wrapFactory.javaClass)
            val scope = context.initStandardObjects()
            scope.put("fixture", scope, Context.javaToJS(InteropFixture(), scope))
            val result = context.evaluateString(scope, """
                JSON.stringify((function() {
                    var name = 'not-caught';
                    try { fixture.choose(null); } catch (error) { name = String(error.name); }
                    return [name, String(fixture['choose(java.lang.String)'](null)),
                        String(fixture['choose(java.lang.Object)'](null))];
                })())
            """.trimIndent(), "unmodified-engine-null-overload", 1, null)
            assertEquals("""["InternalError","String:<null>","Object:null"]""", result)
        } finally { Context.exit() }
    }

    @Test fun lockedEnginePassesCompleteInteropMatrix() {
        val report = InteropSemanticSuite.run()
        assertEquals(report.toString(), true, report["passed"])
        assertEquals(28, report["total"])
        assertEquals(28, report["passedCount"])
        assertEquals(0, report["failed"])
        assertEquals("legado-interop-v1", report["caseSetVersion"])
        @Suppress("UNCHECKED_CAST") val tests = report["tests"] as List<Map<String, Any?>>
        assertEquals(28, tests.size)
        assertEquals(28, tests.map { it["name"] }.toSet().size)
        tests.forEach {
            assertEquals(it.toString(), true, it["passed"])
            assertEquals(it["expected"], it["actual"])
            JsonParser.parseString(it["actual"] as String)
        }
    }

    @Test fun everyCaseReportsExceptionsAndAllFailedRejectsRuntime() {
        val report = InteropSemanticSuite.runWithEvaluator { _, _ -> throw IllegalStateException("synthetic-missing-java-host") }
        assertEquals(false, report["passed"])
        assertEquals(0, report["passedCount"])
        assertEquals(28, report["failed"])
        assertEquals("INTEROP_SUITE_ALL_FAILED", (report["error"] as Map<*, *>)["code"])
        @Suppress("UNCHECKED_CAST") val tests = report["tests"] as List<Map<String, Any?>>
        tests.forEach {
            assertEquals(false, it["passed"])
            assertNotNull(it["expected"])
            val actual = JsonParser.parseString(it["actual"] as String).asJsonObject
            assertEquals("java.lang.IllegalStateException", actual["exception"].asJsonObject["type"].asString)
            assertTrue((it["error"] as Map<*, *>)["message"].toString().contains("synthetic-missing-java-host"))
        }
    }

    @Test fun equalTextDoesNotHideWrongJsonType() {
        val report = InteropSemanticSuite.runWithEvaluator { _, _ -> "\"true\"" }
        assertEquals(false, report["passed"])
        assertEquals(28, report["failed"])
        @Suppress("UNCHECKED_CAST") val tests = report["tests"] as List<Map<String, Any?>>
        assertTrue(tests.all { it["actual"] == "\"true\"" && it["actual"] != it["expected"] })
    }
}
