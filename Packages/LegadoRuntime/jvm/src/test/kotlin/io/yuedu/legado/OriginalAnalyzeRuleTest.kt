package io.yuedu.legado

import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setChapter
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setRuleData
import io.yuedu.legado.originalrule.RuleBook
import io.yuedu.legado.originalrule.RuleChapter
import io.yuedu.legado.originalrule.RuleEnvironment
import io.yuedu.legado.originalrule.RuleSource
import io.yuedu.legado.originalrule.RulePlatform
import io.yuedu.legado.originalrule.UnsupportedRuleCapability
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import org.jsoup.nodes.Element
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.CoroutineContext
import com.google.gson.GsonBuilder
import com.google.gson.JsonParser

/** Desktop tests of the retained coordinator, not an Android-reference or iOS acceptance claim. */
class OriginalAnalyzeRuleTest {
    /** Source-behavior regression from CacheManager's separate Room/ACache branches, not a new Android golden. */
    @Test fun cacheStringAndByteArrayBackingsRemainIndependentForTheSameKey() {
        val clock = AtomicLong(1_000)
        RuleEnvironment(clock = clock::get).use { environment ->
            val cache = environment.cache
            val bytes = byteArrayOf(1, 2, 3)
            cache.put("same", "text", 2)
            cache.put("same", bytes, 4)
            assertEquals("text", cache.get("same", true))
            assertArrayEquals(bytes, cache.getByteArray("same"))
            cache.put("same", "replacement", 3)
            assertArrayEquals(bytes, cache.getByteArray("same"))
            clock.set(4_000)
            assertNull(cache.get("same", true))
            assertArrayEquals(bytes, cache.getByteArray("same"))
            cache.delete("same")
            assertNull(cache.getByteArray("same"))
            assertNull(cache.get("same", true))
            cache.put("same", bytes)
            cache.put("same", "kept")
            assertEquals("kept", cache.get("same", true))
            assertArrayEquals(bytes, cache.getByteArray("same"))
        }
    }

    /** SharedJsScope parses an actual JSON map before classifying it; a JavaScript block stays inline. */
    @Test fun inlineBlockLibraryExecutesWhileActualMapLibrariesRemainUnsupported(): Unit = RuleEnvironment().use { environment ->
        val source = RuleSource(environment, "https://block.invalid", "Synthetic", jsLib = "{ var compatibilityValue = 7; }")
        AnalyzeRule(source = source).use { rule ->
            assertEquals(7.0, rule.evalJS("compatibilityValue"))
            source.jsLib = "{\"library\":\"https://example.invalid/library.js\"}"
            assertThrows(UnsupportedRuleCapability::class.java) { rule.evalJS("1") }
        }
    }

    /** A port lifecycle regression: closing a coordinator must not delegate host effects into its still-open source environment. */
    @Test fun closedCoordinatorRejectsHostCallsWhileItsSharedEnvironmentRemainsOpen() {
        val effects = mutableListOf<String>()
        val platform = object : RulePlatform() {
            override fun request(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext): StrResponse {
                effects.add("request")
                return StrResponse(url, 200, "fixture", emptyMap())
            }
            override fun log(value: Any?): Any? { effects.add("log"); return value }
        }
        RuleEnvironment(platform).use { environment ->
            val source = RuleSource(environment, "https://closed.invalid", "Synthetic")
            val rule = AnalyzeRule(source = source, preUpdateJs = true)
            assertEquals("fixture", rule.connect("https://closed.invalid").body())
            effects.clear()
            rule.close()
            environment.ensureOpen()
            val calls: List<Pair<String, () -> Unit>> = listOf(
                "connect" to { rule.connect("https://closed.invalid") },
                "ajax" to { rule.ajax("https://closed.invalid") },
                "ajax-timeout" to { rule.ajax("https://closed.invalid", 1_000L) },
                "log" to { rule.log("fixture") },
                "reGetBook" to { rule.reGetBook() },
                "refreshTocUrl" to { rule.refreshTocUrl() },
            )
            calls.forEach { (name, call) ->
                val failure = assertThrows(IllegalStateException::class.java) { call() }
                assertEquals(name, "AnalyzeRule is closed", failure.message)
            }
            assertTrue(effects.isEmpty())
        }
    }

