package io.yuedu.legado

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Exercises the actual JVM facade and JS bindings, not just direct DTO helper calls. */
class MainJsFacadeTest {
    private val sessions = mutableListOf<String>()
    @After fun closeSessions() { sessions.forEach(LegadoRuntime::closeSession) }

    @Test fun readingChainNormalizesIdentityTypesRelativeUrlsVolumesAndFilteredIndexes() {
        val session = create("""
            function search(key, page) {
                return [null, {name:'alias',url:'/ignored'}, {name:key,bookUrl:'$BASE/book/1',
                    type:0,origin:'spoof',originName:'spoof',originOrder:999,unknown:true}];
            }
            function getBookInfo(book) {
                if (book.type !== 64) throw new Error('details input type was not reset');
                return {name:book.name+' detail',author:'Author',intro:'Intro',tocUrl:'$BASE/toc/dir/index',
                    type:32,bookUrl:'https://spoof.invalid',durChapterIndex:999,unknown:true};
            }
            function getChapters(book) {
                if (book.type !== 64) throw new Error('toc input type was not reset');
                return [{title:'Volume',url:'Volume',isVolume:true,index:99,bookUrl:'spoof',baseUrl:'spoof'},
                    {title:'missing URL'}, {title:'One',url:'../chapter/1',isVip:true,index:55},
                    {title:'Two',url:'/chapter/2',isPay:true}, {title:'bad boolean',url:'/bad',isVip:[]}];
            }
        """.trimIndent(), sourceType = 2)
        val search = call(session, "search", jsonObject("key" to "Book", "page" to 1)).asJsonArray
        assertEquals(1, search.size())
        val found = search[0].asJsonObject
        assertEquals(BASE, found["origin"].asString)
        assertEquals("Facade source", found["originName"].asString)
        assertEquals(11, found["originOrder"].asInt)
        assertEquals(64, found["type"].asInt)
        assertFalse(found.has("unknown"))
        found.addProperty("durChapterIndex", 5)
        found.addProperty("customTag", "keep")

        val book = call(session, "details", jsonObject("book" to found)).asJsonObject
        assertEquals("Book detail", book["name"].asString)
        assertEquals("Author", book["author"].asString)
        assertEquals("$BASE/book/1", book["bookUrl"].asString)
        assertEquals(32, book["type"].asInt)
        assertEquals(5, book["durChapterIndex"].asInt)
        assertEquals("keep", book["customTag"].asString)
        assertFalse(book.has("unknown"))

        val toc = call(session, "toc", jsonObject("book" to book)).asJsonArray
        assertEquals(3, toc.size())
        assertEquals("Volume", toc[0].asJsonObject["url"].asString)
        assertTrue(toc[0].asJsonObject["isVolume"].asBoolean)
        assertEquals("$BASE/toc/chapter/1", toc[1].asJsonObject["url"].asString)
        assertEquals("$BASE/chapter/2", toc[2].asJsonObject["url"].asString)
        toc.forEachIndexed { index, item ->
            val chapter = item.asJsonObject
            assertEquals(index, chapter["index"].asInt)
            assertEquals("$BASE/book/1", chapter["bookUrl"].asString)
            assertEquals("$BASE/toc/dir/index", chapter["baseUrl"].asString)
        }
        assertFalse(toc[1].asJsonObject["isVolume"].asBoolean)
        assertTrue(toc[1].asJsonObject["isVip"].asBoolean)
        assertFalse(toc[1].asJsonObject["isPay"].asBoolean)
        assertTrue(toc[2].asJsonObject["isPay"].asBoolean)
        assertEquals(32, book["type"].asInt) // prepareInput must not modify the caller's DTO.
    }

