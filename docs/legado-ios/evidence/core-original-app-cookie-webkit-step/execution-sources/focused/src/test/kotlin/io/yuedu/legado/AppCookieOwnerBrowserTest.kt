package io.yuedu.legado

import com.google.gson.JsonObject
import com.sun.net.httpserver.HttpServer
import io.yuedu.legado.originalrule.RulePersistenceHost
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Actual public runtime/host protocol and loopback HTTP only. This controlled
 * callback does not pretend to execute WK; owned native SDK fixtures do that.
 */
class AppCookieOwnerBrowserTest {
    @Test(timeout = 20_000) fun originalBrowserPiecesNoopTargetsAndDbBeforeWebOrderUsePublicRules() {
        Owned().use { owned ->
            val reply = owned.run("""@js:cookie.setWebCookie('data:text/plain,none','x=ignored'); cookie.setWebCookie('HTTPS://Sub.Example.CO.UK:444/path@js:ignored',' a=1 ;  \u00a0 b =2 ; ;Path=/other'); cookie.removeCookie('https://b.a.example.co.uk/path'); cookie.clear(); ({})""")
            assertTrue(reply.toString(), reply["ok"].asBoolean)
            val actions = owned.cookies.map { it["action"].asString }
            assertEquals(listOf("webSet", "remove", "webRemove", "clear"), actions.filter { it != "get" && it != "session" })
            val set = owned.cookies.single { it["action"].asString == "webSet" }
            assertEquals("HTTPS://Sub.Example.CO.UK:444", set["baseUrl"].asString)
            assertEquals(listOf("a=1", "b =2", "Path=/other"), set["pieces"].asJsonArray.map { it.asString })
            val remove = owned.cookies.single { it["action"].asString == "webRemove" }
            assertEquals(listOf("b.a.example.co.uk", "example.co.uk"), remove["domains"].asJsonArray.map { it.asString })
            assertEquals(1, owned.httpCount)
            assertTrue(owned.cookies.all { it["owner"].asString == "browser-owner" && it["deadlineEpochMs"] != null && it["remainingTimeoutMs"] != null })
            assertTrue(owned.cookieTasks.all { it.startsWith("browser-") })
        }
    }

    @Test(timeout = 25_000) fun partialBrowserFailureAndCancellationRemainTypedWithoutIssuingHttp() {
        for (code in listOf("STATE_IO", "UNSUPPORTED_CAPABILITY", "CANCELLED")) {
            Owned().use { owned ->
                owned.failAction = "webSet"; owned.failCode = code
                val failed = owned.run("@js:cookie.setWebCookie('https://owned.invalid/path','a=1'); ({})")
                assertFalse(failed.toString(), failed["ok"].asBoolean)
                val error = failed["error"].asJsonObject
                assertEquals(code, error["code"].asString)
                assertEquals(listOf("webKitCookieMutationIssued", "webSessionCookiesRemoved"), error["completedEffects"].asJsonArray.map { it.asString })
                assertEquals(0, owned.httpCount)
                owned.cookies.clear(); owned.failAction = "webRemove"
                val removed = owned.run("@js:cookie.removeCookie('https://owned.invalid/path'); ({})")
                assertFalse(removed.toString(), removed["ok"].asBoolean)
                assertEquals(code, removed["error"].asJsonObject["code"].asString)
                assertEquals(listOf("cookieRemoval", "webKitCookieMutationIssued", "webSessionCookiesRemoved"), removed["error"].asJsonObject["completedEffects"].asJsonArray.map { it.asString })
                assertEquals(listOf("remove", "webRemove"), owned.cookies.map { it["action"].asString })
                assertEquals(0, owned.httpCount)
            }
        }
        Owned().use { owned ->
            val failed = owned.run("@js:cookie.clear(); ({})", "app-owner-read")
            assertEquals("UNSUPPORTED_CAPABILITY", failed["error"].asJsonObject["code"].asString)
            assertTrue(owned.cookies.isEmpty()); assertEquals(0, owned.httpCount)
        }
    }

