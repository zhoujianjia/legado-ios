import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import io.yuedu.legado.LegadoRuntime;
import java.nio.file.Files;
import java.nio.file.Path;

/** Exercises the assembled JAR on desktop; this does not assert an iOS run. */
public class LegadoHttpWireSmoke {
    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static JsonObject object(String value) {
        return JsonParser.parseString(value).getAsJsonObject();
    }
    private static void absent(String name) throws Exception {
        try {
            Class.forName(name);
            throw new AssertionError("Ordinary payload contains " + name);
        } catch (ClassNotFoundException expected) { }
    }
    public static void main(String[] args) throws Exception {
        require(args.length == 1 && (args[0].equals("present") || args[0].equals("absent")), "Use present or absent");
        boolean expectedPresent = args[0].equals("present");
        var created = object(LegadoRuntime.createSession("{\"bookSourceUrl\":\"https://wire-smoke.invalid\",\"mainJs\":\"function search(){return []}\"}"));
        require(created.get("ok").getAsBoolean(), created.toString());
        String session = created.get("sessionId").getAsString();
        try {
            String envelope = LegadoRuntime.execute(session, "packaged-http-wire", "httpWireCapabilityProbe", "{\"timeoutMs\":50000}");
            Path output = Path.of("build", "reports", "http-wire", expectedPresent
                ? "packaged-operation-envelope.json" : "ordinary-operation-envelope.json");
            Files.createDirectories(output.getParent()); Files.writeString(output, envelope);
            var operation = object(envelope);
            if (!expectedPresent) {
                require(!operation.get("ok").getAsBoolean(), "Ordinary diagnostic must be unavailable");
                require(operation.getAsJsonObject("error").get("code").getAsString().equals("HTTP_WIRE_PROBE_NOT_PACKAGED"), operation.toString());
                absent("okhttp3.OkHttpClient"); absent("io.yuedu.legado.OkHttpWireCapabilityProbe");
                absent("io.yuedu.legado.ReferenceLoopbackFixture"); absent("io.yuedu.legado.ProbeOkHttpTransport");
                System.out.println("PACKAGED_HTTP_WIRE_ABSENT_OK {\"executionPlatform\":\"desktop\",\"g4ValidationPassed\":false}");
                return;
            }
            require(operation.get("ok").getAsBoolean(), operation.toString());
            var report = operation.getAsJsonObject("result");
            require(report.get("suite").getAsString().equals("OkHttpWireCapabilityProbe"), "Unexpected suite");
            require(report.get("passed").getAsBoolean() && report.get("loopbackOnly").getAsBoolean(), report.toString());
            require(!report.get("g4ValidationPassed").getAsBoolean(), "A fixed desktop fixture cannot complete G4");
            var requests = report.getAsJsonObject("wireSnapshot").getAsJsonArray("requests");
            require(requests.size() == 7 && report.getAsJsonArray("transportResponses").size() == 7, "Require seven actual requests and responses");
            for (var entry : requests) {
                var request = entry.getAsJsonObject();
                require(request.get("responseWritten").getAsBoolean(), "Peer did not write a complete response");
                require(request.get("httpVersion").getAsString().equals("HTTP/1.1"), "Wire protocol changed");
                require(request.has("rawHeadBase64") && request.has("rawRequestSHA256"), "Missing raw capture");
            }
            var cleanup = report.getAsJsonObject("cleanup");
            var transport = cleanup.getAsJsonObject("transport");
            require(transport.get("passed").getAsBoolean() && transport.get("dispatcherStopped").getAsBoolean(), "Transport worker remains active");
            require(transport.get("activeCalls").getAsInt() == 0 && transport.get("pooledConnections").getAsInt() == 0, "Transport resources remain active");
            var server = cleanup.getAsJsonObject("server");
            for (String key : new String[]{"listenerClosed", "activeSocketClosed", "workerStopped"}) {
                require(server.get(key).getAsBoolean(), "Server cleanup failed: " + key);
            }
            require(cleanup.get("isolatedSessionClosed").getAsBoolean() && cleanup.getAsJsonArray("errors").isEmpty(), "Isolated task cleanup failed");
            System.out.println("PACKAGED_HTTP_WIRE_OK {\"executionPlatform\":\"desktop\",\"requests\":7,\"responses\":7,\"g4ValidationPassed\":false}");
        } finally {
            require(object(LegadoRuntime.closeSession(session)).get("ok").getAsBoolean(), "Could not close smoke session");
        }
    }
}
