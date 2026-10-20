package io.yuedu.legado

import com.google.gson.JsonObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets.UTF_8
import java.util.Base64
import java.util.UUID

/** Assertions derive from the original HTTP builders, not a copied golden report. */
class SourceHttpSemanticsTest {
    private val sessions = mutableListOf<String>()

    @After fun cleanup() {
        sessions.forEach(LegadoRuntime::closeSession)
        LegadoRuntime.setHostCallback(null)
    }

    @Test fun originalCommonInterceptorAppendsRatherThanOverwritingAuthoredHeaders() {
        val (session, dispatched) = session(linkedMapOf("User-Agent" to "Fixture/1", "Connection" to "close",
            "Accept-Encoding" to "identity", "Cache-Control" to "max-age=60"))
        call(session, "java.ajax('$BASE/one')")
        val request = dispatched.single()
        // HttpHelper.kt:79-81: all three calls are addHeader.
        assertEquals(listOf("close", "Keep-Alive"), values(request, "Connection"))
        assertEquals(listOf("max-age=60", "no-cache"), values(request, "Cache-Control"))
        assertEquals(listOf("300"), values(request, "Keep-Alive"))
        assertEquals(listOf("Fixture/1"), values(request, "User-Agent"))
        assertEquals(listOf("identity"), values(request, "Accept-Encoding"))
        val snapshot = checked(LegadoRuntime.execute(session, UUID.randomUUID().toString(), "snapshot", "{}")).asJsonObject
        assertEquals(request, snapshot["requests"].asJsonArray.single()) // Same DTO that reached the host.
    }

    @Test fun formStringBodySelectsUtf8AndReplacesContentTypeInActualHostRequest() {
        val (session, dispatched) = session()
        val body = "name=reader&password=%E4%B9%A6"
        call(session, """java.connect('$BASE/login,{"method":"POST","body":"$body","headers":{"Content-Type":"application/x-www-form-urlencoded"}}').body()""")
        val request = dispatched.single()
        // AnalyzeUrl.kt:529 -> RequestBody.toRequestBody -> BridgeInterceptor.header.
        assertEquals(listOf("application/x-www-form-urlencoded; charset=utf-8"), values(request, "Content-Type"))
        assertEquals(listOf("30"), values(request, "Content-Length"))
        assertEquals(body, request["body"].asString)
        assertArrayEquals(body.toByteArray(UTF_8), bodyBytes(request))
    }

    @Test fun declaredMediaCharsetControlsBytesAndRetainsExactContentType() {
        val body = "你好"
        val type = "text/plain; charset=GB18030"
        val request = prepare("POST", body, linkedMapOf("Content-Type" to type), "UTF-8")
        assertEquals(listOf(type), values(request, "Content-Type"))
        assertArrayEquals(body.toByteArray(Charset.forName("GB18030")), bodyBytes(request))
        assertFalse(body.toByteArray(UTF_8).contentEquals(bodyBytes(request)))
        assertEquals(listOf("4"), values(request, "Content-Length"))
    }

    @Test fun unsupportedMediaCharsetUsesOkHttpUtf8AppendBehavior() {
        val request = prepare("POST", "书", linkedMapOf("Content-Type" to "text/plain; charset=not_a_charset"))
        assertEquals(listOf("text/plain; charset=not_a_charset; charset=utf-8"), values(request, "Content-Type"))
        assertArrayEquals("书".toByteArray(UTF_8), bodyBytes(request))
    }

    @Test fun bridgeReplacesAllCaseVariantsAndTransferEncodingAfterBodySelection() {
        val request = prepare("POST", "abc", linkedMapOf("Content-Type" to "text/plain",
            "content-type" to "source-second-value", "Content-Length" to "999", "Transfer-Encoding" to "chunked"))
        assertEquals(listOf("text/plain; charset=utf-8"), values(request, "content-type"))
        assertEquals(listOf("3"), values(request, "content-length"))
        assertEquals(emptyList<String>(), values(request, "transfer-encoding"))
    }

    @Test fun absentMediaTypeUsesOriginalFormEncodingAndCharsetRules() {
        // AnalyzeUrl.encodeParams preserves percent triplets when charset is
        // unspecified, while its non-form-safe '+' is encoded as a literal plus.
        val request = prepare("POST", "word=你好&plus=a+b&encoded=%E4%B9%A6")
        val expected = "word=%E4%BD%A0%E5%A5%BD&plus=a%2Bb&encoded=%E4%B9%A6"
        assertEquals(expected, request["body"].asString)
        assertArrayEquals(expected.toByteArray(UTF_8), bodyBytes(request))
        assertEquals(expected, prepare("POST", "word=你好&plus=a+b&encoded=%E4%B9%A6", charset = "")["body"].asString)
        assertEquals(listOf("application/x-www-form-urlencoded; charset=utf-8"), values(request, "Content-Type"))
        val gbk = prepare("POST", "word=你好", charset = "GB18030")
        assertEquals("word=%C4%E3%BA%C3", gbk["body"].asString)
        assertArrayEquals("word=%C4%E3%BA%C3".toByteArray(UTF_8), bodyBytes(gbk))
    }

