package io.yuedu.legado

import com.google.gson.JsonObject
import com.script.ScriptBindings
import com.script.rhino.RhinoScriptEngine
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.yuedu.legado.originalrule.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Owned URL vectors and loopback only; not full Android AnalyzeUrl or App routing. */
class OriginalUrlExecutionTest {
    @Test(timeout = 20_000) fun urlStagesMatchLockedArchiveMethodsIncludingOriginalEdgeCases() {
        val vectors = listOf(
            "  /plain  ", "@js:'/value'", "<JS>'/upper'</JS>",
            "/seed<js>result + '/one'</js><js>result + '/two'</js>/tail/@result",
            "@js: 'http://owned.invalid/{{page > 1 ? 7 : 9}}/<first,second,last>'",
            "/{{1 + 2}}/{{1 / 2}}/{{null}}/{{undefined}}",
            "/{{key}}/{{page}}", "/{{({a:3}).a}}", "/{{'a>b<c'}}",
            "/< first , second , last >/<single>", "/<>/<,>",
            "/{{'}}'}}", "/{{({a:{b:3}}).a.b}}", "/{{1", "/1}}",
            "@js:null", "<js>1</js>@result", "@js:'{{1}}'",
            "/{{1}}/{{2}}/{{1}}", "/<first,second>/<first,second>",
        )
        var comparisons = 0
        RuleEnvironment().use { environment ->
            listOf<Int?>(null, -2, 0, 1, 2, 3, 10).forEach { page ->
                val evaluator = AnalyzeUrl("", key = "owned key", page = page, environment = environment)
                vectors.forEach { raw ->
                    val expected = runCatching { ArchiveUrlExpansionReference(raw, page, evaluator::evalJS).ruleUrl }
                    val actual = runCatching { AnalyzeUrl(raw, key = "owned key", page = page, environment = environment).ruleUrl }
                    val label = "page=$page raw=$raw"
                    assertEquals(label, expected.getOrNull(), actual.getOrNull())
                    assertEquals(label, expected.exceptionOrNull()?.javaClass, actual.exceptionOrNull()?.javaClass)
                    comparisons++
                }
            }
        }
        assertEquals(140, comparisons)
    }

    @Test(timeout = 15_000) fun explicitUrlContextKeepsOriginalJavaTypesAndVariablePrecedence() {
        RuleEnvironment().use { environment ->
            val source = RuleSource(environment, "https://owned.invalid", "Owned", jsLib = "function suffix(){return '/library';}")
            val book = RuleBook(environment, name = "Owned book", bookUrl = "owned:book")
            val chapter = RuleChapter(environment, title = "Owned chapter")
            book.putVariable("shared", "book"); chapter.putVariable("shared", "chapter")
            val url = AnalyzeUrl("@js: baseUrl + '/' + key + '/' + page + suffix()", key = "search", page = 2,
                baseUrl = "https://owned.invalid/path,{\"method\":\"GET\"}", source = source,
                ruleData = book, chapter = chapter, environment = environment)
            assertEquals("https://owned.invalid/path/search/2/library", url.ruleUrl)
            assertSame(url, url.evalJS("java"))
            assertSame(book, url.evalJS("book"))
            assertSame(source, url.evalJS("source"))
            assertEquals("io.legado.app.model.analyzeRule.AnalyzeUrl", url.evalJS("java")!!.javaClass.name)
            assertEquals("Owned book/Owned chapter/chapter", url.evalJS("java.get('bookName')+'/'+java.get('title')+'/'+java.get('shared')"))
            assertEquals("value", url.put("owned", "value"))
            assertEquals("value", chapter.getVariable("owned"))
            assertEquals("", book.getVariable("owned"))
            assertEquals("null/null/null/null", url.evalJS("[speakText,speakSpeed,infoMap,result].map(String).join('/')"))
        }
    }

