package io.yuedu.legado

import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.yuedu.legado.originalrule.RuleEnvironment
import io.yuedu.legado.originalrule.RulePlatform
import io.yuedu.legado.originalrule.RuleSource
import io.yuedu.legado.originalrule.RuleScopes
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
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.CoroutineContext

/** Synthetic port concurrency contracts, not an Android-reference or iOS acceptance claim. */
class OriginalRuleScopesConcurrencyTest {
    @Test fun cancellingSameLibraryWaiterDoesNotWaitForOrCancelItsInitializer() {
        val executor = Executors.newFixedThreadPool(2)
        val environment = RuleEnvironment()
        val waiterJob = Job()
        val waiterRegistered = CountDownLatch(1)
        val waiterThread = AtomicReference<Thread>()
        val scopes = observeCreationRegistration(environment, waiterThread, waiterRegistered)
        RuleScopeInitializationGate.reset()
        try {
            val initializer = executor.submit<Any?> { scopes.getScope(BLOCKED_LIBRARY, null) }
            assertTrue(RuleScopeInitializationGate.entered.await(5, TimeUnit.SECONDS))
            val waiter = executor.submit<Any?> {
                waiterThread.set(Thread.currentThread())
                scopes.getScope(BLOCKED_LIBRARY, waiterJob)
            }
            assertTrue("The same-key call entered creation registration", waiterRegistered.await(5, TimeUnit.SECONDS))
            waiterJob.cancel()
            val failure = assertThrows(ExecutionException::class.java) { waiter.get(2, TimeUnit.SECONDS) }
            assertTrue(failure.cause is CancellationException)
            assertEquals("The unrelated initializer is still held by the actual host gate", 1L, RuleScopeInitializationGate.release.count)
            assertEquals(1, RuleScopeInitializationGate.calls.get())
            RuleScopeInitializationGate.release.countDown()
            val scope = initializer.get(5, TimeUnit.SECONDS)
            assertTrue(scope === scopes.getScope(BLOCKED_LIBRARY, null))
            assertEquals("Cancellation must not reinitialize or discard the owner's scope", 1, RuleScopeInitializationGate.calls.get())
        } finally {
            waiterJob.cancel()
            RuleScopeInitializationGate.release.countDown()
            executor.shutdown()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            environment.close()
            scopes.close()
            assertCreationRegistrationsReleased(scopes)
        }
    }

    @Test fun closingEnvironmentReleasesSameLibraryWaiterBeforeItsInitializerReturns() {
        val executor = Executors.newFixedThreadPool(2)
        val environment = RuleEnvironment()
        val waiterRegistered = CountDownLatch(1)
        val waiterThread = AtomicReference<Thread>()
        val scopes = observeCreationRegistration(environment, waiterThread, waiterRegistered)
        RuleScopeInitializationGate.reset()
        try {
            val initializer = executor.submit<Any?> { scopes.getScope(BLOCKED_LIBRARY, null) }
            assertTrue(RuleScopeInitializationGate.entered.await(5, TimeUnit.SECONDS))
            val waiter = executor.submit<Any?> {
                waiterThread.set(Thread.currentThread())
                scopes.getScope(BLOCKED_LIBRARY, null)
            }
            assertTrue("The same-key call entered creation registration", waiterRegistered.await(5, TimeUnit.SECONDS))
            environment.close()
            scopes.close()
            val failure = assertThrows(ExecutionException::class.java) { waiter.get(2, TimeUnit.SECONDS) }
            assertTrue(failure.cause is IllegalStateException)
            assertEquals("Original-rule environment is closed", failure.cause?.message)
            assertEquals("Close cannot release the owner's arbitrary host call", 1L, RuleScopeInitializationGate.release.count)
            RuleScopeInitializationGate.release.countDown()
            val initializerFailure = assertThrows(ExecutionException::class.java) { initializer.get(5, TimeUnit.SECONDS) }
            assertEquals("Original-rule environment is closed", initializerFailure.cause?.message)
            assertEquals(1, RuleScopeInitializationGate.calls.get())
        } finally {
            RuleScopeInitializationGate.release.countDown()
            executor.shutdown()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            environment.close()
            scopes.close()
            assertCreationRegistrationsReleased(scopes)
        }
    }

    @Test fun alreadyCancelledJobCannotInitializeAnUncachedLibraryOrConsumeACachedScope() {
        val environment = RuleEnvironment()
        val job = Job().apply { cancel() }
        RuleScopeInitializationGate.reset()
        try {
            assertThrows(CancellationException::class.java) { environment.scopes.getScope(BLOCKED_LIBRARY, job) }
            assertEquals(0, RuleScopeInitializationGate.calls.get())
            val library = "var ready = 19;"
            val scope = environment.scopes.getScope(library, null)
            assertThrows(CancellationException::class.java) { environment.scopes.getScope(library, job) }
            assertTrue(scope === environment.scopes.getScope(library, null))
        } finally {
            RuleScopeInitializationGate.release.countDown()
            environment.close()
            assertCreationRegistrationsReleased(environment.scopes)
        }
    }

