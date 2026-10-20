package io.yuedu.legado

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.yuedu.legado.originalrule.RuleCookieHost
import io.yuedu.legado.originalrule.RuleSource
import io.yuedu.legado.originalrule.UnsupportedRuleCapability
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.CookieManager
import java.net.HttpCookie
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Retained AnalyzeRule scripts and the ordinary production transport share one actual jar. */
class OriginalRuleCookiePlatformTest {
    @Test(timeout = 15_000) fun retainedScriptsUseOriginalSetAndMergeNamesWithoutASecondJar() {
        Session("http://127.0.0.1:1").use { owned ->
            owned.environment().use { environment ->
                AnalyzeRule(source = RuleSource(environment, owned.origin, "Owned cookie fixture")).use { rule ->
                    rule.setContent("owned", owned.origin)
                    assertEquals("a=last; token=left=right; literal=null", rule.getString(
                        "@js:cookie.setCookie(baseUrl, 'a=first; token=left=right; empty=; ignored; literal=null; a=last'); cookie.getCookie(baseUrl)", false))
                    assertEquals("updated=tail", rule.getString(
                        "@js:cookie.replaceCookie(baseUrl, 'token=updated=tail; added=value; blank='); cookie.getCookie(baseUrl, 'token')", false))
                    assertEquals("a=last; token=updated=tail; literal=null; added=value", owned.session.cookies.getCookie(owned.origin))
                    assertEquals("", rule.getString("@js:cookie.getCookie(baseUrl, 'missing')", false))
                    assertEquals(owned.session.cookies.getCookie(owned.origin), environment.cookie.getCookie(owned.origin, null))
                    assertEquals("only=new", rule.getString("@js:cookie.setCookie(baseUrl, 'only=new'); cookie.getCookie(baseUrl)", false))
                    assertEquals("", rule.getString("@js:cookie.removeCookie(baseUrl); cookie.getCookie(baseUrl)", false))
                }
            }
        }
    }

