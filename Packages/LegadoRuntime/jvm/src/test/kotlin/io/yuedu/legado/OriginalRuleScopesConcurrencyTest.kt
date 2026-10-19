package io.yuedu.legado

import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.yuedu.legado.originalrule.RuleEnvironment
import io.yuedu.legado.originalrule.RulePlatform
import io.yuedu.legado.originalrule.RuleSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext

/** Synthetic port concurrency contracts, not an Android-reference or iOS acceptance claim. */
class OriginalRuleScopesConcurrencyTest {
    @Test fun unrelatedLibraryInitializationDoesNotWaitForABlockedLibrary() {
        val executor = Executors.newFixedThreadPool(2)
        val environment = RuleEnvironment()
        RuleScopeInitializationGate.reset()
        val blockedSource = RuleSource(environment, "https://blocked.invalid", "Synthetic", jsLib =
            "Packages.io.yuedu.legado.RuleScopeInitializationGate.awaitRelease(); var blockedValue = 7;")
        val independentSource = RuleSource(environment, "https://independent.invalid", "Synthetic", jsLib =
            "var independentValue = 11;")
        try {
            val blocked = executor.submit<Any?> { AnalyzeRule(source = blockedSource).use { it.evalJS("blockedValue") } }
            assertTrue("The first library actually entered its blocking host call", RuleScopeInitializationGate.entered.await(5, TimeUnit.SECONDS))
            val independent = executor.submit<Any?> { AnalyzeRule(source = independentSource).use { it.evalJS("independentValue") } }
            assertEquals(11.0, independent.get(2, TimeUnit.SECONDS))
            RuleScopeInitializationGate.release.countDown()
            assertEquals(7.0, blocked.get(5, TimeUnit.SECONDS))
        } finally {
            RuleScopeInitializationGate.release.countDown()
            executor.shutdown()
            assertTrue("All rule workers finish", executor.awaitTermination(5, TimeUnit.SECONDS))
            environment.close()
        }
    }

    @Test fun noLibraryCryptoScopeDoesNotWaitForABlockedLibrary() {
        val executor = Executors.newFixedThreadPool(2)
        val environment = RuleEnvironment()
        RuleScopeInitializationGate.reset()
        val blockedSource = RuleSource(environment, "https://blocked.invalid", "Synthetic", jsLib = BLOCKED_LIBRARY)
        val independentSource = RuleSource(environment, "https://plain.invalid", "Synthetic")
        try {
            val blocked = executor.submit<Any?> { AnalyzeRule(source = blockedSource).use { it.evalJS("blockedValue") } }
            assertTrue(RuleScopeInitializationGate.entered.await(5, TimeUnit.SECONDS))
            val independent = executor.submit<Any?> { AnalyzeRule(source = independentSource).use { it.evalJS("CryptoJS.MD5('hello').toString()") } }
            assertEquals("5d41402abc4b2a76b9719d911017c592", independent.get(2, TimeUnit.SECONDS))
            RuleScopeInitializationGate.release.countDown()
            assertEquals(7.0, blocked.get(5, TimeUnit.SECONDS))
        } finally {
            RuleScopeInitializationGate.release.countDown()
            executor.shutdown()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            environment.close()
        }
    }

