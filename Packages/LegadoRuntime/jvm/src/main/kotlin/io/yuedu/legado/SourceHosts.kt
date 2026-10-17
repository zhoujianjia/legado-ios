package io.yuedu.legado

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.htmlunit.corejs.javascript.Context
import org.htmlunit.corejs.javascript.Wrapper
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpCookie
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

/** Deliberately limited platform adapter, not a replacement for all upstream JsExtensions. */
class SourceJavaHost internal constructor(
    private val task: RuntimeTask,
    private val dispatch: (RuntimeTask, String, JsonObject) -> JsonObject,
) {
    internal var batchUrls: Set<String>? = null
    internal val savedUrls = linkedSetOf<String>()

    fun getSource() = SourceHost(task.session)
    fun getTag(): String = task.session.source["bookSourceName"]?.asString.orEmpty()
    fun put(key: String, value: String): String = getSource().put(key, value)
    fun get(key: String): String = getSource().get(key)

    fun ajax(url: Any): String = ajax(url, null)
    fun ajax(url: Any, callTimeout: Long?): String = request(url.toString(), null, callTimeout).body()
    fun connect(url: String): StrResponse = request(url, null, null)
    fun connect(url: String, headers: String?): StrResponse = request(url, headers, null)
    fun connect(url: String, headers: String?, callTimeout: Long?): StrResponse = request(url, headers, callTimeout)
    fun get(url: String, headers: Any?): StrResponse = request(url, headers?.toString(), null)
    fun get(url: String, headers: Any?, timeout: Int?): StrResponse = request(url, headers?.toString(), timeout?.toLong())
    fun getCookie(url: String): String = task.session.cookies.getCookie(url)
    fun getCookie(url: String, key: String?): String = if (key == null) getCookie(url) else task.session.cookies.getKey(url, key)

    private fun request(rawUrl: String, headersJson: String?, timeoutMs: Long?): StrResponse {
        task.job.ensureActiveForRuntime()
        var url = rawUrl
        var options = JsonObject()
        val optionsAt = rawUrl.indexOf(",{")
        if (optionsAt >= 0) {
            url = rawUrl.substring(0, optionsAt)
            options = parseObject(rawUrl.substring(optionsAt + 1))
        }
        val base = task.session.source["bookSourceUrl"]?.asString.orEmpty()
        val resolved = URI(base).resolve(url).toString()
        require(URI(resolved).scheme in setOf("http", "https")) { "Only HTTP(S) requests are supported" }
        val headers = linkedMapOf<String, String>()
        fun mergeHeaders(value: com.google.gson.JsonElement?) {
            if (value == null || value.isJsonNull) return
            val objectValue = if (value.isJsonPrimitive) parseObject(value.asString) else value.asJsonObject
            objectValue.entrySet().forEach { (key, item) -> headers[key] = item.asString }
        }
        mergeHeaders(task.session.source["header"])
        task.session.variables["@loginHeader"]?.let { mergeHeaders(JsonParser.parseString(it)) }
        mergeHeaders(options["headers"])
        if (!headersJson.isNullOrBlank()) mergeHeaders(JsonParser.parseString(headersJson))
        val cookie = task.session.cookies.getCookie(resolved)
        if (cookie.isNotEmpty() && headers.keys.none { it.equals("Cookie", true) }) headers["Cookie"] = cookie
        val method = options["method"]?.asString?.uppercase() ?: "GET"
        val body = options["body"]?.asString
        val charset = options["charset"]?.asString ?: "UTF-8"
        val request = LegadoHttpRequestPreprocessor.prepare(resolved, method, headers, body,
            options["charset"]?.asString).apply { addProperty("timeoutMs", timeoutMs ?: 30_000L) }
        val response = dispatch(task, "http.request", request)
        val responseUrl = response["url"]?.asString ?: resolved
        val responseHeaders = linkedMapOf<String, String>()
        response["headers"]?.asJsonObject?.entrySet()?.forEach { (name, value) ->
            val values = if (value.isJsonArray) value.asJsonArray.map { it.asString } else listOf(value.asString)
            responseHeaders[name] = values.joinToString(", ")
            if (name.equals("Set-Cookie", true)) values.forEach { task.session.cookies.setCookie(responseUrl, it) }
        }
        val contentType = responseHeaders.entries.firstOrNull { it.key.equals("Content-Type", true) }?.value.orEmpty()
        val responseCharset = Regex("charset\\s*=\\s*[\"']?([^;\\s\"']+)", RegexOption.IGNORE_CASE)
            .find(contentType)?.groupValues?.get(1) ?: charset
        val text = when {
            response.has("bodyBase64") && !response["bodyBase64"].isJsonNull -> String(Base64.getDecoder().decode(response["bodyBase64"].asString), Charset.forName(responseCharset))
            response.has("body") && !response["body"].isJsonNull -> response["body"].asString
            else -> ""
        }
        return StrResponse(responseUrl, response["status"]?.asInt ?: 200, text, responseHeaders)
    }

    fun webView(html: String?, url: String?, js: String?): String? = webView(html, url, js, false)
    fun webView(html: String?, url: String?, js: String?, cacheFirst: Boolean): String? =
        dispatch(task, "browser.open", jsonObject("html" to html, "url" to url, "js" to js,
            "cacheFirst" to cacheFirst))["body"]?.takeUnless { it.isJsonNull }?.asString

    fun cacheContent(chapter: Any?, content: String): Boolean {
        task.job.ensureActiveForRuntime()
        val allowed = batchUrls ?: throw IllegalStateException("java.cacheContent is only available during batch content")
        val value = if (chapter is Wrapper) chapter.unwrap() else chapter
        val url = when (value) {
            is String -> value
            is org.htmlunit.corejs.javascript.Scriptable -> {
                var property = org.htmlunit.corejs.javascript.ScriptableObject.getProperty(value, "url")
                if (property === org.htmlunit.corejs.javascript.Scriptable.NOT_FOUND)
                    property = org.htmlunit.corejs.javascript.ScriptableObject.getProperty(value, "chapterUrl")
                if (property === org.htmlunit.corejs.javascript.Scriptable.NOT_FOUND) "" else Context.toString(property)
            }
            is Map<*, *> -> (value["url"] ?: value["chapterUrl"])?.toString().orEmpty()
            else -> ""
        }
        require(url in allowed) { "Chapter is outside the current batch" }
        task.session.contents[url] = content
        savedUrls += url
        return true
    }

    fun base64Encode(value: String): String = Base64.getEncoder().encodeToString(value.toByteArray(StandardCharsets.UTF_8))
    fun base64Decode(value: String): String = base64Decode(value, "UTF-8")
    fun base64Decode(value: String, charset: String): String = String(Base64.getDecoder().decode(value), Charset.forName(charset))
    fun base64DecodeToByteArray(value: String): ByteArray = Base64.getDecoder().decode(value)
    fun md5Encode(value: String): String = MessageDigest.getInstance("MD5").digest(value.toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun encodeURI(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20")
    fun log(value: Any?): Any? { task.job.ensureActiveForRuntime(); return value }
}

class StrResponse internal constructor(
    private val responseUrl: String,
    private val status: Int,
    private val text: String,
    private val responseHeaders: Map<String, String>,
) {
    fun url(): String = responseUrl
    fun body(): String = text
    fun code(): Int = status
    fun statusCode(): Int = status
    fun header(name: String): String? = responseHeaders.entries.firstOrNull { it.key.equals(name, true) }?.value
    fun headers(): Map<String, String> = responseHeaders
}

class SourceHost internal constructor(private val session: RuntimeSession) {
    fun getKey(): String = session.source["bookSourceUrl"]?.asString.orEmpty()
    fun getTag(): String = session.source["bookSourceName"]?.asString.orEmpty()
    val bookSourceUrl: String get() = getKey()
    val bookSourceName: String get() = getTag()
    fun put(key: String, value: String): String { ensureOpen(); session.variables[key] = value; return value }
    fun get(key: String): String = session.variables[key].orEmpty()
    fun putVariable(value: String?) { ensureOpen(); if (value == null) session.variables.remove("@variable") else session.variables["@variable"] = value }
    fun setVariable(value: String?) = putVariable(value)
    fun getVariable(): String = session.variables["@variable"].orEmpty()
    fun putLoginInfo(value: String): Boolean { put("@loginInfo", value); return true }
    fun getLoginInfo(): String? = session.variables["@loginInfo"]
    fun putLoginHeader(value: String) {
        val headers = parseObject(value)
        headers.entrySet().firstOrNull { it.key.equals("Cookie", true) }?.let {
            session.cookies.replaceCookie(getKey(), it.value.asString)
        }
        put("@loginHeader", value)
    }
    fun getLoginHeader(): String? = session.variables["@loginHeader"]
    private fun ensureOpen() { check(!session.closed.get()) { "Session is closed" } }
}

class SessionCache internal constructor() {
    private data class Entry(val value: String, val expires: Long)
    private val entries = ConcurrentHashMap<String, Entry>()
    fun put(key: String, value: String) = put(key, value, 0)
    fun put(key: String, value: String, saveTime: Int) {
        require(saveTime >= 0) { "Cache lifetime must not be negative" }
        entries[key] = Entry(value, if (saveTime == 0) 0 else System.currentTimeMillis() + saveTime * 1000L)
    }
    fun get(key: String): String? {
        val entry = entries[key] ?: return null
        if (entry.expires > 0 && entry.expires <= System.currentTimeMillis()) { entries.remove(key, entry); return null }
        return entry.value
    }
    fun get(key: String, onlyDisk: Boolean): String? {
        if (onlyDisk) throw UnsupportedOperationException("This prototype only has an in-memory cache")
        return get(key)
    }
    fun delete(key: String) { entries.remove(key) }
    internal fun snapshot(): Map<String, String?> = entries.keys.associateWith(::get)
    internal fun clear() = entries.clear()
}

class SessionCookies internal constructor() {
    private val manager = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)
    @Synchronized fun setCookie(url: String, value: String) {
        manager.put(URI(url), mapOf("Set-Cookie" to listOf(value)))
    }
    @Synchronized fun replaceCookie(url: String, value: String) {
        manager.cookieStore.get(URI(url)).forEach { manager.cookieStore.remove(URI(url), it) }
        value.split(';').forEach { pair ->
            val split = pair.trim().split('=', limit = 2)
            if (split.size == 2) setCookie(url, "${split[0]}=${split[1]}; Path=/")
        }
    }
    @Synchronized fun getCookie(url: String): String = manager.get(URI(url), emptyMap()).entries
        .filter { it.key.equals("Cookie", true) }.flatMap { it.value }.joinToString("; ")
    @Synchronized fun getKey(url: String, key: String): String = manager.cookieStore.get(URI(url))
        .firstOrNull { it.name == key && !it.hasExpired() }?.value.orEmpty()
    @Synchronized fun removeCookie(url: String) {
        manager.cookieStore.get(URI(url)).forEach { manager.cookieStore.remove(URI(url), it) }
    }
    internal @Synchronized fun snapshot(): List<String> = manager.cookieStore.cookies.map(HttpCookie::toString)
}
