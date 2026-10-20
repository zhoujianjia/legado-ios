package io.legado.app.data.entities

import io.legado.app.model.analyzeRule.RuleDataInterface
import io.yuedu.legado.originalrule.GSON
import io.yuedu.legado.originalrule.splitNotBlank

/** Original BaseBook API/variable methods; big storage is supplied by the concrete JVM model. */
interface BaseBook : RuleDataInterface {
    var name: String
    var author: String
    var bookUrl: String
    var kind: String?
    var wordCount: String?
    var variable: String?
    var infoHtml: String?
    var tocHtml: String?

    override fun putVariable(key: String, value: String?): Boolean {
        if (super.putVariable(key, value)) variable = GSON.toJson(variableMap)
        return true
    }
    fun putCustomVariable(value: String?) { putVariable("custom", value) }
    fun getCustomVariable(): String = getVariable("custom")
    // RuleBigDataHelp's Android filesystem binding is replaced, not silently emulated as disk.
    override fun putBigVariable(key: String, value: String?)
    override fun getBigVariable(key: String): String?
    fun getKindList(): List<String> {
        val kindList = arrayListOf<String>()
        wordCount?.let { if (it.isNotBlank()) kindList.add(it) }
        kind?.let { kindList.addAll(it.splitNotBlank(",", "\n")) }
        return kindList
    }
}
