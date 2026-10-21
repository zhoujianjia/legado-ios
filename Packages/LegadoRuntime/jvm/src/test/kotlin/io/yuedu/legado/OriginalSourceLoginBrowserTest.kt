package io.yuedu.legado

import com.google.gson.JsonObject
import io.yuedu.legado.originalrule.RulePersistenceHost
import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real public execute/Rhino and AnalyzeUrl. The synthetic callback tests the wire
 * admission contract only; it never claims that JVM tests presented UIKit. */
class OriginalSourceLoginBrowserTest {
    @Test(timeout=20_000) fun realRhinoUsesOriginalAnalyzeUrlAndRequiresActualPresentationBoolean() {
        Owned().use { owned ->
            val reply=owned.call("java.startBrowser('https://synthetic-browser.invalid/page,{\"headers\":{\"X-Page\":\"page-value\"}}','Synthetic page');")
            assertTrue(reply["result"].asJsonObject["executed"].asBoolean)
            val request=owned.pages.single()
            assertEquals("browser-owner",request["owner"].asString)
            assertEquals(owned.origin,request["sourceURL"].asString)
            assertEquals("https://synthetic-browser.invalid/page",request["url"].asString)
            assertEquals("Synthetic page",request["title"].asString)
            assertEquals("source-value",request["headers"].asJsonObject["X-Source"].asString)
            assertEquals("page-value",request["headers"].asJsonObject["X-Page"].asString)
            assertTrue(request["remainingTimeoutMs"].asLong>0)
            assertTrue(reply["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserPresented"})
            assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpCalls)
        }
    }
    @Test(timeout=20_000) fun unsupportedHtmlPostAndNonWebSchemesDoNotFakePresentation() {
        Owned().use { owned ->
            for(script in listOf(
                "java.showBrowser('https://synthetic-browser.invalid/page');",
                "java.startBrowser('file:///private/synthetic','Not web');")) {
                val reply=owned.call(script,success=false)
                assertEquals(reply.toString(),"UNSUPPORTED_CAPABILITY",reply["error"].asJsonObject["code"].asString)
            }
            assertTrue(owned.pages.isEmpty())
            // Preserve the historical test identity while migrating only the
            // explicit-HTML branch that the original local-page slice enabled.
            val accepted=owned.call("java.startBrowser('https://synthetic-browser.invalid/page','HTML','');")
            val page=owned.pages.single();assertTrue(page.has("localPage"));assertTrue(page["prefetchedHTML"].asString.isNotEmpty())
            assertFalse(page.has("awaitsResult"))
            assertTrue(accepted["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserPresented"})
            assertEquals(0,owned.httpCalls);assertEquals(0,owned.credentialCalls)
        }
    }
    @Test(timeout=20_000) fun refusalAndSensitiveFailuresKeepAcceptedFactsWithoutLateSourceMutation() {
        Owned().use { owned ->
            owned.presented=false
            val refused=owned.call("java.startBrowser('https://synthetic-browser.invalid/page','Refused');source.putLoginInfo('must-not-store');",success=false)
            assertEquals("BROWSER_NOT_PRESENTED",refused["error"].asJsonObject["code"].asString)
            assertTrue(refused["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserMayPresent"})
            owned.failure="SOURCE_CHANGED"
            val changed=owned.call("java.startBrowser('https://synthetic-browser.invalid/page','Secret');source.putLoginInfo('must-not-store');",success=false)
            assertEquals("SOURCE_CHANGED",changed["error"].asJsonObject["code"].asString)
            assertFalse(changed.toString().contains("SYNTHETIC-BROWSER-CANARY"))
            assertTrue(changed["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserMayPresent"})
            assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpCalls)
        }
    }
    @Test(timeout=20_000) fun cancellationOfLivePresentationKeepsPossibleEffectAndPreventsLateWrites() {
        Owned().use { owned ->
            owned.hold=true;val task="browser-cancel-${UUID.randomUUID()}";val worker=Executors.newSingleThreadExecutor()
            try {
                val pending=worker.submit<JsonObject>{owned.call("java.startBrowser('https://synthetic-browser.invalid/page','Held');source.putLoginInfo('late');",task=task,success=false)}
                assertTrue(owned.entered.await(5,TimeUnit.SECONDS));LegadoRuntime.cancel(task)
                val failed=pending.get(5,TimeUnit.SECONDS)
                assertEquals("CANCELLED",failed["error"].asJsonObject["code"].asString)
                assertTrue(failed["error"].asJsonObject["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserMayPresent"})
                assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpCalls)
            } finally {owned.release.countDown();worker.shutdownNow();check(worker.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    private class Owned:Closeable {
        val origin="https://synthetic-browser-owner-${UUID.randomUUID()}.invalid"
        val pages=mutableListOf<JsonObject>();var credentialCalls=0;var httpCalls=0
        var presented=true;var failure:String?=null;var hold=false
        val entered=CountDownLatch(1);val release=CountDownLatch(1);@Volatile private var cancelled=false
        private val directory=Files.createTempDirectory("original-browser-")
        private val state=RulePersistenceHost(FileRulePersistenceAdapter(directory))
        init {LegadoRuntime.setHostCallback {_,operation,raw ->
            if(operation=="task.cancel"){cancelled=true;release.countDown();"{}"}else {
                val input=parseObject(raw);check(input["owner"].asString=="browser-owner")
                when(operation){
                    "source.browser"->{
                        pages+=input.deepCopy();check(input["sourceURL"].asString==origin)
                        if(hold){entered.countDown();check(release.await(10,TimeUnit.SECONDS))}
                        if(cancelled||failure!=null)jsonObject("ok" to false,"error" to jsonObject("code" to (if(cancelled)"CANCELLED"else failure),"message" to "SYNTHETIC-BROWSER-CANARY","completedEffects" to listOf("sourceBrowserMayPresent"))).toString()
                        else jsonObject("presented" to presented,"hostEffects" to if(presented)listOf("sourceBrowserMayPresent","sourceBrowserPresented")else listOf("sourceBrowserMayPresent")).toString()
                    }
                    "source.login-info"->{credentialCalls++;error("Browser must not use a credential writer")}
                    "http.request"->{httpCalls++;error("Browser must not use a generic HTTP host")}
                    else->state.dispatch(operation,input).toString()
                }
            }
        }}
        fun call(action:String,task:String="browser-${UUID.randomUUID()}",success:Boolean=true):JsonObject {
            val source=jsonObject("bookSourceUrl" to origin,"header" to "{\"X-Source\":\"source-value\"}","loginUi" to "[]","loginUrl" to "var browserPrelude=true;","enabledCookieJar" to false,"ruleContent" to jsonObject())
            val created=parseObject(LegadoRuntime.createSession(source.toString(),jsonObject("sourceMode" to "original-traditional","httpTransport" to "jvm-okhttp","stateOwner" to "browser-owner").toString()));assertTrue(created.toString(),created["ok"].asBoolean)
            val id=created["sessionId"].asString
            try {val reply=parseObject(LegadoRuntime.execute(id,task,"loginAction",jsonObject("action" to action,"credentials" to jsonObject("password" to ""),"timeoutMs" to 20_000).toString()));assertEquals(reply.toString(),success,reply["ok"].asBoolean);return reply}
            finally{LegadoRuntime.closeSession(id)}
        }
        override fun close(){LegadoRuntime.setHostCallback(null);check(directory.toFile().deleteRecursively())}
    }
}
