import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import java.util.*;

/** Independent javac consumer of only the ordinary production runtime JAR. */
public final class OrdinaryPersistLoginInfoSmoke {
    private static final Map<String,String> secrets=new HashMap<>();
    private static int sessions,credentialWrites,genericOrHTTPHostCalls;
    private static boolean reject,ioFailure;
    private static JsonObject object(String s){return JsonParser.parseString(s).getAsJsonObject();}
    private static JsonObject checked(String s){var o=object(s);if(!o.get("ok").getAsBoolean())throw new AssertionError("Unexpected runtime failure");return o;}
    private static JsonObject call(String origin,String values,boolean success){
        var source=object("{\"loginUrl\":\"function login( { malformed source.putLoginInfo('must-not-evaluate')\",\"enabledCookieJar\":false,\"ruleContent\":{}}");source.addProperty("bookSourceUrl",origin);
        var options=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");options.addProperty("stateOwner","owner:"+origin);
        String id=checked(LegadoRuntime.createSession(source.toString(),options.toString())).get("sessionId").getAsString();sessions++;
        try {
            var input=object("{\"timeoutMs\":20000}");input.add("credentials",object(values));
            var reply=object(LegadoRuntime.execute(id,"outside-persist-"+UUID.randomUUID(),"persistLoginInfo",input.toString()));
            if(reply.get("ok").getAsBoolean()!=success)throw new AssertionError("Wrong persistence terminal state");
            if(success&&reply.getAsJsonObject("result").get("executed").getAsBoolean())throw new AssertionError("Pure persistence executed JS");
            return reply;
        } finally {checked(LegadoRuntime.closeSession(id));}
    }
    public static void main(String[] args){
        LegadoRuntime.setHostCallback((task,operation,raw)->{
            if(operation.equals("task.cancel"))return "{}";
            if(!operation.equals("source.login-info")){genericOrHTTPHostCalls++;throw new AssertionError("Pure save reached another host");}
            var input=object(raw);String origin=input.get("sourceURL").getAsString();
            if(!input.get("owner").getAsString().equals("owner:"+origin)||input.get("deadlineEpochMs").getAsLong()<=0)throw new AssertionError("Wrong checked owner");
            if(ioFailure)return "{\"ok\":false,\"error\":{\"code\":\"STATE_IO\",\"message\":\"synthetic private owner detail\",\"completedEffects\":[\"sourceLoginInfoMayCommit\"]}}";
            if(reject)return "{\"committed\":false}";
            String action=input.get("action").getAsString();
            if(action.equals("put"))secrets.put(origin,input.get("value").getAsString());
            else if(action.equals("remove"))secrets.remove(origin);else throw new AssertionError("Pure mutation read credentials");
            credentialWrites++;return "{\"committed\":true,\"hostEffects\":[\"sourceLoginInfoMayCommit\",\"sourceLoginInfoCommitted\"]}";
        });
        try {
            String a="https://ordinary-dismiss-a.invalid",b="https://ordinary-dismiss-b.invalid";
            var first=call(a,"{\"hidden\":\"synthetic-hidden\",\"password\":\"\"}",true).getAsJsonObject("result");
            if(!first.get("credentialsStored").getAsBoolean()||!object(secrets.get(a)).get("password").getAsString().equals(""))throw new AssertionError("Lost hidden/empty Map");
            if(!call(b,"{\"hidden\":\"source-b\"}",true).getAsJsonObject("result").get("credentialsStored").getAsBoolean())throw new AssertionError("Second owner failed");
            if(!call(a,"{}",true).getAsJsonObject("result").get("credentialsCleared").getAsBoolean()||secrets.containsKey(a)||!object(secrets.get(b)).get("hidden").getAsString().equals("source-b"))throw new AssertionError("Remove affected another source");
            reject=true;var refused=call(b,"{\"hidden\":\"must-not-write\"}",true).getAsJsonObject("result");
            if(refused.get("credentialsStored").getAsBoolean()||refused.get("credentialsCleared").getAsBoolean())throw new AssertionError("Rejected owner falsely ACKed");
            reject=false;ioFailure=true;var failed=call(b,"{}",false).getAsJsonObject("error");
            if(!failed.get("code").getAsString().equals("STATE_IO")||failed.getAsJsonArray("completedEffects").size()!=1||failed.get("message").getAsString().contains("private owner detail"))throw new AssertionError("Lost/sensitive failure facts");
            if(sessions!=5||credentialWrites!=3||genericOrHTTPHostCalls!=0)throw new AssertionError("Unexpected owner routing");
            System.out.println("ORDINARY_PERSIST_LOGIN_INFO_OK sessions=5 sources=2 checkedMutations=3 rejects=1 ioFailures=1 credentialReads=0 genericOrHTTPHostCalls=0 executedJS=0");
        } finally {LegadoRuntime.setHostCallback(null);}
    }
}
