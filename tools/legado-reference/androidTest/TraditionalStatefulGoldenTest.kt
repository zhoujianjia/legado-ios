package io.legado.app.reference

import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.script.rhino.RhinoScriptEngine
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.help.CacheManager
import io.legado.app.help.source.clearSharedGlobalState
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setChapter
import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.analyzeRule.RuleDataInterface
import io.legado.app.utils.GSON
import org.htmlunit.corejs.javascript.Context
import org.jsoup.nodes.Element
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.IdentityHashMap
import java.util.UUID

/** Original objects and public APIs only. Fixture-declared instances survive ordered steps. */
class TraditionalStatefulGoldenTest {
    @Test
    fun observeOriginalStatefulTraditionalRules() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val arguments = InstrumentationRegistry.getArguments()
        val runId = arguments.getString("referenceRunId")
        val rows = arrayListOf<Map<String, Any?>>()
        val report = linkedMapOf<String, Any?>(
            "schemaVersion" to 1, "suite" to SUITE, "caseSetVersion" to VERSION,
            "referenceKind" to "original-archive-android-instrumentation", "referenceRunId" to runId,
            "originalArchiveSHA256" to arguments.getString("archiveSHA256"),
            "applicationClass" to context.applicationContext.javaClass.name,
            "applicationMinSdkVersion" to context.applicationInfo.minSdkVersion,
            "androidApi" to Build.VERSION.SDK_INT, "androidRelease" to Build.VERSION.RELEASE,
            "instrumentationRunner" to "androidx.test.runner.AndroidJUnitRunner",
            "passedMeaning" to "All fixture-declared ordered steps observed; ordinary API exceptions are outcomes, never port acceptance.",
            "scope" to "Original AnalyzeRule/RuleData/models/Rhino; fixed public inputs only. Two issue1180 cases are adapted low-level observations, not BookContent coverage.",
            "passed" to false, "total" to 0, "executed" to 0, "failed" to 0,
            "totalSteps" to 0, "completedSteps" to 0, "returnedObservations" to 0, "exceptionObservations" to 0,
            "iosValidationPassed" to false, "deviceValidationPassed" to false,
            "compatibilityValidationPassed" to false, "g4ValidationPassed" to false,
            "fullFeatureParityEstablished" to false, "scenarios" to rows,
        )
        var fatal: Error? = null
        try {
            require(runId != null && UUID.fromString(runId).toString() == runId) { "Canonical referenceRunId required" }
            require(arguments.getString("archiveSHA256") == ARCHIVE) { "Original archive identity differs" }
            require(context.applicationContext.javaClass.name == "io.legado.app.App") { "Original Application required" }
            require(context.applicationInfo.minSdkVersion == 26) { "Reference minSdk override differs" }
            val fixtureBytes = instrumentation.context.assets.open(ASSET).use { it.readBytes() }
            require(sha256(fixtureBytes) == FIXTURE_SHA256) { "Reviewed stateful fixture bytes differ" }
            val fixture = JsonParser.parseString(fixtureBytes.toString(Charsets.UTF_8)).asJsonObject
            require(fixture["schemaVersion"].asInt == 1 && fixture.text("suite") == SUITE && fixture.text("caseSetVersion") == VERSION)
            val scenarios = fixture.getAsJsonArray("scenarios")
            report["fixtureSHA256"] = sha256(fixtureBytes)
            report["sourceProvenance"] = fixture["sourceProvenance"]
            report["entryPoints"] = fixture["apis"]
            report["inputFixture"] = fixture
            report["totalSteps"] = scenarios.sumOf { it.asJsonObject.getAsJsonArray("steps").size() }
            report["total"] = scenarios.sumOf { it.asJsonObject.getAsJsonArray("steps").count { step -> step.asJsonObject.text("kind") == "call" } }
            // This enters the original engine's configured factory; no flags or JS handlers are changed.
            RhinoScriptEngine.initialize()
            val cx = Context.enter()
            try {
                report["runtime"] = linkedMapOf(
                    "engineClass" to RhinoScriptEngine.javaClass.name, "contextClass" to cx.javaClass.name,
                    "implementationVersion" to cx.implementationVersion, "languageVersion" to cx.languageVersion,
                    "interpretedMode" to cx.isInterpretedMode,
                    "e4xEnabled" to cx.hasFeature(Context.FEATURE_E4X),
                    "dynamicDefaultThisEnabled" to cx.hasFeature(Context.FEATURE_LEGADO_DYNAMIC_DEFAULT_THIS),
                    "dynamicEvalRealmEnabled" to cx.hasFeature(Context.FEATURE_LEGADO_DYNAMIC_EVAL_REALM),
                )
            } finally { Context.exit() }
            for (element in scenarios) {
                val input = element.asJsonObject
                val steps = arrayListOf<Map<String, Any?>>()
                val row = linkedMapOf<String, Any?>(
                    "scenarioId" to input.text("scenarioId"), "input" to input,
                    "setupCompleted" to false, "completed" to false, "steps" to steps,
                    "setupFailure" to null, "cleanup" to null,
                )
                rows.add(row)
                val state = ScenarioState(requireNotNull(runId), input)
                try {
                    row["resolvedSetup"] = state.initialize()
                    row["setupCompleted"] = true
                    for (stepElement in input.getAsJsonArray("steps")) {
                        val step = stepElement.asJsonObject
                        val observation = linkedMapOf<String, Any?>(
                            "stepId" to step.text("stepId"), "input" to step,
                            "setupCompleted" to false, "apiInvoked" to false, "completed" to false,
                            "outcome" to null, "actual" to null, "exception" to null,
                            "observationFailure" to null, "before" to null, "after" to null,
                            "runtimeIdentity" to linkedMapOf<String, Any?>("before" to null, "after" to null),
                        )
                        steps.add(observation)
                        try {
                            observation["before"] = state.snapshot()
                            @Suppress("UNCHECKED_CAST")
                            val identities = observation["runtimeIdentity"] as MutableMap<String, Any?>
                            identities["before"] = state.runtimeIdentity()
                            if (step.text("kind") == "setup") {
                                // Setters and mutations are not part of the API exception catch.
                                observation["actual"] = state.mutate(step)
                                observation["setupCompleted"] = true
                                observation["outcome"] = "setup"
                            } else {
                                val original = state.instances.getValue(step.text("instanceId"))
                                val rule = step.text("rule")
                                val api = step.text("api")
                                require(api in listOf("getString-unescape-false", "getString-default", "getString-content-default", "getElements"))
                                // Resolving an earlier returned value is setup, never an API exception.
                                val mContent = if (step.has("contentFromStep")) state.returnedStrings.getValue(step.text("contentFromStep")) else null
                                observation["setupCompleted"] = true
                                observation["apiInvoked"] = true
                                var apiFailure: Exception? = null
                                val value: Any? = try {
                                    when (api) {
                                        "getString-unescape-false" -> original.getString(rule, false)
                                        "getString-default" -> original.getString(rule)
                                        "getString-content-default" -> original.getString(rule, requireNotNull(mContent), false)
                                        "getElements" -> original.getElements(rule)
                                        else -> error("Unknown reviewed API")
                                    }
                                } catch (error: Exception) { apiFailure = error; null }
                                if (apiFailure == null) {
                                    observation["actual"] = typed(value)
                                    if (value is String) state.returnedStrings[step.text("stepId")] = value
                                    observation["outcome"] = "return"
                                    report["returnedObservations"] = (report["returnedObservations"] as Int) + 1
                                } else {
                                    observation["exception"] = exception(requireNotNull(apiFailure))
                                    observation["outcome"] = "exception"
                                    report["exceptionObservations"] = (report["exceptionObservations"] as Int) + 1
                                }
                                report["executed"] = (report["executed"] as Int) + 1
                            }
                            observation["after"] = state.snapshot()
                            identities["after"] = state.runtimeIdentity()
                            observation["completed"] = true
                            report["completedSteps"] = (report["completedSteps"] as Int) + 1
                        } catch (error: Throwable) {
                            observation["observationFailure"] = exception(error)
                            throw error
                        }
                    }
                    row["completed"] = true
                } catch (error: Throwable) {
                    row["setupFailure"] = exception(error)
                    throw error
                } finally {
                    // Cleanup each declared key and source scope; never clear shared caches globally.
                    row["cleanup"] = state.cleanup()
                }
            }
            report["passed"] = report["executed"] == report["total"] && report["completedSteps"] == report["totalSteps"]
                && rows.all { it["completed"] == true && (it["cleanup"] as Map<*, *>)["completed"] == true }
        } catch (error: Throwable) {
            report["failed"] = 1
            report["failure"] = exception(error)
            if (error is Error) fatal = error
        } finally {
            val output = File(context.filesDir, REPORT)
            output.parentFile?.let { require(it.isDirectory || it.mkdirs()) { "Cannot create observation directory" } }
            output.writeText(GSON.newBuilder().serializeNulls().setPrettyPrinting().create().toJson(report), Charsets.UTF_8)
        }
        fatal?.let { throw it }
        assertTrue("Original stateful observation incomplete; inspect $REPORT", report["passed"] == true)
    }

    private class ScenarioState(private val runId: String, private val input: JsonObject) {
        val sources = linkedMapOf<String, BookSource>()
        val data = linkedMapOf<String, RuleDataInterface>()
        val chapters = linkedMapOf<String, BookChapter>()
        val instances = linkedMapOf<String, AnalyzeRule>()
        val returnedStrings = hashMapOf<String, String>()
        private var setupObjects: Map<String, Map<String, Any>> = emptyMap()
        private val keys = input.getAsJsonArray("observedKeys").map { it.asString }
        private fun origin(id: String) = "https://traditional-stateful.invalid/$runId/${input.text("scenarioId")}/$id/"

        fun initialize(): Map<String, Any?> {
            val initialPuts = arrayListOf<Map<String, Any?>>()
            for (item in input.getAsJsonArray("sources")) {
                val definition = item.asJsonObject
                val id = definition.text("id")
                val source = BookSource(bookSourceUrl = origin(id), bookSourceName = "Stateful reference $id", jsLib = definition.optionalText("jsLib"))
                sources[id] = source
                definition.getAsJsonObject("variables").entrySet().forEach { (key, value) ->
                    initialPuts.add(mapOf("target" to "source", "targetId" to id, "key" to key, "returned" to typed(source.put(key, value.asString))))
                }
            }
            for (item in input.getAsJsonArray("data")) {
                val definition = item.asJsonObject
                val id = definition.text("id")
                val model: RuleDataInterface = when (definition.text("kind")) {
                    "rule-data" -> RuleData()
                    "book" -> Book(bookUrl = origin("models") + id, origin = sources.values.firstOrNull()?.bookSourceUrl ?: origin("models"), name = definition.text("name"))
                    else -> error("Unknown original model kind")
                }
                data[id] = model
                definition.getAsJsonObject("variables").entrySet().forEach { (key, value) ->
                    initialPuts.add(mapOf("target" to "data", "targetId" to id, "key" to key, "returned" to typed(model.putVariable(key, value.asString))))
                }
            }
            for (item in input.getAsJsonArray("chapters")) {
                val definition = item.asJsonObject
                val id = definition.text("id")
                val book = data.getValue(definition.text("bookId")) as Book
                val chapter = BookChapter(bookUrl = book.bookUrl, url = origin("chapters") + id, baseUrl = origin("chapters"), title = definition.text("title"))
                chapters[id] = chapter
                definition.getAsJsonObject("variables").entrySet().forEach { (key, value) ->
                    initialPuts.add(mapOf("target" to "chapter", "targetId" to id, "key" to key, "returned" to typed(chapter.putVariable(key, value.asString))))
                }
            }
            for (item in input.getAsJsonArray("instances")) {
                val definition = item.asJsonObject
                val original = AnalyzeRule(definition.optionalText("dataId")?.let { data.getValue(it) }, definition.optionalText("sourceId")?.let { sources.getValue(it) })
                definition.optionalText("chapterId")?.let { original.setChapter(chapters.getValue(it)) }
                original.setContent(definition.text("content"), origin("base"))
                instances[definition.text("id")] = original
            }
            setupObjects = objectGraph()
            return mapOf("sources" to sources.mapValues { (_, source) -> mapOf("javaClass" to source.javaClass.name, "url" to source.bookSourceUrl, "jsLib" to source.jsLib) },
                "initialPutReturns" to initialPuts, "initialState" to snapshot(), "runtimeIdentity" to runtimeIdentity())
        }

        fun mutate(step: JsonObject): Any? = when (step.text("action")) {
            "setContent" -> { instances.getValue(step.text("instanceId")).setContent(step.text("content")); null }
            "setLocal" -> { instances.getValue(step.text("instanceId")).setLocal(step.text("key"), step.text("value")); null }
            "setBookName" -> { (data.getValue(step.text("dataId")) as Book).name = step.text("value"); null }
            "putVariable" -> {
                val target = when (step.text("target")) {
                    "data" -> data.getValue(step.text("targetId"))
                    "chapter" -> chapters.getValue(step.text("targetId"))
                    else -> error("Unknown mutation target")
                }
                typed(target.putVariable(step.text("key"), step["value"].let { if (it.isJsonNull) null else it.asString }))
            }
            else -> error("Unknown reviewed mutation")
        }

        fun snapshot(): Map<String, Any?> {
            fun model(value: RuleDataInterface): Map<String, Any?> = linkedMapOf(
                "javaClass" to value.javaClass.name, "variableMap" to LinkedHashMap(value.variableMap),
                "effectiveVariables" to keys.associateWith { value.getVariable(it) },
                "serializedVariable" to when (value) { is Book -> value.variable; is BookChapter -> value.variable; is RuleData -> value.getVariable(); else -> error("Unknown original model") },
                "name" to (value as? Book)?.name, "title" to (value as? BookChapter)?.title,
                "bookUrl" to when (value) { is Book -> value.bookUrl; is BookChapter -> value.bookUrl; else -> null },
                "url" to (value as? BookChapter)?.url,
            )
            return linkedMapOf(
                "data" to data.mapValues { (_, value) -> model(value) },
                "chapters" to chapters.mapValues { (_, value) -> model(value) },
                "sources" to sources.mapValues { (_, value) -> mapOf("javaClass" to value.javaClass.name, "url" to value.bookSourceUrl, "variables" to keys.associateWith { value.get(it) }) },
                "instances" to instances.mapValues { (_, value) -> mapOf("javaClass" to value.javaClass.name, "resolvedPublicReads" to keys.associateWith { value.get(it) }) },
            )
        }

        private fun objectGraph(): Map<String, Map<String, Any>> = mapOf(
            "sources" to sources.toMap(), "data" to data.toMap(), "chapters" to chapters.toMap(), "instances" to instances.toMap(),
        )

        // Per-run diagnostics only. Never make process-dependent identity hashes semantic golden values.
        fun runtimeIdentity(): Map<String, Any?> {
            val current = objectGraph()
            return mapOf("identityHashCodes" to current.mapValues { (_, values) -> values.mapValues { (_, value) -> System.identityHashCode(value) } },
                "referenceEqualityToSetup" to current.mapValues { (group, values) -> values.mapValues { (id, value) -> value === setupObjects.getValue(group).getValue(id) } })
        }

        fun cleanup(): Map<String, Any?> {
            val failures = arrayListOf<Map<String, Any?>>()
            fun attempt(block: () -> Unit) { try { block() } catch (error: Throwable) { failures.add(exception(error)) } }
            // Include every variable this fixture can write, even if setup failed partway.
            data.values.forEach { value -> (keys + value.variableMap.keys).distinct().forEach { key -> attempt { value.putVariable(key, null) } } }
            chapters.values.forEach { value -> (keys + value.variableMap.keys).distinct().forEach { key -> attempt { value.putVariable(key, null) } } }
            sources.values.forEach { source ->
                keys.forEach { key -> attempt { CacheManager.delete("v_${source.bookSourceUrl}_$key") } }
                attempt { source.clearSharedGlobalState() }
            }
            return mapOf("completed" to failures.isEmpty(), "errors" to failures,
                "sourceURLs" to sources.values.map { it.bookSourceUrl }, "keys" to keys,
                "globalCacheCleared" to false, "sourceSharedStateRemoved" to failures.isEmpty())
        }
    }

    companion object {
        const val SUITE = "TraditionalStatefulRuleObservation"
        const val VERSION = "legado-traditional-stateful-public-v1"
        const val ASSET = "legado-reference/traditional-stateful-cases.json"
        const val REPORT = "legado-reference/traditional-stateful-golden.json"
        private const val ARCHIVE = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
        private const val FIXTURE_SHA256 = "a7e0b23bc73c1a32c6d99466aebad25eee8e3c227e12e4d98efccb53d0008ddf"

        private fun JsonObject.text(name: String): String {
            val value = requireNotNull(get(name)) { "Missing string $name" }
            require(value.isJsonPrimitive && value.asJsonPrimitive.isString) { "Expected string $name" }
            return value.asString
        }
        private fun JsonObject.optionalText(name: String): String? {
            val value = requireNotNull(get(name)) { "Missing nullable string $name" }
            return if (value.isJsonNull) null else text(name)
        }
        private fun typed(value: Any?): Map<String, Any?> {
            // Read the boxed object's class before Boolean smart-cast/unboxing.
            val javaClass = value?.javaClass?.name
            return when (value) {
                null -> mapOf("kind" to "null", "javaClass" to null, "value" to null)
                is String -> mapOf("kind" to "string", "javaClass" to javaClass, "value" to value)
                is Boolean -> mapOf("kind" to "boolean", "javaClass" to javaClass, "value" to value)
                is Number -> mapOf("kind" to "number", "javaClass" to javaClass, "value" to value.toString())
                is Element -> mapOf("kind" to "element", "javaClass" to javaClass, "outerHTML" to value.outerHtml(), "text" to value.text())
                is List<*> -> mapOf("kind" to "list", "javaClass" to javaClass, "items" to value.map { typed(it) })
                else -> error("Unreviewed returned Java type: $javaClass")
            }
        }
        private fun exception(error: Throwable, seen: IdentityHashMap<Throwable, Boolean> = IdentityHashMap()): Map<String, Any?> {
            require(seen.put(error, true) == null && seen.size <= 32) { "Cyclic or excessively deep exception causes cannot be silently truncated" }
            return linkedMapOf("className" to error.javaClass.name, "message" to error.message,
                "classHierarchy" to generateSequence<Class<*>>(error.javaClass) { it.superclass }.map { it.name }.toList(),
                "cause" to error.cause?.let { exception(it, seen) })
        }
        private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
