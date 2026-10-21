package io.yuedu.legado
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
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
