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
    private val http = RuntimeHttpRequestExecutor(task, dispatch)
    internal var batchUrls: Set<String>? = null
    internal val savedUrls = linkedSetOf<String>()

    fun getSource() = SourceHost(task.session)
    fun getTag(): String = task.session.source["bookSourceName"]?.asString.orEmpty()
    fun put(key: String, value: String): String = getSource().put(key, value)
    fun get(key: String): String = getSource().get(key)

    fun ajax(url: Any): String = ajax(url, null)
    fun ajax(url: Any, callTimeout: Long?): String = request(if (url is List<*>) url.firstOrNull().toString() else url.toString(), null, callTimeout).body()
    fun connect(url: String): StrResponse = request(url, null, null)
    fun connect(url: String, headers: String?): StrResponse = request(url, headers, null)
    fun connect(url: String, headers: String?, callTimeout: Long?): StrResponse = request(url, headers, callTimeout)
    fun get(url: String, headers: Any?): StrResponse = get(url, headers, null)
    fun get(url: String, headers: Any?, timeout: Int?): StrResponse {
        if (task.session.options.usesJvmHttp) unsupported("java.get requires the original Jsoup Connection.Response API")
        return request(url, headers?.toString(), timeout?.toLong())
    }
    fun head(url: String, headers: Any?): Nothing = unsupported("java.head is not migrated")
    fun head(url: String, headers: Any?, timeout: Int?): Nothing = unsupported("java.head is not migrated")
    fun post(url: String, body: String, headers: Any?): Nothing = unsupported("java.post is not migrated")
    fun post(url: String, body: String, headers: Any?, timeout: Int?): Nothing = unsupported("java.post is not migrated")
    fun getCookie(url: String): String = task.session.cookies.persistent(task.persistence) { task.session.cookies.getCookie(url) }
    fun getCookie(url: String, key: String?): String = if (key == null) getCookie(url) else task.session.cookies.persistent(task.persistence) { task.session.cookies.getKey(url, key) }

    private fun request(rawUrl: String, headersJson: String?, timeoutMs: Long?): StrResponse {
        task.ensureActiveForRuntime()
        var url = rawUrl
        var options = JsonObject()
        val production = task.session.options.usesJvmHttp
        if (production && listOf("@js:", "<js>", "{{").any { rawUrl.contains(it, true) }) unsupported("Dynamic URL rules are not migrated")
        val delimiter = if (production) Regex("\\s*,\\s*(?=\\{)").find(rawUrl) else null
        val optionsAt = if (production) delimiter?.range?.first ?: -1 else rawUrl.indexOf(",{")
        if (optionsAt >= 0) {
            url = rawUrl.substring(0, optionsAt)
            options = parseObject(rawUrl.substring(if (production) delimiter!!.range.last + 1 else optionsAt + 1))
        }
        if (production) {
            val allowed = setOf("method", "headers", "body", "charset", "timeout", "followRedirects", "retry")
            options.keySet().firstOrNull { it !in allowed }?.let { unsupported("URL option '$it' is not migrated") }
        }
        val base = task.session.source["bookSourceUrl"]?.asString.orEmpty()
        val resolved = URI(base).resolve(url).toString()
        require(URI(resolved).scheme in setOf("http", "https")) { "Only HTTP(S) requests are supported" }
        val headers = linkedMapOf<String, String>()
        fun mergeHeaders(value: com.google.gson.JsonElement?) {
            if (value == null || value.isJsonNull) return
            if (production && value.isJsonPrimitive && listOf("@js:", "<js>", "{{").any { value.asString.contains(it, true) })
                unsupported("Dynamic source headers are not migrated")
            val objectValue = if (value.isJsonPrimitive) parseObject(value.asString) else value.asJsonObject
            objectValue.entrySet().forEach { (key, item) -> headers[key] = item.asString }
        }
        if (production && !headersJson.isNullOrBlank()) {
            // AnalyzeUrl's non-null headerMapF replaces source/login defaults;
            // URL-option headers are applied subsequently by analyzeUrl().
            mergeHeaders(JsonParser.parseString(headersJson))
        } else {
            mergeHeaders(task.session.source["header"])
            if (!production || ProductionHttpTransport.sameLoginSite(base, resolved))
                getSource().getLoginHeader()?.let { mergeHeaders(JsonParser.parseString(it)) }
        }
        mergeHeaders(options["headers"])
        if (!production && !headersJson.isNullOrBlank()) mergeHeaders(JsonParser.parseString(headersJson))
        if (production && headers.keys.any { it.equals("proxy", true) }) unsupported("Source proxy configuration is not migrated")
        if (production && headers.keys.none { it.equals("User-Agent", true) })
            task.session.options.userAgent?.let { headers["User-Agent"] = it }
        val cookie = task.session.cookies.persistent(task.persistence) { task.session.cookies.getCookie(resolved) }
        val networkCookieJar = production && task.session.source["enabledCookieJar"]?.asBoolean == true
        if (!networkCookieJar && cookie.isNotEmpty() && headers.keys.none { it.equals("Cookie", true) }) headers["Cookie"] = cookie
        val method = options["method"]?.asString?.uppercase() ?: "GET"
        val body = options["body"]?.asString
        val charset = options["charset"]?.asString ?: "UTF-8"
        val request = LegadoHttpRequestPreprocessor.prepare(resolved, method, headers, body,
            options["charset"]?.asString, materializeBridgeHeaders = !production).apply {
                addProperty("timeoutMs", timeoutMs ?: if (production) 60_000L else 30_000L)
                if (production) {
                    options["timeout"]?.asLong?.let { require(it >= 0); addProperty("readTimeoutMs", it) }
                    options["retry"]?.asInt?.let { require(it >= 0); addProperty("retry", it) }
                    options["followRedirects"]?.let {
                        require(it.isJsonPrimitive && it.asJsonPrimitive.isBoolean) { "followRedirects must be a boolean" }
                        addProperty("followRedirects", it.asBoolean)
                    }
                }
            }
        return http.execute(request, charset)
    }

    fun webView(html: String?, url: String?, js: String?): String? = webView(html, url, js, false)
    fun webView(html: String?, url: String?, js: String?, cacheFirst: Boolean): String? =
        dispatch(task, "browser.open", jsonObject("html" to html, "url" to url, "js" to js,
            "cacheFirst" to cacheFirst))["body"]?.takeUnless { it.isJsonNull }?.asString

    private fun unsupported(message: String): Nothing = throw RuntimeFailure("UNSUPPORTED_CAPABILITY", message)

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
    private val actualRaw: okhttp3.Response? = null,
) {
    fun url(): String = responseUrl
    fun body(): String = text
    fun code(): Int = status
    fun statusCode(): Int = status
    fun header(name: String): String? = actualRaw?.header(name) ?: responseHeaders.entries.firstOrNull { it.key.equals(name, true) }?.value
    fun headers(): Any = actualRaw?.headers ?: responseHeaders
    fun raw(): okhttp3.Response = actualRaw ?: throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "No JVM raw response exists for this platform/error response")
    fun message(): String = actualRaw?.message ?: throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "No JVM response message exists for this platform/error response")
    fun isSuccessful(): Boolean = status in 200..299
}

