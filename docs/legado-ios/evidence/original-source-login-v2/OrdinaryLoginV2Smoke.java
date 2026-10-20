import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import java.util.*;

/** External Java caller of the ordinary production JAR, no JUnit classes. */
public final class OrdinaryLoginV2Smoke {
    private static final Map<String,String> secrets=new HashMap<>();
    private static int sessions,reads,writes,stateReads,otherCalls;
    private static boolean reject;
    private static JsonObject object(String s){return JsonParser.parseString(s).getAsJsonObject();}
    private static JsonObject checked(String s){var o=object(s);if(!o.get("ok").getAsBoolean())throw new AssertionError("Unexpected runtime failure");return o;}
    private static JsonObject call(String origin,boolean render,String action,boolean success){
        String script="function loginUi(s){if(java!==source||book!==null||chapter!==null||s.phase!==2)throw new Error('wrong render args');return {rows:[{name:'User',key:'user',value:'rendered'},{name:'Status',type:'label'},{name:'Submit',type:'button',action:'submit',countdown:3}]};}function loginAction(a,s,f){if(java!==source||book!==null||chapter!==null||s.phase!==2||f.password!=='synthetic-password')throw new Error('wrong action args');if(a==='invalid')return {state:[],login:{wrong:true},close:true};return {state:{phase:3},login:{token:f.password},close:true,future:'ignored'};}";
        var source=object("{\"loginUi\":\"{\\\"version\\\":2}\",\"enabledCookieJar\":false,\"ruleContent\":{}}");source.addProperty("bookSourceUrl",origin);source.addProperty("loginUrl",script);
        var options=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");options.addProperty("stateOwner","owner:"+origin);
        String id=checked(LegadoRuntime.createSession(source.toString(),options.toString())).get("sessionId").getAsString();sessions++;
        try {
            var input=object("{\"timeoutMs\":20000,\"stateJSON\":\"{\\\"phase\\\":2}\"}");
            if(!render){input.addProperty("action",action);input.add("form",object("{\"password\":\"synthetic-password\"}"));}
            var value=object(LegadoRuntime.execute(id,"outside-v2-"+UUID.randomUUID(),render?"loginV2UI":"loginV2Action",input.toString()));
            if(value.get("ok").getAsBoolean()!=success)throw new AssertionError("Wrong V2 terminal state");return value;
        }finally{checked(LegadoRuntime.closeSession(id));}
    }
    public static void main(String[] args){
        LegadoRuntime.setHostCallback((task,operation,raw)->{
            if(operation.equals("task.cancel"))return "{}";
            var input=object(raw);
            if(operation.equals("state.read")){stateReads++;return "{\"revision\":0,\"values\":{}}";}
            if(!operation.equals("source.login-info")){otherCalls++;throw new AssertionError("V2 reached unexpected host");}
            String origin=input.get("sourceURL").getAsString();if(!input.get("owner").getAsString().equals("owner:"+origin))throw new AssertionError("Wrong source owner");
            if(input.get("action").getAsString().equals("get")){reads++;var result=new JsonObject();result.addProperty("value",secrets.get(origin));return result.toString();}
            if(reject)return "{\"committed\":false}";
            if(!input.get("action").getAsString().equals("put"))throw new AssertionError("V2 unexpectedly removed credentials");
            secrets.put(origin,input.get("value").getAsString());writes++;return "{\"committed\":true,\"hostEffects\":[\"sourceLoginInfoMayCommit\",\"sourceLoginInfoCommitted\"]}";
        });
        try {
            String a="https://ordinary-v2-a.invalid",b="https://ordinary-v2-b.invalid";secrets.put(a,"{\"hidden\":\"a\"}");secrets.put(b,"{\"hidden\":\"b\"}");
            var rendered=call(a,true,"",true).getAsJsonObject("result");
            if(rendered.getAsJsonArray("rows").size()!=3||writes!=0||!rendered.getAsJsonObject("storedValues").get("hidden").getAsString().equals("a"))throw new AssertionError("Render saved or lost stored input");
            var action=call(a,false,"submit",true).getAsJsonObject("result");
            if(!action.get("close").getAsBoolean()||!action.get("loginStored").getAsBoolean()||!object(secrets.get(a)).get("token").getAsString().equals("synthetic-password"))throw new AssertionError("Close preceded checked login");
            if(!call(b,true,"",true).getAsJsonObject("result").getAsJsonObject("storedValues").get("hidden").getAsString().equals("b"))throw new AssertionError("Source owners mixed");
            reject=true;var failed=call(b,false,"submit",false);reject=false;
            if(!failed.getAsJsonObject("error").get("code").getAsString().equals("STATE_REJECTED")||failed.has("result")||!object(secrets.get(b)).get("hidden").getAsString().equals("b"))throw new AssertionError("Rejected save authorized close");
            if(!call(a,false,"invalid",false).getAsJsonObject("error").get("code").getAsString().equals("INVALID_RESULT"))throw new AssertionError("Partial malformed command saved");
            if(sessions!=5||reads!=2||writes!=1||otherCalls!=0)throw new AssertionError("Unexpected owner routing");
            System.out.println("ORDINARY_LOGIN_V2_OK sessions=5 sources=2 renderReads=2 checkedWrites=1 rejectedSave=1 malformedCommand=1 stateReads="+stateReads+" genericOrHTTPHostCalls=0");
        } finally {LegadoRuntime.setHostCallback(null);}
    }
}