    @Test(timeout = 15_000) fun productionSetCookieAndRuleChangesReachTheSameRequestJar() {
        Peer().use { peer ->
            // Both enabled CookieJar interception and the existing disabled-jar
            // explicit-cookie preparation must see script-authored values.
            listOf(true, false).forEach { enabled ->
                Session(peer.origin, enabled).use { owned ->
                    owned.environment().use { environment ->
                        AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned cookie fixture", enabledCookieJar = enabled)).use { rule ->
                            rule.connect(peer.origin + "/seed")
                            assertEquals(if (enabled) "server" else "", environment.cookie.getCookie(peer.origin, "seed"))
                            environment.cookie.replaceCookie(peer.origin, "script=first=second")
                            assertEquals("first=second", owned.session.cookies.getKey(peer.origin, "script"))
                            val before = rule.connect(peer.origin + "/echo").body()
                            assertTrue(before, before.contains("script=first=second"))
                            assertEquals(before, enabled, before.contains("seed=server"))
                            environment.cookie.setCookie(peer.origin, "replacement=only")
                            assertEquals("replacement=only", rule.connect(peer.origin + "/echo").body())
                            environment.cookie.removeCookie(peer.origin)
                            assertEquals("", rule.connect(peer.origin + "/echo").body())
                        }
                    }
                }
            }
        }
    }

    @Test(timeout = 15_000) fun mergesRetainUnrelatedAndSameNameSecurityPathAndExpirationAttributes() {
        Peer().use { peer ->
            Session(peer.origin, true).use { owned ->
                val secureOrigin = peer.origin.replace("http:", "https:")
                owned.session.cookies.setCookie(secureOrigin, "secret=secure; Secure; HttpOnly; Path=/private; Max-Age=3600")
                owned.session.cookies.setCookie(peer.origin, "scoped=one; HttpOnly; Path=/private; Max-Age=3600")
                owned.session.cookies.setCookie(peer.origin, "scoped=two; Path=/other; Max-Age=1800")
                val before = actualCookies(owned.session.cookies).associateBy { it.name to it.path }
                owned.environment().use { environment ->
                    environment.cookie.replaceCookie(secureOrigin, "added=plain; scoped=updated; secret=changed")
                    val after = actualCookies(owned.session.cookies).associateBy { it.name to it.path }
                    before.forEach { (key, previous) ->
                        val current = requireNotNull(after[key])
                        assertEquals(previous.domain, current.domain)
                        assertEquals(previous.path, current.path)
                        assertEquals(previous.secure, current.secure)
                        assertEquals(previous.isHttpOnly, current.isHttpOnly)
                        assertEquals(previous.maxAge, current.maxAge)
                        assertEquals(if (previous.name == "secret") "changed" else "updated", current.value)
                    }
                    assertEquals("", environment.cookie.getCookie(peer.origin + "/echo", "scoped"))
                    assertEquals("", environment.cookie.getCookie(peer.origin + "/private/echo", "secret"))
                    assertEquals("changed", environment.cookie.getCookie(secureOrigin + "/private/echo", "secret"))
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned cookie fixture")).use { rule ->
                        val ordinary = rule.connect(peer.origin + "/echo").body()
                        assertTrue(ordinary, ordinary.contains("added=plain"))
                        assertFalse(ordinary, ordinary.contains("scoped="))
                        assertFalse(ordinary, ordinary.contains("secret="))
                        val scoped = rule.connect(peer.origin + "/private/echo").body()
                        assertTrue(scoped, scoped.contains("scoped=\"updated\""))
                        assertFalse(scoped, scoped.contains("secret="))
                    }
                }
            }
        }
    }

    @Test fun duplicateNamesAcrossParentDomainAndPathsKeepTheirScopeWhenMergedOrRemoved() {
        val origin = "https://book.example.invalid"
        Session(origin).use { owned ->
            owned.session.cookies.setCookie(origin, "named=parent; Domain=.example.invalid; Path=/; Max-Age=3600")
            owned.session.cookies.setCookie(origin, "named=private; Path=/private; Max-Age=1800")
            owned.session.cookies.setCookie("https://elsewhere.invalid", "separate=untouched; Path=/")
            val before = actualCookies(owned.session.cookies).filter { it.name == "named" }
            assertEquals(2, before.size)
            owned.environment().use { environment ->
                environment.cookie.replaceCookie(origin, "named=merged")
                val after = actualCookies(owned.session.cookies).filter { it.name == "named" }
                assertEquals(2, after.size)
                assertEquals(before.map { Triple(it.domain, it.path, it.maxAge) }.toSet(), after.map { Triple(it.domain, it.path, it.maxAge) }.toSet())
                assertTrue(after.all { it.value == "merged" })
                assertEquals("merged", environment.cookie.getCookie("https://sibling.example.invalid/", "named"))
                environment.cookie.removeCookie(origin)
                assertEquals("", environment.cookie.getCookie(origin))
                assertEquals("", environment.cookie.getCookie("https://sibling.example.invalid/"))
                assertEquals("separate=untouched", environment.cookie.getCookie("https://elsewhere.invalid"))
            }
        }
    }

    @Test fun invalidInputsAreTypedAndCannotPartiallyMutateTheLiveJar() {
        Session("https://owned.invalid").use { owned ->
            owned.environment().use { environment ->
                val cookie = environment.cookie
                cookie.setCookie(owned.origin, "before=kept")
                listOf<(String, String) -> Unit>(cookie::setCookie, cookie::replaceCookie).forEach { change ->
                    listOf("valid=first; bad name=invalid", "valid=first; bad=line\r\nbreak").forEach { invalid ->
                        assertThrows(UnsupportedRuleCapability::class.java) { change(owned.origin, invalid) }
                        assertEquals("before=kept", cookie.getCookie(owned.origin))
                    }
                    listOf("owned.invalid", "file:///owned", "http://bad host").forEach { invalid ->
                        assertThrows(UnsupportedRuleCapability::class.java) { change(invalid, "other=new") }
                        assertEquals("before=kept", cookie.getCookie(owned.origin))
                    }
                }
                cookie.replaceCookie("", "ignored=value")
                cookie.replaceCookie(owned.origin, "")
                assertEquals("before=kept", cookie.getCookie(owned.origin))
                cookie.setCookie(owned.origin, "")
                assertEquals("", cookie.getCookie(owned.origin))
            }
        }
    }

    @Test fun ownedLifetimesCancelRetainedCookieHandlesWithoutClearingOtherSessions() {
        Session("https://owned.invalid").use { first ->
            Session(first.origin).use { other ->
                other.environment().use { environment ->
                    environment.cookie.setCookie(other.origin, "other=isolated")
                    val ownedEnvironment = first.environment()
                    val retained = ownedEnvironment.cookie
                    retained.setCookie(first.origin, "first=retained")
                    ownedEnvironment.close()
                    assertThrows(CancellationException::class.java) { retained.setCookie(first.origin, "late=denied") }
                    assertEquals("first=retained", first.session.cookies.getCookie(first.origin))
                    assertTrue(first.task.job.isActive)
                    first.environment().use { nextEnvironment ->
                        assertEquals("first=retained", nextEnvironment.cookie.getCookie(first.origin))
                        first.task.job.cancel()
                        assertThrows(CancellationException::class.java) { nextEnvironment.cookie.removeCookie(first.origin) }
                    }
                    val expired = RuntimeTask("expired", first.session, Job(), System.currentTimeMillis() - 1)
                    // Factory itself enforces the task deadline before exposing hosts.
                    assertThrows(CancellationException::class.java) { LegadoRuntime.originalRuleEnvironment(expired) }
                    other.session.closed.set(true)
                    assertThrows(IllegalStateException::class.java) { environment.cookie.removeCookie(other.origin) }
                    assertEquals("other=isolated", other.session.cookies.getCookie(other.origin))
                    assertEquals("first=retained", first.session.cookies.getCookie(first.origin))
                }
            }
        }
        assertThrows(UnsupportedRuleCapability::class.java) { RuleCookieHost().getCookie("https://owned.invalid") }
    }

    private class Session(val origin: String, enabledJar: Boolean = false) : Closeable {
        val session = RuntimeSession(UUID.randomUUID().toString(), jsonObject("bookSourceUrl" to origin,
            "enabledCookieJar" to enabledJar), RuntimeSessionOptions("jvm-okhttp"))
        val task = RuntimeTask(UUID.randomUUID().toString(), session, Job(), System.currentTimeMillis() + 10_000)
        fun environment() = LegadoRuntime.originalRuleEnvironment(task)
        override fun close() { task.job.cancel(); session.closed.set(true); session.http!!.close() }
    }

    /** Inspect actual JDK cookie attributes; no test-only production accessor or replacement jar. */
    private fun actualCookies(cookies: SessionCookies): List<HttpCookie> {
        val field = SessionCookies::class.java.getDeclaredField("manager").apply { isAccessible = true }
        return (field.get(cookies) as CookieManager).cookieStore.cookies.map { it.clone() as HttpCookie }
    }

    private class Peer : Closeable {
        private val failures = CopyOnWriteArrayList<Throwable>()
        private val executor = Executors.newCachedThreadPool { Thread(it, "original-rule-cookie-peer").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 0).apply {
            executor = this@Peer.executor
            createContext("/") { exchange ->
                try {
                    if (exchange.requestURI.path == "/seed") exchange.responseHeaders.add("Set-Cookie", "seed=server; Path=/")
                    respond(exchange, exchange.requestHeaders.getFirst("Cookie").orEmpty())
                } catch (error: Throwable) { failures += error } finally { exchange.close() }
            }
            start()
        }
        val origin = "http://127.0.0.1:${server.address.port}"
        override fun close() {
            server.stop(0); executor.shutdownNow(); check(executor.awaitTermination(2, TimeUnit.SECONDS))
            if (failures.isNotEmpty()) throw AssertionError("Owned peer failed", failures.first())
        }
    }

    companion object {
        private fun respond(exchange: HttpExchange, text: String) {
            val bytes = text.toByteArray()
            exchange.responseHeaders.add("Content-Type", "text/plain; charset=utf-8")
            exchange.sendResponseHeaders(200, if (bytes.isEmpty()) -1 else bytes.size.toLong())
            if (bytes.isNotEmpty()) exchange.responseBody.write(bytes)
        }
    }
}