class SourceHost internal constructor(private val session: RuntimeSession) {
    private val original get() = if (session.options.stateOwner != null) session.persistenceTask().persistentSource else null
    fun getKey(): String = session.source["bookSourceUrl"]?.asString.orEmpty()
    fun getTag(): String = session.source["bookSourceName"]?.asString.orEmpty()
    val bookSourceUrl: String get() = getKey()
    val bookSourceName: String get() = getTag()
    fun put(key: String, value: String): String { ensureOpen(); original?.let { return it.put(key, value) }; session.variables[key] = value; return value }
    fun get(key: String): String = original?.get(key) ?: session.variables[key].orEmpty()
    fun putVariable(value: String?) { ensureOpen(); original?.let { it.putVariable(value); return }; if (value == null) session.variables.remove("@variable") else session.variables["@variable"] = value }
    fun setVariable(value: String?) = putVariable(value)
    fun getVariable(): String = original?.getVariable() ?: session.variables["@variable"].orEmpty()
    fun putLoginInfo(value: String): Boolean { original?.putLoginInfo(value); put("@loginInfo", value); return true }
    fun getLoginInfo(): String? { original?.getLoginInfo(); return session.variables["@loginInfo"] }
    fun putLoginHeader(value: String) {
        original?.let { it.putLoginHeader(value); return }
        val headers = parseObject(value)
        headers.entrySet().firstOrNull { it.key.equals("Cookie", true) }?.let {
            session.cookies.replaceCookie(getKey(), it.value.asString)
        }
        put("@loginHeader", value)
    }
    fun getLoginHeader(): String? { val source = original; return if (source != null) source.getLoginHeader() else session.variables["@loginHeader"] }
    private fun ensureOpen() { check(!session.closed.get()) { "Session is closed" } }
}

/** Script facade over the same transport-owned jar with this task's explicit owner access. */
class TaskCookieHost internal constructor(private val session: RuntimeSession) {
    private val task get() = session.persistenceTask()
    fun setCookie(url: String, value: String) = task.session.cookies.persistent(task.persistence, true) { task.session.cookies.setCookie(url, value) }
    fun replaceCookie(url: String, value: String) = task.session.cookies.persistent(task.persistence, true) { task.session.cookies.replaceCookie(url, value) }
    fun removeCookie(url: String) = task.session.cookies.persistent(task.persistence, true) { task.session.cookies.removeCookie(url) }
    fun getCookie(url: String): String = task.session.cookies.persistent(task.persistence) { task.session.cookies.getCookie(url) }
    fun getKey(url: String, key: String): String = task.session.cookies.persistent(task.persistence) { task.session.cookies.getKey(url, key) }
}

