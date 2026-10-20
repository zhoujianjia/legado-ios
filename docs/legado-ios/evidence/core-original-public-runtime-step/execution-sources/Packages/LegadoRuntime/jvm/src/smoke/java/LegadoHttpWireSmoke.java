import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import io.yuedu.legado.LegadoRuntime;
import java.nio.file.Files;
import java.nio.file.Path;
import java.net.ServerSocket;
import java.net.InetSocketAddress;
import java.net.InetAddress;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

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
                Class.forName("okhttp3.OkHttpClient");
                Class.forName("io.yuedu.legado.ProductionHttpTransport");
                Class.forName("org.brotli.dec.BrotliInputStream");
                absent("org.junit.Test"); absent("io.yuedu.legado.OkHttpWireCapabilityProbe");
                absent("io.yuedu.legado.ReferenceLoopbackFixture"); absent("io.yuedu.legado.ProbeOkHttpTransport");
                productionRequest();
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

    /** Exercises the ordinary payload's actual production branch, without test classes. */
    private static void productionRequest() throws Exception {
        var worker = Executors.newSingleThreadExecutor(r -> { var thread = new Thread(r, "ordinary-http-smoke-peer"); thread.setDaemon(true); return thread; });
        try (var listener = new ServerSocket()) {
            listener.bind(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127, 0, 0, 1}), 0));
            listener.setSoTimeout(5000);
            String origin = "http://127.0.0.1:" + listener.getLocalPort();
            var peer = worker.submit(() -> {
                try (var socket = listener.accept()) {
                    socket.setSoTimeout(5000);
                    var head = new ByteArrayOutputStream(); int suffix = 0;
                    while (suffix != 0x0d0a0d0a) {
                        int value = socket.getInputStream().read(); require(value >= 0, "Truncated HTTP request");
                        head.write(value); suffix = (suffix << 8) | value;
                        require(head.size() <= 65536, "HTTP header bound");
                    }
                    String request = head.toString(StandardCharsets.ISO_8859_1);
                    require(request.startsWith("GET /book HTTP/1.1\r\n"), request);
                    var connection = request.lines().filter(line -> line.toLowerCase(java.util.Locale.ROOT).startsWith("connection:"))
                        .map(line -> line.substring(line.indexOf(':') + 1).trim()).toList();
                    require(connection.equals(java.util.List.of("close", "Keep-Alive")), "Repeated headers lost: " + request);
                    byte[] body = "ordinary JVM HTTP 书".getBytes(StandardCharsets.UTF_8);
                    socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: "
                        + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.ISO_8859_1));
                    socket.getOutputStream().write(body); socket.getOutputStream().flush();
                    return request;
                }
            });
            var source = new JsonObject();
            source.addProperty("bookSourceUrl", origin);
            source.addProperty("header", "{\"Connection\":\"close\",\"Accept-Encoding\":\"identity\"}");
            source.addProperty("mainJs", "function search(){return [{name:java.ajax(baseUrl+'/book'),bookUrl:baseUrl+'/book'}];}");
            var created = object(LegadoRuntime.createSession(source.toString(), "{\"httpTransport\":\"jvm-okhttp\"}"));
            require(created.get("ok").getAsBoolean(), created.toString());
            String session = created.get("sessionId").getAsString();
            try {
                var result = object(LegadoRuntime.execute(session, "ordinary-production-http", "search", "{\"timeoutMs\":5000}"));
                Path output = Path.of("build/reports/http-wire/ordinary-production-envelope.json");
                Files.createDirectories(output.getParent()); Files.writeString(output, result.toString());
                require(result.get("ok").getAsBoolean(), result.toString());
                require(result.getAsJsonArray("result").get(0).getAsJsonObject().get("name").getAsString().equals("ordinary JVM HTTP 书"), result.toString());
                peer.get(5, TimeUnit.SECONDS);
                System.out.println("PACKAGED_PRODUCTION_HTTP_OK {\"executionPlatform\":\"desktop\",\"requests\":1,\"g4ValidationPassed\":false}");
            } finally { require(object(LegadoRuntime.closeSession(session)).get("ok").getAsBoolean(), "Could not close production session"); }
        } finally { worker.shutdownNow(); require(worker.awaitTermination(2, TimeUnit.SECONDS), "Production smoke peer did not terminate"); }
    }
}
