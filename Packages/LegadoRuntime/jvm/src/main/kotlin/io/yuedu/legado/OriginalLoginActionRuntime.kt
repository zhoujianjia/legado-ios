package io.yuedu.legado

import com.google.gson.JsonObject
import com.script.rhino.runScriptWithContext
import io.legado.app.data.entities.BookSource
import io.yuedu.legado.OriginalRuleDto.boolean
import io.yuedu.legado.OriginalRuleDto.int
import io.yuedu.legado.OriginalRuleDto.requiredObject
import io.yuedu.legado.originalrule.*
import kotlinx.coroutines.currentCoroutineContext

/** Original SourceLoginDialog.handleButtonClick, standalone nonbrowser domain.
 * UI callbacks remain explicit unsupported on the existing finite login host.
 * Rendering/action does not authorize an implicit raw credential write. */
internal object OriginalLoginActionRuntime {
    suspend fun execute(source: BookSource, input: JsonObject): JsonObject {
        require(input.int("timeoutMs", 30_000) in 1..30_000) { "Login action timeout must be between 1 and 30000 milliseconds" }
        if (source.isLoginUiV2()) throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Interactive loginUi v2 is not connected")
        val raw = input.requiredObject("credentials")
        require(raw.size() <= 4096 && raw.entrySet().all { (_, value) -> value.isJsonPrimitive && value.asJsonPrimitive.isString }) { "Login action values must be a bounded String map" }
        val values = raw.entrySet().associateTo(linkedMapOf()) { (key, value) -> key to value.asString }
        val actionValue = input["action"]?.takeUnless { it.isJsonNull }
        require(actionValue == null || actionValue.isJsonPrimitive && actionValue.asJsonPrimitive.isString) { "Login action must be a String or null" }
        val action = actionValue?.asString
        val loginJS = source.getLoginJs()
        if (action == null || loginJS == null) return jsonObject("executed" to false)
        // Original handleButtonClick obtains getLoginJs before getLoginData.
        // The App reports an unavailable physical EditText binding explicitly;
        // it must never become a legitimate empty result Map or execute JS.
        val bindingFailure = input["inputBindingFailed"]
        require(bindingFailure == null || bindingFailure.isJsonPrimitive && bindingFailure.asJsonPrimitive.isBoolean) { "Login action binding failure must be a Boolean" }
        if (input.boolean("inputBindingFailed", false))
            throw RuntimeFailure("UI_BINDING_ERROR", "Original login input control is incompatible")
        if (action.startsWith("http://", true) || action.startsWith("https://", true) ||
            loginJS.startsWith("http://", true) || loginJS.startsWith("https://", true))
            throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "Original login browser action is not connected")
        val environment = source.getRuleEnvironment()
        return environment.platform.runWebBook(currentCoroutineContext()) {
            OriginalSourceLoginHost(source).use { java ->
                runScriptWithContext(currentCoroutineContext()) {
                    source.evalJS("$loginJS\n$action") {
                        put("java", java); put("result", values)
                        put("book", null); put("chapter", null)
                        put("isLongClick", input.boolean("isLongClick", false))
                    }
                }
            }
            // Completion values are ignored by the original action consumer.
            // Explicit source-owned calls retain their actual effects/owner.
            jsonObject("executed" to true)
        }
    }
}