    @Test fun concurrentCallersInitializeTheSameLibraryOnce() {
        val executor = Executors.newFixedThreadPool(2)
        val environment = RuleEnvironment()
        RuleScopeInitializationGate.reset()
        val source = RuleSource(environment, "https://shared.invalid", "Synthetic", jsLib = BLOCKED_LIBRARY)
        val secondStarted = CountDownLatch(1)
        try {
            val first = executor.submit<Any?> { AnalyzeRule(source = source).use { it.evalJS("blockedValue") } }
            assertTrue(RuleScopeInitializationGate.entered.await(5, TimeUnit.SECONDS))
            val second = executor.submit<Any?> {
                secondStarted.countDown()
                AnalyzeRule(source = source).use { it.evalJS("blockedValue") }
            }
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS))
            RuleScopeInitializationGate.release.countDown()
            assertEquals(7.0, first.get(5, TimeUnit.SECONDS))
            assertEquals(7.0, second.get(5, TimeUnit.SECONDS))
            assertEquals(1, RuleScopeInitializationGate.calls.get())
        } finally {
            RuleScopeInitializationGate.release.countDown()
            executor.shutdown()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            environment.close()
        }
    }

    @Test fun closingEnvironmentDoesNotWaitForOrPublishAnInFlightLibrary() {
        val executor = Executors.newFixedThreadPool(2)
        val environment = RuleEnvironment()
        RuleScopeInitializationGate.reset()
        val source = RuleSource(environment, "https://closing.invalid", "Synthetic", jsLib = BLOCKED_LIBRARY)
        try {
            val blocked = executor.submit<Any?> { AnalyzeRule(source = source).use { it.evalJS("blockedValue") } }
            assertTrue(RuleScopeInitializationGate.entered.await(5, TimeUnit.SECONDS))
            executor.submit { environment.close() }.get(2, TimeUnit.SECONDS)
            RuleScopeInitializationGate.release.countDown()
            val failure = assertThrows(ExecutionException::class.java) { blocked.get(5, TimeUnit.SECONDS) }
            assertTrue(failure.cause is IllegalStateException)
            assertEquals("Original-rule environment is closed", failure.cause?.message)
            assertThrows(IllegalStateException::class.java) { environment.ensureOpen() }
        } finally {
            RuleScopeInitializationGate.release.countDown()
            executor.shutdown()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            environment.close()
        }
    }

    @Test fun cancelledLibraryInitializationReleasesItsKeyAndDoesNotCachePartialScope() {
        val executor = Executors.newSingleThreadExecutor()
        val environment = RuleEnvironment()
        val job = Job()
        RuleScopeInitializationGate.reset()
        val source = RuleSource(environment, "https://cancelled.invalid", "Synthetic", jsLib =
            "if (Packages.io.yuedu.legado.RuleScopeInitializationGate.beginCancellableInitialization()) { var partialValue = 99; while(true) {} } var recoveredValue = 13;")
        try {
            val blocked = executor.submit<Any?> {
                AnalyzeRule(source = source).use { it.setCoroutineContext(job).evalJS("recoveredValue") }
            }
            assertTrue(RuleScopeInitializationGate.entered.await(5, TimeUnit.SECONDS))
            job.cancel()
            val failure = assertThrows(ExecutionException::class.java) { blocked.get(2, TimeUnit.SECONDS) }
            assertTrue(failure.cause is CancellationException)
            assertTrue(job.isCancelled)
            val recovered = executor.submit<Any?> {
                AnalyzeRule(source = source).use { it.evalJS("recoveredValue + '|' + typeof partialValue") }
            }
            assertEquals("13|undefined", recovered.get(5, TimeUnit.SECONDS))
            assertEquals(2, RuleScopeInitializationGate.calls.get())
        } finally {
            job.cancel()
            executor.shutdown()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            environment.close()
        }
    }

    @Test fun concurrentInvocationBindingsAndSourceGlobalsRemainIsolatedWithinAndAcrossEnvironments() {
        for (shareEnvironment in listOf(true, false)) {
            val entered = CountDownLatch(2)
            val release = CountDownLatch(1)
            val platform = object : RulePlatform() {
                override fun request(url: String, headers: String?, callTimeout: Long?, context: CoroutineContext): StrResponse {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS)) { "Synthetic invocation gate was not released" }
                    return StrResponse(url, 200, "fixture", emptyMap())
                }
            }
            val firstEnvironment = RuleEnvironment(platform)
            val secondEnvironment = if (shareEnvironment) firstEnvironment else RuleEnvironment(platform)
            val executor = Executors.newFixedThreadPool(2)
            val firstSource = RuleSource(firstEnvironment, "https://first.invalid", "Synthetic", jsLib = "var libraryValue='ready';")
            val secondSource = RuleSource(secondEnvironment, "https://second.invalid", "Synthetic", jsLib = firstSource.jsLib)
            firstSource.put("marker", "one")
            secondSource.put("marker", "two")
            fun evaluate(source: RuleSource) = executor.submit<List<Any?>> {
                AnalyzeRule(source = source).use { rule ->
                    listOf(
                        rule.evalJS("var invocationMarker=java.get('marker'); java.ajax('https://fixture.invalid'); globalThis.saved=invocationMarker; invocationMarker+'|'+globalThis.saved+'|'+libraryValue"),
                        rule.evalJS("typeof invocationMarker+'|'+globalThis.saved"),
                    )
                }
            }
            try {
                val first = evaluate(firstSource)
                val second = evaluate(secondSource)
                assertTrue("Both invocations actually entered their host calls", entered.await(5, TimeUnit.SECONDS))
                release.countDown()
                assertEquals(listOf("one|one|ready", "undefined|one"), first.get(5, TimeUnit.SECONDS))
                assertEquals(listOf("two|two|ready", "undefined|two"), second.get(5, TimeUnit.SECONDS))
            } finally {
                release.countDown()
                executor.shutdown()
                assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
                firstEnvironment.close()
                if (!shareEnvironment) secondEnvironment.close()
            }
        }
    }

    private companion object {
        const val BLOCKED_LIBRARY = "Packages.io.yuedu.legado.RuleScopeInitializationGate.awaitRelease(); var blockedValue = 7;"
    }
}

/** Invoked only by a synthetic jsLib so the test observes real initialization, not a guessed delay. */
object RuleScopeInitializationGate {
    @Volatile var entered = CountDownLatch(1)
        private set
    @Volatile var release = CountDownLatch(1)
        private set
    val calls = AtomicInteger()
    fun reset() { entered = CountDownLatch(1); release = CountDownLatch(1); calls.set(0) }
    @JvmStatic fun awaitRelease() {
        calls.incrementAndGet()
        entered.countDown()
        check(release.await(5, TimeUnit.SECONDS)) { "Synthetic library gate was not released" }
    }
    @JvmStatic fun beginCancellableInitialization(): Boolean {
        val first = calls.incrementAndGet() == 1
        entered.countDown()
        return first
    }
}
