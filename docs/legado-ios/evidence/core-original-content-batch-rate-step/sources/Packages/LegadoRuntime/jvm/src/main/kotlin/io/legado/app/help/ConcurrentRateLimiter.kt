package io.legado.app.help

import io.legado.app.data.entities.BaseSource
import io.legado.app.exception.ConcurrentException
import io.legado.app.model.analyzeRule.AnalyzeUrl.ConcurrentRecord
import io.yuedu.legado.originalrule.unsupportedRule
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.EmptyCoroutineContext

/** Locked original window algorithm with bounded, actual owner/source/revision
 * identity. Registry never retains an old task/environment or grants cache IO.
 * Unscoped Android UI/static-map mutation has not been ported. */
class ConcurrentRateLimiter(private val source: BaseSource?) {
    companion object {
        val concurrentRecordMap: ConcurrentHashMap<String, ConcurrentRecord>
            get() = unsupportedRule("unscoped original global concurrent-rate map")
        fun updateConcurrentRate(key: String, concurrentRate: String) {
            unsupportedRule("original rate UI update needs current source/revision ownership")
        }
    }
    private val concurrentRate = source?.concurrentRate
    private val key = source?.getKey()

    /** Original retry/delay algorithm; current task's absolute deadline bounds
     * a long window without installing a second timeout/job/thread. */
    suspend fun getConcurrentRecord(): ConcurrentRecord? {
        if (concurrentRate.isNullOrEmpty() || concurrentRate == "0" || key == null) return null
        val currentSource = source ?: return null
        val environment = currentSource.getRuleEnvironment()
        while (true) {
            currentCoroutineContext().ensureActive()
            environment.ensureOpen()
            val budget = environment.platform.originalRateDelayBudgetMillis(currentSource)
            try { return OwnedConcurrentWindows.admit(currentSource, concurrentRate) }
            catch (error: ConcurrentException) { delay(minOf(error.waitTime,budget.coerceAtLeast(1L))) }
        }
    }
    fun getConcurrentRecordBlocking(): ConcurrentRecord? =
        runBlocking(source?.getRuleCoroutineContext() ?: EmptyCoroutineContext) { getConcurrentRecord() }
    suspend inline fun <T> withLimit(block: () -> T): T { getConcurrentRecord(); return block() }
    inline fun <T> withLimitBlocking(block: () -> T): T { getConcurrentRecordBlocking(); return block() }
}

/** One process-local registry, no companion field accessor returning a raw Map.
 * Every callable admission takes the real source and validates its current Host
 * grant itself. Lookup, expired-row pruning and the original counter update are
 * a single critical section: no admission can revive an already-pruned row. */
private object OwnedConcurrentWindows {
    private const val maximumRecords = 256
    private val records = LinkedHashMap<String, ConcurrentRecord>()
    fun admit(source: BaseSource, concurrentRate: String): ConcurrentRecord {
        val environment = source.getRuleEnvironment()
        environment.ensureOpen()
        val ownedKey = environment.platform.exploreOwnerScope(source)
        if(ownedKey.isEmpty() || ownedKey.toByteArray(Charsets.UTF_8).size > 32_768)
            unsupportedRule("original concurrent rate needs a bounded actual owner scope")
        // Host ownership/deadline calls happen outside the registry lock.
        environment.platform.originalRateDelayBudgetMillis(source)
        return synchronized(records) {
            var fetchRecord = records[ownedKey]
            if (fetchRecord == null) {
                val now = System.currentTimeMillis()
                val iterator = records.iterator()
                while (iterator.hasNext()) {
                    val row = iterator.next().value
                    if (synchronized(row) { now >= row.time + row.interval.toLong() }) iterator.remove()
                }
                if(records.size >= maximumRecords) unsupportedRule("original concurrent-rate active-owner limit (256); retry after an existing window expires")
                val rateIndex = concurrentRate.indexOf("/")
                fetchRecord = if (rateIndex > 0) {
                    val accessLimit = concurrentRate.take(rateIndex).toIntOrNull() ?: 1
                    val interval = concurrentRate.substring(rateIndex + 1).toIntOrNull() ?: 0
                    ConcurrentRecord(System.currentTimeMillis(), accessLimit, interval, 1)
                } else ConcurrentRecord(System.currentTimeMillis(),1,concurrentRate.toIntOrNull() ?: 0,1)
                records[ownedKey] = fetchRecord
                return@synchronized fetchRecord
            }
            val current = fetchRecord
            val waitTime: Long = synchronized(current) {
                val nextTime = current.time + current.interval.toLong()
                val nowTime = System.currentTimeMillis()
                if (nowTime >= nextTime) {
                    current.time = nowTime
                    current.frequency = 1
                    return@synchronized 0L
                }
                if (current.frequency < current.accessLimit) {
                    current.frequency++
                    return@synchronized 0L
                } else return@synchronized nextTime - nowTime
            }
            if (waitTime > 0) throw ConcurrentException("根据并发率还需等待"+waitTime+"毫秒才可以访问",waitTime=waitTime)
            current
        }
    }
}
