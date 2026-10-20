package io.yuedu.legado

import com.google.gson.JsonObject
import com.script.ScriptBindings
import io.legado.app.data.entities.rule.RowUi
import io.yuedu.legado.originalrule.GSON
import io.yuedu.legado.originalrule.fromJsonArray
import io.yuedu.legado.originalrule.fromJsonObject
import io.yuedu.legado.originalrule.AppPattern.JS_PATTERN
import io.yuedu.legado.originalrule.normalizeRuleJsResult

/** Literal locked BaseSource method bodies compiled with a synthetic plaintext
 * host and the same retained Rhino/GSON seam. Not the full Android application,
 * UI, AES or CacheManager. See stage reference-extraction.json for exact ranges. */
internal object LockedLoginInfoMapInitialization {
    private val initializingSourceKeys = ThreadLocal<MutableSet<String>>()

    fun <T> run(sourceKey: String, onReentry: () -> T, block: () -> T): T {
        val activeKeys = initializingSourceKeys.get()
            ?: mutableSetOf<String>().also(initializingSourceKeys::set)
        if (!activeKeys.add(sourceKey)) {
            return onReentry()
        }
        return try {
            block()
        } finally {
            activeKeys.remove(sourceKey)
            if (activeKeys.isEmpty()) {
                initializingSourceKeys.remove()
            }
        }
    }
}

internal fun LockedLoginMapReference.getStoredLoginInfoMap(): MutableMap<String, String>? {
    val json = getLoginInfo() ?: return null
    return GSON.fromJsonObject<MutableMap<String, String>>(json).getOrNull()
        ?: mutableMapOf()
}

internal abstract class LockedLoginMapReference {
    abstract var loginUrl: String?
    abstract var loginUi: String?
    abstract fun getKey(): String
    abstract fun getLoginInfo(): String?
    abstract fun putLoginInfo(info: String): Boolean
    abstract fun evalJS(js: String, bindingsConfig: ScriptBindings.() -> Unit = {}): Any?
    private fun extractInlineJs(rule: String?): String? {
        val text = rule?.trim().orEmpty()
        if (text.isBlank()) return null
        val matcher = JS_PATTERN.matcher(text)
        if (!matcher.matches()) return null
        return (matcher.group(1) ?: matcher.group(2))?.trim()
    }

    fun getLoginUiJs(): String? {
        return extractInlineJs(loginUi)
    }

    fun isLoginUiV2(): Boolean {
        return LockedLoginUiV2.isV2(loginUi)
    }
    fun getLoginJs(): String? {
        val loginRule = loginUrl?.trim()
        if (loginRule.isNullOrBlank()) return null
        return extractInlineJs(loginRule) ?: loginRule
    }
    private fun configureScriptBindings(): ScriptBindings.() -> Unit = {
        put("result", mutableMapOf<String, String>())
        put("book", null)
        put("chapter", null)
    }

    fun getLoginInfoMap(): MutableMap<String, String> {
        getStoredLoginInfoMap()?.let { return it }
        if (isLoginUiV2()) return mutableMapOf()
        val loginUiRule = loginUi?.trim().takeUnless { it.isNullOrBlank() } ?: return mutableMapOf()
        return LockedLoginInfoMapInitialization.run(
            sourceKey = getKey(),
            onReentry = { mutableMapOf<String, String>() },
        ) {
            // Dynamic login UI scripts can read login info while their defaults are being derived.
            val loginUiJs = extractInlineJs(loginUiRule)
            val loginUiJson = if (loginUiJs != null) {
                LockedJsResult.normalizeJsResult(
                    evalJS(
                        "${getLoginJs() ?: ""}\n$loginUiJs",
                        configureScriptBindings()
                    )
                ).orEmpty()
            } else {
                loginUiRule
            }
            val loginInfo = GSON.fromJsonArray<RowUi>(loginUiJson).getOrNull()
                ?.filter { it.type != "button" }
                ?.associate { it.name to (it.default ?: "") }
                ?.takeIf { it.isNotEmpty() }?.also {
                    putLoginInfo(GSON.toJson(it))
                }
            loginInfo?.toMutableMap() ?: mutableMapOf()
        }
    }

}

private object LockedLoginUiV2 {
    fun isV2(loginUi: String?): Boolean {
        val text = loginUi?.trim() ?: return false
        if (!text.startsWith("{")) return false
        val obj = GSON.fromJsonObject<JsonObject>(text).getOrNull() ?: return false
        return runCatching { obj.get("version")?.asInt == 2 }.getOrDefault(false)
    }

}

private object LockedJsResult {
    fun normalizeJsResult(value: Any?): String? = normalizeRuleJsResult(value)
}