    @Test(timeout = 15_000) fun dynamicConnectReallyUsesProductionHttpAndPreservesResponseTypes() {
        Peer { exchange -> respond(exchange, "owned response", 207) }.use { peer ->
            Session(peer.origin).use { owned ->
                owned.environment.use { environment ->
                    val source = RuleSource(environment, peer.origin, "Owned", jsLib = "function route(){return '/from-library';}")
                    AnalyzeRule(source = source).use { rule ->
                        val response = rule.connect("@js:source.getKey()+route()")
                        assertEquals(207, response.code())
                        assertEquals("owned response", response.body())
                        assertEquals("okhttp3.Response", response.raw().javaClass.name)
                        assertEquals("okhttp3.Headers", response.headers().javaClass.name)
                        rule.connect("<js>'${peer.origin}/tag'</js>/@result")
                        rule.connect(peer.origin + "/{{2 + 3}}, {\"method\":\"POST\",\"body\":\"v={{1+2}}\",\"headers\":{\"X-Owned\":\"{{6+1}}\"}}")
                        assertEquals(listOf("/from-library", "/http://127.0.0.1:${peer.port}/tag", "/5"), peer.requests.map { it.path })
                        assertEquals("POST", peer.requests[2].method)
                        assertEquals("v=3", peer.requests[2].body.toString(Charsets.UTF_8))
                        assertEquals("7", peer.requests[2].header("X-Owned"))
                        assertTrue(owned.task.job.isActive)
                    }
                }
            }
        }
    }

    @Test(timeout = 15_000) fun nestedAjaxDoesNotInheritOuterSearchBindingsAndUsesTheSameCookies() {
        Peer { exchange ->
            if (exchange.requestURI.path == "/seed") exchange.responseHeaders.add("Set-Cookie", "owned=jar; Path=/")
            respond(exchange, "owned")
        }.use { peer ->
            Session(peer.origin).use { owned ->
                owned.environment.use { environment ->
                    val source = RuleSource(environment, peer.origin, "Owned", jsLib = "function route(){return '/nested';}")
                    AnalyzeRule(source = source).use { rule ->
                        rule.setLocal("page", "9")
                        rule.connect(peer.origin + "/seed")
                        val script = "'${peer.origin}/' + [key,page,book,speakText,speakSpeed,infoMap].map(String).join('/') + '/' + baseUrl.length + '/' + java.get('missing')"
                        rule.connect("@js:$script")
                        rule.connect("@js: java.ajax(source.getKey()+route()); source.getKey()+'/after-nested'")
                        assertEquals("/null/null/null/null/null/null/0/", peer.requests[1].path)
                        assertEquals(listOf("/nested", "/after-nested"), peer.requests.takeLast(2).map { it.path })
                        assertTrue(peer.requests.drop(1).all { it.header("Cookie").contains("owned=jar") })
                        assertEquals("jar", environment.cookie.getCookie(peer.origin, "owned"))
                    }
                }
            }
        }
    }

