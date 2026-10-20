package io.yuedu.legado.originalrule

import com.script.rhino.RhinoContext
import com.script.rhino.RhinoScriptEngine
import org.htmlunit.corejs.javascript.Context
import org.htmlunit.corejs.javascript.NativeJSON
import org.htmlunit.corejs.javascript.Scriptable
import org.htmlunit.corejs.javascript.ScriptableObject
import org.htmlunit.corejs.javascript.Undefined
import org.htmlunit.corejs.javascript.Wrapper
import kotlinx.coroutines.CancellationException

/** JsSourceEngine.normalizeJsResult's source-header subset, using real NativeJSON. */
internal fun normalizeRuleJsResult(result: Any?): String? {
    val value = if (result is Wrapper) result.unwrap() else result
    return when {
        value == null || value is Undefined -> null
        value is String -> value
        value is CharSequence -> value.toString()
        value is Scriptable -> stringifyRuleObject(value) ?: GSON.toJson(value)
        else -> GSON.toJson(value)
    }
}

private fun stringifyRuleObject(value: Scriptable): String? {
    val scope = value.parentScope?.let(ScriptableObject::getTopLevelScope) ?: return null
    val context = Context.enter() as RhinoContext
    val previousAllow = context.allowScriptRun
    context.allowScriptRun = true
    context.recursiveCount++
    try {
        context.checkRecursive()
        val raw = try { NativeJSON.stringify(context, scope, value, null, null) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            rethrowRuleControlFailure(error)
            throw NoStackTraceException("JS返回值 JSON.stringify 失败: ${error.message}")
        }
        return RhinoScriptEngine.unwrapReturnValue(raw) as? String
    } finally {
        context.recursiveCount--
        context.allowScriptRun = previousAllow
        Context.exit()
    }
}
