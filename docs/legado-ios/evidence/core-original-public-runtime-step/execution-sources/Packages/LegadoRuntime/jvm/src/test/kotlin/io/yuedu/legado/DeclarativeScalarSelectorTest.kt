package io.yuedu.legado

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Fixed desktop host responses exercise the product dispatcher, not native wire or full G4. */
class DeclarativeScalarSelectorTest {
    private val sessions = arrayListOf<String>()

    @After
    fun close() {
        try { sessions.forEach(LegadoRuntime::closeSession) }
        finally { LegadoRuntime.setHostCallback(null) }
    }

    @Test
    fun nonUrlScalarTransformsReachAllFourExistingDeclarativeReadingStages() {
        val requests = installFixture()
        val session = create(source())
        val list = call(session, "search", jsonObject("key" to "fixture", "page" to 2)).asJsonArray
        val found = list.single().asJsonObject
        assertEquals("Book [12]", found["name"].asString)
        assertEquals("WriterN", found["author"].asString)
        assertEquals("$BASE/book/1", found["bookUrl"].asString)
        val book = call(session, "details", jsonObject("book" to found)).asJsonObject
        assertEquals("&lt; intro", book["intro"].asString)
        assertEquals("$BASE/toc/1", book["tocUrl"].asString)
        val toc = call(session, "toc", jsonObject("book" to book)).asJsonArray
        assertEquals("One [12]", toc.single().asJsonObject["title"].asString)
        assertEquals("$BASE/chapter/1", toc.single().asJsonObject["url"].asString)
        assertEquals("raw [12]\ntail [34]", call(session, "content", jsonObject("book" to book, "chapter" to toc.single())).asString)
        assertEquals(listOf("$BASE/search?key=fixture&page=2", "$BASE/book/1", "$BASE/toc/1", "$BASE/chapter/1"), requests)
    }

    @Test
    fun urlRulesIncludingChapterUrlAndUrlTemplatesNeverUseTheScalarTransform() {
        val requests = installFixture()
        val cases = listOf(
            Triple("searchUrl", "search", ""), Triple("exploreUrl", "explore", ""),
            Triple("ruleSearch", "search", "bookUrl"), Triple("ruleSearch", "search", "coverUrl"),
            Triple("ruleBookInfo", "details", "tocUrl"), Triple("ruleToc", "toc", "chapterUrl"),
        )
        for ((section, operation, field) in cases) {
            val source = source()
            if (field.isEmpty()) source.addProperty(section, "/search##x##y")
            else source[section].asJsonObject.addProperty(field, "@CSS:a@href##x##y")
            val before = requests.size
            val error = execute(create(source), operation, input(operation))
            assertFalse("$section/$field", error["ok"].asBoolean)
            assertEquals("UNSUPPORTED_CAPABILITY", error["error"].asJsonObject["code"].asString)
            assertEquals("No URL template may issue a transformed request", before + if (field.isEmpty()) 0 else 1, requests.size)
        }
    }

    @Test
    fun listTransformsAndCaptureListScalarTransformsRemainUnsupported() {
        installFixture()
        for ((section, field, operation) in listOf(
            Triple("ruleSearch", "bookList", "search"), Triple("ruleToc", "chapterList", "toc"),
        )) {
            val source = source()
            source[section].asJsonObject.addProperty(field, "tag.article##x##y")
            val error = execute(create(source), operation, input(operation))
            assertFalse(error.toString(), error["ok"].asBoolean)
            assertEquals("UNSUPPORTED_CAPABILITY", error["error"].asJsonObject["code"].asString)
        }
        val source = source()
        source["ruleSearch"].asJsonObject.apply {
            addProperty("bookList", ":<a[^>]*>(.*?)</a>")
            addProperty("name", "\$1##Book##invented")
        }
        val error = execute(create(source), "search", input("search"))
        assertFalse(error.toString(), error["ok"].asBoolean)
        assertEquals("UNSUPPORTED_CAPABILITY", error["error"].asJsonObject["code"].asString)
    }

    private fun installFixture(): MutableList<String> {
        val requests = arrayListOf<String>()
        LegadoRuntime.setHostCallback { _, operation, requestJSON ->
            assertEquals("http.request", operation)
            val url = parseObject(requestJSON)["url"].asString
            requests += url
            val body = when (url) {
                "$BASE/search?key=fixture&page=2" -> "<article><a class='book' href='/book/1'>Book 12</a><b>Writer9</b></article>"
                "$BASE/book/1" -> "<p>raw intro</p><a id='toc' href='/toc/1'>TOC</a>"
                "$BASE/toc/1" -> "<li><a href='/chapter/1'>One 12</a></li>"
                "$BASE/chapter/1" -> "<div><p>raw 12</p><p>tail 34</p></div>"
                else -> throw AssertionError("Unexpected fixture request: $url")
            }
            jsonObject("status" to 200, "url" to url, "body" to body).toString()
        }
        return requests
    }

    private fun source(): JsonObject = parseObject("""{
        "bookSourceUrl":"$BASE", "bookSourceName":"Static scalar fixture", "searchUrl":"/search?key={{key}}&page={{page}}",
        "ruleSearch":{"bookList":"tag.article","name":"@CSS:a@text##Book ([0-9]+)##Book [${'$'}1]","author":"@CSS:b@text##[0-9]+##N","bookUrl":"class.book@href"},
        "ruleBookInfo":{"intro":"@XPath://p/text()##raw##&amp;lt;","tocUrl":"id.toc@href"},
        "ruleToc":{"chapterList":"tag.li","chapterName":"@CSS:a@text##One ([0-9]+)##One [${'$'}1]","chapterUrl":"tag.a@href"},
        "ruleContent":{"content":"@CSS:p@text##([0-9]+)##[${'$'}1]"}
    }""")

    private fun input(operation: String): JsonObject = when (operation) {
        "details" -> jsonObject("book" to jsonObject("bookUrl" to "$BASE/book/1"))
        "toc" -> jsonObject("book" to jsonObject("bookUrl" to "$BASE/book/1", "tocUrl" to "$BASE/toc/1"))
        else -> jsonObject("key" to "fixture", "page" to 2)
    }

    private fun create(source: JsonObject): String {
        val result = parseObject(LegadoRuntime.createSession(source.toString()))
        assertTrue(result.toString(), result["ok"].asBoolean)
        return result["sessionId"].asString.also(sessions::add)
    }

    private fun execute(session: String, operation: String, input: JsonObject): JsonObject =
        parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), operation, input.toString()))

    private fun call(session: String, operation: String, input: JsonObject): JsonElement {
        val result = execute(session, operation, input)
        assertTrue(result.toString(), result["ok"].asBoolean)
        return result["result"]
    }

    companion object { private const val BASE = "https://fixture.invalid" }
}
