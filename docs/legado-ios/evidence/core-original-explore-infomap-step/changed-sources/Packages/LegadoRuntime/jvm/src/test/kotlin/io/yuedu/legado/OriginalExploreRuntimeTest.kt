package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpServer
import io.legado.app.utils.InfoMap
import io.yuedu.legado.originalrule.*
import io.yuedu.legado.reference.OriginalInfoMapOracle
import io.yuedu.legado.reference.ReferenceInfoMapCache
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Actual public runtime/host + loopback/file owner, not Android or native SDK. */
class OriginalExploreRuntimeTest {
    @Test(timeout = 20_000) fun pinnedInfoMapBodiesKeepMapIdentitySaveFlagsFailureAndSecondsContract() = runBlocking {
        ReferenceInfoMapCache.reset()
        val source = "https://oracle.invalid/${UUID.randomUUID()}"
        val key = "infoMap_$source"
        ReferenceInfoMapCache.values[key] = "{\"first\":\"old\"}"
        val oracle = OriginalInfoMapOracle(source)
        val clock = AtomicLong(100_000)
        RuleEnvironment(clock = clock::get).use { env ->
            env.cache.put(key, "{\"first\":\"old\"}")
            lateinit var port: InfoMap
            OriginalExploreContexts.withScope(UUID.randomUUID().toString(), source, env, create = true) { current ->
                port = requireNotNull(current)
                assertEquals(oracle.get(), port.get())
                for (map in listOf<MutableMap<String, String>>(oracle, port)) {
                    map["first"] = "new"; map["second"] = "two"; map.entries.first { it.key == "second" }.setValue("changed")
                }
                oracle.save(2, false); port.save(2, false)
                assertFalse(oracle.needSave); assertFalse(port.needSave)
                oracle.save(-1); port.save(-1)
                assertTrue(oracle.needSave); assertTrue(port.needSave)
                ReferenceInfoMapCache.fail = true
                try { oracle.saveNow(); fail("oracle must retain pending flag on real cache failure") } catch (_: java.io.IOException) {}
                assertTrue(oracle.needSave)
                ReferenceInfoMapCache.fail = false
                oracle.saveNow(); port.saveNow()
                assertFalse(oracle.needSave); assertFalse(port.needSave)
                assertEquals(-1, ReferenceInfoMapCache.writes.last().third)
                assertNull(env.cache.get(key)) // Negative seconds expire in the existing CacheManager port.
                assertEquals(oracle.get(), port.get()) // The live InfoMap is not discarded on cache expiry.
                // Original deadline==0 is a sentinel, even when reached by a
                // synthetic epoch clock plus negative seconds.
                clock.set(1_000); port.save(-1); port.saveNow()
                assertNotNull(env.cache.get(key))
                val copy = linkedMapOf("copy" to "kept")
                oracle.set(copy); port.set(copy); copy["copy"] = "later"
                assertEquals(oracle.get(), port.get()); assertEquals("kept", port["copy"])
                assertSame(port.get(), port.get())
            }
            try { port.saveNow(); fail("A retained map must not persist through a closed invocation context") }
            catch (_: UnsupportedRuleCapability) {}
        }
    }

