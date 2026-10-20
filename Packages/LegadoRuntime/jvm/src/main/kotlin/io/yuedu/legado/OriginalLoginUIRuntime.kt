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
        fun inputValues(name: String): MutableMap<String, String>? {
            val supplied = input[name]?.takeUnless { it.isJsonNull } ?: return null
            require(supplied.isJsonObject && supplied.asJsonObject.size() <= 4096 && supplied.asJsonObject.entrySet().all { (_, v) -> v.isJsonPrimitive && v.asJsonPrimitive.isString }) { "Login UI values must be a bounded String map" }
            return supplied.asJsonObject.entrySet().associateTo(linkedMapOf()) { (k,v) -> k to v.asString }
        }
        val suppliedValues = inputValues("values")
        val evaluationValues = inputValues("evaluationValues")
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
                requireRepresentableLoginUIKeys(values.keys + evaluationValues.orEmpty().keys)
                fun evaluate(script: String, result: Map<String, String>): String = normalizeRuleJsResult(
                    source.evalJS("${source.getLoginJs() ?: ""}\n$script") {
                        put("result", result.toMutableMap()); put("book", null); put("chapter", null)
                    }).orEmpty()
                val code = source.getLoginUiJs()
                val json = if (code != null) evaluate(code, evaluationValues ?: values) else source.loginUi
                val rows = GSON.fromJsonArray<RowUi>(json).getOrElse {
                    throw RuntimeFailure("INVALID_RESULT", "Login UI did not return a valid original RowUi array")
                }
                require(rows.size <= 4096) { "Login UI contains too many rows" }
                requireRepresentableLoginUIKeys(values.keys + rows.map { it.name } + evaluationValues.orEmpty().keys)
                // Original selector/toggle construction updates the dialog working
                // map, not Keychain. Text defaults remain display-only edits.
                var workingMapChanged = false
                for (row in rows) if (row.type == "select" || row.type == "toggle") {
                    if (values[row.name].isNullOrEmpty()) {
                        workingMapChanged = true
                        val chars = row.chars?.filterNotNull() ?: if (row.type == "select") listOf("chars", "is null") else listOf("chars is null")
                        values[row.name] = row.default ?: chars.firstOrNull()
                            ?: throw RuntimeFailure("INVALID_RESULT", "Login UI selection has no value")
                    }
                }
                val edited = values.toMutableMap()
                for (row in rows) if (row.type == "text" || row.type == "password")
                    edited[row.name] = values[row.name] ?: row.default ?: ""
                val toggleActionLabels = arrayListOf<String?>()
                val toggleLabelSuffixes = arrayListOf<Boolean>()
                val labels = rows.map { row ->
                    val viewName = row.viewName
                    var retainedName: String? = null
                    var nullResult = false
                    val label = when {
                        row.type !in setOf("text", "password", "select", "button", "toggle") -> row.name
                        viewName == null -> row.name
                        viewName.length in 3..19 && viewName.first() == '\'' && viewName.last() == '\'' ->
                            viewName.substring(1, viewName.length - 1).also { retainedName = it }
                        else -> try {
                            evaluate(viewName, edited).let { value ->
                                if (value.isEmpty()) { nullResult = true; "null" }
                                else value.also { retainedName = it }
                            }
                        } catch (error: Exception) {
                            rethrowRuleControlFailure(error)
                            context.ensureActive()
                            environment.platform.log("Original login label evaluation failed")
                            nullResult = true
                            "null"
                        }
                    }
                    // The original button/toggle builder caches successful
                    // display names on RowUi for later upLoginData resets.
                    if ((row.type == "button" || row.type == "toggle") && retainedName != null)
                        row.viewName = retainedName
                    toggleActionLabels += if (row.type == "toggle") retainedName ?: row.name else null
                    toggleLabelSuffixes += row.type == "toggle" && nullResult
                    label
                }
                jsonObject("rows" to GSON.toJsonTree(rows), "labels" to labels, "values" to values,
                    "dynamic" to (code != null), "toggleActionLabels" to toggleActionLabels,
                    "toggleLabelSuffixes" to toggleLabelSuffixes, "workingMapChanged" to workingMapChanged)
            }
        }
    }
}
