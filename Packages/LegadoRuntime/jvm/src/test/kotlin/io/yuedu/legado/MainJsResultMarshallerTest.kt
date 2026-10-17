package io.yuedu.legado

import com.google.gson.*
import org.junit.Assert.*
import org.junit.Test

/** Expectations anchored in the archive's JsSourceMarshallerTest and production helpers. */
class MainJsResultMarshallerTest {
    private val source = obj("""{"bookSourceUrl":"https://source.example","bookSourceName":"Source","customOrder":7}""")
    private val input = obj("""{"book":{"bookUrl":"https://source.example/book/1","tocUrl":"https://source.example/toc/dir/index.html","name":"Old","author":"Old author"}}""")

    @Test fun searchFiltersEntriesAndOverwritesSourceIdentityWithoutUrlAlias() {
        // JsSourceMarshaller.parseSearchBooks: required name/bookUrl; source identity wins.
        val result = marshal("search", """[null,42,{"name":"missing"},{"name":"alias","url":"/wrong"},
            {"name":" ","bookUrl":"u"},{"name":"Good","bookUrl":"relative","origin":"spoof","originName":"spoof","originOrder":99,"customOrder":99,"unknown":"bad"}]""").asJsonArray
        assertEquals(1, result.size())
        val book = result[0].asJsonObject
        assertEquals("relative", book["bookUrl"].asString) // Search does not absolutize bookUrl.
        assertEquals("https://source.example", book["origin"].asString)
        assertEquals("Source", book["originName"].asString)
        assertEquals(7, book["originOrder"].asInt)
        assertFalse(book.has("customOrder"))
        assertFalse(book.has("unknown"))
        assertEquals("", book["author"].asString)
    }

    @Test fun sourceBookTypesAndReturnedBitMaskMatchOriginalConstants() {
        // BookSourceExtensions.getBookType and BookType.allBookType == 236.
        listOf(0 to 8, 1 to 32, 2 to 64, 3 to 136, 4 to 4, 99 to 8).forEach { (kind, expected) ->
            val configured = source.deepCopy().apply { addProperty("bookSourceType", kind) }
            val result = MainJsResultMarshaller.marshal("search", json("""[{"name":"a","bookUrl":"u"}]"""), input, configured)
            assertEquals(expected, result.asJsonArray[0].asJsonObject["type"].asInt)
        }
        listOf("0", "1", "16", "256", "\"audio\"", "null", "{}").forEach { raw ->
            assertEquals(8, marshal("search", """[{"name":"a","bookUrl":"u","type":$raw}]""")
                .asJsonArray[0].asJsonObject["type"].asInt)
        }
        listOf("236" to 236, "\"32\"" to 32, "[64]" to 64, "8.9" to 8).forEach { (raw, expected) ->
            assertEquals(expected, marshal("search", """[{"name":"a","bookUrl":"u","type":$raw}]""")
                .asJsonArray[0].asJsonObject["type"].asInt)
        }
    }

    @Test fun searchPreservesOriginalCustomGsonStringCoercionsAndSkipsBadObjects() {
        // GsonExtensions.StringJsonDeserializer accepts structured values as JSON text.
        val result = marshal("search", """[{"name":123,"bookUrl":true,"intro":{"html":"x"}},
            {"name":"bad time","bookUrl":"u","time":[]},{"name":null,"bookUrl":"u"}]""").asJsonArray
        assertEquals(1, result.size())
        assertEquals("123", result[0].asJsonObject["name"].asString)
        assertEquals("true", result[0].asJsonObject["bookUrl"].asString)
        assertEquals("""{"html":"x"}""", result[0].asJsonObject["intro"].asString)
    }