    @Test(timeout = 30_000) fun publicExploreSharesUiAndUrlMapAndRunsRetainedCssXPathJsonRegexAndFallback() {
        val exploreOnly = jsonObject("bookSourceUrl" to "https://explore-only.invalid", "ruleExplore" to jsonObject("bookList" to ".book"))
        assertFalse(parseObject(LegadoRuntime.createSession(exploreOnly.toString()))["ok"].asBoolean)
        Owned().use { f ->
            f.exploreOnly = true
            val absent = f.call("explore", jsonObject("url" to "@js: '${f.origin}/css?absent='+(infoMap===null)"))
            assertEquals("CSS", absent["books"].asJsonArray[0].asJsonObject["name"].asString)
            assertTrue(f.requests.last().contains("absent=true"))
            val unopened = f.execute("exploreContext", jsonObject("action" to "evaluate", "script" to "'never'"))
            assertEquals("UNSUPPORTED_CAPABILITY", unopened["error"].asJsonObject["code"].asString)
            assertTrue(f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject.entrySet().isEmpty())
            val ui = f.call("exploreContext", jsonObject("action" to "evaluate", "script" to "infoMap.put('genre','science'); infoMap.save(); source.put('ui','same-source'); 'ui-value'"))
            assertEquals("ui-value", ui["result"].asString); assertTrue(ui["needSave"].asBoolean)
            val rules = listOf(
                "css" to jsonObject("bookList" to ".book", "name" to "text", "bookUrl" to "href"),
                "xpath" to jsonObject("bookList" to "@XPath://a", "name" to "@XPath:text()", "bookUrl" to "@XPath:@href"),
                "json" to jsonObject("bookList" to "$.items", "name" to "$.name", "bookUrl" to "$.url"),
                "regex" to jsonObject("bookList" to ":BOOK\\[([^|]*)\\|([^\\]]*)\\]", "name" to "\$1", "bookUrl" to "\$2"))
            for ((kind, rule) in rules) {
                val url = "@js:if(source.get('ui')!='same-source') throw Error('wrong source'); infoMap.put('lastPage',String(page)); java.put('urlPage',String(page)); '${f.origin}/$kind?p='+page+'&genre='+infoMap.get('genre')"
                val response = f.call("explore", jsonObject("url" to url, "page" to 2), rule = rule)
                val book = response["books"].asJsonArray.single().asJsonObject
                assertEquals(kind.uppercase(), book["name"].asString)
                assertEquals("2", parseObject(book["variable"].asString)["urlPage"].asString)
                assertTrue(f.requests.last().contains("p=2&genre=science"))
            }
            f.exploreOnly = false // The original fallback ruleSearch remains available when authored.
            val fallback = f.call("explore", jsonObject("url" to "/css"), rule = jsonObject("bookList" to ""))
            assertEquals("CSS", fallback["books"].asJsonArray.single().asJsonObject["name"].asString)
            assertEquals("2", f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject["lastPage"].asString)
            assertEquals(6, f.requests.size)
        }
    }

    @Test(timeout = 30_000) fun contextSurvivesNewRuntimeGrantsAndLruEvictionWhileOnlyPendingSavePersists() {
        Owned().use { f ->
            f.call("exploreContext", jsonObject("action" to "open"))
            f.call("exploreContext", jsonObject("action" to "evaluate", "script" to "infoMap.put('memory','retained'); infoMap.save(); 'done'"))
            assertEquals("retained", f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject["memory"].asString)
            f.failWrites = true
            val failure = f.execute("exploreContext", jsonObject("action" to "savePending"))
            assertEquals("STATE_IO", failure["error"].asJsonObject["code"].asString)
            assertTrue(f.call("exploreContext", jsonObject("action" to "open"))["needSave"].asBoolean)
            f.failWrites = false
            assertFalse(f.call("exploreContext", jsonObject("action" to "savePending"))["needSave"].asBoolean)
            f.generation++ // New actual backing/revision scope; cache file owner remains the same.
            assertEquals("retained", f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject["memory"].asString)
            f.call("exploreContext", jsonObject("action" to "evaluate", "script" to "infoMap.put('expire','past'); infoMap.save(-1); 'done'"))
            f.call("exploreContext", jsonObject("action" to "savePending"))
            assertEquals("past", f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject["expire"].asString)
            f.generation++
            assertTrue(f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject.entrySet().isEmpty())
            f.call("exploreContext", jsonObject("action" to "evaluate", "script" to "infoMap.put('unsaved','discard'); infoMap.save(0,false); 'done'"))
            f.call("exploreContext", jsonObject("action" to "savePending"))
            for (index in 0..99) f.call("exploreContext", jsonObject("action" to "open"), sourceID = "lru-$index")
            assertTrue(f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject.entrySet().isEmpty())
            assertTrue(f.requests.isEmpty())
        }
    }

