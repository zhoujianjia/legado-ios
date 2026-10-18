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
 * An independent scalar-rule observation against unchanged original business code.
 * No expected Android values, parser replacements, HTTP fixtures, or modified
 * AnalyzeRule sources are installed by this test. The existing main-JS test and
 * its android-golden.json report remain separate.
 */
class RuleReplacementGoldenTest {
    @Test
    fun observeOriginalStaticScalarReplacements() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val arguments = InstrumentationRegistry.getArguments()
        val referenceRunId = arguments.getString("referenceRunId")
        val report = linkedMapOf<String, Any?>(
            "schemaVersion" to 1,
            "suite" to SUITE,
            "caseSetVersion" to CASE_SET_VERSION,
            "referenceKind" to "original-archive-android-instrumentation",
            "referenceRunId" to referenceRunId,
            "originalArchiveSHA256" to arguments.getString("archiveSHA256"),
            "applicationClass" to context.applicationContext.javaClass.name,
            "applicationMinSdkVersion" to context.applicationInfo.minSdkVersion,
            "androidApi" to Build.VERSION.SDK_INT,
            "androidRelease" to Build.VERSION.RELEASE,
            "instrumentationRunner" to "androidx.test.runner.AndroidJUnitRunner",
            "entryPoint" to "AnalyzeRule().setContent(text).getString(rule, false)",
            "scope" to "Empty-selector static replacement rules with a nonempty pattern; unescape=false isolates the regex stage. No URL or selector behavior is measured.",
            "passed" to false,
            "total" to 0,
            "executed" to 0,
            "failed" to 0,
            "iosValidationPassed" to false,
        )
        val observations = arrayListOf<Map<String, Any?>>()
        report["cases"] = observations
        try {
            require(referenceRunId != null && UUID.fromString(referenceRunId).toString() == referenceRunId) {
                "referenceRunId must be a canonical UUID"
            }
            require(arguments.getString("archiveSHA256") == ARCHIVE_SHA256) { "Wrong original archive identity" }
            require(context.applicationContext.javaClass.name == "io.legado.app.App") { "Original Application is required" }
            require(context.applicationInfo.minSdkVersion == 26) { "Expected the isolated reference minimum-SDK override" }

            val fixtureBytes = instrumentation.context.assets.open(FIXTURE_ASSET).use { it.readBytes() }
            report["fixtureSHA256"] = sha256(fixtureBytes)
            val fixture = JsonParser.parseString(fixtureBytes.toString(Charsets.UTF_8)).asJsonObject
            require(fixture["schemaVersion"].asInt == 1 && string(fixture, "suite") == SUITE)
            require(string(fixture, "caseSetVersion") == CASE_SET_VERSION)
            val provenance = fixture["sourceProvenance"].asJsonObject
            require(string(provenance, "archiveSHA256") == ARCHIVE_SHA256)
            require(string(provenance, "path") == ORIGINAL_PATH)
            require(string(provenance, "fileSHA256") == ORIGINAL_SOURCE_SHA256)
            report["sourceProvenance"] = provenance

            val cases = fixture["cases"].asJsonArray
            require(cases.size() == CASE_IDS.size) { "Incomplete replacement fixture" }
            require(cases.map { string(it.asJsonObject, "caseId") } == CASE_IDS) { "Unexpected replacement case set or order" }
            report["total"] = cases.size()
            var failed = 0
            for (item in cases) {
                val input = item.asJsonObject
                val record = linkedMapOf<String, Any?>("caseId" to string(input, "caseId"))
                observations.add(record)
                try {
                    require(!input.has("actual") && !input.has("expected")) { "Fixture contains an invented reference output" }
                    val text = string(input, "text")
                    val rule = string(input, "rule")
                    record["text"] = text
                    record["rule"] = rule
                    val segments = rule.trim { it <= ' ' }.split("##")
                    require(segments.size > 1 && segments[0].trim().isEmpty() && segments[1].isNotEmpty()) {
                        "Only empty-selector, nonempty-pattern replacement rules are in this suite"
                    }
                    // This is the actual original entry point. In particular,
                    // do not reproduce replaceRegex here or use the ported core.
                    record["actual"] = AnalyzeRule().setContent(text).getString(rule, false)
                    record["passed"] = true
                } catch (error: Throwable) {
                    failed++
                    record["passed"] = false
                    record["exception"] = exception(error)
                }
                report["executed"] = observations.size
                report["failed"] = failed
            }
            report["passed"] = observations.size == CASE_IDS.size && failed == 0
        } catch (error: Throwable) {
            report["failure"] = exception(error)
        } finally {
            // Retain partial observations even when setup or an original call
            // fails. The driver must authenticate the run ID and fixture hash.
            val output = File(context.filesDir, REPORT_PATH)
            output.parentFile?.let { require(it.isDirectory || it.mkdirs()) { "Cannot create report directory" } }
            output.writeText(GSON.newBuilder().serializeNulls().setPrettyPrinting().create().toJson(report), Charsets.UTF_8)
        }
        assertTrue("Original scalar-rule observation failed; inspect $REPORT_PATH", report["passed"] == true)
    }

    private fun string(value: JsonObject, name: String): String {
        val item: JsonElement = requireNotNull(value[name]) { "Missing string field: $name" }
        require(item.isJsonPrimitive && item.asJsonPrimitive.isString) { "Not a string field: $name" }
        return item.asString
    }

    private fun exception(error: Throwable): Map<String, Any?> =
        linkedMapOf("className" to error.javaClass.name, "message" to error.message)

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    companion object {
        const val FIXTURE_ASSET = "legado-reference/rule-replacement-cases.json"
        const val REPORT_PATH = "legado-reference/rule-replacement-golden.json"
        const val SUITE = "StaticRuleReplacement"
        const val CASE_SET_VERSION = "legado-static-rule-replacement-v1"
        private const val ARCHIVE_SHA256 = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
        private const val ORIGINAL_PATH = "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt"
        private const val ORIGINAL_SOURCE_SHA256 = "5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9"
        private val CASE_IDS = listOf(
            "replace-all-number-groups", "extract-first-match", "extract-first-no-match",
            "invalid-pattern-literal-fallback", "invalid-pattern-extract-fallback",
            "invalid-group-literal-fallback", "invalid-group-extract-fallback",
            "missing-replacement-deletes", "named-capture-replacement", "linebreak-unicode-preservation",
            "zero-width-boundaries", "escaped-literal-dollar", "escaped-literal-backslash",
            "extract-zero-width-reapplies-in-match", "extract-lookbehind-reapplies-in-match",
            "fourth-segment-enables-extraction", "explicit-empty-replacement", "regex-case-sensitive"
        )
    }
}
