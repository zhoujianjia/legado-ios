package io.yuedu.legado

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.legado.app.data.entities.*
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setChapter
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.analyzeRule.RuleDataInterface
import io.yuedu.legado.originalrule.*
import org.jsoup.nodes.Element
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import kotlinx.coroutines.Job

/** Existing frozen Android public return/state observations, not platform identity hashes. */
class OriginalStatefulReferenceTest {
    @Test(timeout = 30_000) fun all47OriginalPublicCallsAndEffectiveStateRemainEqualWithMemoryAndPersistentOwners() {
        val golden = JsonParser.parseString(javaClass.getResourceAsStream("/fixtures/android-traditional-stateful-golden.json")!!.bufferedReader().use { it.readText() }).asJsonObject
        assertEquals(47, golden["executed"].asInt)
        for (persistent in listOf(false, true)) {
            val directory = Files.createTempDirectory("owned-stateful-reference-")
            try {
                var calls = 0
                for (scenarioValue in golden["scenarios"].asJsonArray) {
                    val observed = scenarioValue.asJsonObject; val input = observed["input"].asJsonObject; val id = input["scenarioId"].asString
                    val binding = if (persistent) RulePersistenceBinding(FileRulePersistenceAdapter(directory), "owner", id) else null
                    RuleEnvironment(persistence = binding).use { env ->
                        fun objectRows(key: String) = input[key].asJsonArray.map { it.asJsonObject }
                        val initial = observed["resolvedSetup"].asJsonObject["initialState"].asJsonObject
                        val sources = objectRows("sources").associate { row ->
                            val sourceId = row["id"].asString
                            sourceId to BookSource(env, initial["sources"].asJsonObject[sourceId].asJsonObject["url"].asString,
                                jsLib = row["jsLib"].takeUnless { it.isJsonNull }?.asString).also { source -> row["variables"].asJsonObject.entrySet().forEach { source.put(it.key, it.value.asString) } }
                        }
                        val data = objectRows("data").associate { row ->
                            val dataId = row["id"].asString
                            val model: RuleDataInterface = if (row["kind"].asString == "book") Book(env, name = row["name"].asString,
                                bookUrl = initial["data"].asJsonObject[dataId].asJsonObject["bookUrl"].asString) else RuleData()
                            row["variables"].asJsonObject.entrySet().forEach { model.putVariable(it.key, it.value.asString) }; dataId to model
                        }
                        val chapters = objectRows("chapters").associate { row ->
                            val chapterId = row["id"].asString; val state = initial["chapters"].asJsonObject[chapterId].asJsonObject
                            chapterId to BookChapter(env, title = row["title"].asString, bookUrl = state["bookUrl"].asString, url = state["url"].asString).also { chapter ->
                                row["variables"].asJsonObject.entrySet().forEach { chapter.putVariable(it.key, it.value.asString) }
                            }
                        }
                        fun JsonObject.ref(key: String) = this[key].takeUnless { it.isJsonNull }?.asString
                        val instances = objectRows("instances").associate { row -> row["id"].asString to AnalyzeRule(data[row.ref("dataId")], sources[row.ref("sourceId")], environment = env).apply {
                            setContent(row["content"].asString); setChapter(chapters[row.ref("chapterId")]); setCoroutineContext(Job())
                        } }
                        val returned = hashMapOf<String, Any?>()
                        try {
                            for (stepValue in observed["steps"].asJsonArray) {
                                val step = stepValue.asJsonObject; val action = step["input"].asJsonObject; val label = "$persistent/$id/${step["stepId"].asString}"
                                if (action["kind"].asString == "setup") {
                                    when (action["action"].asString) {
                                        "setBookName" -> (data[action["dataId"].asString] as Book).name = action["value"].asString
                                        "setContent" -> instances.getValue(action["instanceId"].asString).setContent(action["content"].asString)
                                        "setLocal" -> instances.getValue(action["instanceId"].asString).setLocal(action["key"].asString, action["value"].asString)
                                        "putVariable" -> (if (action["target"].asString == "chapter") chapters.getValue(action["targetId"].asString) else data.getValue(action["targetId"].asString)).putVariable(action["key"].asString, action["value"].takeUnless { it.isJsonNull }?.asString)
                                        else -> error("Unknown fixture setup")
                                    }
                                } else {
                                    calls++
                                    val rule = instances.getValue(action["instanceId"].asString)
                                    val actual = runCatching {
                                        when (action["api"].asString) {
                                            "getElements" -> rule.getElements(action["rule"].asString)
                                            "getString-unescape-false" -> rule.getString(action["rule"].asString, false)
                                            "getString-default" -> rule.getString(action["rule"].asString)
                                            "getString-content-default" -> rule.getString(action["rule"].asString, returned[action["contentFromStep"].asString])
                                            else -> error("Unknown fixture API")
                                        }
                                    }
                                    if (step["outcome"].asString == "return") {
                                        val value = actual.getOrThrow(); returned[action["stepId"].asString] = value
                                        assertEquals(label, step["actual"], describe(value))
                                    } else {
                                        val failure = actual.exceptionOrNull() ?: error("Expected original exception: $label")
                                        assertEquals(label, step["exception"].asJsonObject["className"].asString, failure.javaClass.name)
                                        assertTrue(label, failure.message.orEmpty().contains("fixture throw"))
                                    }
                                }
                                val after = step["after"]?.takeUnless { it.isJsonNull }?.asJsonObject ?: continue
                                for ((kind, models) in listOf("data" to data, "chapters" to chapters)) for ((modelId, model) in models) {
                                    val expected = after[kind].asJsonObject[modelId].asJsonObject
                                    assertEquals(label, expected["variableMap"], gson.toJsonTree(model.variableMap))
                                    expected["effectiveVariables"].asJsonObject.entrySet().forEach { assertEquals("$label:$modelId:${it.key}", it.value.asString, model.getVariable(it.key)) }
                                }
                                for ((sourceId, source) in sources) after["sources"].asJsonObject[sourceId].asJsonObject["variables"].asJsonObject.entrySet().forEach { assertEquals(label, it.value.asString, source.get(it.key)) }
                                for ((instanceId, rule) in instances) after["instances"].asJsonObject[instanceId].asJsonObject["resolvedPublicReads"].asJsonObject.entrySet().forEach { assertEquals(label, it.value.asString, rule.get(it.key)) }
                            }
                        } finally { instances.values.forEach(AnalyzeRule::close) }
                    }
                }
                assertEquals(47, calls)
            } finally { directory.toFile().deleteRecursively() }
        }
    }
    private fun describe(value: Any?): JsonElement = when (value) {
        null -> gson.toJsonTree(mapOf("kind" to "null"))
        is Element -> gson.toJsonTree(mapOf("kind" to "element", "javaClass" to value.javaClass.name, "outerHTML" to value.outerHtml(), "text" to value.text()))
        is List<*> -> JsonObject().apply { addProperty("kind", "list"); addProperty("javaClass", value.javaClass.name); add("items", com.google.gson.JsonArray().apply { value.forEach { add(describe(it)) } }) }
        else -> gson.toJsonTree(mapOf("kind" to when (value) { is String -> "string"; is Number -> "number"; is Boolean -> "boolean"; else -> error("Unexpected reference value") }, "javaClass" to value.javaClass.name, "value" to if (value is Boolean) value else value.toString()))
    }
}
