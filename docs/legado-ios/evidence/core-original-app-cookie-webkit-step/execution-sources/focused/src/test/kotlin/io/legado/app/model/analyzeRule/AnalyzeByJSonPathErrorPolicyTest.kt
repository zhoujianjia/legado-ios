package io.legado.app.model.analyzeRule

import com.google.gson.Gson
import com.google.gson.JsonParser
import com.jayway.jsonpath.InvalidJsonException
import com.jayway.jsonpath.InvalidPathException
import com.jayway.jsonpath.PathNotFoundException
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.logging.Handler
import java.util.logging.Level
import java.util.logging.LogRecord
import java.util.logging.Logger

/** Only the three original helper catches; this is not a full AnalyzeRule port. */
class AnalyzeByJSonPathErrorPolicyTest {
    @Test
    fun missingAndInvalidPathsLeaveEmptyResultsInEachHelper() {
        // Original AnalyzeByJSonPath getString/getStringList/getList catches
        // (archive SHA 724ded...; original lines 55/92/142) continue after
        // printOnDebug when no explicit handler is supplied.
        for (rule in BAD_RULES) {
            assertEquals(rule, "", AnalyzeByJSonPath(JSON).getString(rule))
            assertEquals(rule, emptyList<String>(), AnalyzeByJSonPath(JSON).getStringList(rule))
            assertEquals(rule, emptyList<Any>(), AnalyzeByJSonPath(JSON).getList(rule))
        }
        // Keep the helper's nullable empty-rule contract distinct from the
        // original public AnalyzeRule.getString's final empty-string coercion.
        assertNull(AnalyzeByJSonPath(JSON).getString(""))
    }

    @Test
    fun orFallbackAfterMissingOrInvalidMatchesTheFourApplicableOriginalObservations() {
        val bytes = requireNotNull(javaClass.getResourceAsStream("/fixtures/android-jsonpath-public-golden.json"))
            .use { it.readBytes() }
        assertEquals("8563213d759975f4b7857757e7ee784da7e49e4eb4a5825b681f4d9421ec2c98",
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) })
        val rows = JsonParser.parseString(bytes.toString(Charsets.UTF_8)).asJsonObject["observations"].asJsonArray
            .map { it.asJsonObject }.filter {
                it["caseId"].asString in setOf("or-missing-fallback", "or-invalid-fallback") &&
                    it["api"].asString in setOf("getString", "getStringList")
            }
        assertEquals(4, rows.size)
        val gson = Gson()
        for (row in rows) {
            assertEquals("return", row["outcome"].asString)
            val engine = AnalyzeByJSonPath(row["jsonText"].asString)
            val rule = row["rule"].asString
            val actual: Any? = when (row["api"].asString) {
                "getString" -> engine.getString(rule)
                else -> engine.getStringList(rule)
            }
            // These four nonempty returns need no public null/element cleanup.
            // Do not project getElements or generalize this to all 36 cases.
            assertEquals(row["actual"], gson.toJsonTree(actual))
            assertEquals(row["javaClass"].asString, requireNotNull(actual).javaClass.name)
        }
    }

    @Test
    fun explicitCallbacksReceiveRealExceptionsAndBypassControllableFineLogging() {
        val logger = Logger.getLogger(AnalyzeByJSonPath::class.java.name)
        val previousLevel = logger.level
        val previousParents = logger.useParentHandlers
        val records = arrayListOf<LogRecord>()
        val capture = object : Handler() {
            init { level = Level.ALL }
            override fun publish(record: LogRecord) { records.add(record) }
            override fun flush() {}
            override fun close() {}
        }
        logger.level = Level.FINE
        logger.useParentHandlers = false
        logger.addHandler(capture)
        try {
            for (helper in HELPERS.values) {
                for (rule in BAD_RULES) {
                    val errors = arrayListOf<Exception>()
                    helper(AnalyzeByJSonPath(JSON) { errors.add(it) }, rule)
                    assertEquals(1, errors.size)
                    if (rule == "$.missing") assertTrue(errors.single() is PathNotFoundException)
                    else assertTrue(errors.single() is InvalidPathException)
                }
            }
            assertTrue("Explicit callback is the only error sink", records.isEmpty())
            AnalyzeByJSonPath(JSON).getString("$.missing")
            assertEquals(1, records.size)
            assertEquals(Level.FINE, records.single().level)
            assertTrue(records.single().thrown is PathNotFoundException)
            logger.level = Level.OFF
            AnalyzeByJSonPath(JSON).getString("$.missing")
            assertEquals("Disabled debug logging must remain quiet", 1, records.size)
        } finally {
            logger.removeHandler(capture)
            logger.level = previousLevel
            logger.useParentHandlers = previousParents
            capture.close()
        }
    }

    @Test
    fun anExplicitHandlerThrowPropagatesTheSameThrowableFromAllThreeHelpers() {
        for ((name, helper) in HELPERS) {
            for (sentinel in listOf(IllegalStateException("callback sentinel"), AssertionError("fatal callback sentinel"))) {
                val engine = AnalyzeByJSonPath(JSON) { throw sentinel }
                val caught = assertThrows(Throwable::class.java) { helper(engine, "$.missing") }
                assertSame(name, sentinel, caught)
            }
        }
    }

    @Test
    fun malformedJsonConstructionStillThrowsBeforeAnyErrorCallback() {
        var invoked = false
        assertThrows(InvalidJsonException::class.java) { AnalyzeByJSonPath("{\"name\":") { invoked = true } }
        assertFalse("A rule-read callback does not replace JSON construction errors", invoked)
    }

    companion object {
        private const val JSON = """{"name":"fallback","items":[]}"""
        private val BAD_RULES = listOf("$.missing", "$.items[?]")
        private val HELPERS: Map<String, (AnalyzeByJSonPath, String) -> Any?> = linkedMapOf(
            "getString" to { engine, rule -> engine.getString(rule) },
            "getStringList" to { engine, rule -> engine.getStringList(rule) },
            "getList" to { engine, rule -> engine.getList(rule) },
        )
    }
}