    @Test fun originalClassIdentitiesAreRealAndVisibleThroughPackageLookup(): Unit = RuleEnvironment().use { environment ->
        val source = RuleSource(environment, "https://example.invalid", "Synthetic")
        val book = RuleBook(environment, name = "Book")
        val chapter = RuleChapter(environment)
        assertEquals("io.legado.app.data.entities.Book", book.javaClass.name)
        assertEquals("io.legado.app.data.entities.BookChapter", chapter.javaClass.name)
        assertEquals("io.legado.app.data.entities.BookSource", source.javaClass.name)
        AnalyzeRule(book, source).use { rule ->
            assertEquals("io.legado.app.model.analyzeRule.AnalyzeRule", rule.javaClass.name)
            assertEquals(true, rule.evalJS("book instanceof Packages.io.legado.app.data.entities.Book"))
            // Original RhinoScriptEngine:148–159 initializes standard objects, not ImporterTopLevel.
            assertEquals("undefined", rule.evalJS("typeof importClass"))
        }
    }

    @Test fun retainedPublicScalarApiMatchesAll28OriginalAndroidObservations() {
        val golden = resource("android-scalar-selector-golden.json")
        val observations = golden["observations"].asJsonArray
        assertEquals(28, observations.size())
        observations.forEach { value ->
            val row = value.asJsonObject
            val label = row["caseId"].asString + ":" + row["api"].asString
            val setup = row["context"].asJsonObject
            val selected: Any = when (setup["kind"].asString) {
                "document" -> row["content"].asString
                "css-element", "xpath-node" -> AnalyzeRule().use { selector ->
                    selector.setContent(row["content"].asString).getElements(setup["rule"].asString)[setup["index"].asInt]
                }
                else -> error("Unknown frozen context")
            }
            assertEquals(label, row["contextJavaClass"].asString, selected.javaClass.name)
            AnalyzeRule().use { rule ->
                rule.setContent(selected)
                val actual = when (row["api"].asString) {
                    "getString-default" -> rule.getString(row["rule"].asString)
                    "getString-unescape-false" -> rule.getString(row["rule"].asString, false)
                    else -> error("Unknown frozen API")
                }
                assertEquals(label, "return", row["outcome"].asString)
                assertTrue(label, row["exception"].isJsonNull)
                assertEquals(label, row["javaClass"].asString, actual.javaClass.name)
                assertEquals(label, row["actual"].asString, actual)
            }
        }
    }

    @Test fun retainedPublicJsonPathApisMatchAll36OriginalAndroidObservationsAndTypes() {
        val observations = resource("android-jsonpath-public-golden.json")["observations"].asJsonArray
        val serialization = GsonBuilder().serializeNulls().create()
        assertEquals(36, observations.size())
        observations.forEach { value ->
            val row = value.asJsonObject
            val label = row["caseId"].asString + ":" + row["api"].asString
            AnalyzeRule().use { rule ->
                rule.setContent(row["jsonText"].asString)
                val actual: Any? = when (row["api"].asString) {
                    "getString" -> rule.getString(row["rule"].asString, false)
                    "getStringList" -> rule.getStringList(row["rule"].asString)
                    "getElements" -> rule.getElements(row["rule"].asString)
                    else -> error("Unknown frozen API")
                }
                assertEquals(label, "return", row["outcome"].asString)
                assertTrue(label, row["exception"].isJsonNull)
                assertEquals(label, row["javaClass"].asString, actual?.javaClass?.name)
                assertEquals(label, row["actual"], serialization.toJsonTree(actual))
                if (!row["elementJavaClasses"].isJsonNull) {
                    val actualTypes = (actual as List<*>).map { it?.javaClass?.name }
                    assertEquals(label, row["elementJavaClasses"], serialization.toJsonTree(actualTypes))
                }
            }
        }
    }

    private fun resource(name: String) = JsonParser.parseString(requireNotNull(javaClass.getResourceAsStream("/fixtures/$name"))
        .use { String(it.readBytes(), Charsets.UTF_8) }).asJsonObject

    @Test fun actualElementListsAndNestedJavaRuleCalls(): Unit = RuleEnvironment().use { environment ->
        val source = RuleSource(environment, "https://example.invalid", "Synthetic")
        AnalyzeRule(source = source).use { rule ->
            rule.setContent("<h1>Title</h1><ul><li>A</li><li>B</li></ul>")
            val elements = rule.getElements("li")
            assertEquals(2, elements.size)
            assertTrue(elements.first() is Element)
            assertEquals("A", (elements.first() as Element).text())
            assertEquals("Title", rule.getString("@js:java.getString('h1@text', false)"))
            assertEquals("2:B", rule.getString("@js:var xs=java.getElements('li'); xs.size()+':'+xs.get(1).text()"))
            assertEquals("NAME", rule.getString("h1@text<js>result.toUpperCase()</js>##TITLE##NAME"))
        }
    }