    @Test(timeout = 25_000) fun cancellationOfWaitingContextDoesNotMutateAnotherLiveInvocationOrCrossOwners() {
        Owned().use { f ->
            f.call("exploreContext", jsonObject("action" to "open"))
            val pool = Executors.newFixedThreadPool(2)
            try {
                val first = pool.submit<JsonObject> { f.execute("explore", jsonObject("url" to "@js: infoMap.put('first','accepted'); '${f.origin}/held'")) }
                assertTrue(f.heldEntered.await(5, TimeUnit.SECONDS))
                val secondID = "waiting-${UUID.randomUUID()}"; f.waitForScopeTask = secondID
                val second = pool.submit<JsonObject> { f.execute("exploreContext", jsonObject("action" to "evaluate", "script" to "infoMap.put('late','forbidden'); 'late'"), taskID = secondID) }
                assertTrue(f.waitingScope.await(5, TimeUnit.SECONDS))
                LegadoRuntime.cancel(secondID)
                assertEquals("CANCELLED", second.get(4, TimeUnit.SECONDS)["error"].asJsonObject["code"].asString)
                f.heldRelease.countDown(); assertTrue(first.get(5, TimeUnit.SECONDS)["ok"].asBoolean)
                val map = f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject
                assertEquals("accepted", map["first"].asString); assertFalse(map.has("late"))
                val other = f.call("exploreContext", jsonObject("action" to "open"), sourceID = "other-source")["infoMap"].asJsonObject
                assertTrue(other.entrySet().isEmpty())
            } finally { f.heldRelease.countDown(); pool.shutdownNow(); assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS)) }
        }
    }

    @Test(timeout = 25_000) fun rawJavaMapAndMutableViewsCannotKeepSourceOrTaskObjectsInTheProcessLru() {
        Owned().use { f ->
            f.call("exploreContext", jsonObject("action" to "open"))
            f.call("exploreContext", jsonObject("action" to "evaluate", "script" to "infoMap.put('safe','kept'); 'ready'"))
            val attempts = listOf(
                "var m=new Packages.java.util.LinkedHashMap();m.put('safe','changed');m.put('retained',source);infoMap.set(m)",
                "var m=new Packages.java.util.LinkedHashMap();m.put('safe','changed');m.put('retained',source);infoMap.putAll(m)",
                "var m=new Packages.java.util.HashMap();m.put(source,'retained');infoMap.set(m)",
                "infoMap.get().put('retained',source)",
                "infoMap.get().entrySet().iterator().next().setValue(source)",
                "infoMap.entries.iterator().next().setValue(source)",
                "infoMap.compute('retained',new JavaAdapter(Packages.java.util.function.BiFunction,{apply:function(k,v){return source;}}))",
                "infoMap.computeIfAbsent('retained',new JavaAdapter(Packages.java.util.function.Function,{apply:function(k){return source;}}))",
                "infoMap.get().compute('retained',new JavaAdapter(Packages.java.util.function.BiFunction,{apply:function(k,v){return source;}}))",
                "infoMap.get().replaceAll(new JavaAdapter(Packages.java.util.function.BiFunction,{apply:function(k,v){return source;}}))")
            for (script in attempts) {
                val failure = f.execute("exploreContext", jsonObject("action" to "evaluate", "script" to script))
                assertFalse(script + failure + f.logs, failure["ok"].asBoolean)
                assertEquals(script + failure, "UNSUPPORTED_CAPABILITY", failure["error"].asJsonObject["code"].asString)
                val map = f.call("exploreContext", jsonObject("action" to "open"))["infoMap"].asJsonObject
                assertEquals(script + map, setOf("safe"), map.keySet()); assertEquals("kept", map["safe"].asString)
            }
            val caught = f.call("exploreContext", jsonObject("action" to "evaluate", "script" to "try { infoMap.get().put('retained',source); } catch(e) { infoMap.put('caught','yes'); } infoMap.get().values().remove('kept'); infoMap.put('safe','view-updated'); 'continued'"))
            assertEquals("continued", caught["result"].asString)
            assertEquals("yes", caught["infoMap"].asJsonObject["caught"].asString)
            assertEquals("view-updated", caught["infoMap"].asJsonObject["safe"].asString)
            // The URL JS path shares the same gate; no request occurs on failure.
            val failedUrl = f.execute("explore", jsonObject("url" to "@js:infoMap.get().put('retained',source); '${f.origin}/css'"))
            assertEquals("UNSUPPORTED_CAPABILITY", failedUrl["error"].asJsonObject["code"].asString)
            assertTrue(f.requests.isEmpty())
            val failedCheck = f.execute("explore", jsonObject("url" to "/css"), loginCheckJs = "if(result.code()==500) java.connect('${f.origin}/recovered'); else { infoMap.get().put('retained',source); result; }")
            assertEquals("UNSUPPORTED_CAPABILITY", failedCheck["error"].asJsonObject["code"].asString)
            assertEquals(listOf("/css"), f.requests.toList()) // No login recovery HTTP after the controlled type failure.
        }
    }

    private class Owned : Closeable {
        private val directory = Files.createTempDirectory("original-explore-public-")
        private val adapter = FileRulePersistenceAdapter(directory)
        private val state = RulePersistenceHost(adapter)
        private val identity = UUID.randomUUID().toString()
        private val grants = java.util.concurrent.ConcurrentHashMap<String, String>()
        val logs = CopyOnWriteArrayList<String>()
        private val logger = java.util.logging.Logger.getLogger("io.yuedu.legado.originalrule")
        private val previousLevel = logger.level
        private val handler = object : java.util.logging.Handler() {
            override fun publish(record: java.util.logging.LogRecord) { logs += record.message }
            override fun flush() {}
            override fun close() {}
        }
        val requests = CopyOnWriteArrayList<String>()
        val heldEntered = CountDownLatch(1); val heldRelease = CountDownLatch(1); val waitingScope = CountDownLatch(1)
        @Volatile var waitForScopeTask: String? = null
        @Volatile var failWrites = false
        var generation = 0
        var exploreOnly = false
        private val serverPool = Executors.newFixedThreadPool(2)
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply {
            executor = serverPool
            createContext("/") { e ->
                requests += e.requestURI.toString()
                if (e.requestURI.path == "/held") { heldEntered.countDown(); check(heldRelease.await(15, TimeUnit.SECONDS)) }
                val kind = e.requestURI.path.substringAfterLast('/')
                val body = when(kind) {
                    "json" -> "{\"items\":[{\"name\":\"JSON\",\"url\":\"/book\"}]}"
                    "regex" -> "BOOK[REGEX|/book]"
                    else -> "<a class='book' href='/book'>${if(kind == "held") "CSS" else kind.uppercase()}</a>"
                }.toByteArray(Charsets.UTF_8)
                e.sendResponseHeaders(200,body.size.toLong()); e.responseBody.use { it.write(body) }; e.close()
            }; start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        init {
            logger.addHandler(handler); logger.level = java.util.logging.Level.FINE
            LegadoRuntime.setHostCallback { task, op, raw ->
                if (op == "task.cancel") "{}" else {
                    val input = parseObject(raw)
                    val owner = input["owner"].asString
                    val source = requireNotNull(grants[owner]) { "Revoked controlled source grant" }
                    if (op == "explore.owner.scope") {
                        check(input["sourceURL"].asString == source); check(input.has("deadlineEpochMs"))
                        if (task == waitForScopeTask) waitingScope.countDown()
                        jsonObject("scope" to "$identity|$generation|$source").toString()
                    } else {
                        check(op in setOf("state.read", "state.commit"))
                        if (op == "state.commit" && failWrites) throw RulePersistenceException("Actual controlled owner refused its file commit")
                        // Native grants are per invocation; the existing backing
                        // owner is stable. This fixture models that same mapping.
                        input.addProperty("owner", identity)
                        state.dispatch(op,input).toString()
                    }
                }
            }
        }
        fun execute(op: String, request: JsonObject, rule: JsonObject? = null, sourceID: String = "main", taskID: String = UUID.randomUUID().toString(), loginCheckJs: String? = null): JsonObject {
            val sourceURL = "$origin/source-$sourceID"
            val source = jsonObject("bookSourceUrl" to sourceURL, "enabledCookieJar" to false, "loginCheckJs" to loginCheckJs,
                "bookUrlPattern" to ".*", "ruleBookInfo" to jsonObject("name" to "@js:'WRONG_SEARCH_ONLY_BRANCH'"),
                "ruleSearch" to jsonObject("bookList" to ".book", "name" to "text", "bookUrl" to "href"),
                "ruleExplore" to (rule ?: jsonObject("bookList" to ".book", "name" to "text", "bookUrl" to "href")))
            if (exploreOnly) source.remove("ruleSearch")
            val grant = "grant-${UUID.randomUUID()}"; grants[grant] = sourceURL
            val created = parseObject(LegadoRuntime.createSession(source.toString(), jsonObject("sourceMode" to "original-traditional", "httpTransport" to "jvm-okhttp", "stateOwner" to grant).toString()))
            assertTrue(created.toString(),created["ok"].asBoolean)
            val session = created["sessionId"].asString
            return try { parseObject(LegadoRuntime.execute(session,taskID,op,request.toString())) }
            finally { LegadoRuntime.closeSession(session); grants.remove(grant) }
        }
        fun call(op: String, request: JsonObject, rule: JsonObject? = null, sourceID: String = "main"): JsonObject {
            val reply = execute(op,request,rule,sourceID); assertTrue(reply.toString(), reply["ok"].asBoolean); return reply["result"].asJsonObject
        }
        override fun close() {
            heldRelease.countDown(); server.stop(0); serverPool.shutdownNow(); check(serverPool.awaitTermination(5,TimeUnit.SECONDS))
            LegadoRuntime.setHostCallback(null); logger.removeHandler(handler); logger.level = previousLevel; check(directory.toFile().deleteRecursively())
        }
    }
}