    @Test fun searchAcceptsLegacyJsonStringsButRejectsWrongShapeAndStringifiedNull() {
        val legacy = JsonPrimitive("""[{"name":"Good","bookUrl":"u"}]""")
        assertEquals(1, MainJsResultMarshaller.marshal("search", legacy, input, source).asJsonArray.size())
        assertEquals(0, marshal("search", "null").asJsonArray.size())
        assertEquals(0, MainJsResultMarshaller.marshal("search", JsonPrimitive("  "), input, source).asJsonArray.size())
        assertFailure("INVALID_RESULT", "返回值不是数组") { marshal("search", "{}") }
        assertFailure("INVALID_RESULT", "返回值不是数组") {
            MainJsResultMarshaller.marshal("search", JsonPrimitive("null"), input, source)
        }
    }

    @Test fun chaptersResolveRelativeUrlsAndOverwriteBookIdentityAndSequentialIndex() {
        // JsSourceMarshaller.parseChapters, including the volume-name exception.
        val chapters = marshal("toc", """[{"title":"Volume","url":"Volume","isVolume":true,"index":99,"bookUrl":"spoof","baseUrl":"spoof"},
            {"title":" ","url":"/bad"},{"title":"One","url":"../chapter/1","index":55},
            {"title":"Two","url":"https://cdn.example/c2","isVip":true,"isPay":true}]""").asJsonArray
        assertEquals(3, chapters.size())
        assertEquals("Volume", chapters[0].asJsonObject["url"].asString)
        assertEquals("https://source.example/toc/chapter/1", chapters[1].asJsonObject["url"].asString)
        assertEquals("https://cdn.example/c2", chapters[2].asJsonObject["url"].asString)
        chapters.forEachIndexed { index, item ->
            val chapter = item.asJsonObject
            assertEquals(index, chapter["index"].asInt)
            assertEquals("https://source.example/book/1", chapter["bookUrl"].asString)
            assertEquals("https://source.example/toc/dir/index.html", chapter["baseUrl"].asString)
        }
        assertFalse(chapters[1].asJsonObject["isVolume"].asBoolean)
        assertFalse(chapters[1].asJsonObject["isVip"].asBoolean)
        assertFalse(chapters[1].asJsonObject["isPay"].asBoolean)
        assertTrue(chapters[2].asJsonObject["isVip"].asBoolean)
    }

    @Test fun chaptersHaveNoChapterUrlAliasAndSkipMalformedBooleanObjects() {
        val chapters = marshal("getChapters", """[{"title":"alias","chapterUrl":"/alias"},
            {"title":"bad","url":"/bad","isVip":[]},{"title":"ok","url":"/ok"}]""").asJsonArray
        assertEquals(1, chapters.size())
        assertEquals(0, chapters[0].asJsonObject["index"].asInt)
        assertEquals("https://source.example/ok", chapters[0].asJsonObject["url"].asString)
    }

    @Test fun chaptersUseNetworkUtilsCommaOptionAndInvalidBaseBehavior() {
        val comma = input.deepCopy().apply { getAsJsonObject("book").addProperty("tocUrl", "https://host.example/toc/index,{\"method\":\"GET\"}") }
        assertEquals("https://host.example/chapter/1", marshal("toc", """[{"title":"One","url":"../chapter/1"}]""", comma)
            .asJsonArray[0].asJsonObject["url"].asString)
        val invalid = input.deepCopy().apply { getAsJsonObject("book").addProperty("tocUrl", "not a URL") }
        assertEquals("chapter/1", marshal("toc", """[{"title":"One","url":"  chapter/1  "}]""", invalid)
            .asJsonArray[0].asJsonObject["url"].asString)
    }

    @Test fun emptyTocFailsAtJsSourceBookBoundaryInsteadOfReportingSuccess() {
        assertFailure("TOC_EMPTY", "目录列表为空") { marshal("toc", "[]") }
        assertFailure("TOC_EMPTY", "目录列表为空") { marshal("toc", "null") }
        assertFailure("INVALID_RESULT", "getChapters 返回值不是数组") { marshal("toc", "{}") }
        assertFailure("INVALID_RESULT", "getChapters 返回值不是数组") {
            MainJsResultMarshaller.marshal("toc", JsonPrimitive("null"), input, source)
        }
    }

