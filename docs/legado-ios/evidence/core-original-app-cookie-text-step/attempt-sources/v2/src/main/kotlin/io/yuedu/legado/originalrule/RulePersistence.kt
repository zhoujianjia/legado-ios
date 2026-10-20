package io.yuedu.legado.originalrule

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.IOException
import java.util.Base64

/** The embedding owner supplies one atomic backing store; imported rules never choose a path. */
interface RulePersistenceAdapter {
    fun read(owner: String, keys: Set<String>): RulePersistenceSnapshot
    /** False means a concurrent owner write won; no mutation was committed. */
    fun compareAndSet(owner: String, revision: Long, changes: Map<String, ByteArray?>): Boolean
}

data class RulePersistenceSnapshot(val revision: Long, val values: Map<String, ByteArray>)
class RulePersistenceException private constructor(message: String, cause: Throwable?, internal val completedEffect: String?) : IOException(message, cause) {
    constructor(message: String, cause: Throwable? = null) : this(message, cause, null)
    internal companion object {
        fun afterCommittedEffect(effect: String, message: String, cause: Throwable): RulePersistenceException =
            RulePersistenceException(message, cause, effect)
    }
}

/** Stable owner + source identity, separate from the ephemeral task/environment lifetime. */
class RulePersistenceBinding(
    private val adapter: RulePersistenceAdapter,
    private val owner: String,
    private val source: String,
    private val checkActive: () -> Unit = {},
) {
    init { require(owner.isNotBlank()); require(source.isNotBlank()) }
    internal fun key(area: String, vararg parts: String): String = GSON.toJson(listOf(source, area) + parts)
    internal fun read(key: String): ByteArray? {
        checkActive()
        val result = adapter.read(owner, setOf(key)).values[key]?.copyOf()
        checkActive()
        return result
    }
    internal fun <T> update(keys: Set<String>, action: (Map<String, ByteArray>) -> Pair<Map<String, ByteArray?>, T>): T {
        repeat(32) {
            checkActive()
            val snapshot = adapter.read(owner, keys)
            val (changes, result) = action(snapshot.values)
            require(changes.keys.all { it in keys }) { "Persistence transaction changed an undeclared key" }
            checkActive()
            if (changes.isEmpty()) return result
            if (adapter.compareAndSet(owner, snapshot.revision, changes)) {
                checkActive()
                return result
            }
        }
        throw RulePersistenceException("Persistent owner changed repeatedly; retry the operation")
    }
    internal fun put(key: String, value: ByteArray?) = update(setOf(key)) { mapOf(key to value) to Unit }
}

internal inline fun <T> decodePersistent(description: String, block: () -> T): T = try { block() }
catch (error: Exception) { rethrowRuleControlFailure(error); throw RulePersistenceException("Invalid persistent $description", error) }

/** Concrete production bridge over the existing platform host, not a second App database. */
internal class HostRulePersistenceAdapter(private val dispatch: (String, JsonObject) -> JsonObject) : RulePersistenceAdapter {
    override fun read(owner: String, keys: Set<String>): RulePersistenceSnapshot = decodePersistent("state host snapshot") {
        val request = JsonObject().apply { addProperty("owner", owner); add("keys", GSON.toJsonTree(keys)) }
        val result = dispatch("state.read", request)
        val revision = result["revision"]?.let { java.math.BigDecimal(it.asString).toBigIntegerExact().longValueExact() }
            ?: throw RulePersistenceException("State host omitted revision")
        require(revision >= 0)
        val values = result["values"]?.asJsonObject ?: throw RulePersistenceException("State host omitted values")
        require(values.keySet().all { it in keys }) { "State host returned an unrequested key" }
        RulePersistenceSnapshot(revision, values.entrySet().associate { (key, value) -> key to Base64.getDecoder().decode(value.asString) })
    }
    override fun compareAndSet(owner: String, revision: Long, changes: Map<String, ByteArray?>): Boolean {
        val request = JsonObject().apply {
            addProperty("owner", owner); addProperty("revision", revision)
            add("changes", JsonObject().apply { changes.forEach { (key, value) -> add(key, value?.let { GSON.toJsonTree(Base64.getEncoder().encodeToString(it)) }) } })
        }
        return decodePersistent("state host commit result") {
            val value = dispatch("state.commit", request)["committed"] ?: throw RulePersistenceException("State host omitted committed")
            require(value.isJsonPrimitive && value.asJsonPrimitive.isBoolean)
            value.asBoolean
        }
    }
}

/** Protocol adapter used by an explicitly supplied owner; useful to embed/test any concrete store. */
class RulePersistenceHost(private val adapter: RulePersistenceAdapter) {
    fun dispatch(operation: String, request: JsonObject): JsonObject {
        val owner = request["owner"].asString
        return when (operation) {
            "state.read" -> {
                val keys = request["keys"].asJsonArray.map { it.asString }.toSet()
                val snapshot = adapter.read(owner, keys)
                JsonObject().apply {
                    addProperty("revision", snapshot.revision)
                    add("values", JsonObject().apply { snapshot.values.forEach { (key, value) -> addProperty(key, Base64.getEncoder().encodeToString(value)) } })
                }
            }
            "state.commit" -> {
                val changes = request["changes"].asJsonObject.entrySet().associate { (key, value) -> key to if (value.isJsonNull) null else Base64.getDecoder().decode(value.asString) }
                JsonObject().apply { addProperty("committed", adapter.compareAndSet(owner, request["revision"].asLong, changes)) }
            }
            else -> unsupportedRule("Unknown state owner operation: $operation")
        }
    }
}
