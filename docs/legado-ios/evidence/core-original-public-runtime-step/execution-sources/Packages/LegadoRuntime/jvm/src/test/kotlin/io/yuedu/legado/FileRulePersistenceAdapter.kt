package io.yuedu.legado

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.yuedu.legado.originalrule.RulePersistenceAdapter
import io.yuedu.legado.originalrule.RulePersistenceException
import io.yuedu.legado.originalrule.RulePersistenceSnapshot
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

/** Controlled-directory embedding fixture only. No App state directory/default is created. */
internal class FileRulePersistenceAdapter(private val directory: Path, private val stagingDirectory: Path = directory) : RulePersistenceAdapter {
    private fun stem(owner: String) = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun file(owner: String) = directory.resolve(stem(owner) + ".json")
    private fun <T> locked(owner: String, action: (JsonObject) -> T): T {
        val path = directory.toAbsolutePath().normalize()
        return synchronized(locks.computeIfAbsent(path.resolve(stem(owner))) { Any() }) {
            try {
                Files.createDirectories(path)
                FileChannel.open(path.resolve(stem(owner) + ".lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE).use { channel -> channel.lock().use {
                    val snapshot = if (Files.exists(file(owner))) JsonParser.parseString(Files.readString(file(owner))).asJsonObject else JsonObject().apply {
                        addProperty("version", 1); addProperty("revision", 0); add("values", JsonObject())
                    }
                    require(snapshot["version"].asInt == 1 && snapshot["revision"].asLong >= 0)
                    snapshot["values"].asJsonObject.entrySet().forEach { Base64.getDecoder().decode(it.value.asString) }
                    action(snapshot)
                } }
            } catch (error: Exception) { throw RulePersistenceException("Controlled file owner operation failed", error) }
        }
    }
    override fun read(owner: String, keys: Set<String>) = locked(owner) { snapshot ->
        val entries = snapshot["values"].asJsonObject
        RulePersistenceSnapshot(snapshot["revision"].asLong, keys.mapNotNull { key -> entries[key]?.let { key to Base64.getDecoder().decode(it.asString) } }.toMap())
    }
    override fun compareAndSet(owner: String, revision: Long, changes: Map<String, ByteArray?>): Boolean = locked(owner) { snapshot ->
        if (snapshot["revision"].asLong != revision) return@locked false
        val values = snapshot["values"].asJsonObject
        changes.forEach { (key, value) -> if (value == null) values.remove(key) else values.addProperty(key, Base64.getEncoder().encodeToString(value)) }
        snapshot.addProperty("revision", Math.addExact(revision, 1))
        val staged = Files.createTempFile(stagingDirectory, stem(owner), ".pending")
        try {
            FileChannel.open(staged, StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING).use { channel ->
                val bytes = ByteBuffer.wrap(snapshot.toString().toByteArray(Charsets.UTF_8)); while (bytes.hasRemaining()) channel.write(bytes); channel.force(true)
            }
            Files.move(staged, file(owner), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            true
        } finally { Files.deleteIfExists(staged) }
    }
    companion object { private val locks = ConcurrentHashMap<Path, Any>() }
}