    @Test fun cancellationAndCloseNotifyAWaiterAlreadyParkedOnItsCreationCondition() {
        for (cancel in listOf(true, false)) {
            val executor = Executors.newFixedThreadPool(2)
            val environment = RuleEnvironment()
            val job = Job()
            val waiterThread = AtomicReference<Thread>()
            val condition = AtomicReference<java.lang.Object>()
            val enteringWait = CountDownLatch(1)
            lateinit var scopes: RuleScopes
            scopes = RuleScopes {
                environment.ensureOpen()
                if (Thread.currentThread() === waiterThread.get()) {
                    val field = scopes.javaClass.getDeclaredField("libraryCreationLocks").apply { isAccessible = true }
                    val entries = synchronized(scopes) { (field.get(scopes) as Map<*, *>).values.toList() }
                    entries.forEach { entry ->
                        val monitorField = entry!!.javaClass.getDeclaredField("monitor").apply { isAccessible = true }
                        val monitor = monitorField.get(entry) as java.lang.Object
                        if (Thread.holdsLock(monitor)) { condition.set(monitor); enteringWait.countDown() }
                    }
                }
            }
            RuleScopeInitializationGate.reset()
            try {
                val initializer = executor.submit<Any?> { scopes.getScope(BLOCKED_LIBRARY, null) }
                assertTrue(RuleScopeInitializationGate.entered.await(5, TimeUnit.SECONDS))
                val waiter = executor.submit<Any?> {
                    waiterThread.set(Thread.currentThread())
                    scopes.getScope(BLOCKED_LIBRARY, if (cancel) job else null)
                }
                assertTrue("The waiter reached the occupied condition", enteringWait.await(5, TimeUnit.SECONDS))
                // Acquiring the same monitor proves the worker released it through wait().
                // Keep it while notifying, so neither cancellation nor close can race ahead of parking.
                synchronized(condition.get()) {
                    assertEquals(Thread.State.WAITING, waiterThread.get().state)
                    if (cancel) job.cancel() else { environment.close(); scopes.close() }
                }
                val failure = assertThrows(ExecutionException::class.java) { waiter.get(2, TimeUnit.SECONDS) }
                if (cancel) assertTrue(failure.cause is CancellationException)
                else assertEquals("Original-rule environment is closed", failure.cause?.message)
                assertEquals(1L, RuleScopeInitializationGate.release.count)
                RuleScopeInitializationGate.release.countDown()
                if (cancel) initializer.get(5, TimeUnit.SECONDS)
                else assertThrows(ExecutionException::class.java) { initializer.get(5, TimeUnit.SECONDS) }
                assertEquals(1, RuleScopeInitializationGate.calls.get())
            } finally {
                job.cancel()
                RuleScopeInitializationGate.release.countDown()
                executor.shutdown()
                assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
                environment.close()
                scopes.close()
                assertCreationRegistrationsReleased(scopes)
            }
        }
    }

    @Test fun sameThreadReentrantLibraryRemovalRetainsTheOriginalMonitorContract() {
        val executor = Executors.newSingleThreadExecutor()
        val environment = RuleEnvironment()
        val library = "Packages.io.yuedu.legado.RuleScopeInitializationGate.runReentrantAction(); var ready=23;"
        RuleScopeInitializationGate.reset()
        RuleScopeInitializationGate.reentrantAction = { environment.scopes.remove(library) }
        try {
            val scope = executor.submit<Any?> { environment.scopes.getScope(library, null) }.get(2, TimeUnit.SECONDS)
            assertTrue(scope === environment.scopes.getScope(library, null))
            assertEquals(1, RuleScopeInitializationGate.calls.get())
        } finally {
            executor.shutdown()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            RuleScopeInitializationGate.reentrantAction = null
            environment.close()
            assertCreationRegistrationsReleased(environment.scopes)
        }
    }

    /** Observe the existing open-check seam at creation registration, without a product hook or guessed delay.
     * The callback runs under the metadata monitor, so close cannot overtake registration after the event. */
    private fun observeCreationRegistration(environment: RuleEnvironment, worker: AtomicReference<Thread>, registered: CountDownLatch): RuleScopes =
        RuleScopes {
            environment.ensureOpen()
            if (Thread.currentThread() === worker.get() &&
                Thread.currentThread().stackTrace.any { it.methodName == "withCreationLock" }) registered.countDown()
        }

    private fun assertCreationRegistrationsReleased(scopes: RuleScopes) {
        for (name in listOf("libraryCreationLocks", "cryptoCreationLocks")) {
            val field = scopes.javaClass.getDeclaredField(name).apply { isAccessible = true }
            assertTrue("All completed/cancelled/closed calls release $name registrations", (field.get(scopes) as Map<*, *>).isEmpty())
        }
    }

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
    @Volatile var reentrantAction: (() -> Unit)? = null
    fun reset() { entered = CountDownLatch(1); release = CountDownLatch(1); calls.set(0); reentrantAction = null }
    @JvmStatic fun runReentrantAction() { calls.incrementAndGet(); requireNotNull(reentrantAction).invoke() }
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
