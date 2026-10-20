package io.yuedu.legado.originalrule

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.rule.*

/** Explicit original-rule source decoding; does not deserialize an environment or select the App route. */
internal fun decodeOriginalBookSource(environment: RuleEnvironment, snapshot: JsonObject): BookSource {
    fun text(key: String): String? = snapshot[key]?.takeUnless(JsonElement::isJsonNull)?.asString
    fun <T> rule(key: String, type: Class<T>): T? = snapshot[key]?.takeUnless(JsonElement::isJsonNull)?.let {
        GSON.fromJson(if (it.isJsonPrimitive) it.asString else it.toString(), type)
    }
    return BookSource(environment, bookSourceUrl = text("bookSourceUrl").orEmpty(), bookSourceName = text("bookSourceName").orEmpty(),
        jsLib = text("jsLib"), header = text("header"), enabledCookieJar = if (!snapshot.has("enabledCookieJar")) true else snapshot["enabledCookieJar"]?.takeUnless(JsonElement::isJsonNull)?.asBoolean,
        concurrentRate = text("concurrentRate"), bookSourceType = snapshot["bookSourceType"]?.asInt ?: 0,
        bookUrlPattern = text("bookUrlPattern"), customOrder = snapshot["customOrder"]?.asInt ?: 0,
        searchUrl = text("searchUrl"), exploreUrl = text("exploreUrl"), loginCheckJs = text("loginCheckJs"), mainJs = text("mainJs"),
        loginUrl = text("loginUrl"), loginUi = text("loginUi"),
        ruleSearch = rule("ruleSearch", SearchRule::class.java), ruleExplore = rule("ruleExplore", ExploreRule::class.java),
        ruleBookInfo = rule("ruleBookInfo", BookInfoRule::class.java), ruleToc = rule("ruleToc", TocRule::class.java),
        ruleContent = rule("ruleContent", ContentRule::class.java))
}
