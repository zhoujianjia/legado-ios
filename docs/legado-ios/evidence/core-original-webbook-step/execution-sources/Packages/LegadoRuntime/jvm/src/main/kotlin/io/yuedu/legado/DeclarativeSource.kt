package io.yuedu.legado

import com.google.gson.*
import io.legado.app.model.analyzeRule.*
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

/** Minimal orchestration around the actual upstream analyzers. AnalyzeUrl/AnalyzeRule and
 * Android persistence are intentionally not represented as migrated by this prototype. */
internal class DeclarativeSource(private val task: RuntimeTask, private val host: SourceJavaHost) {
    private val source get() = task.session.source
    private val base get() = source["bookSourceUrl"]?.asString.orEmpty()

    fun execute(operation: String, input: JsonObject): JsonElement = when (operation) {
        "search", "explore" -> {
            val field = if (operation == "search") "searchUrl" else "exploreUrl"
            val rawUrl = source[field]?.asString ?: throw RuntimeFailure("INVALID_SOURCE", "Missing $field")
            val url = template(rawUrl, input)
            val response = host.connect(url)
            val rules = source[if (operation == "search") "ruleSearch" else "ruleExplore"]?.asJsonObject
                ?: throw RuntimeFailure("INVALID_SOURCE", "Missing list rules")
            JsonArray().apply { elements(response.body(), required(rules, "bookList")).forEach { element ->
                task.job.ensureActiveForRuntime()
                add(extract(element, rules, listOf("name", "author", "bookUrl", "coverUrl", "intro", "kind", "lastChapter", "wordCount"), response.url()))
            } }
        }
        "details", "getBookInfo" -> {
            val book = input["book"]?.asJsonObject?.deepCopy() ?: throw IllegalArgumentException("book is required")
            val response = host.connect(required(book, "bookUrl"))
            val rules = source["ruleBookInfo"]?.asJsonObject ?: JsonObject()
            val fields = extract(response.body(), rules, listOf("name", "author", "coverUrl", "intro", "kind", "lastChapter", "tocUrl", "wordCount"), response.url())
            fields.entrySet().forEach { (key, value) -> book.add(key, value) }
            if (!book.has("tocUrl") || book["tocUrl"].asString.isBlank()) book.addProperty("tocUrl", response.url())
            book
        }
        "toc", "getChapters" -> {
            val book = input["book"]?.asJsonObject ?: throw IllegalArgumentException("book is required")
            val response = host.connect(book["tocUrl"]?.asString ?: required(book, "bookUrl"))
            val rules = source["ruleToc"]?.asJsonObject ?: throw RuntimeFailure("INVALID_SOURCE", "Missing ruleToc")
            JsonArray().apply { elements(response.body(), required(rules, "chapterList")).forEachIndexed { index, item ->
                task.job.ensureActiveForRuntime()
                add(jsonObject("index" to index, "title" to text(item, required(rules, "chapterName")),
                    "url" to resolve(response.url(), text(item, required(rules, "chapterUrl"), isUrl = true))))
            } }
        }
        "content", "getContent" -> {
            val chapter = input["chapter"]?.asJsonObject ?: throw IllegalArgumentException("chapter is required")
            val response = host.connect(chapterUrl(chapter) ?: throw IllegalArgumentException("chapter url is required"))
            val rules = source["ruleContent"]?.asJsonObject ?: throw RuntimeFailure("INVALID_SOURCE", "Missing ruleContent")
            JsonPrimitive(text(response.body(), required(rules, "content")))
        }
        "batch", "getContentBatch" -> jsonObject("exists" to false, "missing" to input["chapters"])
        else -> throw RuntimeFailure("UNSUPPORTED_OPERATION", "Declarative prototype does not implement $operation")
    }

    private fun template(raw: String, input: JsonObject): String {
        if (raw.contains("##")) unsupported("URL replacement rules")
        var value = raw.replace("{{key}}", URLEncoder.encode(input["key"]?.asString.orEmpty(), StandardCharsets.UTF_8))
            .replace("{{page}}", (input["page"]?.asInt ?: 1).toString())
        if (value.contains("{{") || value.contains("@js:", true)) unsupported("Dynamic URL expressions")
        // The native host resolves relative URLs against bookSourceUrl.
        return value
    }

    private fun extract(document: Any, rules: JsonObject, fields: List<String>, responseUrl: String): JsonObject = JsonObject().apply {
        fields.forEach { field ->
            rules[field]?.takeUnless { it.isJsonNull || it.asString.isBlank() }?.let { rule ->
                val value = text(document, rule.asString, isUrl = field.endsWith("Url"))
                addProperty(field, if (field.endsWith("Url")) resolve(responseUrl, value) else value)
            }
        }
    }

    private fun elements(document: Any, rawRule: String): List<Any> {
        val rule = supported(rawRule)
        return when {
            rule.startsWith(":") -> AnalyzeByRegex.getElements(document.toString(), rule.drop(1).split("&&").toTypedArray())
            isJson(rule, document) -> AnalyzeByJSonPath(document).getList(strip(rule, "@Json:")).orEmpty()
            isXPath(rule) -> AnalyzeByXPath(document).getElements(strip(rule, "@XPath:")).orEmpty()
            else -> AnalyzeByJSoup(document).getElements(if (rule.startsWith("@@")) rule.drop(2) else rule)
        }
    }

    private fun text(document: Any, rawRule: String, isUrl: Boolean = false): String {
        if (rawRule.contains("##")) {
            if (isUrl) unsupported("URL replacement rules")
            return StaticScalarSelectorRule.evaluate(document, rawRule)
        }
        val rule = supported(rawRule)
        if (document is List<*> && rule.matches(Regex("\\$[0-9]+"))) return document.getOrNull(rule.drop(1).toInt())?.toString().orEmpty()
        return when {
            isJson(rule, document) -> AnalyzeByJSonPath(document).getString(strip(rule, "@Json:")).orEmpty()
            isXPath(rule) -> AnalyzeByXPath(document).getString(strip(rule, "@XPath:")).orEmpty()
            else -> AnalyzeByJSoup(document).getString(if (rule.startsWith("@@")) rule.drop(2) else rule).orEmpty()
        }
    }

    private fun supported(rule: String): String {
        if (listOf("@js:", "<js>", "<webJs>", "##", "@put:", "@get:", "{{").any { rule.contains(it, true) }) {
            unsupported("Rule transforms and state directives")
        }
        return rule
    }
    private fun isJson(rule: String, document: Any): Boolean = rule.startsWith("@Json:", true) || rule.startsWith("$.") || rule.startsWith("$[") || document is Map<*, *>
    private fun isXPath(rule: String): Boolean = rule.startsWith("@XPath:", true) || rule.startsWith("/")
    private fun strip(rule: String, prefix: String) = if (rule.startsWith(prefix, true)) rule.drop(prefix.length) else rule
    private fun resolve(url: String, value: String): String = if (value.isBlank()) "" else URI(url.ifBlank { base }).resolve(value).toString()
    private fun required(value: JsonObject, field: String): String = value[field]?.takeUnless { it.isJsonNull }?.asString
        ?: throw RuntimeFailure("INVALID_SOURCE", "Missing $field")
    private fun unsupported(feature: String): Nothing = throw RuntimeFailure("UNSUPPORTED_CAPABILITY", "$feature have not been ported from AnalyzeRule/AnalyzeUrl")
}
