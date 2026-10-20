package io.yuedu.legado

import com.google.gson.JsonParser
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.legado.app.data.entities.BaseSource
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.analyzeRule.parseBooleanOption
import io.legado.app.model.analyzeRule.parseRequestTimeoutMillis
import io.yuedu.legado.originalrule.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Test
import io.yuedu.legado.reference.HutoolIpPatterns
import java.util.regex.Pattern
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Retained source/URL phases plus one real owned JVM transport. No App or Android execution. */
class OriginalUrlRequestOptionsTest {
    @Test(timeout = 15_000) fun dynamicSourceHeaderUsesSourceBindingsAndRunsBeforeUrlScripts() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, peer.origin, "Owned", header =
                "@js:source.put('phase','header'); ({'X-Bindings': [java.equals(source),source.equals(sourceApi),String(baseUrl)===String(source.getKey()),typeof key,typeof page,typeof result,typeof book].join('|'), 'X-Value':'prefix-'+3, 'X-Number':7})")
            source.putLoginHeader("{\"Authorization\":\"Bearer owned\",\"X-Login\":\"login\"}")
            AnalyzeRule(source = source).use { rule ->
                val response = rule.connect("@js: if(String(source.get('phase'))!=='header') throw new Error('wrong order'); source.put('phase','url'); source.getKey()+'/order'")
                assertEquals("owned", response.body())
                assertEquals("true|true|true|undefined|undefined|undefined|undefined", peer.requests.single().header("X-Bindings"))
                assertEquals("prefix-3", peer.requests.single().header("X-Value"))
                assertEquals("7", peer.requests.single().header("X-Number"))
                assertEquals("Bearer owned", peer.requests.single().header("Authorization"))
                assertEquals("owned-agent", peer.requests.single().header("User-Agent"))
                assertEquals("url", source.get("phase"))
            }
        } }
    }

    @Test(timeout = 15_000) fun explicitEmptyMapSkipsSourceHeaderAndLoginWhileOptionHeadersWin() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, peer.origin, "Owned", header =
                "@js:source.put('calls',String(Number(source.get('calls')||0)+1)); ({'X-Source':'source','X-Shared':'source'})")
            source.putLoginHeader("{\"Authorization\":\"Bearer owned\",\"X-Shared\":\"login\"}")
            AnalyzeRule(source = source).use { rule ->
                rule.connect(peer.origin + "/empty", "{}")
                assertEquals("", source.get("calls"))
                assertEquals("", peer.requests[0].header("X-Source"))
                assertEquals("", peer.requests[0].header("Authorization"))
                rule.connect(peer.origin + "/explicit,{\"headers\":\"{\\\"X-Shared\\\":\\\"option\\\",\\\"X-Number\\\":2}\"}", "{\"X-Shared\":\"explicit\"}")
                assertEquals("option", peer.requests[1].header("X-Shared"))
                assertEquals("2", peer.requests[1].header("X-Number"))
                rule.connect(peer.origin + "/defaults,{\"headers\":{\"X-Shared\":\"option\"}}", "invalid-json")
                assertEquals("1", source.get("calls"))
                assertEquals("source", peer.requests[2].header("X-Source"))
                assertEquals("option", peer.requests[2].header("X-Shared"))
                assertEquals("Bearer owned", peer.requests[2].header("Authorization"))
                source.header = "{\"proxy\":null,\"X-Null-Proxy\":\"cleared\"}"
                rule.connect(peer.origin + "/null-proxy")
                assertEquals("cleared", peer.requests.last().header("X-Null-Proxy"))
                assertEquals("", peer.requests.last().header("proxy"))
            }
        } }
    }

    @Test(timeout = 15_000) fun loginSiteIsDecidedFromInitialUrlBeforeJavascriptRewritesIt() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, "https://auth.example.co.uk", "Owned", header = "{\"X-Source\":\"owned\"}")
            source.putLoginHeader("{\"Authorization\":\"Bearer initial-site\"}")
            AnalyzeRule(source = source).use { rule ->
                rule.connect("https://api.example.co.uk@js:'${peer.origin}/initial-same'")
                rule.connect("https://cdn.other.example.net@js:'${peer.origin}/initial-other'")
                rule.connect("@js:'${peer.origin}/unknown-initial'")
                assertEquals("Bearer initial-site", peer.requests[0].header("Authorization"))
                assertEquals("", peer.requests[1].header("Authorization"))
                assertEquals("Bearer initial-site", peer.requests[2].header("Authorization"))
            }
        } }
    }

    @Test fun pinnedPublicSuffixAndOriginalBaseUrlParsingDoNotUseLastTwoLabelHeuristics() {
        val vectors = mapOf(
            "https://a.b.example.co.uk/path" to "example.co.uk", "https://a.owner.github.io/path" to "owner.github.io",
            "http://127.0.0.1:1234/path" to "127.0.0.1", "http://[::1]:1234/path" to "[::1]",
            "https://localhost/path" to "localhost", "https://EXAMPLE.COM/path" to "EXAMPLE.COM",
        )
        vectors.forEach { (url, expected) -> assertEquals(url, expected, NetworkUtils.getSubDomainOrNull(url)) }
        assertNull(NetworkUtils.getSubDomainOrNull("owned-source-id"))
        assertNull(NetworkUtils.getBaseUrl("data:text/plain;base64,b3duZWQ="))
        assertEquals("https://owned.invalid:1234", NetworkUtils.getBaseUrl("https://owned.invalid:1234/path@js:'data:text/plain;base64,eA=='"))
    }

    @Test fun numericIpClassificationMatchesPinnedHutoolPatternsIncludingOriginalBracketQuirks() {
        val values = listOf(null, "", "127.0.0.1", "127.001.02.3", "001.002.003.004", "0.0.0.0", "255.255.255.255", "256.1.1.1", "127.0.0", "127.0.0.1.",
            "::1", "[::1]", "2001:db8::1", "::ffff:192.0.2.1", "[::ffff:192.0.2.1]", "fe80::1%eth0", "[fe80::1%eth0]", "::g", "x:y", "1:2:3:4:5:6:7:8")
        values.forEach { value ->
            assertEquals(value, value != null && Pattern.compile(HutoolIpPatterns.IPV4).matcher(value).matches(), OriginalIpValidator.isIpv4(value))
            assertEquals(value, value != null && Pattern.compile(HutoolIpPatterns.IPV6).matcher(value).matches(), OriginalIpValidator.isIpv6(value))
        }
    }

    @Test(timeout = 15_000) fun explicitWebBookInputsResolveRelativeUrlAndNestedAjaxRetainsEmptyBase() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, peer.origin, "Owned")
            assertEquals("owned", owned.environment.platform.requestUrl("../{{key}}/<first,second>", source,
                peer.origin + "/books/part/,{\"method\":\"POST\"}", owned.task.job, key = "search", page = 2).body())
            assertEquals("/books/search/second", peer.requests.single().path)
            AnalyzeRule(source = source).use { rule ->
                val error = rule.connect("/nested-relative")
                assertTrue(error.body(), error.body().contains("IllegalArgumentException"))
                assertEquals("http://localhost/", error.url())
                assertEquals(200, error.raw().code)
                assertEquals(1, peer.requests.size)
            }
        } }
    }

    @Test(timeout = 15_000) fun optionJsRunsAfterResolutionAndFrozenHeadersThenBodyJsKeepsRawTypes() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, peer.origin, "Owned", header = "{\"X-Phase\":\"header\"}")
            AnalyzeRule(source = source).use { rule ->
                val options = jsonObject("headers" to jsonObject("X-Phase" to "option"),
                    "js" to "if(String(baseUrl)!==String(source.getKey())) throw new Error('base'); source.header='{}'; result+'/rewritten'",
                    "bodyJs" to "result + '/' + java.headerMap.get('X-Phase')")
                val response = rule.connect(peer.origin + "/initial," + options)
                assertEquals("/initial/rewritten", peer.requests.single().path)
                assertEquals("option", peer.requests.single().header("X-Phase"))
                assertEquals("owned/option", response.body())
                assertEquals("okhttp3.Response", response.raw().javaClass.name)
                assertEquals("okhttp3.Headers", response.headers().javaClass.name)
                rule.connect(peer.origin + "/unchanged,{\"js\":\"null\",\"bodyJs\":\"null\"}").let {
                    assertEquals("null", it.body()); assertEquals("/unchanged", peer.requests.last().path)
                }
            }
        } }
    }

    @Test(timeout = 15_000) fun xmlDeclarationRetainsOriginalPrecedenceOverBodyJs() {
        Peer { exchange ->
            val declared = exchange.requestURI.path == "/declared"
            respond(exchange, if (declared) "<?xml version=\"1.0\"?><owned/>" else "<owned/>", contentType = "application/xml; charset=utf-8")
        }.use { peer -> Session(peer.origin).use { owned ->
            AnalyzeRule(source = RuleSource(owned.environment, peer.origin, "Owned")).use { rule ->
                assertEquals("<?xml version=\"1.0\"?><owned/>", rule.connect(peer.origin + "/plain,{\"bodyJs\":\"'transformed'\"}").body())
                assertEquals("transformed", rule.connect(peer.origin + "/declared,{\"bodyJs\":\"'transformed'\"}").body())
            }
        } }
    }

    @Test(timeout = 15_000) fun queryFormStructuredBodyAndEscapeOptionsPreserveBytes() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            AnalyzeRule(source = RuleSource(owned.environment, peer.origin, "Owned")).use { rule ->
                rule.connect(peer.origin + "/query?q=书 space&percent=%2B,{\"charset\":\"GB18030\"}")
                assertEquals("/query?q=%CA%E9%20space&percent=%2B", peer.requests.last().path)
                rule.connect(peer.origin + "/form,{\"method\":\"POST\",\"charset\":\"escape\",\"body\":\"v=书 &plus=a+b\"}")
                assertEquals("v=%u4e66%20&plus=a%2bb", peer.requests.last().body.toString(Charsets.UTF_8))
                rule.connect(peer.origin + "/json,{\"method\":\"POST\",\"body\":{\"name\":\"书\",\"count\":1}}")
                assertEquals(JsonParser.parseString("{\"name\":\"书\",\"count\":1}"), JsonParser.parseString(peer.requests.last().body.toString(Charsets.UTF_8)))
                rule.connect(peer.origin + "/encoded?q=%E4%B9%A6+plus,{\"charset\":\"GB18030\"}")
                assertEquals("/encoded?q=%E4%B9%A6+plus", peer.requests.last().path)
                listOf("&&a" to "a", "&a&&" to "a&&", "&&" to "&&", "=&&a" to "=&&a").forEach { (input, expected) ->
                    rule.connect(peer.origin + "/empty-fields," + jsonObject("method" to "POST", "body" to input))
                    assertEquals(input, expected, peer.requests.last().body.toString(Charsets.UTF_8))
                }
                rule.connect(peer.origin + "/punctuation?q='😀 %25invalid")
                assertEquals("/punctuation?q=%27%F0%9F%98%80%20%25invalid", peer.requests.last().path)
            }
        } }
    }

    @Test(timeout = 15_000) fun originalDnsTimeoutAndBooleanOptionsReachTheSameTransport() {
        Peer { exchange ->
            if (exchange.requestURI.path == "/redirect") {
                exchange.responseHeaders.add("Location", "/final")
                respond(exchange, "redirect", 302)
            } else respond(exchange, "owned")
        }.use { peer -> Session(peer.origin).use { owned ->
            val target = "http://owned.fixture.invalid:${peer.port}"
            AnalyzeRule(source = RuleSource(owned.environment, target, "Owned")).use { rule ->
                val response = rule.connect(target + "/redirect,{\"dnsIp\":\"127.0.0.1\",\"timeout\":\"1500\",\"followRedirects\":\"0\"}")
                assertEquals(302, response.code())
                assertEquals("owned.fixture.invalid:${peer.port}", peer.requests.single().header("Host"))
                assertEquals(1500, owned.session.requests.single()["readTimeoutMs"].asInt)
                assertEquals(60_000, owned.session.requests.single()["timeoutMs"].asInt)
                val followed = rule.connect(target + "/redirect,{\"resolveIp\":\"127.0.0.1\",\"followRedirects\":1}")
                assertEquals("owned", followed.body())
                assertTrue(followed.url(), followed.url().endsWith("/final"))
            }
        } }
    }

    @Test fun optionParsingUsesTheRetainedOriginalPureFunctions() {
        mapOf<Any, Long?>(" 1200 " to 1200L, 12.0 to 12L, 12.5 to null, 0 to null, -1 to null,
            "bad" to null, Int.MAX_VALUE.toLong() + 1 to null).forEach { (value, expected) -> assertEquals(expected, parseRequestTimeoutMillis(value)) }
        mapOf<Any, Boolean?>(" true " to true, "0" to false, 1 to true, 0.0 to false, 2 to null, "bad" to null)
            .forEach { (value, expected) -> assertEquals(expected, parseBooleanOption(value)) }
    }

    @Test(timeout = 15_000) fun sourceCookieSettingAndAuthoredCookiePriorityAreRequestScoped() {
        Peer { exchange ->
            if (exchange.requestURI.path == "/seed") exchange.responseHeaders.add("Set-Cookie", "token=stored; Path=/")
            respond(exchange, "owned")
        }.use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, peer.origin, "Owned", enabledCookieJar = false)
            AnalyzeRule(source = source).use { rule ->
                rule.connect(peer.origin + "/seed")
                assertEquals("", owned.environment.cookie.getCookie(peer.origin, "token"))
                source.enabledCookieJar = true
                rule.connect(peer.origin + "/seed")
                assertEquals("stored", owned.environment.cookie.getCookie(peer.origin, "token"))
                rule.connect(peer.origin + "/echo,{\"headers\":{\"Cookie\":\"token=authored; extra=owned\"}}")
                assertEquals("token=authored; extra=owned", peer.requests.last().header("Cookie"))
                assertEquals("stored", owned.environment.cookie.getCookie(peer.origin, "token"))
            }
        } }
    }

    @Test(timeout = 15_000) fun analyzeRuleAjaxSuppliesBookButDefaultConnectAndTimeoutAjaxDoNot() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, peer.origin, "Owned")
            val book = RuleBook(owned.environment, name = "Owned book", bookUrl = "owned:book")
            book.putVariable("token", "book-variable")
            AnalyzeRule(ruleData = book, source = source).use { rule ->
                rule.ajax("@js: if(String(book.name)!=='Owned book'||String(java.get('token'))!=='book-variable') throw new Error('book missing'); source.getKey()+'/ajax-book'")
                rule.connect("@js:if(book!==null) throw new Error('connect inherited book'); source.getKey()+'/connect-null'")
                rule.ajax("@js:if(book!==null) throw new Error('timeout ajax inherited book'); source.getKey()+'/timeout-null'", 2_000L)
                assertEquals(listOf("/ajax-book", "/connect-null", "/timeout-null"), peer.requests.map { it.path })
                assertEquals("book-variable", book.getVariable("token"))
            }
        } }
    }

    @Test(timeout = 15_000) fun constructorErrorsEscapeWhileExecutionErrorsReturnOriginalSyntheticResponse() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            AnalyzeRule(source = RuleSource(owned.environment, peer.origin, "Owned")).use { rule ->
                for (url in listOf("@js:throw new Error('owned-constructor')", peer.origin + "," + jsonObject("js" to "throw new Error('owned-option-constructor')"))) {
                    assertThrows(com.script.ScriptException::class.java) { rule.ajax(url) }
                    assertThrows(com.script.ScriptException::class.java) { rule.connect(url) }
                }
                assertTrue(peer.requests.isEmpty())
                val response = rule.connect(peer.origin + "/body-error," + jsonObject("bodyJs" to "throw new Error('owned-body-error')"))
                assertTrue(response.body(), response.body().contains("owned-body-error"))
                assertEquals(peer.origin + "/body-error", response.url())
                assertEquals(200, response.raw().code)
                assertEquals("OK", response.raw().message)
                assertEquals(0, response.raw().headers.size)
                assertEquals(1, peer.requests.size)
            }
        } }
    }

    @Test(timeout = 15_000) fun explicitWebBookUrlRequestLeavesExecutionErrorsForItsCaller() {
        Peer { exchange -> if (exchange.requestURI.path == "/disconnect") exchange.close() else respond(exchange, "owned") }.use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, peer.origin, "Owned")
            assertThrows(com.script.ScriptException::class.java) {
                owned.environment.platform.requestUrl(peer.origin + "/body-error," + jsonObject("bodyJs" to "throw new Error('webbook-owned-error')"), source, "", owned.task.job)
            }
            assertThrows(IllegalArgumentException::class.java) {
                owned.environment.platform.requestUrl("/missing-base", source, "", owned.task.job)
            }
            assertThrows(java.io.IOException::class.java) {
                owned.environment.platform.requestUrl(peer.origin + "/disconnect", source, "", owned.task.job)
            }
            assertEquals("/body-error", peer.requests.first().path)
            assertTrue(peer.requests.none { it.path == "/missing-base" })
            assertTrue(owned.task.job.isActive)
        } }
    }

    @Test(timeout = 15_000) fun unsupportedToJsonCannotBecomeDefaultHeaderButJavascriptCanCatchIt() {
        Peer().use { peer -> Session(peer.origin).use { owned ->
            val source = RuleSource(owned.environment, peer.origin, "Owned")
            val nested = "java.connect('${peer.origin}/,{\"webView\":true}', '{}')"
            source.header = "@js: ({toJSON:function(){ $nested }})"
            AnalyzeRule(source = source).use { rule ->
                assertThrows(UnsupportedRuleCapability::class.java) { rule.ajax(peer.origin + "/must-not-run") }
                assertTrue(peer.requests.isEmpty())
                source.header = "@js: ({toJSON:function(){ try { $nested } catch(error){}; return {'X-ToJson':'caught'} }})"
                assertEquals("owned", rule.ajax(peer.origin + "/caught"))
                assertEquals("caught", peer.requests.single().header("X-ToJson"))
                source.header = "@js:throw new Error('owned-header-error')"
                assertEquals("owned", rule.ajax(peer.origin + "/original-error-behavior"))
                assertEquals("owned-agent", peer.requests.last().header("User-Agent"))
            }
        } }
    }

    @Test(timeout = 30_000) fun headerNormalizationOptionJsAndBodyJsObserveCancellationAndAbsoluteDeadline() {
        for (phase in listOf("header", "toJSON", "optionJs", "bodyJs")) for (reason in listOf("caller", "deadline")) {
            Peer().use { peer -> Session(peer.origin, if (reason == "deadline") 1000 else 10_000).use { owned ->
                val entered = CountDownLatch(1)
                owned.environment.cache.putMemory("entered", entered)
                val source = RuleSource(owned.environment, peer.origin, "Owned")
                source.evalJS("1") // Scope setup consumes the same absolute task deadline.
                val loop = "cache.getFromMemory('entered').countDown(); while(true) {}"
                val url = when (phase) {
                    "header" -> { source.header = "@js:$loop"; peer.origin }
                    "toJSON" -> { source.header = "@js:({toJSON:function(){$loop}})"; peer.origin }
                    "optionJs" -> peer.origin + "," + jsonObject("js" to loop)
                    else -> peer.origin + "," + jsonObject("bodyJs" to loop)
                }
                val executor = Executors.newSingleThreadExecutor()
                val caller = Job()
                try {
                    AnalyzeRule(source = source).use { rule ->
                        rule.setCoroutineContext(caller)
                        val result = executor.submit<String?> { rule.ajax(url) }
                        assertTrue("$phase/$reason never entered", entered.await(3, TimeUnit.SECONDS))
                        if (reason == "caller") caller.cancel()
                        val error = assertThrows(ExecutionException::class.java) { result.get(3, TimeUnit.SECONDS) }
                        assertTrue("$phase/$reason ${error.cause}", error.cause is CancellationException)
                        assertEquals(reason == "deadline", owned.task.timedOut.get())
                        assertEquals(if (phase == "bodyJs") 1 else 0, peer.requests.size)
                    }
                } finally { caller.cancel(); owned.task.job.cancel(); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)) }
            } }
        }
    }

    @Test(timeout = 15_000) fun dynamicHeaderScopeAcquisitionReceivesTheActualTaskCancellation() {
        RuleScopeInitializationGate.reset()
        Peer().use { peer -> Session(peer.origin).use { owned ->
            val library = "Packages.io.yuedu.legado.RuleScopeInitializationGate.awaitRelease(); function value(){return 'owned'}"
            val source = RuleSource(owned.environment, peer.origin, "Owned", jsLib = library, header = "@js:({'X-Owned':value()})")
            val entered = CountDownLatch(1)
            val observed = object : BaseSource by source {
                override fun getHeaderMap(hasLoginHeader: Boolean): Map<String, String> {
                    entered.countDown()
                    return source.getHeaderMap(hasLoginHeader)
                }
            }
            val executor = Executors.newFixedThreadPool(2)
            try {
                val initializer = executor.submit<Any?> { owned.environment.scopes.getScope(library, null) }
                assertTrue(RuleScopeInitializationGate.entered.await(3, TimeUnit.SECONDS))
                val waiting = executor.submit<StrResponse> { owned.environment.platform.requestUrl(peer.origin, observed, "", owned.task.job) }
                assertTrue(entered.await(3, TimeUnit.SECONDS))
                owned.task.job.cancel()
                val error = assertThrows(ExecutionException::class.java) { waiting.get(2, TimeUnit.SECONDS) }
                assertTrue(error.cause.toString(), error.cause is CancellationException)
                assertEquals(1, RuleScopeInitializationGate.release.count)
                RuleScopeInitializationGate.release.countDown()
                initializer.get(3, TimeUnit.SECONDS)
                assertTrue(peer.requests.isEmpty())
            } finally { RuleScopeInitializationGate.release.countDown(); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)) }
        } }
    }

    private class Session(origin: String, timeoutMs: Long = 10_000) : Closeable {
        val session = RuntimeSession(UUID.randomUUID().toString(), jsonObject("bookSourceUrl" to origin, "enabledCookieJar" to true), RuntimeSessionOptions("jvm-okhttp", "owned-agent"))
        val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + timeoutMs)
        val environment = LegadoRuntime.originalRuleEnvironment(task)
        override fun close() { environment.close(); task.job.cancel(); session.closed.set(true); session.http!!.close() }
    }
    private data class Capture(val path: String, val headers: Map<String, List<String>>, val body: ByteArray) {
        fun header(name: String): String = headers.entries.firstOrNull { it.key.equals(name, true) }?.value.orEmpty().joinToString("; ")
    }
    private class Peer(handler: (HttpExchange) -> Unit = { respond(it, "owned") }) : Closeable {
        val requests = CopyOnWriteArrayList<Capture>()
        private val errors = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool { Thread(it, "original-request-options-owned-peer").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = this@Peer.executor
            createContext("/") { exchange ->
                try { requests += Capture(exchange.requestURI.toString(), exchange.requestHeaders.mapValues { it.value.toList() }, exchange.requestBody.readBytes()); handler(exchange) }
                catch (error: Throwable) { errors += error } finally { exchange.close() }
            }
            start()
        }
        val port = server.address.port
        val origin = "http://127.0.0.1:$port"
        override fun close() { server.stop(0); executor.shutdownNow(); check(executor.awaitTermination(3, TimeUnit.SECONDS)); if (errors.isNotEmpty()) throw AssertionError("Owned peer failed", errors.first()) }
    }
    companion object {
        private fun respond(exchange: HttpExchange, text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") {
            exchange.responseHeaders.add("Content-Type", contentType)
            val bytes = text.toByteArray(Charsets.UTF_8)
            exchange.sendResponseHeaders(status, bytes.size.toLong()); exchange.responseBody.write(bytes)
        }
    }
}
