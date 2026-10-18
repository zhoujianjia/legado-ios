import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import io.yuedu.legado.StaticRuleReplacement;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;

/**
 * JDK 21 source-file runner for the actual assembled port, without JUnit.
 * Arguments: fixturePath outputPath sourceCommit aggregateJarPath.
 * Run with -Xint -Xmx128m -cp aggregateJarPath before this Java filename.
 * The source commit is a caller-supplied run label; jarSHA256 authenticates
 * the exact artifact from which the kernel class is loaded.
 */
public class StaticRuleReplacementPortTrace {
    private static final String SUITE = "StaticRuleReplacement";
    private static final String VERSION = "legado-static-rule-replacement-v1";
    private static final Gson GSON = new GsonBuilder().serializeNulls()
        .disableHtmlEscaping().setPrettyPrinting().create();
    private static final List<String> CASE_IDS = List.of(
        "replace-all-number-groups", "extract-first-match", "extract-first-no-match",
        "invalid-pattern-literal-fallback", "invalid-pattern-extract-fallback",
        "invalid-group-literal-fallback", "invalid-group-extract-fallback",
        "missing-replacement-deletes", "named-capture-replacement", "linebreak-unicode-preservation",
        "zero-width-boundaries", "escaped-literal-dollar", "escaped-literal-backslash",
        "extract-zero-width-reapplies-in-match", "extract-lookbehind-reapplies-in-match",
        "fourth-segment-enables-extraction", "explicit-empty-replacement", "regex-case-sensitive"
    );

    public static void main(String[] args) throws Exception {
        if (args.length != 4) {
            System.err.println("Usage: StaticRuleReplacementPortTrace.java fixturePath outputPath sourceCommit aggregateJarPath");
            System.exit(2);
            return;
        }
        Path output = Path.of(args[1]);
        JsonObject report = new JsonObject();
        report.addProperty("schemaVersion", 1);
        report.addProperty("suite", SUITE);
        report.addProperty("caseSetVersion", VERSION);
        report.addProperty("executionPlatform", "jvm-desktop");
        report.addProperty("referenceKind", "ported-rule-kernel");
        report.addProperty("sourceCommit", args[2]);
        report.addProperty("sourceCommitKind", "caller-checkout-label");
        report.addProperty("sourceCommitScope", "Caller-supplied run source label; jarSHA256 identifies the loaded kernel artifact.");
        report.addProperty("javaVersion", System.getProperty("java.version"));
        report.addProperty("vmName", System.getProperty("java.vm.name"));
        report.addProperty("vmVersion", System.getProperty("java.vm.version"));
        report.addProperty("osName", System.getProperty("os.name"));
        report.addProperty("iosValidationPassed", false);
        report.addProperty("g4ValidationPassed", false);
        report.addProperty("passed", false);
        report.addProperty("total", 0);
        report.addProperty("executed", 0);
        report.addProperty("failed", 0);
        JsonArray observations = new JsonArray();
        report.add("cases", observations);
        try {
            require(args[2].matches("[0-9a-f]{40}"), "sourceCommit must be 40 lowercase hexadecimal characters");
            Path jar = Path.of(args[3]).toRealPath();
            require(Files.isRegularFile(jar), "aggregateJarPath must be a regular file");
            Path loadedFrom = Path.of(StaticRuleReplacement.class.getProtectionDomain()
                .getCodeSource().getLocation().toURI()).toRealPath();
            require(loadedFrom.equals(jar), "Kernel was not loaded from aggregateJarPath");
            report.addProperty("jarSHA256", sha256(jar));

            byte[] fixtureBytes = Files.readAllBytes(Path.of(args[0]));
            report.addProperty("fixtureSHA256", HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(fixtureBytes)));
            JsonObject fixture = JsonParser.parseString(new String(fixtureBytes, StandardCharsets.UTF_8)).getAsJsonObject();
            require(fixture.get("schemaVersion").getAsInt() == 1, "Unexpected fixture schema");
            require(string(fixture, "suite").equals(SUITE) && string(fixture, "caseSetVersion").equals(VERSION), "Unexpected fixture suite/version");
            JsonObject provenance = fixture.getAsJsonObject("sourceProvenance");
            require(provenance != null && string(provenance, "archiveSHA256").equals("724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd")
                && string(provenance, "path").equals("app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt")
                && string(provenance, "fileSHA256").equals("5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9"), "Unexpected original-source provenance");
            report.add("sourceProvenance", provenance.deepCopy());
            report.addProperty("originalArchiveSHA256", string(provenance, "archiveSHA256"));
            JsonArray cases = fixture.getAsJsonArray("cases");
            require(cases != null && cases.size() == CASE_IDS.size(), "Incomplete fixed replacement case set");
            for (int index = 0; index < CASE_IDS.size(); index++) {
                require(string(cases.get(index).getAsJsonObject(), "caseId").equals(CASE_IDS.get(index)), "Unexpected case ID/order at " + index);
            }
            report.addProperty("total", cases.size());
            int failed = 0;
            for (JsonElement item : cases) {
                JsonObject input = item.getAsJsonObject();
                JsonObject observation = new JsonObject();
                observation.addProperty("caseId", string(input, "caseId"));
                observations.add(observation);
                try {
                    require(!input.has("actual") && !input.has("expected"), "Input fixture must not contain reference outputs");
                    String text = string(input, "text");
                    String rule = string(input, "rule");
                    observation.addProperty("text", text);
                    observation.addProperty("rule", rule);
                    // No local substitute algorithm or output lookup: invoke the
                    // kernel class authenticated against aggregateJarPath above.
                    observation.addProperty("actual", StaticRuleReplacement.INSTANCE.evaluate(text, rule));
                    observation.addProperty("passed", true);
                } catch (Throwable error) {
                    failed++;
                    observation.addProperty("passed", false);
                    observation.add("exception", exception(error));
                }
                report.addProperty("executed", observations.size());
                report.addProperty("failed", failed);
            }
            report.addProperty("passed", observations.size() == CASE_IDS.size() && failed == 0);
        } catch (Throwable error) {
            report.add("failure", exception(error));
        } finally {
            Path parent = output.toAbsolutePath().getParent();
            if (parent != null) Files.createDirectories(parent);
            Files.writeString(output, GSON.toJson(report) + "\n", StandardCharsets.UTF_8);
        }
        boolean passed = report.get("passed").getAsBoolean();
        System.out.println((passed ? "PORT_RULE_TRACE_OK " : "PORT_RULE_TRACE_FAILED ")
            + "executed=" + report.get("executed") + " failed=" + report.get("failed") + " output=" + output);
        if (!passed) System.exit(1);
    }

    private static String string(JsonObject object, String name) {
        JsonElement element = object.get(name);
        require(element != null && element.isJsonPrimitive() && element.getAsJsonPrimitive().isString(), "Missing/non-string field: " + name);
        return element.getAsString();
    }

    private static JsonObject exception(Throwable error) {
        JsonObject result = new JsonObject();
        result.addProperty("className", error.getClass().getName());
        result.addProperty("message", error.getMessage());
        return result;
    }

    private static String sha256(Path path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = Files.newInputStream(path)) {
            byte[] buffer = new byte[64 * 1024];
            for (int count; (count = input.read(buffer)) != -1;) digest.update(buffer, 0, count);
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new IllegalArgumentException(message);
    }
}
