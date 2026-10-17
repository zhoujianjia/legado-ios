import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import io.yuedu.legado.LegadoRuntime;
import java.util.HashSet;

/** Runs against only the assembled JAR, proving optional test packaging and real execution. */
public class LegadoSemanticSuiteSmoke {
    private static JsonObject checked(String json) {
        var result = JsonParser.parseString(json).getAsJsonObject();
        if (!result.get("ok").getAsBoolean()) throw new AssertionError(json);
        return result;
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !(args[0].equals("present") || args[0].equals("absent")))
            throw new IllegalArgumentException("Expected present or absent");
        var source = "{\"bookSourceUrl\":\"https://fixture.invalid\",\"mainJs\":\"function search(){return [];}\"}";
        var session = checked(LegadoRuntime.createSession(source)).get("sessionId").getAsString();
        try {
            var interopResponse = checked(LegadoRuntime.execute(session, "packaged-interop-suite",
                "interopSuite", "{\"timeoutMs\":300000}"));
            var interop = interopResponse.getAsJsonObject("result");
            if (!interop.get("suite").getAsString().equals("InteropSemanticSuite") ||
                !interop.get("caseSetVersion").getAsString().equals("legado-interop-v1") ||
                !interop.get("passed").getAsBoolean() || interop.get("passedCount").getAsInt() != 28 ||
                interop.get("failed").getAsInt() != 0 || interop.get("total").getAsInt() != 28 ||
                interop.getAsJsonArray("tests").size() != interop.get("total").getAsInt())
                throw new AssertionError(interopResponse);
            var interopNames = new HashSet<String>();
            for (var entry : interop.getAsJsonArray("tests")) {
                var test = entry.getAsJsonObject();
                if (!test.get("passed").getAsBoolean() ||
                    !interopNames.add(test.get("name").getAsString()) ||
                    !test.has("actual") || !test.has("expected") ||
                    !test.get("actual").getAsString().equals(test.get("expected").getAsString()))
                    throw new AssertionError(interopResponse);
            }
            System.out.println("PACKAGED_INTEROP_SUITE_OK " + interopResponse);
            var response = JsonParser.parseString(LegadoRuntime.execute(session, "packaged-semantic-suite",
                "semanticSuite", "{\"timeoutMs\":300000}")).getAsJsonObject();
            if (args[0].equals("absent")) {
                if (response.get("ok").getAsBoolean() ||
                    !response.getAsJsonObject("error").get("code").getAsString().equals("SEMANTIC_SUITE_NOT_PACKAGED"))
                    throw new AssertionError(response);
                for (var name : new String[]{"org.junit.Test", "io.legado.app.JsEngineCapabilitiesTest"}) {
                    try { Class.forName(name); throw new AssertionError("Unexpected diagnostic class: " + name); }
                    catch (ClassNotFoundException expected) { }
                }
                System.out.println("PACKAGED_SUITE_ABSENT_OK " + response);
                return;
            }
            var suite = checked(response.toString()).getAsJsonObject("result");
            if (!suite.get("suite").getAsString().equals("JsEngineCapabilitiesTest") ||
                suite.get("total").getAsInt() != 25 || suite.get("passed").getAsInt() != 25 ||
                suite.get("failed").getAsInt() != 0 || suite.get("skipped").getAsInt() != 0 ||
                suite.getAsJsonArray("tests").size() != 25) throw new AssertionError(response);
            var names = new HashSet<String>();
            for (var entry : suite.getAsJsonArray("tests")) {
                var test = entry.getAsJsonObject();
                if (!test.get("passed").getAsBoolean() || !names.add(test.get("name").getAsString()))
                    throw new AssertionError(response);
            }
            var beans = suite.getAsJsonObject("javaBeans");
            if (!beans.get("passed").getAsBoolean() || !beans.get("propertyName").getAsString().equals("value") ||
                !beans.get("readMethod").getAsString().equals("getValue") ||
                !beans.get("writeMethod").getAsString().equals("setValue")) throw new AssertionError(response);
            for (var property : new String[]{"javaVersion", "vmVersion", "vmName"})
                if (suite.get(property).getAsString().isBlank()) throw new AssertionError(response);
            System.out.println("PACKAGED_SEMANTIC_SUITE_OK " + response);
        } finally { checked(LegadoRuntime.closeSession(session)); }
    }
}
