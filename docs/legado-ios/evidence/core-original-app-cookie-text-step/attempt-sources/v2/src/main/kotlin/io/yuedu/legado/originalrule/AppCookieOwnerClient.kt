package io.yuedu.legado.originalrule

import com.google.gson.JsonObject
import io.yuedu.legado.RuntimeFailure
import io.yuedu.legado.RuntimeTask
import io.yuedu.legado.ensureActiveForRuntime
import io.yuedu.legado.jsonObject
import kotlinx.coroutines.CancellationException
import okhttp3.Cookie
import okhttp3.Response

/** Explicit App-owner text operations on the existing host, never a Java jar
 * imported from an unknown WK snapshot. Read-only and default modes keep their
 * contracts. Text mode sends known original OkHttp response properties directly
 * to the same native owner before following a redirect or returning a response.
 */
internal class AppCookieOwnerClient(private val task: RuntimeTask,
    private val dispatch: (RuntimeTask, String, JsonObject) -> JsonObject) {
    fun getCookie(url: String, key: String? = null): String {
        var raw = if (task.session.options.writesAppCookieOwner) text("get", url)["cookie"]?.let(::cookieText)
            ?: throw RulePersistenceException("App Cookie text owner omitted its result") else read("getCookie", url)
        if (!task.session.options.writesAppCookieOwner && raw.length > 4096)
            unsupportedRule("CookieStore.getCookie random 4096-character pruning is not connected to the read-only App owner")
        val values = cookieMap(raw)
        while (raw.length > 4096) {
            task.ensureActiveForRuntime()
            val removed = values.keys.random()
            mutate("removeKey", url, removed)
            values.remove(removed)
            raw = cookieString(values)
        }
        if (key == null) return raw
        if (task.session.options.writesAppCookieOwner) {
            // Original getKey additionally looks up the session cache using the
            // unmodified URL argument, after getCookie's normalized domain read.
            val session = text("session", url).get("cookie")?.let(::cookieText)
                ?: throw RulePersistenceException("App Cookie owner omitted session text")
            values.putAll(cookieMap(session))
        }
        return values[key].orEmpty()
    }

    private fun cookieMap(raw: String): LinkedHashMap<String, String> {
        // Original CookieStore.cookieToMap: split the first '=', ignore blank
        // values, ASCII trim, later duplicate wins. Do not parse rich attributes.
        val values = linkedMapOf<String, String>()
        raw.split(';').forEach { pair ->
            val parts = pair.split('=', limit = 2)
            if (parts.size == 2 && parts[1].isNotBlank()) values[parts[0].trim { it <= ' ' }] = parts[1].trim { it <= ' ' }
        }
        return values
    }

    private fun cookieString(values: Map<String, String>): String = values.entries.joinToString("; ") { "${it.key}=${it.value}" }

    fun requestHeader(url: String): String = if (task.session.options.writesAppCookieOwner) getCookie(url) else read("requestHeader", url)

    fun mutate(action: String, url: String, value: String? = null) {
        if (!task.session.options.writesAppCookieOwner) unsupportedRule("Cookie text mutation requires explicit app-owner-text mode")
        require(action in setOf("set", "replace", "remove", "removeKey"))
        if (action == "replace" && (url.isEmpty() || value.isNullOrEmpty())) return
        val result = text(action, url, value)
        if (result["committed"]?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean }?.asBoolean != true)
            throw RulePersistenceException("The App Cookie owner did not acknowledge its mutation")
    }

    fun saveResponse(response: Response) {
        if (!task.session.options.writesAppCookieOwner) unsupportedRule("Response Cookie ingestion requires explicit app-owner-text mode")
        val headers = response.headers.values("Set-Cookie")
        if (headers.isEmpty()) return
        if (headers.size > 256 || headers.sumOf { it.toByteArray(Charsets.UTF_8).size } > 65536)
            unsupportedRule("Response Cookie headers exceed the App owner byte budget")
        // Exactly the parser used by locked original CookieManager.kt:43.
        val cookies = Cookie.parseAll(response.request.url, response.headers)
        if (cookies.isEmpty()) return
        val acceptedHeaders = headers.filter { Cookie.parse(response.request.url, it) != null }
        check(acceptedHeaders.size == cookies.size) { "Original Cookie parser header association changed" }
        val input = input(response.request.url.toString()).apply {
            addProperty("action", "response")
            add("headers", GSON.toJsonTree(headers))
            add("cookies", GSON.toJsonTree(cookies.mapIndexed { index, cookie -> mapOf(
                "name" to cookie.name, "value" to cookie.value, "domain" to cookie.domain, "path" to cookie.path,
                "expiresAtMs" to cookie.expiresAt, "secure" to cookie.secure, "httpOnly" to cookie.httpOnly,
                "hostOnly" to cookie.hostOnly, "persistent" to cookie.persistent,
                "setCookieHeader" to acceptedHeaders[index]) }))
            addProperty("persistentText", cookies.filter { it.persistent }.joinToString("; ") { "${it.name}=${it.value}" })
            addProperty("sessionText", cookies.filter { !it.persistent }.joinToString("; ") { "${it.name}=${it.value}" })
        }
        val result = call("cookie.owner.text", input)
        if (result["committed"]?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean }?.asBoolean != true)
            throw RulePersistenceException("The App Cookie owner did not acknowledge the HTTP response")
    }

    private fun text(action: String, url: String, value: String? = null): JsonObject = call("cookie.owner.text", input(url).apply {
        addProperty("action", action)
        value?.let {
            require(it.toByteArray(Charsets.UTF_8).size <= 65536) { "Cookie text exceeds its byte budget" }
            addProperty("cookie", it)
        }
    })

    private fun input(url: String): JsonObject {
        require(url.toByteArray(Charsets.UTF_8).size <= 8192) { "Cookie URL exceeds its byte budget" }
        return jsonObject("owner" to requireNotNull(task.session.options.stateOwner), "url" to url,
            "domain" to NetworkUtils.getSubDomain(url))
    }

    private fun read(purpose: String, url: String): String {
        task.ensureActiveForRuntime()
        if (task.session.closed.get()) throw CancellationException("Cookie owner session is closed")
        return cookieText(call("cookie.owner.read", input(url).apply { addProperty("purpose", purpose) })["cookie"]
            ?: throw RulePersistenceException("App Cookie owner omitted its text result"))
    }

    private fun call(operation: String, input: JsonObject): JsonObject {
        task.ensureActiveForRuntime()
        if (task.session.closed.get()) throw CancellationException("Cookie owner session is closed")
        val result = try { dispatch(task, operation, input) }
        catch (error: CancellationException) { throw error }
        catch (error: RuntimeFailure) {
            if (error.code in setOf("UNSUPPORTED_CAPABILITY", "unsupported_host")) throw UnsupportedRuleCapability(error.message.orEmpty())
            throw RulePersistenceException("App Cookie owner operation failed", error)
        }
        catch (error: Exception) { throw RulePersistenceException("App Cookie owner operation failed", error) }
        task.ensureActiveForRuntime()
        if (task.session.closed.get()) throw CancellationException("Cookie owner session is closed")
        return result
    }

    private fun cookieText(cookie: com.google.gson.JsonElement): String {
        if (!cookie.isJsonPrimitive || !cookie.asJsonPrimitive.isString) throw RulePersistenceException("App Cookie owner returned non-text data")
        return cookie.asString.also { if (it.toByteArray(Charsets.UTF_8).size > 65536) throw RulePersistenceException("App Cookie result exceeds its byte budget") }
    }
}
