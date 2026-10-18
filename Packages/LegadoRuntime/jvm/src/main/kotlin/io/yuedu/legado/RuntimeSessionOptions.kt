package io.yuedu.legado

import com.google.gson.JsonObject

/** Embedding configuration, separate from imported book-source data and JS bindings. */
internal data class RuntimeSessionOptions(val httpTransport: String = "platform-host", val userAgent: String? = null) {
    val usesJvmHttp get() = httpTransport == "jvm-okhttp"
    companion object {
        fun parse(options: JsonObject): RuntimeSessionOptions {
            require(options.keySet().all { it in setOf("httpTransport", "userAgent") }) { "Unknown runtime session option" }
            fun string(name: String): String? = options[name]?.let {
                require(it.isJsonPrimitive && it.asJsonPrimitive.isString) { "$name must be a string" }; it.asString
            }
            val mode = string("httpTransport") ?: "platform-host"
            require(mode in setOf("platform-host", "jvm-okhttp")) { "Unknown HTTP transport: $mode" }
            val agent = string("userAgent")
            require(agent == null || agent.isNotBlank() && agent.all { it.code in 32..126 }) { "userAgent must be a nonblank ASCII HTTP value" }
            return RuntimeSessionOptions(mode, agent)
        }
    }
}