    @Test(timeout = 20_000) fun issuedNativeFactsSurviveCancellationAfterAHostSuccessAndAJsCatch() {
        Owned().use { owned ->
            owned.cancelAfterAction = "webSet"
            val failed = owned.run("@js:cookie.setWebCookie('https://owned.invalid/path','a=1'); ({})")
            assertEquals("CANCELLED", failed["error"].asJsonObject["code"].asString)
            assertEquals(listOf("webKitCookieMutationIssued"), failed["error"].asJsonObject["completedEffects"].asJsonArray.map { it.asString })
            assertEquals(0, owned.httpCount)
        }
        Owned().use { owned ->
            owned.failAction = "webSet"
            val failed = owned.run("@js:try { cookie.setWebCookie('https://owned.invalid/path','a=1'); } catch(e) {} throw Error('later source error');", urlScript = true)
            assertFalse(failed["ok"].asBoolean)
            assertEquals("SCRIPT_ERROR", failed["error"].asJsonObject["code"].asString)
            assertEquals(listOf("webKitCookieMutationIssued", "webSessionCookiesRemoved"), failed["error"].asJsonObject["completedEffects"].asJsonArray.map { it.asString })
            assertEquals(0, owned.httpCount)
        }
    }

    private class Owned : Closeable {
        private val directory = Files.createTempDirectory("original-browser-protocol-")
        private val state = RulePersistenceHost(FileRulePersistenceAdapter(directory))
        private val sessions = CopyOnWriteArrayList<String>()
        val cookies = CopyOnWriteArrayList<JsonObject>()
        val cookieTasks = CopyOnWriteArrayList<String>()
        var cancelAfterAction: String? = null
        var failAction: String? = null
        var failCode = "STATE_IO"
        @Volatile var httpCount = 0
        private val executor = Executors.newFixedThreadPool(2)
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)),0),0).apply {
            this.executor = this@Owned.executor
            createContext("/") { exchange ->
                httpCount++
                val body = "<a class='book' href='/book'>Owned</a>".toByteArray(Charsets.UTF_8)
                exchange.sendResponseHeaders(200, body.size.toLong())
                exchange.responseBody.use { it.write(body) }; exchange.close()
            }; start()
        }
        init {
            LegadoRuntime.setHostCallback { task, operation, raw ->
                when (operation) {
                    "task.cancel" -> "{}"
                    "cookie.owner.text" -> {
                        val input = parseObject(raw); cookies += input; cookieTasks += task
                        if (input["action"].asString == cancelAfterAction) {
                            LegadoRuntime.cancel(task)
                            jsonObject("committed" to true, "hostEffects" to listOf("webKitCookieMutationIssued")).toString()
                        } else if (input["action"].asString == failAction) jsonObject("ok" to false, "error" to jsonObject("code" to failCode,
                            "message" to "Actual browser IPC may already have changed Cookies", "completedEffects" to listOf("webKitCookieMutationIssued", "webSessionCookiesRemoved"))).toString()
                        else if (input["action"].asString in listOf("get", "session")) jsonObject("cookie" to "").toString()
                        else jsonObject("committed" to true).toString()
                    }
                    else -> state.dispatch(operation, parseObject(raw)).toString()
                }
            }
        }
        fun run(script: String, access: String = "app-owner-text", urlScript: Boolean = false): JsonObject {
            val origin = "http://127.0.0.1:${server.address.port}"
            val source = jsonObject("bookSourceUrl" to origin, "searchUrl" to (if (urlScript) script else "$origin/search"), "enabledCookieJar" to false,
                "header" to (if (urlScript) "" else script), "ruleSearch" to jsonObject("bookList" to ".book", "name" to "text", "bookUrl" to "href"))
            val created = parseObject(LegadoRuntime.createSession(source.toString(), jsonObject("sourceMode" to "original-traditional",
                "httpTransport" to "jvm-okhttp", "stateOwner" to "browser-owner", "cookieAccess" to access).toString()))
            assertTrue(created.toString(), created["ok"].asBoolean)
            val id = created["sessionId"].asString; sessions += id
            return parseObject(LegadoRuntime.execute(id, "browser-${UUID.randomUUID()}", "search", jsonObject("key" to "owned").toString()))
        }
        override fun close() {
            sessions.forEach(LegadoRuntime::closeSession); LegadoRuntime.setHostCallback(null)
            server.stop(0); executor.shutdownNow(); assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS))
            check(directory.toFile().deleteRecursively())
        }
    }
}
