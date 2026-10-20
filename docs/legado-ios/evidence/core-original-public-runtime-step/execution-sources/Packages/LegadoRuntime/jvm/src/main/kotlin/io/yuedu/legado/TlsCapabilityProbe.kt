package io.yuedu.legado

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import kotlinx.coroutines.InternalCoroutinesApi
import java.io.Closeable
import java.io.DataInputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.KeyFactory
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertPathBuilderException
import java.security.cert.CertPathValidatorException
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory

/** Offline capability probe only; the published fixture key is not a credential. */
internal object TlsCapabilityProbe {
    private const val RESOURCE = "/io/yuedu/legado/tls-fixture-v1/"
    private val hashes = linkedMapOf(
        "test-ca.der" to "fe824a7c9fa6cc49b5574eb0a6333774d4901391bd80b489135718d9a7710e08",
        "server-localhost.der" to "f63e394e2d50066d0b32130fa2a30ee695fb40cdf8b7e7336c45657467cc4a10",
        "server-private-key.pk8" to "685632b4576a8bb80f4cf1fb15e567c03ec4ae638120338e90ebd58529fe929f",
        "unrelated-ca.der" to "c7e734a9fc9cc0c07346315745226756b32d3dadd92e46cef9986c1d5440604e",
    )
    private val ping = byteArrayOf(0x54, 0x4c, 0x53, 0x31)
    private val pong = byteArrayOf(0x54, 0x4c, 0x53, 0x32)