    @Test fun detailsMergeWhitelistPreservesExistingFieldsAndRenameOptOut() {
        // JsSourceMarshallerTest: merges only allowed detail fields.
        val base = input.deepCopy().apply {
            addProperty("canReName", false)
            getAsJsonObject("book").addProperty("durChapterIndex", 5)
            getAsJsonObject("book").addProperty("customTag", "keep")
        }
        val book = marshal("details", """{"name":"New","author":"New author","intro":"Intro","bookUrl":"spoof","durChapterIndex":0,"customTag":"overwrite","unknown":"bad"}""", base).asJsonObject
        assertEquals("Old", book["name"].asString)
        assertEquals("Old author", book["author"].asString)
        assertEquals("Intro", book["intro"].asString)
        assertEquals("https://source.example/book/1", book["bookUrl"].asString)
        assertEquals(5, book["durChapterIndex"].asInt)
        assertEquals("keep", book["customTag"].asString)
        assertFalse(book.has("unknown"))
    }

    @Test fun detailsDefaultCanRenameIsTrueAndOnlyEmptyAuthorBypassesFalse() {
        // WebBook.getBookInfoAwait defaults canReName=true; author uses isEmpty, not isBlank.
        val renamed = marshal("getBookInfo", """{"name":"New","author":"New author"}""").asJsonObject
        assertEquals("New", renamed["name"].asString)
        assertEquals("New author", renamed["author"].asString)
        val empty = input.deepCopy().apply { addProperty("canReName", false); getAsJsonObject("book").addProperty("author", "") }
        assertEquals("Filled", marshal("details", """{"author":"Filled"}""", empty).asJsonObject["author"].asString)
        empty.getAsJsonObject("book").addProperty("author", " ")
        assertEquals(" ", marshal("details", """{"author":"Filled"}""", empty).asJsonObject["author"].asString)
    }

    @Test fun detailsVariableObjectAndStringReplaceRatherThanMergePreviousMap() {
        // JsSourceMarshaller.mergeVariable clears variableMap before putAll.
        val base = input.deepCopy().apply { getAsJsonObject("book").addProperty("variable", """{"old":"value"}""") }
        val book = marshal("details", """{"variable":{"token":"abc","nested":{"n":1}}}""", base).asJsonObject
        val variables = json(book["variable"].asString).asJsonObject
        assertFalse(variables.has("old"))
        assertEquals("abc", variables["token"].asString)
        assertEquals("""{"n":1}""", variables["nested"].asString)
        val encoded = obj("""{"variable":"{\"session\":\"xyz\"}"}""")
        val next = MainJsResultMarshaller.marshal("details", encoded, base, source).asJsonObject
        assertEquals(json("""{"session":"xyz"}"""), json(next["variable"].asString))
        assertEquals(base["book"].asJsonObject["variable"], marshal("details", """{"variable":[]}""", base).asJsonObject["variable"])
    }

    @Test fun detailsDownloadUrlsResolveTrimDeduplicateAndRejectWholeBadArray() {
        val result = marshal("details", """{"downloadUrls":[" /download/a.txt ","https://cdn.example/b.epub","/download/a.txt","javascript:bad","JavaScript:bad",""]}""").asJsonObject
        assertEquals(json("""["https://source.example/download/a.txt","https://cdn.example/b.epub"]"""), result["downloadUrls"])
        val base = input.deepCopy().apply { getAsJsonObject("book").add("downloadUrls", json("""["keep"]""")) }
        assertEquals(json("""["keep"]"""), marshal("details", """{"downloadUrls":["/valid",12]}""", base).asJsonObject["downloadUrls"])
        assertEquals(json("""["keep"]"""), marshal("details", """{"downloadUrls":"invalid"}""", base).asJsonObject["downloadUrls"])
    }