/** Invocation lookup keeps retained global closures from capturing a completed task or owner lease. */
class PersistentCacheHost internal constructor(private val session: RuntimeSession) {
    private val cache get() = requireNotNull(session.persistenceTask().persistentEnvironment).cache
    @JvmOverloads fun put(key: String, value: Any, saveTime: Int = 0) = cache.put(key, value, saveTime)
    @JvmOverloads fun get(key: String, onlyDisk: Boolean = false) = cache.get(key, onlyDisk)
    fun delete(key: String) = cache.delete(key)
    fun putMemory(key: String, value: Any) = cache.putMemory(key, value)
    fun getFromMemory(key: String): Any? = cache.getFromMemory(key)
    fun deleteMemory(key: String) = cache.deleteMemory(key)
    fun getInt(key: String) = cache.getInt(key)
    fun getLong(key: String) = cache.getLong(key)
    fun getDouble(key: String) = cache.getDouble(key)
    fun getFloat(key: String) = cache.getFloat(key)
    fun getByteArray(key: String) = cache.getByteArray(key)
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
    private var manager = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)
    private var origins = java.util.IdentityHashMap<HttpCookie, String>()
    private var expirations = java.util.IdentityHashMap<HttpCookie, Long>()
    private data class StoredCookie(val origin: String, val name: String, val value: String, val domain: String?, val path: String?,
                                    val expiresAt: Long?, val secure: Boolean, val httpOnly: Boolean, val version: Int,
                                    val discard: Boolean, val portList: String?, val comment: String?, val commentURL: String?)
    /** One jar, restored and committed through the explicitly supplied owner. No second transport jar. */
    internal @Synchronized fun <T> persistent(store: io.yuedu.legado.originalrule.RulePersistenceBinding?, write: Boolean = false,
                                             extraChanges: Map<String, ByteArray?> = emptyMap(), action: () -> T): T {
        if (store == null) return action()
        val oldManager = manager; val oldOrigins = origins; val oldExpirations = expirations
        val key = store.key("cookies")
        try {
            return if (write) store.update(setOf(key) + extraChanges.keys) { prior ->
                restore(prior[key])
                val result = action()
                (mapOf(key to encodeCookies()) + extraChanges) to result
            } else {
                restore(store.read(key)); action()
            }
        } catch (error: Exception) {
            manager = oldManager; origins = oldOrigins; expirations = oldExpirations
            throw error
        }
    }
    private fun restore(bytes: ByteArray?) = io.yuedu.legado.originalrule.decodePersistent("cookies") {
        val next = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)
        val nextOrigins = java.util.IdentityHashMap<HttpCookie, String>(); val nextExpirations = java.util.IdentityHashMap<HttpCookie, Long>()
        val now = System.currentTimeMillis()
        val entries = bytes?.let { gson.fromJson(it.toString(Charsets.UTF_8), Array<StoredCookie>::class.java).toList() }.orEmpty()
        entries.forEach { entry ->
            if (entry.expiresAt != null && entry.expiresAt <= now) return@forEach
            val origin = ruleCookieUri(entry.origin)
            val cookie = HttpCookie(entry.name, entry.value).apply {
                domain = entry.domain; path = entry.path; secure = entry.secure; isHttpOnly = entry.httpOnly; version = entry.version
                discard = entry.discard; portlist = entry.portList; comment = entry.comment; commentURL = entry.commentURL
                maxAge = entry.expiresAt?.let { ((it - now + 999) / 1000).coerceAtLeast(1) } ?: -1
            }
            next.cookieStore.add(origin, cookie); nextOrigins[cookie] = entry.origin
            entry.expiresAt?.let { nextExpirations[cookie] = it }
        }
        manager = next; origins = nextOrigins; expirations = nextExpirations
    }
    private fun recordCookies(origin: String, now: Long = System.currentTimeMillis()) {
        manager.cookieStore.cookies.forEach { cookie ->
            if (!origins.containsKey(cookie)) {
                origins[cookie] = origin
                if (cookie.maxAge >= 0) expirations[cookie] = now + cookie.maxAge * 1000
            }
        }
    }
    private fun encodeCookies(): ByteArray = gson.toJson(manager.cookieStore.cookies.filterNot(HttpCookie::hasExpired).map { c ->
        StoredCookie(requireNotNull(origins[c]), c.name, c.value, c.domain, c.path, expirations[c], c.secure, c.isHttpOnly, c.version,
            c.discard, c.portlist, c.comment, c.commentURL)
    }).toByteArray(Charsets.UTF_8)
    @Synchronized fun setCookie(url: String, value: String) {
        val now = System.currentTimeMillis()
        manager.put(URI(url), mapOf("Set-Cookie" to listOf(value)))
        recordCookies(url, now)
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

    /**
     * Original CookieStore's text operations use this same transport-owned jar.
     * setCookie replaces text, whereas replaceCookie merges named values. These
     * methods do not change the existing mainJs/HTTP Set-Cookie API above.
     *
     * Scope remains the existing URL/domain/path-aware in-memory CookieManager,
     * not Android's registrable-domain Room/session/WebView store. In particular,
     * a merge preserves every existing cookie's security/path/expiry attributes.
     */
    internal @Synchronized fun setRuleCookie(url: String, value: String) {
        val uri = ruleCookieUri(url)
        val replacements = ruleCookieValues(value).map { (name, text) -> newRuleCookie(name, text) }
        // Parse and validate the complete input before discarding any live state.
        manager.cookieStore.get(uri).forEach { manager.cookieStore.remove(uri, it) }
        replacements.forEach { manager.cookieStore.add(uri, it) }
        recordCookies(url)
    }

    internal @Synchronized fun replaceRuleCookie(url: String, value: String) {
        // CookieStore.replaceCookie treats either empty argument as a no-op.
        if (url.isEmpty() || value.isEmpty()) return
        val uri = ruleCookieUri(url)
        val replacements = ruleCookieValues(value).map { (name, text) -> newRuleCookie(name, text) }
        val existing = manager.cookieStore.get(uri)
        replacements.forEach { replacement ->
            val matching = existing.filter { it.name == replacement.name }
            if (matching.isEmpty()) {
                manager.cookieStore.add(uri, replacement)
            } else {
                // A name may have several paths/domains in the RFC jar. Update
                // each matching value without flattening it into a new root
                // cookie or dropping Secure, HttpOnly or expiration metadata.
                // The sole owned CookieManager returns its stored HttpCookie
                // objects. Only value changes, so name/domain/path index keys
                // and original header ordering remain intact under this lock.
                matching.forEach { it.value = replacement.value }
            }
        }
        recordCookies(url)
    }

    internal @Synchronized fun getRuleCookie(url: String, key: String? = null): String {
        val uri = ruleCookieUri(url)
        val visible = manager.get(uri, emptyMap()).entries
            .filter { it.key.equals("Cookie", true) }.flatMap { it.value }
        if (key == null) return visible.joinToString("; ")
        // Let CookieManager decide visibility, including paths, ports and
        // Secure. Match its complete per-cookie rendering back to the live
        // value; reparsing an RFC 2965 header would expose $Path/$Version or
        // incorrectly add quotation marks to the caller's logical value.
        val matching = manager.cookieStore.get(uri).filter { it.name == key }.associateBy(HttpCookie::toString)
        return visible.asReversed().firstNotNullOfOrNull { matching[it]?.value }.orEmpty()
    }

    internal @Synchronized fun removeRuleCookie(url: String) {
        ruleCookieUri(url)
        removeCookie(url)
    }

    private fun ruleCookieUri(url: String): URI {
        val uri = try { URI(url) } catch (_: Exception) {
            throw IllegalArgumentException("Original-rule cookies require an absolute HTTP(S) URL")
        }
        require(uri.scheme.equals("http", true) || uri.scheme.equals("https", true)) {
            "Original-rule cookies require an absolute HTTP(S) URL"
        }
        require(!uri.host.isNullOrEmpty()) { "Original-rule cookies require an absolute HTTP(S) URL" }
        return uri
    }

    private fun ruleCookieValues(value: String): Map<String, String> = linkedMapOf<String, String>().apply {
        // CookieStore.cookieToMap: first '=' splits a pair, blank values are
        // ignored, later duplicate keys win and the original key order remains.
        value.split(';').forEach { pair ->
            val split = pair.split('=', limit = 2)
            if (split.size == 2 && split[1].isNotBlank()) put(split[0].trim { it <= ' ' }, split[1].trim { it <= ' ' })
        }
    }

    private fun newRuleCookie(name: String, value: String): HttpCookie {
        require(value.none { it == '\r' || it == '\n' || it == '\u0000' }) { "Invalid original-rule cookie value" }
        return try { HttpCookie(name, value).apply { path = "/"; version = 0 } }
        catch (_: IllegalArgumentException) { throw IllegalArgumentException("Invalid original-rule cookie name") }
    }

    internal @Synchronized fun snapshot(): List<String> = manager.cookieStore.cookies.map(HttpCookie::toString)
    internal @Synchronized fun clear() { manager.cookieStore.removeAll(); origins.clear(); expirations.clear() }
}
