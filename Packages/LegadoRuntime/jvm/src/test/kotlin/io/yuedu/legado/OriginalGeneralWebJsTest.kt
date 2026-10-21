package io.yuedu.legado

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CancellationException

/** Locked Backstage contract at the actual native-only JVM policy seam. */
class OriginalGeneralWebJsTest {
    private fun policy(html: String? = "<html>synthetic</html>", rule: Boolean = false,
                       resource: String? = null, navigation: String? = null, deadline: Long = System.currentTimeMillis() + 60_000) =
        OriginalGeneralWebPolicy("https://synthetic.invalid/initial", html, null, rule,
            "https://synthetic.invalid/source", deadline, resource, navigation, 0)
    private fun code(expected: String, body: () -> Unit) {
        try { body(); fail("Expected $expected") } catch (e: RuntimeFailure) { assertEquals(expected, e.code) }
    }
    @Test fun rawNullRetriesButQuotedEmptyAndNullStringsAreAccepted() {
        val p = policy(); p.configure(true)
        val expected = listOf(200,400,600,800,1000,1000)
        expected.forEachIndexed { i, delay ->
            val raw = listOf(null,"","null")[i % 3]
            val result = com.google.gson.JsonParser.parseString(p.evaluate(raw)["value"].asString).asJsonObject
            assertTrue(result["retry"].asBoolean); assertEquals(delay, result["delayMs"].asInt)
        }
        val accepted = com.google.gson.JsonParser.parseString(p.evaluate("\"\"")["value"].asString).asJsonObject
        assertEquals("", accepted["body"].asString)
        assertEquals("", p.validateTerminal(jsonObject("body" to "", "url" to "https://synthetic.invalid/actual", "redirected" to false)))
        val literal = policy();literal.configure(false)
        assertEquals("null",com.google.gson.JsonParser.parseString(literal.evaluate("\"null\"")["value"].asString).asJsonObject["body"].asString)
        val exhausted = policy();exhausted.configure(false);repeat(31) { exhausted.evaluate(null) }
        code("WEBJS_TIMEOUT") { exhausted.evaluate(null) }
    }
    @Test fun actualRuleHtmlAndRegisteredSourceControlInterfacesWithoutGrantingBasicPages() {
        val basic=policy();basic.configure(true)
        code("UNSUPPORTED_CAPABILITY") { basic.checkBridge("cache.get") }
        code("UNSUPPORTED_CAPABILITY") { basic.checkBridge("source.get") }
        val unregistered=policy(rule=true);unregistered.configure(false);unregistered.checkBridge("cache.get")
        code("UNSUPPORTED_CAPABILITY") { unregistered.checkBridge("java.get") }
        val registered=policy(rule=true);registered.configure(true);registered.checkBridge("java.get");registered.checkBridge("source.getKey")
        val empty=policy(html="",rule=true);empty.configure(true)
        code("UNSUPPORTED_CAPABILITY") { empty.checkBridge("cache.get") }
        code("INVALID_WEBVIEW_POLICY") { registered.configure(true) }
    }
    @Test fun javaFullMatchesRetainSnifferIdentityAndGuardBacktracking() {
        val p=policy(navigation="https://synthetic\\.invalid/(?:capture|other)/[0-9]+")
        p.configure(false);assertEquals("false",p.matchNavigation("prefixhttps://synthetic.invalid/capture/42"){}["value"].asString)
        assertEquals("true",p.matchNavigation("https://synthetic.invalid/capture/42"){}["value"].asString)
        code("INVALID_WEBVIEW_RESULT") {p.validateTerminal(jsonObject("body" to "https://synthetic.invalid/capture/42", "url" to "https://synthetic.invalid/capture/42", "redirected" to false))}
        assertEquals("https://synthetic.invalid/capture/42",p.validateTerminal(jsonObject("body" to "https://synthetic.invalid/capture/42", "url" to "https://synthetic.invalid/initial", "redirected" to false)))
        val dangerous=policy(resource="(a+)+$");dangerous.configure(false);var checks=0
        try { dangerous.matchResource("a".repeat(400)+"! ") {if(++checks>200)throw CancellationException("synthetic cancellation")};fail("Missing regex cancellation") }
        catch (_: CancellationException) {assertTrue(checks>200)}
    }
    @Test fun noPresentationOrFabricatedBodyCanReplaceAnAcceptedPolicyTerminal() {
        val p=policy()
        code("INVALID_WEBVIEW_POLICY") {p.validateTerminal(jsonObject("body" to "fake"))}
        p.configure(false)
        code("INVALID_WEBVIEW_RESULT") {p.validateTerminal(jsonObject("body" to "fake"))}
        p.evaluate("\"accepted\\nbody\"")
        code("INVALID_WEBVIEW_RESULT") {p.validateTerminal(jsonObject("body" to "different"))}
        assertEquals("accepted\nbody",p.validateTerminal(jsonObject("body" to "accepted\nbody")))
        code("WEBJS_TIMEOUT") {policy(deadline=0).configure(true)}
    }
}
