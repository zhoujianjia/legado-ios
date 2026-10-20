package io.yuedu.legado

import com.google.gson.JsonObject

/** Embedding configuration, separate from imported book-source data and JS bindings. */
internal data class RuntimeSessionOptions(val httpTransport: String = "platform-host", val userAgent: String? = null,
                                        val stateOwner: String? = null, val sourceMode: String = "existing") {
    val usesJvmHttp get() = httpTransport == "jvm-okhttp"
    val usesOriginalTraditional get() = sourceMode == "original-traditional"
    companion object {
        fun parse(options: JsonObject): RuntimeSessionOptions {
            require(options.keySet().all { it in setOf("httpTransport", "userAgent", "stateOwner", "sourceMode") }) { "Unknown runtime session option" }
            fun string(name: String): String? = options[name]?.let {
                require(it.isJsonPrimitive && it.asJsonPrimitive.isString) { "$name must be a string" }; it.asString
            }
            val mode = string("httpTransport") ?: "platform-host"
            require(mode in setOf("platform-host", "jvm-okhttp")) { "Unknown HTTP transport: $mode" }
            val agent = string("userAgent")
            require(agent == null || agent.isNotBlank() && agent.all { it.code in 32..126 }) { "userAgent must be a nonblank ASCII HTTP value" }
            val owner = string("stateOwner")
            require(owner == null || owner.isNotBlank()) { "stateOwner must not be blank" }
            val sourceMode = string("sourceMode") ?: "existing"
            require(sourceMode in setOf("existing", "original-traditional")) { "Unknown source mode: $sourceMode" }
            if (sourceMode == "original-traditional" && (mode != "jvm-okhttp" || owner == null))
                throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Original traditional mode requires jvm-okhttp and an embedding stateOwner")
            return RuntimeSessionOptions(mode, agent, owner, sourceMode)
        }
    }
}
