package io.yuedu.legado

import com.google.gson.JsonObject
import com.google.gson.JsonElement
import io.legado.app.model.analyzeRule.AnalyzeByJSonPath
import io.legado.app.model.analyzeRule.AnalyzeByRegex
import io.legado.app.model.analyzeRule.AnalyzeByXPath
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class DeclarativeSourceTest {
    private var session: String? = null
    @After fun close() { session?.let(LegadoRuntime::closeSession); LegadoRuntime.setHostCallback(null) }

    @Test fun originalCssAnalyzerCompletesTraditionalReadingChain() {
        val requests = mutableListOf<String>()
        LegadoRuntime.setHostCallback { _, op, requestJson ->
            assertEquals("http.request", op)
            val request = parseObject(requestJson)
            val url = request["url"].asString
            requests += url
            val body = when (url) {
                "$BASE/search?key=fixture&page=2" -> "<article><a class='book' href='/book/1'>Fixture</a><b>Author</b></article>"
                "$BASE/book/1" -> "<p>Intro</p><a id='toc' href='/toc/1'>TOC</a>"
                "$BASE/toc/1" -> "<li><a href='/chapter/1'>Chapter One</a></li>"
                "$BASE/chapter/1" -> "<div class='content'><p>Paragraph one</p><p>Paragraph two</p></div>"
                else -> throw AssertionError("Unexpected request: $url")
            }
            jsonObject("status" to 200, "url" to url, "body" to body).toString()
        }
        val source = """{
            "bookSourceUrl":"$BASE", "bookSourceName":"CSS fixture", "searchUrl":"/search?key={{key}}&page={{page}}",
            "ruleSearch":{"bookList":"tag.article","name":"class.book@text","author":"tag.b@text","bookUrl":"class.book@href"},
            "ruleBookInfo":{"intro":"tag.p@text","tocUrl":"id.toc@href"},
            "ruleToc":{"chapterList":"tag.li","chapterName":"tag.a@text","chapterUrl":"tag.a@href"},
            "ruleContent":{"content":"class.content@tag.p@text"}
        }"""
        session = parseObject(LegadoRuntime.createSession(source))["sessionId"].asString
        val list = call("search", """{"key":"fixture","page":2}""").asJsonArray
        val book = call("details", jsonObject("book" to list[0]).toString()).asJsonObject
        assertEquals("Intro", book["intro"].asString)
        assertEquals("$BASE/toc/1", book["tocUrl"].asString)
        val toc = call("toc", jsonObject("book" to book).toString()).asJsonArray
        assertEquals("Chapter One", toc[0].asJsonObject["title"].asString)
        assertEquals("Paragraph one\nParagraph two", call("content", jsonObject("book" to book, "chapter" to toc[0]).toString()).asString)
        assertEquals(4, requests.size)
    }

    @Test fun upstreamJsonPathXPathAndRegexRemainExecutable() {
        assertEquals("one\ntwo", AnalyzeByJSonPath("""{"items":[{"name":"one"},{"name":"two"}]}""").getString("$.items[*].name"))
        assertEquals(listOf("one", "two"), AnalyzeByXPath("<div><b>one</b><b>two</b></div>").getStringList("//b/text()"))
        assertEquals(listOf(listOf("<b>one</b>", "one"), listOf("<b>two</b>", "two")),
            AnalyzeByRegex.getElements("<b>one</b><b>two</b>", arrayOf("<b>(.*?)</b>")))
    }

    @Test fun unportedTransformsReturnUnsupportedInsteadOfApproximateOutput() {
        LegadoRuntime.setHostCallback { _, _, _ -> """{"status":200,"body":"<article>value</article>"}""" }
        session = parseObject(LegadoRuntime.createSession("""{"bookSourceUrl":"$BASE","searchUrl":"/search","ruleSearch":{"bookList":"tag.article@js:result","name":"text"}}"""))["sessionId"].asString
        val result = parseObject(LegadoRuntime.execute(session!!, UUID.randomUUID().toString(), "search", "{}"))
        assertFalse(result["ok"].asBoolean)
        assertEquals("UNSUPPORTED_CAPABILITY", result["error"].asJsonObject["code"].asString)
    }

    private fun call(operation: String, json: String): JsonElement {
        val result = parseObject(LegadoRuntime.execute(session!!, UUID.randomUUID().toString(), operation, json))
        assertTrue(result.toString(), result["ok"].asBoolean)
        return result["result"]
    }
    companion object { private const val BASE = "https://fixture.invalid" }
}
