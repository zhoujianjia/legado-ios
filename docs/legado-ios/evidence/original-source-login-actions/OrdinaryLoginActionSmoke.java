import com.google.gson.JsonObject;
import com.google.gson.JsonNull;
import com.google.gson.JsonParser;
import io.yuedu.legado.LegadoRuntime;
import java.util.UUID;

/** Outside javac consumer of only the ordinary production JAR. */
public final class OrdinaryLoginActionSmoke {
    private static int sessions,unexpectedHostCalls;
    private static JsonObject object(String s){return JsonParser.parseString(s).getAsJsonObject();}
    private static JsonObject checked(String s){var value=object(s);if(!value.get("ok").getAsBoolean())throw new AssertionError(s);return value;}
    private static JsonObject call(String origin,String prelude,String action,JsonObject values,boolean longClick,boolean success){
        var source=new JsonObject();source.addProperty("bookSourceUrl",origin);source.addProperty("loginUrl",prelude);source.addProperty("loginUi","[]");source.addProperty("enabledCookieJar",false);source.add("ruleContent",new JsonObject());
        var options=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");options.addProperty("stateOwner","owned:"+origin);
        String id=checked(LegadoRuntime.createSession(source.toString(),options.toString())).get("sessionId").getAsString();sessions++;
        try {
            var input=new JsonObject();input.addProperty("timeoutMs",20000);input.add("credentials",values);input.addProperty("isLongClick",longClick);input.add("action",action==null?JsonNull.INSTANCE:new com.google.gson.JsonPrimitive(action));
            var reply=object(LegadoRuntime.execute(id,"outside-action-"+UUID.randomUUID(),"loginAction",input.toString()));
            if(reply.get("ok").getAsBoolean()!=success)throw new AssertionError(reply);
            return reply;
        } finally {checked(LegadoRuntime.closeSession(id));}
    }
    public static void main(String[] args){
        LegadoRuntime.setHostCallback((task,operation,raw)->{if(operation.equals("task.cancel"))return "{}";unexpectedHostCalls++;throw new AssertionError("Pure action must not reach a credential/generic/HTTP host");});
        try {
            String a="https://ordinary-action-a.invalid",b="https://ordinary-action-b.invalid";
            var first=call(a,"function login(){throw new Error('must-not-call-login');}","if(java===source||book!==null||chapter!==null||isLongClick!==true||String(result.get('hidden'))!=='synthetic-hidden'||String(result.get('username'))!=='')throw new Error('wrong Map');java.setContent('<p>outside</p>');if(String(java.getString('p@text'))!=='outside')throw new Error('wrong parser');result.put('temporary','not-persistent');JSON.stringify({Authorization:'must-not-infer'});",object("{\"hidden\":\"synthetic-hidden\",\"username\":\"\"}"),true,true);
            if(!first.getAsJsonObject("result").get("executed").getAsBoolean())throw new AssertionError("action not run");
            var noAction=call(a,"source.putLoginHeader('must-not-run')",null,new JsonObject(),false,true);
            if(noAction.getAsJsonObject("result").get("executed").getAsBoolean())throw new AssertionError("null action ran");
            var noLogin=call(a,"","throw new Error('must-not-run')",new JsonObject(),false,true);
            if(noLogin.getAsJsonObject("result").get("executed").getAsBoolean())throw new AssertionError("missing login ran");
            var empty=call(b,"var prefix='present';","",new JsonObject(),false,true);
            if(!empty.getAsJsonObject("result").get("executed").getAsBoolean())throw new AssertionError("empty action skipped");
            var callback=call(b,"var prefix='present';","java.reLoginView(true)",new JsonObject(),false,false);
            if(!callback.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"))throw new AssertionError("callback falsely accepted");
            if(sessions!=5||unexpectedHostCalls!=0)throw new AssertionError("unexpected owner access");
            System.out.println("ORDINARY_LOGIN_ACTION_OK sessions=5 sources=2 credentialReads=0 credentialWrites=0 genericOrHTTPHostCalls=0");
        } finally {LegadoRuntime.setHostCallback(null);}
    }
}
