package io.legado.app.reference

import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.utils.GSON
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Observe original public results and exceptions without deciding port compatibility. */
class JsonPathRuleGoldenTest {
    @Test
    fun observeOriginalPublicJsonPathResults() {
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
            "instrumentationRunner" to "androidx.test.runner.AndroidJUnitRunner",
            "entryPoints" to APIS,
            "passedMeaning" to "All observations completed; an original API exception is a recorded outcome, not a compatibility pass.",
            "scope" to "Fixed JSON text and JSONPath public calls; no HTML unescape, URL conversion, JS, replacement rules or private sources.",
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
                require(input.keySet() == setOf("caseId", "jsonText", "rule")) { "Fixture must contain only inputs" }
                val caseId = string(input, "caseId")
                val jsonText = string(input, "jsonText")
                val rule = string(input, "rule")
                require(rule.isNotEmpty() && JsonParser.parseString(jsonText).isJsonObject)
                for (api in APIS) {
                    val observation = linkedMapOf<String, Any?>(
                        "caseId" to caseId, "api" to api, "jsonText" to jsonText, "rule" to rule,
                        "apiInvoked" to false, "completed" to false,
                    )
                    observations.add(observation)
                    try {
                        // Only original public methods; each invocation has fresh
                        // state, no onError override, no unescape or URL rewrite.
                        // Construction/content setup is not an API outcome.
                        // A failure here leaves apiInvoked=false and is recorded
                        // by the outer observation-failure handler.
                        val original = AnalyzeRule().setContent(jsonText)
                        var apiFailure: Exception? = null
                        observation["apiInvoked"] = true
                        val value: Any? = try {
                            when (api) {
                                "getString" -> original.getString(rule, false)
                                "getStringList" -> original.getStringList(rule)
                                "getElements" -> original.getElements(rule)
                                else -> error("Unknown observation API")
                            }
                        } catch (error: Exception) { apiFailure = error; null }
                        if (apiFailure != null) {
                            observation["outcome"] = "exception"
                            observation["actual"] = JsonNull.INSTANCE
                            observation["javaClass"] = null
                            observation["elementJavaClasses"] = null
                            observation["exception"] = exception(apiFailure)
                            exceptions++
                        } else {
                            // Keep raw JSON types, nulls, list order and text.
                            // Serialization failures are observation failures,
                            // separate from an exception thrown by the API.
                            observation["actual"] = serializer.toJsonTree(value)
                            observation["javaClass"] = value?.javaClass?.name
                            observation["elementJavaClasses"] = when (value) {
                                is Iterable<*> -> value.map { it?.javaClass?.name }
                                is Array<*> -> value.map { it?.javaClass?.name }
                                else -> null
                            }
                            observation["exception"] = null
                            observation["outcome"] = "return"
                            returns++
                        }
                        observation["completed"] = true
                    } catch (error: Throwable) {
                        failures++
                        observation["observationFailure"] = exception(error)
                        report["failed"] = failures
                        // Preserve the partial report but stop on VM/linkage or
                        // other Errors; they cannot become ordinary API results.
                        if (error is Error) throw error
                    }
                    report["executed"] = observations.count { it["completed"] == true }
                    report["failed"] = failures
                    report["returnedObservations"] = returns
                    report["exceptionObservations"] = exceptions
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
        assertTrue("Original JSONPath observation incomplete; inspect $REPORT", report["passed"] == true)
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
        const val SUITE = "JsonPathRuleObservation"
        const val VERSION = "legado-jsonpath-public-v1"
        const val ASSET = "legado-reference/jsonpath-rule-cases.json"
        const val REPORT = "legado-reference/jsonpath-rule-golden.json"
        const val TOTAL = 36
        private const val ARCHIVE = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
        private val APIS = listOf("getString", "getStringList", "getElements")
        private val CASE_IDS = listOf("scalar-unicode-newline", "missing-path", "invalid-balanced-path", "explicit-null",
            "mixed-list", "empty-list", "object-result", "or-missing-fallback", "or-invalid-fallback", "and-lists",
            "interleave-unequal-lists", "balanced-filter-inner-and")
        private val SOURCE_HASHES = linkedMapOf(
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt" to "5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt" to "ee5ee9ebc95b4f5d6e2d459d6f727fccd10a6bd6a36ce872547f6cee5684109d",
            "app/src/main/java/io/legado/app/model/analyzeRule/RuleAnalyzer.kt" to "74ab0152bce9d5e014cc69d9c6974cbb093d8353200f1452066f7d05102265a7",
        )
    }
}
