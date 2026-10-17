package io.yuedu.legado

import com.google.gson.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.util.concurrent.*

class LegadoRuntimeTest {
    private val ids = mutableListOf<String>()
    private val workers = Executors.newCachedThreadPool()

    @After fun cleanup() {
        ids.forEach(LegadoRuntime::closeSession)
        LegadoRuntime.setHostCallback(null)
        workers.shutdownNow()
    }

    @Test fun completeMainJsReadingChainPreservesRequestsCookiesVariablesAndCache() {
        val requests = mutableListOf<JsonObject>()
        LegadoRuntime.setHostCallback { _, op, json ->
            assertEquals("http.request", op)
            val request = parseObject(json)
            requests += request
            val response = when (request["url"].asString.removePrefix(BASE)) {
                "/login" -> jsonObject("status" to 200, "body" to "ok", "headers" to mapOf("Set-Cookie" to listOf("sid=fixture; Path=/; HttpOnly")))
                "/search?key=%E4%B9%A6&page=1" -> jsonObject("status" to 200, "body" to """{"books":[{"name":"Fixture","bookUrl":"$BASE/book/1"}]}""")
                "/book/1" -> jsonObject("status" to 200, "body" to "<p id='intro'>Introduction</p><a id='toc' href='/toc/1'>TOC</a>")
                "/toc/1" -> jsonObject("status" to 200, "body" to """[{"index":0,"title":"One","url":"$BASE/chapter/1"},{"index":1,"title":"Two","url":"$BASE/chapter/2"}]""")
                "/chapter/1" -> jsonObject("status" to 200, "body" to "第一章\ncontent one")
                "/chapter/2" -> jsonObject("status" to 200, "body" to "第二章\ncontent two")
                else -> throw AssertionError("Unexpected fixture request: $request")
            }
            response.add("url", request["url"])
            response.toString()
        }
        val script = javaClass.getResource("/fixtures/main-source.js")!!.readText()
        val id = create(script)
        assertEquals(true, call(id, "login").asBoolean)
        val list = call(id, "search", jsonObject("key" to "书", "page" to 1)).asJsonArray
        assertEquals("Fixture", list[0].asJsonObject["name"].asString)
        val book = call(id, "details", jsonObject("book" to list[0])).asJsonObject
        assertEquals("Introduction", book["intro"].asString)
        val chapters = call(id, "toc", jsonObject("book" to book)).asJsonArray
        assertEquals("第一章\ncontent one", call(id, "content", jsonObject("book" to book, "chapter" to chapters[0])).asString)
        val batch = call(id, "batch", jsonObject("book" to book, "chapters" to chapters)).asJsonObject
        assertEquals(2, batch["saved"].asJsonArray.size())
        assertEquals(0, batch["missing"].asJsonArray.size())
        val state = call(id, "snapshot").asJsonObject
        assertEquals("logged-in", state["variables"].asJsonObject["@variable"].asString)
        assertEquals("书", state["cache"].asJsonObject["lastKey"].asString)
        assertEquals("第二章\ncontent two", state["contents"].asJsonObject["$BASE/chapter/2"].asString)
        assertEquals("POST", requests.first()["method"].asString)
        val body = "name=reader&password=%E4%B9%A6"
        assertEquals(body, requests.first()["body"].asString)
        assertArrayEquals(body.toByteArray(), java.util.Base64.getDecoder().decode(requests.first()["bodyBase64"].asString))
        assertEquals("sid=fixture", requests[1]["headers"].asJsonObject["Cookie"].asString)
        assertEquals("Bearer fixture", requests[1]["headers"].asJsonObject["Authorization"].asString)
        assertTrue(requests[1]["remainingTimeoutMs"].asLong > 0)
        assertTrue(requests[1]["deadlineEpochMs"].asLong >= System.currentTimeMillis() - 30_000)
        assertEquals(listOf("/login", "/search?key=%E4%B9%A6&page=1", "/book/1", "/toc/1", "/chapter/1", "/chapter/1", "/chapter/2"), requests.map { it["url"].asString.removePrefix(BASE) })
        // The source script executes again in a fresh call scope but explicit globals survive.
        call(id, "search", jsonObject("key" to "书"))
        assertEquals(2, call(id, "evaluate", jsonObject("script" to "globalThis.calls")).asInt)
    }

