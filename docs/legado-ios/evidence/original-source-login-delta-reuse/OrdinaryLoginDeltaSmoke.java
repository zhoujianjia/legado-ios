import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import java.util.*;

/** Independent javac consumer of the ordinary production JAR, no test classes. */
public final class OrdinaryLoginDeltaSmoke {
    private static int sessions,hostCalls;
    private static JsonObject object(String s){return JsonParser.parseString(s).getAsJsonObject();}
    private static JsonObject checked(String s){var o=object(s);if(!o.get("ok").getAsBoolean())throw new AssertionError("Unexpected runtime failure");return o;}
    private static JsonObject reuse(JsonObject result){var o=new JsonObject();o.add("layout",result.get("layout").deepCopy());o.add("controls",result.get("controlStates").deepCopy());return o;}
    private static JsonObject ui(String origin,String script,JsonObject values,JsonObject previous){
        var source=object("{\"loginUrl\":\"var prefix='outside';function login(){throw new Error('must-not-submit')}\",\"enabledCookieJar\":false,\"ruleContent\":{}}");
        source.addProperty("bookSourceUrl",origin);source.addProperty("loginUi",script);
        var options=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");options.addProperty("stateOwner","owner:"+origin);
        String id=checked(LegadoRuntime.createSession(source.toString(),options.toString())).get("sessionId").getAsString();sessions++;
        try {
            var input=object("{\"timeoutMs\":20000}");input.add("values",values);if(previous!=null)input.add("reuseState",previous);
            return checked(LegadoRuntime.execute(id,"outside-delta-"+UUID.randomUUID(),"loginUi",input.toString())).getAsJsonObject("result");
        } finally {checked(LegadoRuntime.closeSession(id));}
    }
    public static void main(String[] args){
        LegadoRuntime.setHostCallback((task,operation,raw)->{if(operation.equals("task.cancel"))return "{}";hostCalls++;throw new AssertionError("Supplied UI Map must not read/write owner or HTTP");});
        try {
            String a="https://ordinary-delta-a.invalid",b="https://ordinary-delta-b.invalid";
            var first=ui(a,"[{name:'x',action:'oldWatcher()',viewName:\"'old x'\"},{name:'y',type:'button',action:'oldButton()',viewName:\"'old y'\"}]",object("{\"hidden\":\"synthetic\",\"x\":\"working\"}"),null);
            var previous=reuse(first);previous.getAsJsonArray("controls").get(0).getAsJsonObject().addProperty("value","visible-edit");
            var next=ui(a,"[{name:'y',type:'button',action:'newButton()',viewName:\"throw new Error('reused label evaluated')\"},{name:'x',type:'password',viewName:\"throw new Error('reused label evaluated')\"},{name:'flag',type:'toggle',chars:['off','on'],viewName:\"prefix+':'+String(result.get('x'))+':'+String(book)+':'+String(chapter)\"}]",first.getAsJsonObject("values"),previous);
            var children=next.getAsJsonObject("layout").getAsJsonArray("children");
            if(!children.get(0).getAsJsonObject().get("id").getAsString().equals("original-row-1")||!children.get(1).getAsJsonObject().get("id").getAsString().equals("original-row-0"))throw new AssertionError("Move replaced stable identity");
            if(!children.get(0).getAsJsonObject().getAsJsonObject("row").get("action").getAsString().equals("oldButton()"))throw new AssertionError("Captured action was replaced");
            if(!next.getAsJsonArray("labels").get(0).getAsString().equals("old y")||!next.getAsJsonArray("labels").get(2).getAsString().equals("outside:visible-edit:null:null"))throw new AssertionError("Reused/new Rhino label contract changed");
            if(!next.getAsJsonObject("values").get("x").getAsString().equals("working")||!next.get("workingMapChanged").getAsBoolean())throw new AssertionError("Working/control Map mixed");
            var trimmed=ui(a,"[{name:'x',viewName:\"throw new Error('retained label evaluated')\"}]",next.getAsJsonObject("values"),reuse(next));
            if(trimmed.getAsJsonObject("layout").getAsJsonArray("children").size()!=1||!trimmed.getAsJsonObject("layout").getAsJsonArray("children").get(0).getAsJsonObject().get("id").getAsString().equals("original-row-0"))throw new AssertionError("Removed/truncated controls were retained");
            var unknown=ui(b,"[{name:'unknown',type:'future'},{name:'a',viewName:\"'a'\"},{name:'b',type:'button',viewName:\"'b'\"}]",object("{\"a\":\"source-b\"}"),null);
            var physical=ui(b,"[{name:'a'},{name:'b',type:'button',viewName:\"throw new Error('bad input binding must not evaluate')\"}]",unknown.getAsJsonObject("values"),reuse(unknown));
            if(!physical.getAsJsonObject("layout").getAsJsonArray("children").get(0).getAsJsonObject().get("id").getAsString().equals("original-row-2")||!physical.getAsJsonArray("labels").get(1).getAsString().equals("null"))throw new AssertionError("Unknown name slot physical behavior was invented");
            if(sessions!=5||hostCalls!=0)throw new AssertionError("Unexpected owner access");
            System.out.println("ORDINARY_LOGIN_DELTA_OK sessions=5 sources=2 stableMoves=true capturedAction=true newRhinoLabels=true unknownPhysicalIndex=true credentialReads=0 credentialWrites=0 genericOrHTTPHostCalls=0");
        } finally {LegadoRuntime.setHostCallback(null);}
    }
}
