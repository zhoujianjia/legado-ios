package io.yuedu.legado

import io.legado.app.model.analyzeRule.RuleAnalyzer
import java.util.regex.Pattern

/**
 * Test-only exact AnalyzeUrl.analyzeJs/replaceKeyPageJs method extraction from
 * F:/legado-master.zip, SHA256 724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd.
 * Only the constructor/eval seam below is synthetic. Android orchestration is
 * not executed. String innerRule keeps its original first-end-delimiter behavior.
 */
internal class ArchiveUrlExpansionReference(
    mUrl: String,
    private val page: Int?,
    private val evaluator: (String, Any?) -> Any?,
) {
    var ruleUrl = mUrl
        private set
    init { analyzeJs(); replaceKeyPageJs() }
    private fun evalJS(js: String, result: Any? = null): Any? = evaluator(js, result)
    private object AppPattern {
        val JS_PATTERN: Pattern = Pattern.compile("<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", Pattern.CASE_INSENSITIVE)
    }
    private companion object { val pagePattern: Pattern = Pattern.compile("<(.*?)>") }

    private fun analyzeJs() {
        var start = 0
        val jsMatcher = AppPattern.JS_PATTERN.matcher(ruleUrl)
        var result = ruleUrl
        while (jsMatcher.find()) {
            if (jsMatcher.start() > start) {
                ruleUrl.substring(start, jsMatcher.start()).trim().let {
                    if (it.isNotEmpty()) {
                        result = it.replace("@result", result)
                    }
                }
            }
            result = evalJS(jsMatcher.group(2) ?: jsMatcher.group(1), result).toString()
            start = jsMatcher.end()
        }
        if (ruleUrl.length > start) {
            ruleUrl.substring(start).trim().let {
                if (it.isNotEmpty()) {
                    result = it.replace("@result", result)
                }
            }
        }
        ruleUrl = result
    }

    /**
     * 替换关键字,页数,JS
     */
    private fun replaceKeyPageJs() { //先替换内嵌规则再替换页数规则，避免内嵌规则中存在大于小于号时，规则被切错
        //js
        if (ruleUrl.contains("{{") && ruleUrl.contains("}}")) {
            val analyze = RuleAnalyzer(ruleUrl) //创建解析
            //替换所有内嵌{{js}}
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
        //page
        page?.let {
            val matcher = pagePattern.matcher(ruleUrl)
            while (matcher.find()) {
                val pages = matcher.group(1)!!.split(",")
                ruleUrl = if (page < pages.size) { //pages[pages.size - 1]等同于pages.last()
                    ruleUrl.replace(matcher.group(), pages[page - 1].trim { it <= ' ' })
                } else {
                    ruleUrl.replace(matcher.group(), pages.last().trim { it <= ' ' })
                }
            }
        }
    }

}