    @Test fun serializedLegacyReturnsAreDecodedOnceThroughRealFacade() {
        val session = create("""
            function search() { return JSON.stringify([{name:'Legacy',bookUrl:'$BASE/book/2'}]); }
            function getBookInfo(book) { return JSON.stringify({intro:'Legacy intro',tocUrl:'$BASE/toc/index'}); }
            function getChapters(book) { return JSON.stringify([{title:'Legacy chapter',url:'../legacy/1'}]); }
        """.trimIndent())
        val found = call(session, "search").asJsonArray[0]
        val book = call(session, "getBookInfo", jsonObject("book" to found)).asJsonObject
        assertEquals("Legacy", book["name"].asString)
        assertEquals("Legacy intro", book["intro"].asString)
        val toc = call(session, "getChapters", jsonObject("book" to book)).asJsonArray
        assertEquals("$BASE/legacy/1", toc[0].asJsonObject["url"].asString)
        assertEquals("$BASE/book/2", toc[0].asJsonObject["bookUrl"].asString)
        assertEquals("$BASE/toc/index", toc[0].asJsonObject["baseUrl"].asString)
        assertEquals(0, toc[0].asJsonObject["index"].asInt)
    }

    @Test fun returnlessMutationUsesExplicitFiniteDtoFallbackAndMergeWhitelist() {
        val session = create("""
            function getBookInfo(book) {
                book.name = 'Mutated'; book.intro = 'Mutation retained'; book.tocUrl = '$BASE/toc';
                book.durChapterIndex = 999; book.unknown = 'discard';
            }
        """.trimIndent())
        val original = jsonObject("bookUrl" to "$BASE/book/3", "name" to "Original", "durChapterIndex" to 3)
        val book = call(session, "details", jsonObject("book" to original)).asJsonObject
        assertEquals("Mutated", book["name"].asString)
        assertEquals("Mutation retained", book["intro"].asString)
        assertEquals("$BASE/toc", book["tocUrl"].asString)
        assertEquals(3, book["durChapterIndex"].asInt)
        assertFalse(book.has("unknown"))
        assertEquals("Original", original["name"].asString)

        // Explicit prototype limitation: a DTO fallback still uses the rename gate.
        // Upstream's real mutable Java Book can retain direct name mutations even
        // with canReName=false; this test does not claim Java entity reference parity.
        val noRename = call(session, "details", jsonObject("book" to original, "canReName" to false)).asJsonObject
        assertEquals("Original", noRename["name"].asString)
        assertEquals("Mutation retained", noRename["intro"].asString)
    }

    @Test fun invalidShapesAndAliasOnlyChaptersRemainExplicitErrors() {
        val session = create("""
            function search() { return {name:'not an array'}; }
            function getBookInfo(book) { return 'null'; }
            function getChapters(book) { return [{title:'alias only',chapterUrl:'/not-supported'}]; }
        """.trimIndent())
        val book = jsonObject("bookUrl" to "$BASE/book/4", "tocUrl" to "$BASE/toc")
        assertError(session, "search", JsonObject(), "INVALID_RESULT", "返回值不是数组")
        assertError(session, "details", jsonObject("book" to book), "INVALID_RESULT", "返回值不是对象")
        assertError(session, "toc", jsonObject("book" to book), "TOC_EMPTY", "目录列表为空")
    }

    private fun create(script: String, sourceType: Int = 0): String {
        val created = parseObject(LegadoRuntime.createSession(jsonObject("bookSourceUrl" to BASE,
            "bookSourceName" to "Facade source", "customOrder" to 11,
            "bookSourceType" to sourceType, "mainJs" to script).toString()))
        assertTrue(created.toString(), created["ok"].asBoolean)
        return created["sessionId"].asString.also(sessions::add)
    }
    private fun call(session: String, operation: String, input: JsonObject = JsonObject()): JsonElement {
        val result = parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), operation, input.toString()))
        assertTrue(result.toString(), result["ok"].asBoolean)
        return result["result"]
    }
    private fun assertError(session: String, operation: String, input: JsonObject, code: String, message: String) {
        val result = parseObject(LegadoRuntime.execute(session, UUID.randomUUID().toString(), operation, input.toString()))
        assertFalse(result.toString(), result["ok"].asBoolean)
        assertEquals(code, result["error"].asJsonObject["code"].asString)
        assertTrue(result.toString(), result["error"].asJsonObject["message"].asString.contains(message))
    }
    companion object { private const val BASE = "https://facade.example" }
}