    @Test fun semanticProbeUsesOriginalE4xAndCustomEvalFeatures() {
        val result = call(create("function search() { return []; }"), "semanticProbe").asJsonObject
        assertEquals("ok", result["e4x"].asString)
        assertEquals("function", result["indirect"].asString)
        assertTrue(result["dynamicThis"].asBoolean)
        assertEquals(42, result["legacy"].asInt)
    }

    @Test fun originalJavaInteropPreservesCollectionsBytesRegexAndOverloads() {
        val id = create("function search() { return []; }")
        val result = call(id, "evaluate", jsonObject("script" to """
            var values = new Packages.java.util.ArrayList();
            values.add('one'); values.add('two');
            var bytes = new Packages.java.lang.String('书').getBytes('UTF-8');
            var text = new Packages.java.lang.String(bytes, 'UTF-8');
            var matcher = Packages.java.util.regex.Pattern.compile('(\\d+)').matcher('n42');
            matcher.find();
            [values[1], String(text), bytes.length, String(matcher.group(1)),
                String(Packages.java.lang.Integer.parseInt('2a', 16))].join(':');
        """.trimIndent())).asString
        assertEquals("two:书:3:42:42", result)
    }

    @Test fun byteResponsesUseDeclaredCharsetBeforeLossyHostText() {
        val bytes = "中文正文".toByteArray(java.nio.charset.Charset.forName("GB18030"))
        LegadoRuntime.setHostCallback { _, _, _ -> jsonObject("status" to 200, "body" to "lossy",
            "bodyBase64" to java.util.Base64.getEncoder().encodeToString(bytes),
            "headers" to mapOf("Content-Type" to "text/html; charset=GB18030")).toString() }
        assertEquals("中文正文", call(create("function search(){return [];}"), "evaluate",
            jsonObject("script" to "java.ajax('$BASE/gbk')")).asString)
    }

    @Test fun sharedPrototypeMatchesUpstreamWhileOtherSessionsAndCallBindingsRemainIsolated() {
        val first = create("function search(key) { var local = key; return local; }")
        val second = create("function search(key) { return key; }")
        call(first, "evaluate", jsonObject("script" to "globalThis.marker='first'; Array.prototype.custom='leak'; true"))
        val handle = com.script.ScriptBindings.getSharedGlobalStateHandle("reference:${UUID.randomUUID()}")
        try {
            val originalFirst = com.script.ScriptBindings().apply { chainTo(com.script.rhino.RhinoScriptEngine.newStandardTopLevel(), handle) }
            com.script.rhino.RhinoScriptEngine.eval("Array.prototype.custom='leak'", originalFirst)
            val originalSecond = com.script.ScriptBindings().apply { chainTo(com.script.rhino.RhinoScriptEngine.newStandardTopLevel(), handle) }
            val expected = com.script.rhino.RhinoScriptEngine.eval("typeof Array.prototype.custom", originalSecond)
            assertEquals("string", expected)
            assertEquals(expected, call(first, "evaluate", jsonObject("script" to "typeof Array.prototype.custom")).asString)
        } finally { com.script.ScriptBindings.removeSharedGlobalState(handle) }
        assertEquals("first", call(first, "evaluate", jsonObject("script" to "globalThis.marker")).asString)
        assertTrue(call(second, "evaluate", jsonObject("script" to "globalThis.marker")).isJsonNull)
        assertEquals("undefined", call(second, "evaluate", jsonObject("script" to "typeof Array.prototype.custom")).asString)
        val futures = (1..12).map { i -> workers.submit<JsonElement> { call(first, "evaluate", jsonObject("script" to "var key=$i; key")) } }
        assertEquals((1..12).toList(), futures.map { it.get(10, TimeUnit.SECONDS).asInt })
    }

    @Test fun infiniteLoopCanBeCancelledFromAnotherThread() {
        val id = create("function search() { while (true) {} }")
        val task = UUID.randomUUID().toString()
        val enteredHost = CountDownLatch(1)
        LegadoRuntime.setHostCallback { _, op, _ ->
            if (op == "http.request") enteredHost.countDown()
            "{\"status\":200,\"body\":\"ok\"}"
        }
        val script = "java.ajax('$BASE/started'); while(true){}"
        val result = workers.submit<String> { LegadoRuntime.execute(id, task, "evaluate", jsonObject("script" to script).toString()) }
        assertTrue(enteredHost.await(5, TimeUnit.SECONDS))
        LegadoRuntime.cancel(task)
        assertEquals("CANCELLED", parseObject(result.get(5, TimeUnit.SECONDS))["error"].asJsonObject["code"].asString)
    }

