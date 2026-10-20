import com.google.gson.JsonObject;
import com.google.gson.JsonNull;
import com.google.gson.JsonParser;
import io.yuedu.legado.LegadoRuntime;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/** Separate javac consumer, fresh ordinary JAR only; synthetic owner values. */
public final class OrdinaryLoginUISmoke {
    private static final Map<String,String> secrets=new HashMap<>();
    private static int sessions,rawReads,headerReads;
    private static JsonObject object(String s){return JsonParser.parseString(s).getAsJsonObject();}
    private static JsonObject checked(String s){var v=object(s);if(!v.get("ok").getAsBoolean())throw new AssertionError(s);return v;}
    private static JsonObject call(String origin,String ui,String prelude,JsonObject values,boolean success){
        var source=new JsonObject();source.addProperty("bookSourceUrl",origin);source.addProperty("loginUi",ui);source.addProperty("loginUrl",prelude);source.addProperty("enabledCookieJar",false);source.add("ruleContent",new JsonObject());
        var options=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");options.addProperty("stateOwner","owned:"+origin);
        String id=checked(LegadoRuntime.createSession(source.toString(),options.toString())).get("sessionId").getAsString();sessions++;
        try{
            var input=new JsonObject();input.addProperty("timeoutMs",20000);if(values!=null)input.add("values",values);
            var reply=object(LegadoRuntime.execute(id,"ordinary-ui-"+UUID.randomUUID(),"loginUi",input.toString()));
            if(reply.get("ok").getAsBoolean()!=success)throw new AssertionError(reply);
            return reply;
        }finally{checked(LegadoRuntime.closeSession(id));}
    }
    public static void main(String[] args){
        LegadoRuntime.setHostCallback((task,operation,raw)->{
            if(operation.equals("task.cancel"))return "{}";
            var input=object(raw);String owner=input.get("owner").getAsString();
            if(operation.equals("source.login-info")){
                String origin=input.get("sourceURL").getAsString();if(!owner.equals("owned:"+origin))throw new AssertionError("owner mismatch");
                if(!input.get("action").getAsString().equals("get"))throw new AssertionError("UI must not derive/persist credentials");rawReads++;
                var out=new JsonObject();out.add("value",secrets.containsKey(origin)?new com.google.gson.JsonPrimitive(secrets.get(origin)):JsonNull.INSTANCE);return out.toString();
            }
            if(!operation.equals("state.read"))throw new AssertionError("unexpected generic mutation/HTTP host");
            String origin=owner.substring("owned:".length());
            for(var item:input.getAsJsonArray("keys")){
                var key=JsonParser.parseString(item.getAsString()).getAsJsonArray();
                if(key.size()!=3||!key.get(0).getAsString().equals(origin)||!key.get(1).getAsString().equals("cache-text")||!key.get(2).getAsString().equals("loginHeader_"+origin))throw new AssertionError("unexpected generic key");
            }
            headerReads++;return "{\"revision\":0,\"values\":{}}";
        });
        try{
            String a="https://ordinary-ui-a.invalid",b="https://ordinary-ui-b.invalid";
            secrets.put(a,"{\"hidden\":\"synthetic-hidden\",\"password\":\"\"}");
            var first=call(a,"[{name:'password',type:'password',default:'must-not-replace-empty'},{name:'caption',type:'label',viewName:\"throw new Error('must-not-evaluate')\"}]","",null,true).getAsJsonObject("result");
            if(first.getAsJsonArray("rows").size()!=2||!first.getAsJsonObject("values").get("password").getAsString().isEmpty())throw new AssertionError("static/raw rows mismatch");
            var dynamic=call(a,"@js:if(java!==source||book!==null||chapter!==null||String(result.get('hidden'))!=='synthetic-hidden')throw new Error('wrong Map');[{name:'x',viewName:'prefixValue'}];","var prefixValue='jar-label';function login(){throw new Error('must-not-submit');}",null,true).getAsJsonObject("result");
            if(!dynamic.get("dynamic").getAsBoolean()||!dynamic.getAsJsonArray("labels").get(0).getAsString().equals("jar-label"))throw new AssertionError("dynamic normalization mismatch");
            var edited=call(a,"[{name:'password',viewName:\"String(result.get('password'))\"}]","",object("{\"password\":\"synthetic-edit\"}"),true).getAsJsonObject("result");
            if(!edited.getAsJsonArray("labels").get(0).getAsString().equals("synthetic-edit"))throw new AssertionError("working edits mismatch");
            var failed=call(a,"@js:throw new Error('SYNTHETIC-UI-JAR-CANARY');","",null,false);
            if(!failed.getAsJsonObject("error").get("code").getAsString().equals("SCRIPT_ERROR")||failed.toString().contains("SYNTHETIC-UI-JAR-CANARY"))throw new AssertionError("sensitive error escaped");
            var missing=call(b,"[{name:'password',default:'display-only'}]","",null,true).getAsJsonObject("result");
            if(!missing.getAsJsonObject("values").isEmpty()||secrets.containsKey(b)||sessions!=5||rawReads!=4||headerReads!=4)throw new AssertionError("UI owner/default count mismatch");
            System.out.println("ORDINARY_LOGIN_UI_OK sessions=5 sources=2 rawReads=4 headerOwnerReads=4 credentialOrGenericWrites=0");
        }finally{LegadoRuntime.setHostCallback(null);}
    }
}
