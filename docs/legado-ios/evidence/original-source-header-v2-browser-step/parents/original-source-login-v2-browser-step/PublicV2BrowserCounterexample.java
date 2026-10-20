import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import java.util.*;
public final class PublicV2BrowserCounterexample {
 static int browser,credentials,http;
 static JsonObject obj(String text){return JsonParser.parseString(text).getAsJsonObject();}
 static JsonObject ok(String text){var v=obj(text);if(!v.get("ok").getAsBoolean())throw new AssertionError(v);return v;}
 public static void main(String[]args){
  LegadoRuntime.setHostCallback((task,operation,raw)->{
   if(operation.equals("task.cancel"))return "{}";
   if(operation.equals("state.read"))return "{\"revision\":0,\"values\":{}}";
   if(operation.equals("state.commit"))return "{\"committed\":true}";
   if(operation.equals("source.browser"))browser++;
   if(operation.equals("source.login-info"))credentials++;
   if(operation.equals("http.request"))http++;
   throw new AssertionError("Unexpected Host "+operation);
  });
  var source=obj("{\"bookSourceUrl\":\"https://synthetic-v2-browser.invalid/source\",\"loginUi\":\"{\\\"version\\\":2}\",\"enabledCookieJar\":false,\"ruleContent\":{}}");
  source.addProperty("loginUrl","function loginUi(s){return {rows:[]};} function loginAction(a,s,f){if(java!==source)throw Error('binding');if(a==='inspect')return {state:{nonawaitType:typeof java.startBrowser,awaitType:typeof java.startBrowserAwait}};java.startBrowserAwait('https://synthetic-v2-browser.invalid/page','Counterexample',false);return {state:{unexpected:true}};}");
  String id=ok(LegadoRuntime.createSession(source.toString(),"{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\"v2-counterexample\"}")).get("sessionId").getAsString();
  try{
   var input=obj("{\"action\":\"inspect\",\"stateJSON\":\"{}\",\"form\":{},\"timeoutMs\":20000}");
   var inspected=ok(LegadoRuntime.execute(id,"v2-browser-inspect","loginV2Action",input.toString()));
   String serialized=inspected.toString();
   if(!serialized.contains("undefined"))throw new AssertionError(inspected);
   input.addProperty("action","missing");
   var missing=obj(LegadoRuntime.execute(id,"v2-browser-missing","loginV2Action",input.toString()));
   if(missing.get("ok").getAsBoolean()||!missing.getAsJsonObject("error").get("code").getAsString().equals("SCRIPT_ERROR"))throw new AssertionError(missing);
   if(browser!=0||credentials!=0||http!=0)throw new AssertionError("Unexpected effect");
   System.out.println("PUBLIC_V2_COUNTEREXAMPLE_OK "+serialized+" failure="+missing+" browser=0 credentials=0 genericHTTPHost=0");
  }finally{ok(LegadoRuntime.closeSession(id));LegadoRuntime.setHostCallback(null);}
 }
}