    @OptIn(InternalCoroutinesApi::class)
    fun run(task: RuntimeTask): JsonObject {
        val started = System.nanoTime()
        task.job.ensureActiveForRuntime()
        stage("run.begin")
        val budget = minOf(60_000L, task.deadlineEpochMs - System.currentTimeMillis())
        if (budget <= 0) throw SocketTimeoutException("TLS probe task deadline already expired")
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(budget)
        fun remaining(): Long = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
            .also { if (it <= 0) throw SocketTimeoutException("TLS probe deadline exceeded") }
        val report = jsonObject("suite" to "TlsCapabilityProbe", "passed" to false,
            "loopbackOnly" to true, "provesHTTPCompatibility" to false, "fixtureSHA256" to hashes)
        val cases = JsonArray().also { report.add("cases", it) }
        val resources = Resources()
        val server = Executors.newSingleThreadExecutor { Thread(it, "legado-tls-probe-server").apply { isDaemon = true } }
        val timer = Executors.newSingleThreadScheduledExecutor { Thread(it, "legado-tls-probe-deadline").apply { isDaemon = true } }
        // onCancelling closes I/O even if another child of the task is still finishing.
        val cancellation = task.job.invokeOnCompletion(onCancelling = true, invokeImmediately = true) { resources.close() }
        val watchdog = timer.schedule({ resources.close() }, budget, TimeUnit.MILLISECONDS)
        try {
            val bytes = hashes.mapValues { (name, expected) ->
                val value = checkNotNull(javaClass.getResourceAsStream(RESOURCE + name)) { "Missing TLS fixture: $name" }.use { it.readBytes() }
                check(sha256(value) == expected) { "TLS fixture digest mismatch: $name" }
                value
            }
            stage("fixtures.verified")
            fun certificate(name: String) = (CertificateFactory.getInstance("X.509")
                .generateCertificate(bytes.getValue(name).inputStream()) as X509Certificate).apply { checkValidity() }
            val ca = certificate("test-ca.der")
            val leaf = certificate("server-localhost.der").apply { verify(ca.publicKey) }
            val unrelated = certificate("unrelated-ca.der")
            val key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(bytes.getValue("server-private-key.pk8")))
            val password = "public-loopback-fixture".toCharArray()
            val keyStore = KeyStore.getInstance("PKCS12").apply {
                load(null, null); setKeyEntry("server", key, password, arrayOf(leaf, ca))
            }
            val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keyStore, password) }
            val serverContext = SSLContext.getInstance("TLS").apply { init(managers.keyManagers, null, null) }
            stage("server_context.ready")
            val specs = listOf(
                Case("trusted-tls12", "TLSv1.2", "localhost", ca, "ACCEPTED"),
                Case("trusted-tls13", "TLSv1.3", "localhost", ca, "ACCEPTED"),
                Case("untrusted-ca", "TLSv1.3", "localhost", unrelated, "CERTIFICATE_CHAIN_REJECTED"),
                Case("wrong-host", "TLSv1.3", "wrong.invalid", ca, "HOSTNAME_REJECTED"),
            )
            for (spec in specs) {
                task.job.ensureActiveForRuntime()
                stage("${spec.name}.begin")
                val caseStarted = System.nanoTime()
                val result = jsonObject("name" to spec.name, "protocol" to spec.protocol,
                    "peerHost" to spec.host, "expected" to spec.expected, "passed" to false,
                    "applicationRoundtrip" to false, "endpointIdentificationAlgorithm" to "HTTPS",
                    "trustAnchorSHA256" to sha256(spec.anchor.encoded))
                cases.add(result)
                try {
                    val owned = resources.add(Resources(resources.errors))
                    val trust = KeyStore.getInstance("PKCS12").apply { load(null, null); setCertificateEntry("anchor", spec.anchor) }
                    val tm = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
                    val clientContext = SSLContext.getInstance("TLS").apply { init(null, tm.trustManagers, null) }
                    val listener = owned.add(serverContext.serverSocketFactory.createServerSocket() as SSLServerSocket).apply {
                        reuseAddress = true; enabledProtocols = arrayOf(spec.protocol); needClientAuth = false
                        soTimeout = minOf(10_000L, remaining()).toInt()
                        bind(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0))
                    }
                    val future = server.submit<Unit> {
                        owned.add(listener.accept() as SSLSocket).use { socket ->
                            socket.soTimeout = minOf(10_000L, remaining()).toInt()
                        stage("${spec.name}.server_handshake.begin")
                            socket.startHandshake()
                        stage("${spec.name}.server_handshake.returned")
                            val received = ByteArray(ping.size)
                            DataInputStream(socket.inputStream).readFully(received)
                            check(received.contentEquals(ping)) { "TLS server received unexpected application bytes" }
                            socket.outputStream.write(pong); socket.outputStream.flush()
                        }
                    }
                    var clientFailure: Throwable? = null
                    var serverFailure: Throwable? = null
                    try {
                        val raw = owned.add(Socket()).apply { connect(InetSocketAddress("127.0.0.1", listener.localPort), minOf(3_000L, remaining()).toInt()) }
                        owned.add(clientContext.socketFactory.createSocket(raw, spec.host, listener.localPort, true) as SSLSocket).use { socket ->
                            socket.enabledProtocols = arrayOf(spec.protocol)
                            socket.soTimeout = minOf(10_000L, remaining()).toInt()
                            socket.sslParameters = socket.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                            stage("${spec.name}.client_handshake.begin")
                            socket.startHandshake()
                            stage("${spec.name}.client_handshake.returned")
                            result.addProperty("negotiatedProtocol", socket.session.protocol)
                            result.addProperty("cipherSuite", socket.session.cipherSuite)
                            result.addProperty("peerCertificateSHA256", sha256(socket.session.peerCertificates.first().encoded))
                            socket.outputStream.write(ping); socket.outputStream.flush()
                            val received = ByteArray(pong.size)
                            DataInputStream(socket.inputStream).readFully(received)
                            check(received.contentEquals(pong)) { "TLS client received unexpected application bytes" }
                            result.addProperty("applicationRoundtrip", true)
                        }
                    } catch (failure: Throwable) {
                        if (failure is VirtualMachineError || failure is ThreadDeath) throw failure
                        clientFailure = failure
                    }
                    finally { if (clientFailure != null) owned.close() else listener.close() }
                    try { future.get(remaining(), TimeUnit.MILLISECONDS) }
                    catch (failure: ExecutionException) { serverFailure = failure.cause ?: failure }
                    catch (failure: Exception) { serverFailure = failure; future.cancel(true) }
                    finally { owned.close() }
                    serverFailure?.let { if (it is VirtualMachineError || it is ThreadDeath) throw it }
                    task.job.ensureActiveForRuntime()
                    val classification = classify(clientFailure, spec.host)
                    stage("${spec.name}.classified.$classification")
                    result.addProperty("classification", classification)
                    result.add("clientFailure", describe(clientFailure)); result.add("serverFailure", describe(serverFailure))
                    val serverFinished = future.isDone && !future.isCancelled
                    val accepted = spec.expected == "ACCEPTED"
                    result.addProperty("passed", classification == spec.expected && serverFinished &&
                        (!accepted || (serverFailure == null && result["applicationRoundtrip"].asBoolean &&
                            result["negotiatedProtocol"]?.asString == spec.protocol)))
                } finally { result.addProperty("elapsedMilliseconds", (System.nanoTime() - caseStarted) / 1_000_000.0) }
            }
        } catch (failure: Throwable) {
            if (failure is VirtualMachineError || failure is ThreadDeath) throw failure
            report.add("failure", describe(failure))
        } finally {
            cancellation.dispose(); watchdog.cancel(false); resources.close()
            server.shutdownNow(); timer.shutdownNow()
            fun stopped(executor: java.util.concurrent.ExecutorService): Boolean = try {
                executor.awaitTermination(2, TimeUnit.SECONDS)
            } catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
            val serverStopped = stopped(server)
            val timerStopped = stopped(timer)
            report.add("cleanup", jsonObject("serverStopped" to serverStopped, "timerStopped" to timerStopped,
                "errors" to resources.errors.toList()))
            report.addProperty("deadlineExceeded", System.nanoTime() >= deadline)
            report.addProperty("passed", !report.has("failure") && cases.size() == 4 &&
                cases.all { it.asJsonObject["passed"].asBoolean } && serverStopped && timerStopped &&
                resources.errors.isEmpty() && !report["deadlineExceeded"].asBoolean)
            report.addProperty("totalMilliseconds", (System.nanoTime() - started) / 1_000_000.0)
            stage("cleanup.complete")
        }
        task.job.ensureActiveForRuntime()
        return report
    }

    private data class Case(val name: String, val protocol: String, val host: String, val anchor: X509Certificate, val expected: String)
    // Only fixed probe phase identifiers are emitted, never keys, source input
    // or exception text. Simulator stderr survives a native abort mid-handshake.
    private fun stage(name: String) {
        System.err.println("LEGADO_TLS_STAGE $name")
        System.err.flush()
    }
    private fun causes(failure: Throwable?) = generateSequence(failure) { it.cause }.take(8).toList()
    private fun describe(failure: Throwable?) = JsonArray().apply {
        causes(failure).forEach { add(jsonObject("type" to it.javaClass.name, "message" to it.message?.take(400))) }
    }
    private fun classify(failure: Throwable?, host: String): String {
        if (failure == null) return "ACCEPTED"
        val chain = causes(failure)
        if (chain.any { it is SocketTimeoutException || it is TimeoutException }) return "TIMEOUT"
        if (chain.none { it is SSLHandshakeException }) return "UNEXPECTED_FAILURE"
        if (chain.any { it is CertPathBuilderException || it is CertPathValidatorException }) return "CERTIFICATE_CHAIN_REJECTED"
        if (chain.any { it is CertificateException && it.message.orEmpty().contains(host) }) return "HOSTNAME_REJECTED"
        return "UNEXPECTED_FAILURE"
    }
    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    private class Resources(val errors: ConcurrentLinkedQueue<String> = ConcurrentLinkedQueue()) : Closeable {
        private val closed = AtomicBoolean(false)
        private val handles = ConcurrentLinkedQueue<Closeable>()
        fun <T : Closeable> add(handle: T): T {
            handles.add(handle)
            if (closed.get()) closeHandle(handle)
            return handle
        }
        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            // Closing the plain client socket first unblocks its TLS peer.
            handles.toList().sortedBy { it is SSLSocket }.forEach(::closeHandle)
        }
        private fun closeHandle(handle: Closeable) {
            try { handle.close() } catch (failure: Exception) { errors.add(failure.javaClass.name + ": " + failure.message) }
        }
    }
}