    @Test fun deadlineAndCancellationBeforeRegistrationAreBothEffective() {
        val id = create("function search() { while(true){} }")
        val timeout = parseObject(LegadoRuntime.execute(id, UUID.randomUUID().toString(), "search", "{\"timeoutMs\":100}"))
        assertEquals("TIMEOUT", timeout["error"].asJsonObject["code"].asString)
        val preCancelled = UUID.randomUUID().toString()
        LegadoRuntime.cancel(preCancelled)
        val cancelled = parseObject(LegadoRuntime.execute(id, preCancelled, "search", "{}"))
        assertEquals("CANCELLED", cancelled["error"].asJsonObject["code"].asString)
    }

    @Test fun hostTimeoutAndBrowserCancellationRemainDistinctErrors() {
        val id = create("function search() { return []; }")
        LegadoRuntime.setHostCallback { _, _, _ -> """{"ok":false,"error":{"code":"NETWORK_TIMEOUT","message":"Fixture deadline"}}""" }
        assertError(id, "java.ajax('$BASE/slow')", "NETWORK_TIMEOUT")
        LegadoRuntime.setHostCallback { _, _, _ -> """{"ok":false,"error":{"code":"BROWSER_CANCELLED","message":"Dismissed"}}""" }
        assertError(id, "java.webView(null,'$BASE/login',null)", "BROWSER_CANCELLED")
    }

    @Test fun unregisteredHostAndClosedSessionFailExplicitly() {
        val id = create("function search() { return []; }")
        assertError(id, "java.ajax('$BASE/not-available')", "HOST_UNAVAILABLE")
        assertTrue(parseObject(LegadoRuntime.closeSession(id))["ok"].asBoolean)
        val result = parseObject(LegadoRuntime.execute(id, UUID.randomUUID().toString(), "search", "{}"))
        assertEquals("UNKNOWN_SESSION", result["error"].asJsonObject["code"].asString)
    }

    @Test fun batchRejectsOutOfBatchCacheWritesAndHandlesMissingFunction() {
        val id = create("function getContentBatch(chapters,book) { java.cacheContent('https://outside.invalid/chapter','bad'); }")
        val result = parseObject(LegadoRuntime.execute(id, UUID.randomUUID().toString(), "batch", "{\"chapters\":[{\"url\":\"$BASE/chapter/1\"}]}"))
        assertFalse(result["ok"].asBoolean)
        assertTrue(call(id, "snapshot").asJsonObject["contents"].asJsonObject.entrySet().isEmpty())
        val missing = call(create("function search() { return []; }"), "batch", jsonObject("chapters" to listOf(mapOf("url" to "$BASE/chapter/1")))).asJsonObject
        assertFalse(missing["exists"].asBoolean)
        assertEquals(1, missing["missing"].asJsonArray.size())
    }

    private fun assertError(id: String, script: String, code: String) {
        val result = parseObject(LegadoRuntime.execute(id, UUID.randomUUID().toString(), "evaluate", jsonObject("script" to script).toString()))
        assertFalse(result.toString(), result["ok"].asBoolean)
        assertEquals(result.toString(), code, result["error"].asJsonObject["code"].asString)
    }
    private fun create(script: String): String {
        val result = parseObject(LegadoRuntime.createSession(jsonObject("bookSourceUrl" to BASE, "bookSourceName" to "Fixture", "mainJs" to script).toString()))
        assertTrue(result.toString(), result["ok"].asBoolean)
        return result["sessionId"].asString.also(ids::add)
    }
    private fun call(id: String, operation: String, input: JsonObject = JsonObject()): JsonElement {
        val result = parseObject(LegadoRuntime.execute(id, UUID.randomUUID().toString(), operation, input.toString()))
        assertTrue(result.toString(), result["ok"].asBoolean)
        return result["result"]
    }
    companion object { private const val BASE = "https://fixture.invalid" }
}
