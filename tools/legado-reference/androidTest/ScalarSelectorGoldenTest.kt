package io.legado.app.reference

import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.utils.GSON
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/**
 * Original AnalyzeRule only: getString 302-381, splitSourceRule 593-635,
 * SourceRule.makeUpRule 776-835 and replaceRegex 544-568. Node setup also uses
 * public getElements. No copied selectors, replacement kernel or port adapter.
 */
class ScalarSelectorGoldenTest {
    @Test
    fun observeOriginalScalarSelectionReplacementAndUnescape() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val arguments = InstrumentationRegistry.getArguments()
        val runId = arguments.getString("referenceRunId")
        val serializer = GSON.newBuilder().serializeNulls().setPrettyPrinting().create()
        val observations = arrayListOf<Map<String, Any?>>()
        val report = linkedMapOf<String, Any?>(
            "schemaVersion" to 1, "suite" to SUITE, "caseSetVersion" to VERSION,
            "referenceKind" to "original-archive-android-instrumentation", "referenceRunId" to runId,
            "originalArchiveSHA256" to arguments.getString("archiveSHA256"),
            "applicationClass" to context.applicationContext.javaClass.name,
            "applicationMinSdkVersion" to context.applicationInfo.minSdkVersion,
            "androidApi" to Build.VERSION.SDK_INT, "androidRelease" to Build.VERSION.RELEASE,
            "instrumentationRunner" to "androidx.test.runner.AndroidJUnitRunner", "entryPoints" to APIS,
            "passedMeaning" to "All 28 original observations completed; ordinary API exceptions are outcomes, never port acceptance.",
            "scope" to "Fixed static non-URL scalar selectors, replacement and optional final HTML unescape; no private sources, JS, HTTP or port comparator.",
            "passed" to false, "total" to TOTAL, "executed" to 0, "failed" to 0,
            "returnedObservations" to 0, "exceptionObservations" to 0,
            "iosValidationPassed" to false, "deviceValidationPassed" to false,
            "compatibilityValidationPassed" to false, "g4ValidationPassed" to false,
            "fullFeatureParityEstablished" to false, "observations" to observations,
        )
        try {
            require(runId != null && UUID.fromString(runId).toString() == runId) { "Canonical referenceRunId required" }
            require(arguments.getString("archiveSHA256") == ARCHIVE) { "Original archive identity differs" }
            require(context.applicationContext.javaClass.name == "io.legado.app.App") { "Original Application required" }
            require(context.applicationInfo.minSdkVersion == 26) { "Reference minSdk override differs" }
            val fixtureBytes = instrumentation.context.assets.open(ASSET).use { it.readBytes() }
            report["fixtureSHA256"] = sha256(fixtureBytes)
            val fixture = JsonParser.parseString(fixtureBytes.toString(Charsets.UTF_8)).asJsonObject
            require(fixture["schemaVersion"].asInt == 1 && string(fixture, "suite") == SUITE)
            require(string(fixture, "caseSetVersion") == VERSION)
            require(fixture["apis"].asJsonArray.map { it.asString } == APIS)
            val provenance = fixture["sourceProvenance"].asJsonObject
            require(string(provenance, "archiveSHA256") == ARCHIVE)
            val sources = provenance["files"].asJsonArray
            require(sources.size() == SOURCE_HASHES.size)
            require(sources.map { string(it.asJsonObject, "path") } == SOURCE_HASHES.keys.toList())
            sources.forEach { element ->
                val source = element.asJsonObject
                require(source.keySet() == setOf("path", "fileSHA256"))
                require(string(source, "fileSHA256") == SOURCE_HASHES[string(source, "path")])
            }
            report["sourceProvenance"] = provenance
            val cases = fixture["cases"].asJsonArray
            require(cases.size() == CASE_IDS.size && cases.map { string(it.asJsonObject, "caseId") } == CASE_IDS)
            var failures = 0
            var returns = 0
            var exceptions = 0
            for (element in cases) {
                val input = element.asJsonObject
                require(input.keySet() == setOf("caseId", "content", "context", "rule")) { "Fixture must contain only inputs" }
                val caseId = string(input, "caseId")
                val content = string(input, "content")
                val rule = string(input, "rule")
                val nodeSetup = input["context"].asJsonObject
                require(nodeSetup.keySet() == setOf("kind", "rule", "index"))
                val kind = string(nodeSetup, "kind")
                val setupRule = string(nodeSetup, "rule")
                require(nodeSetup["index"].isJsonPrimitive && nodeSetup["index"].asJsonPrimitive.isNumber
                    && nodeSetup["index"].asString == "0")
                require((kind == "document" && setupRule.isEmpty())
                    || (kind == "css-element" && setupRule == "tag.article")
                    || (kind == "xpath-node" && setupRule == "//article"))
                val parts = rule.trim { it <= ' ' }.split("##")
                require(parts.size > 1 && parts[0].trim().isNotEmpty() && parts[1].isNotEmpty())
                for (api in APIS) {
                    val observation = linkedMapOf<String, Any?>(
                        "caseId" to caseId, "api" to api, "content" to content, "context" to nodeSetup, "rule" to rule,
                        "unescape" to (api == "getString-default"), "defaultArgumentUsed" to (api == "getString-default"),
                        "setupCompleted" to false, "apiInvoked" to false, "completed" to false,
                        "contextJavaClass" to null, "actual" to null, "javaClass" to null,
                        "exception" to null, "observationFailure" to null,
                    )
                    observations.add(observation)
                    try {
                        // Setup and public node selection are outside the API
                        // outcome catch. A missing node or failed constructor
                        // must not count as a completed getString exception.
                        val selected: Any = if (kind == "document") content else {
                            val nodes = AnalyzeRule().setContent(content).getElements(setupRule)
                            require(nodes.size > 0) { "Public context selection returned no node" }
                            nodes[0]
                        }
                        require(selected.javaClass.name == CONTEXT_CLASSES[kind]) { "Unexpected public context Java class" }
                        observation["contextJavaClass"] = selected.javaClass.name
                        val original = AnalyzeRule().setContent(selected)
                        observation["setupCompleted"] = true
                        var apiFailure: Exception? = null
                        observation["apiInvoked"] = true
                        val value: String? = try {
                            when (api) {
                                "getString-unescape-false" -> original.getString(rule, false)
                                // Original 302's one-argument call uses its
                                // default mContent/isUrl and 315's unescape=true;
                                // the Boolean overload 308 requires two args.
                                "getString-default" -> original.getString(rule)
                                else -> error("Unknown scalar observation API")
                            }
                        } catch (error: Exception) { apiFailure = error; null }
                        if (apiFailure != null) {
                            observation["outcome"] = "exception"
                            observation["exception"] = exception(apiFailure)
                            exceptions++
                        } else {
                            // Retain the original String verbatim. No trim,
                            // unescape, JSON parsing or helper-value projection.
                            observation["actual"] = requireNotNull(value) { "Original String API returned null" }
                            observation["javaClass"] = value.javaClass.name
                            observation["outcome"] = "return"
                            returns++
                        }
                        observation["completed"] = true
                    } catch (error: Throwable) {
                        failures++
                        observation["observationFailure"] = exception(error)
                        if (error is Error) throw error
                    } finally {
                        report["executed"] = observations.count { it["completed"] == true }
                        report["failed"] = failures
                        report["returnedObservations"] = returns
                        report["exceptionObservations"] = exceptions
                    }
                }
            }
            report["passed"] = observations.size == TOTAL && report["executed"] == TOTAL && failures == 0
        } catch (error: Throwable) {
            report["failure"] = exception(error)
        } finally {
            val output = File(context.filesDir, REPORT)
            output.parentFile?.let { require(it.isDirectory || it.mkdirs()) { "Cannot create observation directory" } }
            output.writeText(serializer.toJson(report), Charsets.UTF_8)
        }
        assertTrue("Original scalar selector observation incomplete; inspect $REPORT", report["passed"] == true)
    }

    private fun string(value: JsonObject, name: String): String {
        val item: JsonElement = requireNotNull(value[name]) { "Missing string: $name" }
        require(item.isJsonPrimitive && item.asJsonPrimitive.isString) { "Expected string: $name" }
        return item.asString
    }

    private fun exception(error: Throwable): Map<String, Any?> = linkedMapOf(
        "className" to error.javaClass.name, "message" to error.message,
        "classHierarchy" to generateSequence<Class<*>>(error.javaClass) { it.superclass }.map { it.name }.toList(),
    )

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    companion object {
        const val SUITE = "ScalarSelectorRuleObservation"
        const val VERSION = "legado-scalar-selector-public-v1"
        const val ASSET = "legado-reference/scalar-selector-cases.json"
        const val REPORT = "legado-reference/scalar-selector-golden.json"
        const val TOTAL = 28
        private const val ARCHIVE = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
        private val APIS = listOf("getString-unescape-false", "getString-default")
        private val CASE_IDS = listOf("css-unicode-group-replace", "css-element-joined-before-replace", "css-missing-skips-empty-replace",
            "css-attribute-whitespace", "xpath-document-text", "xpath-node-relative-text", "xpath-missing-empty-replace",
            "json-string-unicode-newline", "json-missing-empty-replace", "json-invalid-empty-replace",
            "json-null-empty-replace", "static-delimiter-whitespace", "entity-in-json-result", "entity-introduced-by-replacement")
        private val CONTEXT_CLASSES = mapOf("document" to "java.lang.String", "css-element" to "org.jsoup.nodes.Element",
            "xpath-node" to "org.seimicrawler.xpath.JXNode")
        private val SOURCE_HASHES = linkedMapOf(
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt" to "5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSoup.kt" to "9889421f76a8fda62b0b874e70d0535f2b781b59a9c84fa797af695a9f8cccfa",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByXPath.kt" to "b6ee22cc3242313f8d5e3758dc93ff06891eeec7b3ab9ee9267ebac11145d842",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt" to "ee5ee9ebc95b4f5d6e2d459d6f727fccd10a6bd6a36ce872547f6cee5684109d",
            "app/src/main/java/io/legado/app/model/analyzeRule/RuleAnalyzer.kt" to "74ab0152bce9d5e014cc69d9c6974cbb093d8353200f1452066f7d05102265a7",
            "app/src/main/java/io/legado/app/model/analyzeRule/SourceHtmlParser.kt" to "252630eef2545dc71b3c30905accc93dc834b78bfff2f207769e2aabfd3ed19a",
        )
    }
}
