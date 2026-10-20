package io.yuedu.legado

import com.google.gson.JsonObject
import com.script.rhino.runScriptWithContext
import io.legado.app.data.entities.BookSource
import io.legado.app.model.login.LoginUiV2
import io.yuedu.legado.OriginalRuleDto.int
import io.yuedu.legado.OriginalRuleDto.requiredObject
import io.yuedu.legado.OriginalRuleDto.requiredText
import io.yuedu.legado.originalrule.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** SourceLoginV2Delegate's domain execution on the existing original source.
 * State/session controls and countdowns stay in the current form, never here. */
internal object OriginalLoginV2Runtime {
    suspend fun execute(source: BookSource, operation: String, input: JsonObject): JsonObject {
        require(input.int("timeoutMs", 30_000) in 1..30_000) { "Login UI v2 timeout must be between1 and30000 milliseconds" }
        require(source.isLoginUiV2()) { "Login UI v2 requires the version2 source marker" }
        val stateJson = input.requiredText("stateJSON")
        val state = GSON.fromJsonObject<JsonObject>(stateJson).getOrElse {
            throw RuntimeFailure("INVALID_ARGUMENT", "Login UI v2 state must be a JSON object")
        }
        require(state != null) { "Login UI v2 state must be a JSON object" }
        val environment = source.getRuleEnvironment()
        return environment.platform.runWebBook(currentCoroutineContext()) {
            val context = currentCoroutineContext()
            runScriptWithContext(context) {
                if (operation == "loginV2UI") {
                    // Existing ViewModel initializes header ownership before V2 start.
                    source.getHeaderMap(true)
                    val rows = LoginUiV2.parseRender(source.evalLoginUiV2(stateJson))
                        ?: throw RuntimeFailure("INVALID_RESULT", "Login UI v2 render is invalid")
                    require(rows.size <= 4096) { "Login UI v2 contains too many rows" }
                    val stored = source.getLoginInfoMap()
                    requireRepresentableLoginUIKeys(rows.mapNotNull { it.key } + stored.keys)
                    jsonObject("rows" to GSON.toJsonTree(rows), "storedValues" to stored)
                } else {
                    val action = input.requiredText("action")
                    val form = input.requiredObject("form")
                    require(form.size() <= 4096 && form.entrySet().all { (_, v) -> v.isJsonPrimitive && v.asJsonPrimitive.isString }) { "Login UI v2 form must be a bounded String map" }
                    requireRepresentableLoginUIKeys(form.keySet())
                    val command = LoginUiV2.parseActionResult(source.evalLoginActionV2(action, stateJson, GSON.toJson(form)))
                    if (command.malformed) throw RuntimeFailure("INVALID_RESULT", "Login UI v2 action command is invalid")
                    requireRepresentableLoginUIKeys(command.error.orEmpty().keys)
                    context.ensureActive()
                    // Validate the entire command before an explicit checked save.
                    // Known rejection, IO and cancellation cannot authorize close.
                    val loginStored = command.loginJson?.let { loginJson ->
                        if (!source.putLoginInfo(loginJson))
                            throw RuntimeFailure("STATE_REJECTED", "Login UI v2 credential owner rejected save")
                        true
                    } ?: false
                    context.ensureActive()
                    jsonObject("stateJSON" to command.stateJson, "errors" to command.error,
                        "close" to command.close, "loginStored" to loginStored,
                        "unknownKeys" to command.unknownKeys)
                }
            }
        }
    }
}