    @Test fun detailsResetBookTypeBeforeScriptAndRespectValidOverride() {
        // JsSourceBook.getBookInfoAwait removes all source bits but keeps local/error flags.
        val base = input.deepCopy().apply { getAsJsonObject("book").addProperty("type", 304) }
        val prepared = MainJsResultMarshaller.prepareInput("details", base, source)
        assertEquals(280, prepared["book"].asJsonObject["type"].asInt)
        assertEquals(304, base["book"].asJsonObject["type"].asInt) // Deep copy, caller untouched.
        assertEquals(280, marshal("details", """{"type":16}""", base).asJsonObject["type"].asInt)
        assertEquals(32, marshal("details", """{"type":32}""", base).asJsonObject["type"].asInt)
    }

    @Test fun fileSourceReaddsFileBitsAndRequiresNonemptyDownloads() {
        // JsSourceBook file postprocessing runs after the permitted detail type override.
        val fileSource = source.deepCopy().apply { addProperty("bookSourceType", 3) }
        val result = MainJsResultMarshaller.marshal("details", json("""{"type":32,"downloadUrls":["/a.epub"]}"""), input, fileSource).asJsonObject
        assertEquals(168, result["type"].asInt)
        assertFailure("DOWNLOAD_URLS_EMPTY", "下载链接为空") {
            MainJsResultMarshaller.marshal("details", JsonNull.INSTANCE, input, fileSource)
        }
    }

    @Test fun detailsTocFallbackAppliesOnlyWhenBlankAndDoesNotAbsolutizeReturnedToc() {
        val base = input.deepCopy().apply { getAsJsonObject("book").addProperty("tocUrl", " ") }
        assertEquals("https://source.example/book/1", marshal("details", "{}", base).asJsonObject["tocUrl"].asString)
        assertEquals("../toc", marshal("details", """{"tocUrl":"../toc"}""", base).asJsonObject["tocUrl"].asString)
    }

    @Test fun detailsNullBlankAndLegacyJsonStringsFollowOriginalReturnProtocol() {
        assertEquals("Old", marshal("details", "null").asJsonObject["name"].asString)
        assertEquals("Old", MainJsResultMarshaller.marshal("details", JsonPrimitive(" "), input, source).asJsonObject["name"].asString)
        assertEquals("New", MainJsResultMarshaller.marshal("details", JsonPrimitive("""{"name":"New"}"""), input, source).asJsonObject["name"].asString)
        assertFailure("INVALID_RESULT", "getBookInfo 返回值不是对象") { marshal("details", "[]") }
        assertFailure("INVALID_RESULT", "getBookInfo 返回值不是对象") {
            MainJsResultMarshaller.marshal("details", JsonPrimitive("null"), input, source)
        }
    }

    @Test fun detailsDoNotSilentlySerializeInvalidStringFieldsAsSuccessfulMetadata() {
        assertFailure("INVALID_RESULT", "intro 无法读取为字符串") { marshal("details", """{"intro":{"bad":true}}""") }
        assertEquals("42", marshal("details", """{"wordCount":42}""").asJsonObject["wordCount"].asString)
        val original = input["book"].asJsonObject["name"].asString
        assertEquals(original, marshal("details", """{"name":null}""").asJsonObject["name"].asString)
    }

    @Test fun unrelatedOperationsKeepTheirJsonProtocol() {
        val content = JsonPrimitive("")
        assertSame(content, MainJsResultMarshaller.marshal("content", content, input, source))
        val evaluated = obj("""{"arbitrary":true}""")
        assertSame(evaluated, MainJsResultMarshaller.marshal("evaluate", evaluated, input, source))
    }

    private fun marshal(operation: String, result: String, request: JsonObject = input): JsonElement =
        MainJsResultMarshaller.marshal(operation, json(result), request, source)
    private fun obj(value: String) = json(value).asJsonObject
    private fun json(value: String) = JsonParser.parseString(value)
    private fun assertFailure(code: String, message: String, action: () -> Any?) {
        try { action(); fail("Expected $code") }
        catch (error: RuntimeFailure) {
            assertEquals(code, error.code)
            assertTrue(error.message.orEmpty(), error.message.orEmpty().contains(message))
        }
    }
}
