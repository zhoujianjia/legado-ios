package io.yuedu.legado

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets.UTF_8
import java.util.Base64
import java.util.Locale

/** Ordered, non-lossy host boundary; the entries are the request actually dispatched. */
internal data class LegadoHttpHeader(val name: String, val value: String)

/**
 * Finite port of AnalyzeUrl's String POST body selection, HttpHelper's common
 * interceptor, and OkHttp 5.4.0 RequestBody/BridgeInterceptor header processing.
 * It is request preparation, not a replacement for the original OkHttp transport:
 * redirects, gzip decoding, TLS, retry and connection pooling still belong there.
 * The Android AppConfig default User-Agent is not synthesized on this boundary;
 * an explicit User-Agent is kept. Its "null" sentinel removes it in HttpHelper,
 * after which OkHttp's BridgeInterceptor inserts its own versioned User-Agent.
 */
internal object LegadoHttpRequestPreprocessor {
    fun prepare(url: String, method: String, authored: Map<String, String>, body: String?, charset: String?): JsonObject {
        val headers = authored.map {
            LegadoHttpHeader(it.key, it.value).also(::validateHeader).let { header -> header.copy(value = header.value.trim()) }
        }.toMutableList()
        val actualMethod = when (method.uppercase(Locale.ROOT)) { "POST" -> "POST"; "HEAD" -> "HEAD"; else -> "GET" }
        val preparedBody = if (actualMethod == "POST") prepareBody(body, authored["Content-Type"], charset) else null

        // HttpHelper.kt:71-82 uses addHeader, not header/set: an authored
        // Connection: close must remain before the additional Keep-Alive value.
        val removeUserAgent = headers.lastOrNull { it.name.equals("User-Agent", true) }?.value == "null"
        if (removeUserAgent)
            headers.removeAll { it.name.equals("User-Agent", true) }
        headers += LegadoHttpHeader("Keep-Alive", "300")
        headers += LegadoHttpHeader("Connection", "Keep-Alive")
        headers += LegadoHttpHeader("Cache-Control", "no-cache")

        // BridgeInterceptor replaces body-derived headers, case insensitively.
        preparedBody?.let {
            set(headers, "Content-Type", it.contentType)
            set(headers, "Content-Length", it.bytes.size.toString())
            headers.removeAll { entry -> entry.name.equals("Transfer-Encoding", true) }
        }
        if (headers.none { it.name.equals("Host", true) }) headers += LegadoHttpHeader("Host", authority(url))
        if (headers.none { it.name.equals("Accept-Encoding", true) || it.name.equals("Range", true) })
            headers += LegadoHttpHeader("Accept-Encoding", "gzip")
        if (removeUserAgent) headers += LegadoHttpHeader("User-Agent", "okhttp/5.4.0")

        return jsonObject("url" to url, "method" to actualMethod,
            "headers" to JsonArray().apply { headers.forEach { add(jsonObject("name" to it.name, "value" to it.value)) } },
            "body" to preparedBody?.text,
            "bodyBase64" to preparedBody?.let { Base64.getEncoder().encodeToString(it.bytes) })
    }

    private data class Body(val text: String, val bytes: ByteArray, val contentType: String)

    private fun prepareBody(body: String?, contentType: String?, charset: String?): Body {
        // AnalyzeUrl.kt:302-306, 524-532; OkHttpUtils.kt:138-142/194-197.
        val trimmed = body?.trim().orEmpty()
        val structured = (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
            (trimmed.startsWith('[') && trimmed.endsWith(']')) ||
            (trimmed.startsWith('<') && trimmed.endsWith('>'))
        val encodedForm = if (body != null && !structured && contentType.isNullOrEmpty()) encodeForm(body, charset) else null
        val (text, mediaType) = when {
            !encodedForm.isNullOrEmpty() || body.isNullOrBlank() -> encodedForm.orEmpty() to "application/x-www-form-urlencoded"
            !contentType.isNullOrBlank() -> body to contentType
            else -> body to "application/json; charset=UTF-8"
        }
        val declaredCharset = mediaTypeCharset(mediaType)
        // OkHttp's MediaType.charset() returns null for unsupported encodings;
        // String.toRequestBody then selects UTF-8 and appends the charset token.
        val encoding = declaredCharset?.let { runCatching { Charset.forName(it) }.getOrNull() }
        val finalType = if (encoding == null) "$mediaType; charset=utf-8" else mediaType
        return Body(text, text.toByteArray(encoding ?: UTF_8), finalType)
    }

    private fun encodeForm(text: String, charset: String?): String = text.split('&').joinToString("&") { field ->
        val equals = field.indexOf('=')
        fun encode(part: String): String = if (charset.isNullOrEmpty() && alreadyEncodedForm(part)) part
            else URLEncoder.encode(part, charset?.takeIf { it.isNotEmpty() }?.let(Charset::forName) ?: UTF_8)
        if (equals < 0) encode(field) else encode(field.substring(0, equals)) + "=" + encode(field.substring(equals + 1))
    }

    private fun alreadyEncodedForm(value: String): Boolean {
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char in 'a'..'z' || char in 'A'..'Z' || char in '0'..'9' || char in "*-._") index++
            else if (char == '%' && index + 2 < value.length && value[index + 1] in "0123456789abcdefABCDEF" &&
                value[index + 2] in "0123456789abcdefABCDEF") index += 3
            else return false
        }
        return true
    }

    private const val TOKEN = "[A-Za-z0-9!#$%&'*+.^_`{|}~-]+"
    private val mediaHead = Regex("$TOKEN/$TOKEN")
    private val mediaParameter = Regex(";\\s*(?:($TOKEN)=(?:($TOKEN)|\"([^\"]*)\"))?")

    private fun mediaTypeCharset(value: String): String? {
        val head = mediaHead.matchAt(value, 0) ?: throw IllegalArgumentException("Invalid HTTP Content-Type: $value")
        var offset = head.range.last + 1
        var charset: String? = null
        while (offset < value.length) {
            val parameter = mediaParameter.matchAt(value, offset)
                ?: throw IllegalArgumentException("Invalid HTTP Content-Type parameter: $value")
            if (charset == null && parameter.groupValues[1].equals("charset", true)) {
                val raw = parameter.groups[2]?.value ?: parameter.groupValues[3]
                charset = if (raw.length > 2 && raw.startsWith('\'') && raw.endsWith('\'')) raw.substring(1, raw.length - 1) else raw
            }
            offset = parameter.range.last + 1
        }
        return charset
    }

    private fun set(headers: MutableList<LegadoHttpHeader>, name: String, value: String) {
        headers.removeAll { it.name.equals(name, true) }
        headers += LegadoHttpHeader(name, value)
    }

    private fun authority(url: String): String {
        val uri = URI(url)
        val rawHost = requireNotNull(uri.host) { "HTTP URL has no host" }
        val host = if (':' in rawHost && !rawHost.startsWith('[')) "[$rawHost]" else rawHost
        val defaultPort = if (uri.scheme.equals("https", true)) 443 else 80
        return host + if (uri.port >= 0 && uri.port != defaultPort) ":${uri.port}" else ""
    }

    private fun validateHeader(header: LegadoHttpHeader) {
        require(Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+").matches(header.name)) { "Invalid HTTP header name" }
        require(header.value.all { it == '\t' || it.code in 32..126 }) { "Invalid HTTP header value for ${header.name}" }
    }
}