    @Test fun scalarListAndUrlNormalizationStayInTheOriginalCoordinator(): Unit = AnalyzeRule().use { rule ->
        rule.setContent("<p>&amp;lt;</p><a href='../b'>B</a>", "https://example.invalid/a/index")
        rule.setRedirectUrl("https://example.invalid/a/index")
        assertEquals("&lt;", rule.getString("p@text", false))
        assertEquals("<", rule.getString("p@text"))
        assertEquals("https://example.invalid/b", rule.getString("a@href", isUrl = true))
        assertEquals("https://example.invalid/a/index", rule.getString("missing@href", isUrl = true))
        assertEquals(listOf("B"), rule.getStringList("a@text"))
    }

    @Test fun cachedMakeUpRuleReevaluatesCurrentJavaBook(): Unit = RuleEnvironment().use { environment ->
        val source = RuleSource(environment, "https://one.invalid", "Synthetic")
        val book = RuleBook(environment, name = "First", bookUrl = "book")
        AnalyzeRule(book, source).use { rule ->
            rule.setContent("ignored")
            assertEquals("First", rule.getString("{{book.name}}"))
            book.name = "Second"
            assertEquals("Second", rule.getString("{{book.name}}"))
            assertEquals("Second", rule.getString("@js:book.getName()"))
        }
    }

    @Test fun statePrecedenceAndLocalValuesSurviveSetContent(): Unit = RuleEnvironment().use { environment ->
        val source = RuleSource(environment, "https://one.invalid", "Synthetic")
        val book = RuleBook(environment, name = "Book", bookUrl = "book")
        val chapter = RuleChapter(environment, title = "Chapter", bookUrl = "book", url = "c")
        source.put("x", "source"); book.putVariable("x", "book"); chapter.putVariable("x", "chapter")
        AnalyzeRule(book, source).use { rule ->
            rule.setContent("first").setChapter(chapter)
            assertEquals("chapter", rule.get("x"))
            rule.put("x", "new")
            assertEquals("new", chapter.getVariable("x")); assertEquals("book", book.getVariable("x"))
            rule.setLocal("x", "local").setContent("second")
            assertEquals("local", rule.get("x")); assertEquals("Book", rule.get("bookName")); assertEquals("Chapter", rule.get("title"))
            rule.evalJS("book.name='Changed'; chapter.putVariable('js','written')")
            assertEquals("Changed", book.name); assertEquals("written", chapter.getVariable("js"))
        }
    }

    @Test fun falseRuleDataWriteDoesNotFallThroughElvisToSource(): Unit = RuleEnvironment().use { environment ->
        val source = RuleSource(environment, "https://one.invalid", "Synthetic")
        val data = RuleData()
        val long = "x".repeat(10_001)
        assertFalse(data.putVariable("first", long))
        source.put("second", "sentinel")
        AnalyzeRule(data, source).use { rule ->
            rule.setContent("content")
            assertEquals(long, rule.put("second", long))
            assertEquals(long, data.getVariable("second"))
            assertEquals("sentinel", source.get("second"))
        }
    }

    @Test fun bookAndChapterLargeVariableBackingIsDistinctAndRetainsOriginalReturnValues(): Unit = RuleEnvironment().use { environment ->
        val book = RuleBook(environment, bookUrl = "book")
        val chapter = RuleChapter(environment, bookUrl = "book", url = "c")
        val long = "x".repeat(10_000)
        assertTrue(book.putVariable("x", long)); assertTrue(chapter.putVariable("x", "chapter"))
        assertNull(book.variable) // Original BaseBook only serializes when super.putVariable returned true.
        assertFalse(book.variableMap.containsKey("x")); assertEquals(long, book.getVariable("x"))
        assertEquals("chapter", chapter.getVariable("x"))
        assertTrue(book.putVariable("x", null)); assertEquals("", book.getVariable("x"))
    }

    @Test fun sourceNamespaceAndCacheMemoryVsBackingAndSeconds() {
        val clock = AtomicLong(1_000)
        RuleEnvironment(clock = clock::get).use { environment ->
            val source = RuleSource(environment, "https://one.invalid", "Synthetic")
            val other = RuleSource(environment, "https://two.invalid", "Synthetic")
            source.put("x", "one"); other.put("x", "two"); source.putVariable("custom")
            assertEquals("one", environment.cache.get("v_https://one.invalid_x"))
            assertEquals("two", other.get("x")); assertEquals("custom", source.getVariable())
            assertEquals("", other.getVariable())
            environment.cache.put("n", 7)
            environment.cache.putMemory("n", 9)
            assertEquals(9, environment.cache.getInt("n")); assertEquals("7", environment.cache.get("n", true))
            environment.cache.put("ttl", "value", 2)
            clock.set(2_999); assertEquals("value", environment.cache.get("ttl"))
            clock.set(3_000); assertNull(environment.cache.get("ttl"))
        }
    }