    @Test fun structuredOrEmptyPostUsesOriginalBodySelection() {
        val json = prepare("POST", "{\"value\":1}")
        assertEquals(listOf("application/json; charset=UTF-8"), values(json, "Content-Type"))
        val xml = prepare("POST", "<value>1</value>")
        assertEquals(listOf("application/json; charset=UTF-8"), values(xml, "Content-Type"))
        // The original sends an empty form even with an explicitly different type.
        val empty = prepare("POST", "  ", linkedMapOf("Content-Type" to "application/json"))
        assertEquals(listOf("application/x-www-form-urlencoded; charset=utf-8"), values(empty, "Content-Type"))
        assertEquals(listOf("0"), values(empty, "Content-Length"))
        assertEquals("", empty["bodyBase64"].asString)
        // Without a Content-Type, AnalyzeUrl first encodes the whitespace form;
        // its nonempty encodedForm takes precedence over body.isNullOrBlank().
        assertEquals("++", prepare("POST", "  ")["body"].asString)
        assertEquals(listOf("application/json; charset=UTF-8"), values(
            prepare("POST", "plain", linkedMapOf("Content-Type" to " ")), "Content-Type"))
        for (method in listOf("GET", "HEAD")) {
            val request = prepare(method, "ignored")
            assertTrue(request.has("bodyBase64"))
            assertTrue(request["bodyBase64"].isJsonNull)
            assertTrue(values(request, "Content-Length").isEmpty())
        }
    }

    @Test fun bridgeHostAndGzipDefaultsRespectExplicitOverridesAndRange() {
        val request = prepare("GET", null)
        assertEquals(listOf("fixture.invalid"), values(request, "Host"))
        assertEquals(listOf("gzip"), values(request, "Accept-Encoding"))
        assertTrue(values(prepare("GET", null, linkedMapOf("Range" to "bytes=0-9")), "Accept-Encoding").isEmpty())
        assertEquals(listOf("identity"), values(prepare("GET", null,
            linkedMapOf("Accept-Encoding" to "identity")), "Accept-Encoding"))
        val ipv6 = LegadoHttpRequestPreprocessor.prepare("http://[::1]:8080/path", "GET", emptyMap(), null, null)
        assertEquals(listOf("[::1]:8080"), values(ipv6, "Host"))
        val standardPort = LegadoHttpRequestPreprocessor.prepare("https://example.test:443/path", "GET", emptyMap(), null, null)
        assertEquals(listOf("example.test"), values(standardPort, "Host"))
    }

    @Test fun nullUserAgentSentinelAndHeaderValidationMatchBuilderBoundary() {
        val request = prepare("GET", null, linkedMapOf("User-Agent" to "null", "X-Test" to "  value \t"))
        // HttpHelper removes the sentinel; BridgeInterceptor then supplies its UA.
        assertEquals(listOf("okhttp/5.4.0"), values(request, "User-Agent"))
        assertEquals(listOf("value"), values(request, "X-Test"))
        for ((name, value) in listOf("Bad:Name" to "ok", "X-Test" to "ok\r\nInjected: value")) {
            assertThrows(IllegalArgumentException::class.java) { prepare("GET", null, linkedMapOf(name to value)) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            prepare("POST", "body", linkedMapOf("Content-Type" to "not a media type"))
        }
    }

    private fun session(headers: Map<String, String> = emptyMap()): Pair<String, MutableList<JsonObject>> {
        val requests = mutableListOf<JsonObject>()
        LegadoRuntime.setHostCallback { _, operation, request ->
            assertEquals("http.request", operation)
            requests += parseObject(request)
            jsonObject("status" to 200, "body" to "ok").toString()
        }
        val response = parseObject(LegadoRuntime.createSession(jsonObject("bookSourceUrl" to BASE,
            "header" to gson.toJson(headers), "mainJs" to "function search(){return [];}").toString()))
        assertTrue(response.toString(), response["ok"].asBoolean)
        return response["sessionId"].asString.also(sessions::add) to requests
    }
    private fun call(session: String, script: String) = checked(LegadoRuntime.execute(session,
        UUID.randomUUID().toString(), "evaluate", jsonObject("script" to script).toString()))
    private fun checked(json: String) = parseObject(json).let {
        assertTrue(it.toString(), it["ok"].asBoolean)
        it["result"]
    }
    private fun prepare(method: String, body: String?, headers: Map<String, String> = emptyMap(), charset: String? = null) =
        LegadoHttpRequestPreprocessor.prepare("$BASE/path", method, headers, body, charset)
    private fun values(request: JsonObject, name: String) = request["headers"].asJsonArray
        .map { it.asJsonObject }.filter { it["name"].asString.equals(name, true) }.map { it["value"].asString }
    private fun bodyBytes(request: JsonObject) = Base64.getDecoder().decode(request["bodyBase64"].asString)
    companion object { private const val BASE = "https://fixture.invalid" }
}
