package io.legado.app.model.analyzeRule

import com.script.buildScriptBindings
import com.script.rhino.RhinoScriptEngine
import io.legado.app.data.entities.BaseSource
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.yuedu.legado.originalrule.RuleEnvironment
import io.yuedu.legado.originalrule.RuleJsExtensions
import java.util.regex.Pattern
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/**
 * Finite port of AnalyzeUrl's URL-script expansion, not the complete Android
 * constructor/network orchestrator. The three retained stages run in upstream
 * order: @js/<js>, the original {{JS}} delimiter scan, then page alternatives. HTTP encoding and
 * finite options remain owned by SourceJavaHost. option.js/bodyJs, dynamic
 * source headers, WebView, DNS, rate limiting and persistent login are unported.
 * Keeping the original FQN does not imply those capabilities are available.
 */
class AnalyzeUrl(
    private val mUrl: String,
    private val key: String? = null,
    private val page: Int? = null,
    private var baseUrl: String = "",
    private val source: BaseSource? = null,
    private val ruleData: RuleDataInterface? = null,
    private val chapter: BookChapter? = null,
    private val environment: RuleEnvironment,
    coroutineContext: CoroutineContext = EmptyCoroutineContext,
) : RuleJsExtensions {
    private val context = coroutineContext.minusKey(ContinuationInterceptor)
    var ruleUrl: String = ""
        private set

    init {
        environment.ensureOpen()
        val matcher = paramPattern.matcher(baseUrl)
        if (matcher.find()) baseUrl = baseUrl.substring(0, matcher.start())
        ruleUrl = mUrl
        analyzeJs()
        replaceKeyPageJs()
    }

    private fun analyzeJs() {
        var start = 0
        val jsMatcher = jsPattern.matcher(ruleUrl)
        var result = ruleUrl
        while (jsMatcher.find()) {
            if (jsMatcher.start() > start) {
                ruleUrl.substring(start, jsMatcher.start()).trim().let {
                    if (it.isNotEmpty()) result = it.replace("@result", result)
                }
            }
            result = evalJS(jsMatcher.group(2) ?: jsMatcher.group(1), result).toString()
            start = jsMatcher.end()
        }
        if (ruleUrl.length > start) {
            ruleUrl.substring(start).trim().let {
                if (it.isNotEmpty()) result = it.replace("@result", result)
            }
        }
        ruleUrl = result
    }

    private fun replaceKeyPageJs() {
        if (ruleUrl.contains("{{") && ruleUrl.contains("}}")) {
            val analyze = RuleAnalyzer(ruleUrl)
            val url = analyze.innerRule("{{", "}}") {
                val jsEval = evalJS(it) ?: ""
                when (jsEval) {
                    is String -> jsEval
                    is Double if jsEval % 1.0 == 0.0 -> String.format("%.0f", jsEval)
                    else -> jsEval.toString()
                }
            }
            if (url.isNotEmpty()) ruleUrl = url
        }
        page?.let {
            val matcher = pagePattern.matcher(ruleUrl)
            while (matcher.find()) {
                val pages = matcher.group(1)!!.split(",")
                ruleUrl = if (page < pages.size) {
                    ruleUrl.replace(matcher.group(), pages[page - 1].trim { it <= ' ' })
                } else {
                    ruleUrl.replace(matcher.group(), pages.last().trim { it <= ' ' })
                }
            }
        }
    }

    fun evalJS(jsStr: String, result: Any? = null): Any? {
        environment.ensureOpen()
        val bindings = buildScriptBindings {
            it["java"] = this
            it["baseUrl"] = baseUrl
            it["cookie"] = environment.cookie
            it["cache"] = environment.cache
            it["page"] = page
            it["key"] = key
            it["speakText"] = null
            it["speakSpeed"] = null
            it["book"] = ruleData as? Book
            it["source"] = source
            it["result"] = result
            it["infoMap"] = null
        }
        val scope = environment.scopes.getScope(source?.jsLib, context)
            ?: environment.scopes.getCryptoScope(source ?: this, context)
        bindings.chainTo(scope, environment.scopes.sharedHandle(source))
        return RhinoScriptEngine.eval(jsStr, bindings, context)
    }

    fun put(key: String, value: String): String {
        environment.ensureOpen()
        chapter?.putVariable(key, value) ?: ruleData?.putVariable(key, value)
        return value
    }

    fun get(key: String): String {
        environment.ensureOpen()
        when (key) {
            "bookName" -> (ruleData as? Book)?.let { return it.name }
            "title" -> chapter?.let { return it.title }
        }
        return chapter?.getVariable(key)?.takeIf(String::isNotEmpty)
            ?: ruleData?.getVariable(key)?.takeIf(String::isNotEmpty) ?: ""
    }

    override fun getSource(): BaseSource? = source
    override fun getTag(): String? = source?.getTag()
    override fun getRuleEnvironment(): RuleEnvironment = environment
    override fun getRuleCoroutineContext(): CoroutineContext = context
    override fun ajax(url: Any): String? = connect(if (url is List<*>) url.firstOrNull().toString() else url.toString()).body()

    private companion object {
        val jsPattern: Pattern = Pattern.compile("<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", Pattern.CASE_INSENSITIVE)
        val pagePattern: Pattern = Pattern.compile("<(.*?)>")
        val paramPattern: Pattern = Pattern.compile("\\s*,\\s*(?=\\{)")
    }
}
