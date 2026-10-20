import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import java.util.UUID;

/** Only a unique synthetic marker; no host, HTTP or user credentials. */
public final class PreTaskRedactionProbe {
    public static void main(String[] args) {
        String source = "{\"bookSourceUrl\":\"https://redaction-probe.invalid\",\"enabledCookieJar\":false,\"ruleContent\":{}}";
        String options = "{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\"owner:probe\"}";
        JsonObject created = JsonParser.parseString(LegadoRuntime.createSession(source, options)).getAsJsonObject();
        if (!created.get("ok").getAsBoolean()) throw new AssertionError("Synthetic session creation failed");
        String id = created.get("sessionId").getAsString();
        String marker = "OWNED_SYNTHETIC_PRIVATE_TIMEOUT";
        try {
            String request = "{\"credentials\":{\"password\":\"synthetic-password\"},\"timeoutMs\":\"" + marker + "\"}";
            JsonObject response = JsonParser.parseString(LegadoRuntime.execute(id, UUID.randomUUID().toString(), "persistLoginInfo", request)).getAsJsonObject();
            String message = response.getAsJsonObject("error").get("message").getAsString();
            System.out.println("PRE_TASK_REDACTION code=" + response.getAsJsonObject("error").get("code").getAsString()
                + " syntheticMarkerLeaked=" + message.contains(marker));
        } finally { LegadoRuntime.closeSession(id); }
    }
}
