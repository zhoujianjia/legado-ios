package io.yuedu.legado.originalrule

import com.google.gson.JsonObject
import io.yuedu.legado.RuntimeFailure
import io.yuedu.legado.RuntimeTask
import io.yuedu.legado.ensureActiveForRuntime
import io.yuedu.legado.jsonObject
import kotlinx.coroutines.CancellationException

/** Explicit, finite App-owner read seam. It never reconstructs a Java cookie or
 * restores an unknown WK property into the session RFC jar. Default jar mode is
 * unchanged. Original text writes and enabledCookieJar still fail before HTTP.
 */
internal class AppCookieOwnerClient(private val task: RuntimeTask,
    private val dispatch: (RuntimeTask, String, JsonObject) -> JsonObject) {
    fun getCookie(url: String, key: String? = null): String {
        val raw = read("getCookie", url)
        if (raw.length > 4096) unsupportedRule("CookieStore.getCookie random 4096-character pruning is not connected to the App owner")
        if (key == null) return raw
        // Original CookieStore.cookieToMap: split the first '=', ignore blank
        // values, ASCII trim, later duplicate wins. Do not parse rich attributes.
        val values = linkedMapOf<String, String>()
        raw.split(';').forEach { pair ->
            val parts = pair.split('=', limit = 2)
            if (parts.size == 2 && parts[1].isNotBlank()) values[parts[0].trim { it <= ' ' }] = parts[1].trim { it <= ' ' }
        }
        return values[key].orEmpty()
    }

    fun requestHeader(url: String): String = read("requestHeader", url)

    private fun read(purpose: String, url: String): String {
        task.ensureActiveForRuntime()
        if (task.session.closed.get()) throw CancellationException("Cookie owner session is closed")
        require(url.toByteArray(Charsets.UTF_8).size <= 8192) { "Cookie URL exceeds its byte budget" }
        val input = jsonObject("owner" to requireNotNull(task.session.options.stateOwner), "purpose" to purpose,
            "url" to url, "domain" to NetworkUtils.getSubDomain(url))
        val result = try { dispatch(task, "cookie.owner.read", input) }
        catch (error: CancellationException) { throw error }
        catch (error: RuntimeFailure) {
            if (error.code in setOf("UNSUPPORTED_CAPABILITY", "unsupported_host")) throw UnsupportedRuleCapability(error.message.orEmpty())
            throw RulePersistenceException("App Cookie owner read failed", error)
        }
        catch (error: Exception) { throw RulePersistenceException("App Cookie owner read failed", error) }
        task.ensureActiveForRuntime()
        if (task.session.closed.get()) throw CancellationException("Cookie owner session is closed")
        val cookie = result["cookie"] ?: throw RulePersistenceException("App Cookie owner omitted its text result")
        if (!cookie.isJsonPrimitive || !cookie.asJsonPrimitive.isString) throw RulePersistenceException("App Cookie owner returned non-text data")
        return cookie.asString.also { if (it.toByteArray(Charsets.UTF_8).size > 65536) throw RulePersistenceException("App Cookie result exceeds its byte budget") }
    }
}