    @Test fun noLibraryGlobalsAreInvocationLocalWhileInlineLibrarySharesBySource(): Unit = RuleEnvironment().use { environment ->
        val plain = RuleSource(environment, "https://plain.invalid", "Synthetic")
        AnalyzeRule(source = plain).use { rule ->
            assertEquals(1.0, rule.evalJS("globalThis.n=(globalThis.n||0)+1;n"))
            assertEquals("undefined", rule.evalJS("typeof globalThis.n"))
        }
        val shared = RuleSource(environment, "https://shared.invalid", "Synthetic", jsLib = "var polyfill='ready';")
        val other = RuleSource(environment, "https://other.invalid", "Synthetic", jsLib = shared.jsLib)
        AnalyzeRule(source = shared).use { first ->
            assertEquals(1.0, first.evalJS("globalThis.n=(globalThis.n||0)+1;n"))
        }
        AnalyzeRule(source = shared).use { second ->
            assertEquals(2.0, second.evalJS("globalThis.n=(globalThis.n||0)+1;n"))
            assertEquals("ready", second.evalJS("polyfill"))
        }
        AnalyzeRule(source = other).use { separate -> assertEquals("undefined", separate.evalJS("typeof globalThis.n")) }
    }

    @Test fun originalCryptoJsResourceAndSecureRandomRemainAvailable(): Unit = AnalyzeRule().use { rule ->
        assertEquals("5d41402abc4b2a76b9719d911017c592", rule.evalJS("CryptoJS.MD5('hello').toString()"))
        assertEquals(4.0, rule.evalJS("CryptoJS.lib.WordArray.random(4).sigBytes"))
        assertEquals("undefined", rule.evalJS("typeof __legadoSecureRandomInt"))
    }

    @Test fun hutoolStringBase64OverloadsKeepWhitespaceUrlSafeAndCharsetBehavior(): Unit = AnalyzeRule().use { rule ->
        assertEquals("hello", rule.evalJS("java.base64Decode('aG Vs\\nbG8=')"))
        assertEquals("中文", rule.evalJS("java.base64Decode('1tDOxA==','GBK')"))
        assertEquals("hello", rule.evalJS("java.base64Decode('aGVsbG8')"))
        assertEquals("", rule.evalJS("java.base64Decode('')"))
        val decoded = rule.evalJS("java.base64Decode('-_8=','ISO-8859-1')") as String
        assertEquals(listOf(251, 255), decoded.map { it.code })
        // The no-flags overloads above remain Hutool. The separate Android
        // flags overload is now implemented; DEFAULT=0 decodes this same text.
        assertEquals("hello", rule.evalJS("java.base64Decode('aGVsbG8=',0)"))
        assertThrows(Exception::class.java) { rule.evalJS("java.base64Decode('A',0)") }
    }

    @Test fun platformCapabilitiesAreRejectedAndCancelledJobsRemainCancelled(): Unit = RuleEnvironment().use { environment ->
        val source = RuleSource(environment, "https://one.invalid", "Synthetic")
        AnalyzeRule(source = source).use { rule ->
            assertThrows(UnsupportedRuleCapability::class.java) { rule.ajax("https://one.invalid") }
            assertThrows(UnsupportedRuleCapability::class.java) { rule.connect("https://one.invalid") }
            assertThrows(UnsupportedRuleCapability::class.java) { rule.webView(null, null, null) }
            source.jsLib = "https://one.invalid/lib.js"
            assertThrows(UnsupportedRuleCapability::class.java) { rule.evalJS("1") }
            source.jsLib = null
            val job = Job(); job.cancel()
            rule.setCoroutineContext(job)
            assertThrows(CancellationException::class.java) { rule.evalJS("while(true){}") }
        }
    }

    @Test fun closingEnvironmentReleasesSourceCacheAndPreventsFurtherEvaluation() {
        val environment = RuleEnvironment()
        val source = RuleSource(environment, "https://one.invalid", "Synthetic", jsLib = "var library=1;")
        val rule = AnalyzeRule(source = source)
        rule.evalJS("globalThis.x=1")
        environment.close()
        assertThrows(IllegalStateException::class.java) { source.get("x") }
        assertThrows(IllegalStateException::class.java) { rule.evalJS("1") }
        rule.close(); environment.close()
    }
}
