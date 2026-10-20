import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import java.util.*;

/** New public-boundary counterexamples; no production, JUnit, JNI or WK code. */
public final class GeneralWebJSUnsupported {
    static int reads, otherHosts;
    static final List<String> codes = new ArrayList<>();
    static JsonObject object(String text) { return JsonParser.parseString(text).getAsJsonObject(); }
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    public static void main(String[] args) {
        LegadoRuntime.setHostCallback((task, operation, raw) -> {
            if (operation.equals("task.cancel")) return "{}";
            if (operation.equals("state.read")) { reads++; return "{\"revision\":0,\"values\":{}}"; }
            otherHosts++; throw new AssertionError("Unexpected effect/transport " + operation);
        });
        JsonObject source = object("{\"bookSourceUrl\":\"https://general-webjs.invalid/source\",\"loginUi\":\"[]\",\"loginUrl\":\"var finiteLogin=true;\",\"ruleContent\":{},\"ruleSearch\":{\"bookList\":\"class.none\"}}");
        JsonObject created = object(LegadoRuntime.createSession(source.toString(),
            "{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"cookieAccess\":\"app-owner-text\",\"stateOwner\":\"general-webjs-owned\"}"));
        check(created.get("ok").getAsBoolean(), "Session creation failed");
        String session = created.get("sessionId").getAsString();
        try {
            String[] actions = {
                "java.webView('<html><body>owned</body></html>','https://general-webjs.invalid/page','document.body.textContent');",
                "java.setContent('<html><body>owned</body></html>');java.getString('@webjs:document.body.textContent');",
                "java.connect('https://general-webjs.invalid/options,{\"webView\":true}');"
            };
            for (String action : actions) {
                JsonObject input = object("{\"credentials\":{},\"isLongClick\":false,\"timeoutMs\":5000}");
                input.addProperty("action", action);
                JsonObject out = object(LegadoRuntime.execute(session,"general-webjs-"+UUID.randomUUID(),"loginAction",input.toString()));
                check(!out.get("ok").getAsBoolean(), "Unexpected browser capability success");
                JsonObject error = out.getAsJsonObject("error");
                String code = error.get("code").getAsString();
                check(code.equals("UNSUPPORTED_CAPABILITY"), "Wrong rejection " + out);
                check(!error.has("completedEffects"), "Unexpected side effect " + out);
                codes.add(code);
            }
            check(otherHosts == 0, "Unexpected transport or mutation");
            System.out.println("GENERAL_WEBJS_COUNTEREXAMPLES sessions=1 calls=3 unsupported=3 stateReads="+reads+" otherHostCalls=0 actualNetwork=0 JUnit=0 JNI=0 Swift=0 WK=0");
        } finally {
            check(object(LegadoRuntime.closeSession(session)).get("ok").getAsBoolean(), "Close failed");
            LegadoRuntime.setHostCallback(null);
        }
    }
}
