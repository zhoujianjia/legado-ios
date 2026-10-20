import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import java.util.UUID;

/** Outside javac consumer, no test classes or embedding owner implementation. */
public final class OrdinaryLoginUIEventsSmoke {
    private static int sessions,hostCalls;
    private static JsonObject object(String s){return JsonParser.parseString(s).getAsJsonObject();}
    private static JsonObject checked(String s){var o=object(s);if(!o.get("ok").getAsBoolean())throw new AssertionError("Unexpected runtime failure");return o;}
    private static JsonObject call(String origin,String action,boolean success){
        var source=object("{\"loginUrl\":\"var prefix='present';\",\"loginUi\":\"[]\",\"enabledCookieJar\":false,\"ruleContent\":{}}");
        source.addProperty("bookSourceUrl",origin);
        var options=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");options.addProperty("stateOwner","owner:"+origin);
        String id=checked(LegadoRuntime.createSession(source.toString(),options.toString())).get("sessionId").getAsString();sessions++;
        try {
            var input=object("{\"timeoutMs\":20000,\"credentials\":{\"hidden\":\"synthetic-hidden\",\"empty\":\"\"},\"isLongClick\":false}");input.addProperty("action",action);
            String task="outside-events-"+UUID.randomUUID();var reply=object(LegadoRuntime.execute(id,task,"loginAction",input.toString()));
            if(reply.get("ok").getAsBoolean()!=success)throw new AssertionError("Wrong terminal state");
            var detail=success?reply:reply.getAsJsonObject("error");var events=detail.getAsJsonArray("loginUIEvents");
            if(events!=null)for(int i=0;i<events.size();i++){
                var e=events.get(i).getAsJsonObject();if(!e.get("taskId").getAsString().equals(task)||e.get("sequence").getAsInt()!=i+1)throw new AssertionError("Wrong task sequence");
            }
            return reply;
        } finally {checked(LegadoRuntime.closeSession(id));}
    }
    public static void main(String[] args){
        LegadoRuntime.setHostCallback((task,operation,raw)->{if(operation.equals("task.cancel"))return "{}";hostCalls++;throw new AssertionError("UI events may not dispatch synchronous owner calls");});
        try {
            String a="https://ordinary-ui-event-a.invalid",b="https://ordinary-ui-event-b.invalid";
            var first=call(a,"java.upLoginData(result);java.upLoginData(result);result.clear();java.upLoginData(result);java.upLoginData(null);java.reLoginView(false);java.refreshExplore();",true);
            var events=first.getAsJsonArray("loginUIEvents");if(events.size()!=6||!events.equals(first.getAsJsonObject("result").get("loginUIEvents")))throw new AssertionError("Missing/reordered terminal events");
            if(!events.get(0).getAsJsonObject().get("entries").equals(events.get(1).getAsJsonObject().get("entries"))||events.get(0).getAsJsonObject().getAsJsonArray("entries").size()!=2)throw new AssertionError("Not eager Map snapshot");
            if(events.get(2).getAsJsonObject().getAsJsonArray("entries").size()!=0||!events.get(3).getAsJsonObject().get("entries").isJsonNull())throw new AssertionError("Empty/null conflated");
            var failed=call(a,"java.upLoginData(result);throw new Error('synthetic secret');",false).getAsJsonObject("error");
            if(!failed.get("code").getAsString().equals("SCRIPT_ERROR")||failed.getAsJsonArray("loginUIEvents").size()!=1||failed.get("message").getAsString().contains("synthetic secret"))throw new AssertionError("Error erased events or exposed diagnostics");
            var delta=call(b,"java.upLoginData(null);java.reLoginView(true);",false).getAsJsonObject("error");
            if(!delta.get("code").getAsString().equals("UNSUPPORTED_CAPABILITY")||delta.getAsJsonArray("loginUIEvents").size()!=1)throw new AssertionError("Delta was falsely accepted");
            if(call(b,"1;",true).has("loginUIEvents"))throw new AssertionError("Events leaked across tasks or sources");
            var limit=call(b,"for(var i=0;i<129;i++)java.upLoginData(null);",false).getAsJsonObject("error");
            if(!limit.get("code").getAsString().equals("STATE_LIMIT")||limit.getAsJsonArray("loginUIEvents").size()!=128)throw new AssertionError("Accepted prefix lost");
            if(sessions!=5||hostCalls!=0)throw new AssertionError("Unexpected host calls");
            System.out.println("ORDINARY_LOGIN_UI_EVENTS_OK sessions=5 sources=2 ordered=true nullDistinct=true acceptedPrefix=128 credentialReads=0 credentialWrites=0 synchronousHostCalls=0");
        } finally {LegadoRuntime.setHostCallback(null);}
    }
}
