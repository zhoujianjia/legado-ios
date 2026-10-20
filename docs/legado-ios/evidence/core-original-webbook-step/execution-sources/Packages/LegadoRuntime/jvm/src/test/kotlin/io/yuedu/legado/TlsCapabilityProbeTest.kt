package io.yuedu.legado

import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.net.SocketTimeoutException

class TlsCapabilityProbeTest {
    @Test fun cancelledTaskCannotStartTLSWork() {
        val task = RuntimeTask("tls-precancelled", RuntimeSession("tls-cancel", jsonObject()),
            Job().apply { cancel() }, System.currentTimeMillis() + 60_000)
        assertThrows(CancellationException::class.java) { TlsCapabilityProbe.run(task) }
    }

    @Test fun expiredDeadlineCannotStartTLSWork() {
        val task = RuntimeTask("tls-expired", RuntimeSession("tls-expired", jsonObject()),
            Job(), System.currentTimeMillis() - 1_000)
        try {
            assertThrows(SocketTimeoutException::class.java) { TlsCapabilityProbe.run(task) }
        } finally { task.job.cancel() }
    }

    @Test(timeout = 70_000) fun realLoopbackTlsValidatesBothProtocolsTrustAndHostAndStopsWorkers() {
        val task = RuntimeTask(UUID.randomUUID().toString(), RuntimeSession("tls-test", jsonObject()),
            Job(), System.currentTimeMillis() + 60_000)
        try {
            val report = TlsCapabilityProbe.run(task)
            assertTrue(report.toString(), report["passed"].asBoolean)
            assertTrue(report["loopbackOnly"].asBoolean)
            assertFalse(report["provesHTTPCompatibility"].asBoolean)
            val cases = report["cases"].asJsonArray.map { it.asJsonObject }
            assertEquals(4, cases.size)
            cases.forEach { assertTrue(it["elapsedMilliseconds"].asDouble >= 0.0) }
            assertTrue(report["totalMilliseconds"].asDouble >= cases.sumOf { it["elapsedMilliseconds"].asDouble })
            assertEquals(listOf("ACCEPTED", "ACCEPTED", "CERTIFICATE_CHAIN_REJECTED", "HOSTNAME_REJECTED"),
                cases.map { it["classification"].asString })
            cases.take(2).forEach {
                assertTrue(it["applicationRoundtrip"].asBoolean)
                assertEquals(it["protocol"].asString, it["negotiatedProtocol"].asString)
                assertEquals(report["fixtureSHA256"].asJsonObject["server-localhost.der"].asString,
                    it["peerCertificateSHA256"].asString)
            }
            cases.drop(2).forEach {
                assertFalse(it["applicationRoundtrip"].asBoolean)
                assertTrue(it["clientFailure"].asJsonArray.size() > 0)
            }
            assertEquals(report["fixtureSHA256"].asJsonObject["unrelated-ca.der"].asString,
                cases[2]["trustAnchorSHA256"].asString)
            assertEquals(report["fixtureSHA256"].asJsonObject["test-ca.der"].asString,
                cases[3]["trustAnchorSHA256"].asString)
            val cleanup = report["cleanup"].asJsonObject
            assertTrue(cleanup["serverStopped"].asBoolean)
            assertTrue(cleanup["timerStopped"].asBoolean)
            assertEquals(0, cleanup["errors"].asJsonArray.size())
        } finally { task.job.cancel() }
    }
}
