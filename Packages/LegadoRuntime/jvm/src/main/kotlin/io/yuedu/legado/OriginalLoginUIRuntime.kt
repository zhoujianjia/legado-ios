package io.yuedu.legado

import com.google.gson.JsonObject
import com.script.rhino.runScriptWithContext
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.rule.RowUi
import io.yuedu.legado.OriginalRuleDto.int
import io.yuedu.legado.originalrule.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Locked standalone SourceLoginDialog render/evalUiJs contract. No UI engine,
 * browser, Book, derived-default credential write or new persistent owner. */
internal object OriginalLoginUIRuntime {
    suspend fun execute(source: BookSource, input: JsonObject): JsonObject {
        require(input.int("timeoutMs", 30_000) in 1..30_000) { "Login UI timeout must be between 1 and 30000 milliseconds" }
        if (source.isLoginUiV2()) throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Interactive loginUi v2 is not connected")
        val supplied = input["values"]?.takeUnless { it.isJsonNull }
        val suppliedValues = if (supplied == null) null else {
            require(supplied.isJsonObject && supplied.asJsonObject.size() <= 4096 && supplied.asJsonObject.entrySet().all { (_, v) -> v.isJsonPrimitive && v.asJsonPrimitive.isString }) { "Login UI values must be a bounded String map" }
            supplied.asJsonObject.entrySet().associateTo(linkedMapOf()) { (k,v) -> k to v.asString }
        }
        val environment = source.getRuleEnvironment()
        return environment.platform.runWebBook(currentCoroutineContext()) {
            val context = currentCoroutineContext()
            runScriptWithContext(context) {
                val values = suppliedValues ?: run {
                    // SourceLoginViewModel initializes header ownership before the
                    // raw stored Map, without getLoginInfoMap default derivation.
                    source.getHeaderMap(true)
                    source.getStoredLoginInfoMap()?.toMutableMap() ?: linkedMapOf()
                }
                fun evaluate(script: String, result: Map<String, String>): String = normalizeRuleJsResult(
                    source.evalJS("${source.getLoginJs() ?: ""}\n$script") {
                        put("result", result.toMutableMap()); put("book", null); put("chapter", null)
                    }).orEmpty()
                val code = source.getLoginUiJs()
                val json = if (code != null) evaluate(code, values) else source.loginUi
                val rows = GSON.fromJsonArray<RowUi>(json).getOrElse {
                    throw RuntimeFailure("INVALID_RESULT", "Login UI did not return a valid original RowUi array")
                }
                require(rows.size <= 4096) { "Login UI contains too many rows" }
                // Original selector/toggle construction updates the dialog working
                // map, not Keychain. Text defaults remain display-only edits.
                for (row in rows) if (row.type == "select" || row.type == "toggle") {
                    if (values[row.name].isNullOrEmpty()) {
                        val chars = row.chars?.filterNotNull() ?: if (row.type == "select") listOf("chars", "is null") else listOf("chars is null")
                        values[row.name] = row.default ?: chars.firstOrNull()
                            ?: throw RuntimeFailure("INVALID_RESULT", "Login UI selection has no value")
                    }
                }
                val edited = values.toMutableMap()
                for (row in rows) if (row.type == "text" || row.type == "password")
                    edited[row.name] = values[row.name] ?: row.default ?: ""
                val labels = rows.map { row ->
                    val viewName = row.viewName
                    when {
                        row.type !in setOf("text", "password", "select", "button", "toggle") -> row.name
                        viewName == null -> row.name
                        viewName.length in 3..19 && viewName.first() == '\'' && viewName.last() == '\'' -> viewName.substring(1, viewName.length - 1)
                        else -> try { evaluate(viewName, edited).ifEmpty { "null" } }
                        catch (error: Exception) {
                            rethrowRuleControlFailure(error)
                            context.ensureActive()
                            // evalUiJsResult failure -> getOrNull() -> the original
                            // row builder's null-label branch. Never expose secrets.
                            environment.platform.log("Original login label evaluation failed")
                            "null"
                        }
                    }
                }
                jsonObject("rows" to GSON.toJsonTree(rows), "labels" to labels, "values" to values, "dynamic" to (code != null))
            }
        }
    }
}
