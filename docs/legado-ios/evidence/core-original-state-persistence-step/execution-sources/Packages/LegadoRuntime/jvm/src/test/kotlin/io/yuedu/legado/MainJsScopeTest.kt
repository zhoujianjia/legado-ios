package io.yuedu.legado

import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Public-facade regressions for BaseSourceExtensions.getSharedGlobalStateKey:17-20. */
class MainJsScopeTest {
    private val sessions = mutableListOf<String>()

    @After fun closeSessions() { sessions.forEach(LegadoRuntime::closeSession) }

    @Test fun missingNullEmptyAndBlankJsLibKeepExplicitGlobalsInvocationLocal() {
        listOf(null, JsonNull.INSTANCE, JsonPrimitive(""), JsonPrimitive(" \t\r\n")).forEach { library ->
            val session = create(library)
            // The original returns no shared handle for absent/blank jsLib. Both
            // the ordinary var and explicit globalThis counter restart each call.
            assertEquals("1:1", call(session, "getContent").asString)
            assertEquals("1:1", call(session, "getContent").asString)
            assertEquals("undefined", evaluate(session, "typeof globalThis.calls").asString)
            evaluate(session, "globalThis.marker='one-call'; Array.prototype.scopeMarker='one-call'; true")
            assertEquals("undefined:undefined", evaluate(session,
                "typeof globalThis.marker+':'+typeof Array.prototype.scopeMarker").asString)
        }
    }

    @Test fun nonblankJsLibPreservesExplicitGlobalsWhileCallBindingsRestart() {
        val session = create(JsonPrimitive(SHARED_LIBRARY))
        assertEquals("1:1", call(session, "getContent").asString)
        assertEquals("1:2", call(session, "getContent").asString)
        assertEquals(2, evaluate(session, "globalThis.calls").asInt)
        evaluate(session, "globalThis.marker='shared'; true")
        assertEquals("shared", evaluate(session, "globalThis.marker").asString)
        assertEquals(0, evaluate(session, "invocationOnly").asInt)
    }

    @Test fun differentSourcesWithSameJsLibKeepTheirExplicitGlobalsSeparate() {
        val first = create(JsonPrimitive(SHARED_LIBRARY), "$BASE/first")
        val second = create(JsonPrimitive(SHARED_LIBRARY), "$BASE/second")
        assertEquals("1:1", call(first, "getContent").asString)
        evaluate(first, "globalThis.marker='first'; true")
        assertEquals("1:1", call(second, "getContent").asString)
        assertEquals("undefined", evaluate(second, "typeof globalThis.marker").asString)
        evaluate(second, "globalThis.marker='second'; true")
        assertEquals("1:2", call(first, "getContent").asString)
        assertEquals("1:2", call(second, "getContent").asString)
        assertEquals("first", evaluate(first, "globalThis.marker").asString)
        assertEquals("second", evaluate(second, "globalThis.marker").asString)
    }

    @Test fun sourceVariablesLoginCookiesAndCachePersistWithoutJsLib() {
        val session = create(null)
        evaluate(session, """
            source.putVariable('source-value'); source.put('key','source-key');
            source.putLoginInfo('{"name":"reader"}');
            source.putLoginHeader('{"Authorization":"Bearer fixture"}');
            cache.put('cached-key','cached-value');
            cookie.setCookie('$BASE','sid=fixture; Path=/');
            globalThis.marker='temporary'; true;
        """.trimIndent())
        val actual = evaluate(session, """({
            variable:source.getVariable(), key:source.get('key'),
            loginInfo:source.getLoginInfo(), loginHeader:source.getLoginHeader(),
            cached:cache.get('cached-key'), cookie:cookie.getKey('$BASE','sid'),
            globalType:typeof globalThis.marker
        })""").asJsonObject
        assertEquals("source-value", actual["variable"].asString)
        assertEquals("source-key", actual["key"].asString)
        assertEquals("""{"name":"reader"}""", actual["loginInfo"].asString)
        assertEquals("""{"Authorization":"Bearer fixture"}""", actual["loginHeader"].asString)
        assertEquals("cached-value", actual["cached"].asString)
        assertEquals("fixture", actual["cookie"].asString)
        assertEquals("undefined", actual["globalType"].asString)
    }

    private fun create(library: JsonElement?, sourceUrl: String = BASE): String {
        val source = jsonObject("bookSourceUrl" to sourceUrl, "mainJs" to """
            var invocationOnly = 0;
            function getContent(chapter, book, nextChapterUrl) {
                invocationOnly++;
                globalThis.calls = (globalThis.calls || 0) + 1;
                return invocationOnly + ':' + globalThis.calls;
            }
        """.trimIndent())
        library?.let { source.add("jsLib", it) }
        val response = parseObject(LegadoRuntime.createSession(source.toString()))
        assertTrue(response.toString(), response["ok"].asBoolean)
        return response["sessionId"].asString.also(sessions::add)
    }

    private fun evaluate(session: String, script: String) = call(session, "evaluate", jsonObject("script" to script))

    private fun call(session: String, operation: String, input: JsonObject = JsonObject()): JsonElement {
        val response = parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), operation, input.toString()))
        assertTrue(response.toString(), response["ok"].asBoolean)
        return response["result"]
    }

    companion object {
        private const val BASE = "https://scope.fixture.invalid"
        private const val SHARED_LIBRARY = "/* Legado reference shared scope */"
    }
}