    @Test(timeout = 15_000) fun unsupportedOptionsHeadersAndUnmigratedMainJsStayTypedBeforeHttp() {
        Peer { exchange -> respond(exchange, "unexpected") }.use { peer ->
            Session(peer.origin).use { owned ->
                owned.environment.use { environment ->
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned")).use { rule ->
                        listOf("js", "bodyJs", "webView", "dnsIp", "serverID").forEach { option ->
                            val url = peer.origin + "/{{1}}, {\"$option\":\"unported\"}"
                            assertThrows(UnsupportedRuleCapability::class.java) { rule.connect(url) }
                            assertThrows(UnsupportedRuleCapability::class.java) { rule.ajax(url) }
                        }
                    }
                    owned.session.source.addProperty("header", "@js: JSON.stringify({})")
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned")).use { rule ->
                        assertThrows(UnsupportedRuleCapability::class.java) { rule.connect("@js:'${peer.origin}'") }
                    }
                    val mainJs = SourceJavaHost(owned.task) { _, _, _ -> fail("Must not dispatch"); JsonObject() }
                    assertThrows(RuntimeFailure::class.java) { mainJs.connect("@js:'${peer.origin}'") }
                    val bindings = RhinoScriptEngine.getRuntimeScope(ScriptBindings().apply { this["java"] = mainJs })
                    assertEquals("", RhinoScriptEngine.eval("var names=[]; for(var name in java){if(name.indexOf('connectExpanded')>=0 || name.indexOf('expandedOriginalUrl')>=0) names.push(name)}; names.join(',')", bindings, owned.task.job))
                    assertTrue(SourceJavaHost::class.java.methods.none { it.name.contains("connectExpanded") || it.name.contains("expandedOriginalUrl", true) })
                    val formerlyMangled = "connectExpandedOriginalUrl" + '$' + "io_yuedu_legado_runtime"
                    assertEquals("blocked", RhinoScriptEngine.eval("try { java['$formerlyMangled']('${peer.origin}',null,null); 'bypassed' } catch(error) { 'blocked' }", bindings, owned.task.job))
                    val error = RhinoScriptEngine.eval("try { java.connect(\"@js:'${peer.origin}'\"); 'bypassed' } catch(error) { String(error) }", bindings, owned.task.job).toString()
                    assertTrue(error, error.contains("Dynamic URL rules are not migrated"))
                    assertTrue(peer.requests.isEmpty())
                }
            }
        }
    }

    @Test(timeout = 15_000) fun escapingNestedUnsupportedRemainsTypedButScriptCanCatchIt() {
        Peer { exchange -> respond(exchange, "caught") }.use { peer ->
            Session(peer.origin).use { owned ->
                owned.environment.use { environment ->
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned")).use { rule ->
                        val url = peer.origin + "/,{\"webView\":true}"
                        listOf("connect", "ajax").forEach { method ->
                            val script = "java.$method('$url'); '${peer.origin}'"
                            assertThrows(UnsupportedRuleCapability::class.java) { rule.ajax("@js:$script") }
                            assertThrows(UnsupportedRuleCapability::class.java) { rule.connect("@js:$script") }
                            assertEquals("caught", rule.ajax("@js:try { java.$method('$url') } catch(error) {}; '${peer.origin}/caught-$method'"))
                        }
                        assertEquals(listOf("/caught-connect", "/caught-ajax"), peer.requests.map { it.path })
                        assertTrue(rule.ajax("@js:throw new Error('owned-ordinary-script-error')").orEmpty().contains("owned-ordinary-script-error"))
                    }
                }
            }
        }
    }

    @Test(timeout = 20_000) fun cpuUrlScriptStopsForTaskDeadlineCallerCancellationAndEnvironmentClose() {
        listOf("deadline", "caller", "environment").forEach { reason ->
            val entered = CountDownLatch(1)
            Peer { exchange -> respond(exchange, "entered") }.use { peer ->
                Session(peer.origin, if (reason == "deadline") 900 else 10_000).use { owned ->
                    val executor = Executors.newSingleThreadExecutor()
                    val caller = Job()
                    try {
                        owned.environment.use { environment ->
                            val source = RuleSource(environment, peer.origin, "Owned")
                            environment.cache.putMemory("url-loop-entered", entered)
                            // Warm the source's CryptoJS scope before loop entry;
                            // setup still consumes the same absolute task deadline.
                            AnalyzeUrl("", source = source, environment = environment).evalJS("1")
                            AnalyzeRule(source = source).use { rule ->
                                rule.setCoroutineContext(caller)
                                val result = executor.submit<String?> {
                                    rule.ajax("@js:java.ajax('${peer.origin}/entered'); cache.getFromMemory('url-loop-entered').countDown(); while(true) {}")
                                }
                                assertTrue("No owned HTTP entry for $reason", entered.await(3, TimeUnit.SECONDS))
                                when (reason) {
                                    "caller" -> caller.cancel()
                                    "environment" -> environment.close()
                                }
                                val error = assertThrows(ExecutionException::class.java) { result.get(3, TimeUnit.SECONDS) }
                                assertTrue("$reason: ${error.cause}", error.cause is CancellationException)
                                assertEquals(reason == "deadline", owned.task.timedOut.get())
                                assertEquals(reason != "environment", owned.task.job.isCancelled)
                                assertEquals(1, peer.requests.size)
                            }
                        }
                    } finally {
                        caller.cancel(); owned.task.job.cancel(); executor.shutdownNow()
                        check(executor.awaitTermination(3, TimeUnit.SECONDS))
                    }
                }
            }
        }
    }

    @Test(timeout = 15_000) fun completedDynamicRequestDetachesCallerAndClosedOwnerCannotRequest() {
        Peer { exchange -> respond(exchange, "owned") }.use { peer ->
            Session(peer.origin).use { owned ->
                owned.environment.use { environment ->
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned")).use { rule ->
                        val caller = Job()
                        rule.setCoroutineContext(caller)
                        assertEquals("owned", rule.ajax("@js:'${peer.origin}/done'"))
                        caller.cancel()
                        assertTrue(owned.task.job.isActive)
                        rule.setCoroutineContext(kotlin.coroutines.EmptyCoroutineContext)
                        assertEquals("owned", rule.ajax("@js:'${peer.origin}/after'"))
                        environment.close()
                        assertThrows(IllegalStateException::class.java) { rule.connect("@js:'${peer.origin}/closed'") }
                        assertEquals(2, peer.requests.size)
                    }
                }
            }
        }
    }

    @Test(timeout = 15_000) fun closeDuringLibraryHostCallCannotPublishAjaxErrorText() {
        RuleScopeInitializationGate.reset()
        Peer { exchange -> respond(exchange, "unexpected") }.use { peer ->
            Session(peer.origin).use { owned ->
                val executor = Executors.newSingleThreadExecutor()
                try {
                    owned.environment.use { environment ->
                        val source = RuleSource(environment, peer.origin, "Owned", jsLib =
                            "Packages.io.yuedu.legado.RuleScopeInitializationGate.awaitRelease(); function route(){return '/library';}")
                        AnalyzeRule(source = source).use { rule ->
                            val result = executor.submit<String?> { rule.ajax("@js:source.getKey()+route()") }
                            assertTrue(RuleScopeInitializationGate.entered.await(3, TimeUnit.SECONDS))
                            environment.close()
                            assertTrue("Close does not cancel a shared task or interrupt arbitrary Java host code", owned.task.job.isActive)
                            RuleScopeInitializationGate.release.countDown()
                            val error = assertThrows(ExecutionException::class.java) { result.get(3, TimeUnit.SECONDS) }
                            assertTrue(error.cause.toString(), error.cause is CancellationException)
                            assertEquals("Original-rule environment is closed", error.cause!!.message)
                            assertTrue(owned.task.job.isActive)
                            assertTrue(peer.requests.isEmpty())
                        }
                    }
                } finally {
                    RuleScopeInitializationGate.release.countDown(); owned.task.job.cancel(); executor.shutdownNow()
                    check(executor.awaitTermination(3, TimeUnit.SECONDS))
                }
            }
        }
    }

    private class Session(origin: String, timeoutMs: Long = 10_000) : Closeable {
        val session = RuntimeSession(UUID.randomUUID().toString(), jsonObject("bookSourceUrl" to origin,
            "enabledCookieJar" to true), RuntimeSessionOptions("jvm-okhttp"))
        val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + timeoutMs)
        val environment = LegadoRuntime.originalRuleEnvironment(task)
        override fun close() { environment.close(); task.job.cancel(); session.closed.set(true); session.http!!.close() }
    }
    private data class Capture(val path: String, val method: String, val headers: Map<String, List<String>>, val body: ByteArray) {
        fun header(name: String): String = headers.entries.firstOrNull { it.key.equals(name, true) }?.value.orEmpty().joinToString("; ")
    }
    private class Peer(handler: (HttpExchange) -> Unit) : Closeable {
        val requests = CopyOnWriteArrayList<Capture>()
        private val failures = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool { Thread(it, "original-url-owned-peer").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = this@Peer.executor
            createContext("/") { exchange ->
                try {
                    requests += Capture(exchange.requestURI.toString(), exchange.requestMethod,
                        exchange.requestHeaders.mapValues { it.value.toList() }, exchange.requestBody.readBytes())
                    handler(exchange)
                } catch (error: Throwable) { failures += error } finally { exchange.close() }
            }
            start()
        }
        val port = server.address.port
        val origin = "http://127.0.0.1:$port"
        override fun close() {
            server.stop(0); executor.shutdownNow()
            check(executor.awaitTermination(3, TimeUnit.SECONDS))
            if (failures.isNotEmpty()) throw AssertionError("Owned peer failed", failures.first())
        }
    }
    companion object {
        private fun respond(exchange: HttpExchange, text: String, status: Int = 200) {
            exchange.responseHeaders.add("Content-Type", "text/plain; charset=utf-8")
            val bytes = text.toByteArray(Charsets.UTF_8)
            exchange.sendResponseHeaders(status, bytes.size.toLong()); exchange.responseBody.write(bytes)
        }
    }
}
