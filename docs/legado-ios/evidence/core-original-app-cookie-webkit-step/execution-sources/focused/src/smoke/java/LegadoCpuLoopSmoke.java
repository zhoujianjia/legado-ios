import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import io.yuedu.legado.LegadoRuntime;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.Set;

/** Desktop assembled-payload check; no Simulator or physical-device claim. */
public class LegadoCpuLoopSmoke {
    static void require(boolean condition, String detail) { if (!condition) throw new AssertionError(detail); }
    static JsonObject object(String text) { return JsonParser.parseString(text).getAsJsonObject(); }
    public static void main(String[] args) throws Exception {
        require(args.length == 1 && (args[0].equals("present") || args[0].equals("absent")), "Use present or absent");
        boolean present = args[0].equals("present");
        var created = object(LegadoRuntime.createSession("{\"bookSourceUrl\":\"https://cpu-smoke.invalid\",\"mainJs\":\"function search(){return [];}\"}"));
        require(created.get("ok").getAsBoolean(), created.toString());
        String session = created.get("sessionId").getAsString();
        try {
            String envelope = LegadoRuntime.execute(session, "packaged-cpu-loop", "cpuLoopCapabilityProbe", "{\"timeoutMs\":30000}");
            Path output = Path.of("build/reports/cpu-loop", present ? "packaged-operation-envelope.json" : "ordinary-operation-envelope.json");
            Files.createDirectories(output.getParent()); Files.writeString(output, envelope);
            var operation = object(envelope);
            if (!present) {
                require(!operation.get("ok").getAsBoolean() && operation.getAsJsonObject("error").get("code").getAsString().equals("CPU_LOOP_PROBE_NOT_PACKAGED"), envelope);
                try { Class.forName("io.yuedu.legado.CpuLoopCapabilityProbe"); throw new AssertionError("CPU helper leaked into ordinary payload"); }
                catch (ClassNotFoundException expected) { }
                System.out.println("PACKAGED_CPU_LOOP_ABSENT_OK"); return;
            }
            require(operation.get("ok").getAsBoolean(), envelope);
            var report = operation.getAsJsonObject("result");
            require(report.get("suite").getAsString().equals("CpuLoopCapabilityProbe") && report.get("passed").getAsBoolean(), report.toString());
            require(!report.get("g4ValidationPassed").getAsBoolean() && report.getAsJsonArray("cases").size() == 2, "Fixed scope differs");
            var names = new HashSet<String>();
            for (var element : report.getAsJsonArray("cases")) {
                var item = element.getAsJsonObject();
                String name = item.get("name").getAsString();
                require(names.add(name) && Set.of("public-cancel", "absolute-deadline").contains(name), "Unexpected or duplicate CPU case");
                require(item.get("passed").getAsBoolean() && item.get("sessionClosed").getAsBoolean() && item.get("contextExited").getAsBoolean(), item.toString());
                require(item.get("childDeadlineEpochMs").getAsLong() <= report.get("parentDeadlineEpochMs").getAsLong(), "Child deadline exceeded parent");
                require(item.getAsJsonObject("cpuSample").get("passed").getAsBoolean(), "No positive CPU stack sample");
                String expected = name.equals("public-cancel") ? "CANCELLED" : "TIMEOUT";
                require(object(item.get("operationEnvelope").getAsString()).getAsJsonObject("error").get("code").getAsString().equals(expected), item.toString());
                require(object(item.getAsJsonObject("recovery").get("operationEnvelope").getAsString()).get("result").getAsInt() == 42, "Recovery failed");
            }
            require(names.equals(Set.of("public-cancel", "absolute-deadline")), "Both CPU cases must be present");
            var cleanup = report.getAsJsonObject("cleanup");
            require(cleanup.get("workerStopped").getAsBoolean() && cleanup.get("sessionsClosed").getAsBoolean() && cleanup.get("registryEmpty").getAsBoolean() && cleanup.getAsJsonArray("errors").isEmpty(), cleanup.toString());
            System.out.println("PACKAGED_CPU_LOOP_OK {\"executionPlatform\":\"desktop\",\"cases\":2,\"g4ValidationPassed\":false}");
        } finally { require(object(LegadoRuntime.closeSession(session)).get("ok").getAsBoolean(), "Could not close smoke session"); }
    }
}
