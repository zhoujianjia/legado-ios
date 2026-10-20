package io.yuedu.legado

import com.google.gson.JsonObject
import java.io.IOException
import java.nio.charset.Charset
import java.util.Base64

/** One response/dispatch boundary shared by mainJs and original AnalyzeUrl. */
internal class RuntimeHttpRequestExecutor(
    private val task: RuntimeTask,
    private val dispatch: (RuntimeTask, String, JsonObject) -> JsonObject,
) {
    fun execute(request: JsonObject, charset: String = "UTF-8", recoverIoFailure: Boolean = true,
                transform: ((String, String) -> String)? = null): StrResponse {
        val production = task.session.options.usesJvmHttp
        val resolved = request["url"].asString
        val response = try { dispatch(task, "http.request", request) } catch (error: IOException) {
            if (error is io.yuedu.legado.originalrule.RulePersistenceException) throw error
            if (!production || !recoverIoFailure) throw error
            task.ensureActiveForRuntime()
            return StrResponse(resolved, 200, error.stackTraceToString(), emptyMap())
        }
        val responseUrl = response["url"]?.asString ?: resolved
        val rawResponse = response["jvmResponseHandle"]?.asString?.let { task.rawHttpResponses.remove(it) }
        val responseHeaders = linkedMapOf<String, String>()
        response["headers"]?.asJsonObject?.entrySet()?.forEach { (name, value) ->
            val values = if (value.isJsonArray) value.asJsonArray.map { it.asString } else listOf(value.asString)
            responseHeaders[name] = values.joinToString(", ")
            if (!production && name.equals("Set-Cookie", true)) task.session.cookies.persistent(task.persistence, write = true) {
                values.forEach { task.session.cookies.setCookie(responseUrl, it) }
            }
        }
        val contentType = responseHeaders.entries.firstOrNull { it.key.equals("Content-Type", true) }?.value.orEmpty()
        val responseCharset = Regex("charset\\s*=\\s*[\"']?([^;\\s\"']+)", RegexOption.IGNORE_CASE)
            .find(contentType)?.groupValues?.get(1) ?: charset
        val text = when {
            response.has("bodyBase64") && !response["bodyBase64"].isJsonNull -> {
                val bytes = Base64.getDecoder().decode(response["bodyBase64"].asString)
                if (production) LegadoResponseText.decode(bytes, contentType) else String(bytes, Charset.forName(responseCharset))
            }
            response.has("body") && !response["body"].isJsonNull -> response["body"].asString
            else -> ""
        }
        return StrResponse(responseUrl, response["status"]?.asInt ?: 200,
            transform?.invoke(text, contentType) ?: text, responseHeaders, rawResponse)
    }
}
