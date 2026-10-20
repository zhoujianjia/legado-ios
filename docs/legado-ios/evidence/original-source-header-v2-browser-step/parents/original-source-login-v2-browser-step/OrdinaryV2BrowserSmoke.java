import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import io.yuedu.legado.LegadoRuntime;
import java.net.*;
import java.util.*;
import java.util.concurrent.CopyOnWriteArrayList;
import java.nio.charset.StandardCharsets;
public final class OrdinaryV2BrowserSmoke {
 static String origin,mode="refetchConfirmed";static int sessions,pages,credentials,nativeHTTP;
 static final List<String> routes=new CopyOnWriteArrayList<>();static final Set<String> sources=new HashSet<>();
 static JsonObject obj(String s){return JsonParser.parseString(s).getAsJsonObject();}
 static JsonObject checked(String s){var v=obj(s);if(!v.get("ok").getAsBoolean())throw new AssertionError(v);return v;}
 static JsonObject execute(String source,String script,boolean success,boolean search){
  var src=obj("{\"loginUi\":\"{\\\"version\\\":2}\",\"enabledCookieJar\":false,\"header\":\"{\\\"X-Initial\\\":\\\"synthetic\\\"}\",\"ruleContent\":{}}");src.addProperty("bookSourceUrl",source);src.addProperty("loginUrl","function login(){};function loginUi(s){return {rows:[{name:'Ready',type:'label'}]};}function loginAction(a,s,f){if(java!==source)throw Error('binding');eval(a);return {state:{done:true}};}");
  if(search){src.addProperty("searchUrl","@js:source.login();source.startBrowser('"+origin+"/forbidden','Not login');'"+origin+"/search';");src.add("ruleSearch",obj("{\"bookList\":\"class.none\"}"));}
  var opts=obj("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");opts.addProperty("stateOwner","v2:"+source);
  String id=checked(LegadoRuntime.createSession(src.toString(),opts.toString())).get("sessionId").getAsString();sessions++;sources.add(source);
  try{var input=search?obj("{\"key\":\"synthetic\",\"page\":1,\"timeoutMs\":20000}"):obj("{\"stateJSON\":\"{}\",\"form\":{},\"timeoutMs\":20000}");if(!search)input.addProperty("action",script);var result=obj(LegadoRuntime.execute(id,"ordinary-v2-"+UUID.randomUUID(),search?"search":"loginV2Action",input.toString()));if(result.get("ok").getAsBoolean()!=success)throw new AssertionError(result);return result;}
  finally{checked(LegadoRuntime.closeSession(id));}
 }
 public static void main(String[]args)throws Exception{
  var server=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);server.createContext("/",e->{try{routes.add(e.getRequestMethod()+" "+e.getRequestURI().getPath());if(!"synthetic".equals(e.getRequestHeaders().getFirst("X-Initial")))throw new AssertionError("headers");String body=new String(e.getRequestBody().readAllBytes(),StandardCharsets.UTF_8);if(e.getRequestMethod().equals("POST")&&!body.equals("field=synthetic"))throw new AssertionError("POST body");byte[]b="<html>network</html>".getBytes(StandardCharsets.UTF_8);e.sendResponseHeaders(201,b.length);e.getResponseBody().write(b);}finally{e.close();}});server.start();origin="http://127.0.0.1:"+server.getAddress().getPort();
  LegadoRuntime.setHostCallback((task,op,raw)->{
   if(op.equals("task.cancel"))return "{}";var input=obj(raw);
   if(op.equals("state.read"))return "{\"revision\":0,\"values\":{}}";
   if(op.equals("state.commit"))return "{\"committed\":true}";
   if(op.equals("source.login-info")){credentials++;throw new AssertionError("credential mutation");}
   if(op.equals("http.request")){nativeHTTP++;throw new AssertionError("genericHTTP owner");}
   if(!op.equals("source.browser"))throw new AssertionError(op);pages++;
   if(!input.get("owner").getAsString().equals("v2:"+input.get("sourceURL").getAsString()))throw new AssertionError("owner");
   var result=new JsonObject();result.add("hostEffects",JsonParser.parseString("[\"sourceBrowserMayPresent\",\"sourceBrowserPresented\"]"));
   if(mode.equals("presented"))result.addProperty("presented",true);else{result.addProperty("mode",mode);result.addProperty("body","<html>actual-dom</html>");result.addProperty("finalURL",origin+"/dom-final");}return result.toString();
  });
  try{
   String a=origin+"/source-a",b=origin+"/source-b",post=origin+"/post,{\"method\":\"POST\",\"body\":\"field=synthetic\"}";
   execute(a,"var r=java.startBrowserAwait('"+origin+"/get','GET');if(String(r.body())!=='<html>network</html>'||r.code()!==200||r.headers().size()!==0)throw Error('response');",true,false);
   execute(b,"var r=source.startBrowserAwait('"+post+"','POST',true,null);if(String(r.body())!=='<html>network</html>')throw Error('POST repeated');",true,false);
   mode="response";execute(a,"var r=java.startBrowserAwait('"+origin+"/dom','DOM',false);if(String(r.body())!=='<html>actual-dom</html>'||String(r.url())!=='"+origin+"/dom-final')throw Error('DOM');",true,false);
   mode="presented";var failed=execute(b,"java.startBrowser('"+origin+"/nonawait','Nonawait',null);throw Error('SYNTHETIC-V2-PRIVATE');",false,false);
   if(!failed.getAsJsonObject("error").get("code").getAsString().equals("SCRIPT_ERROR")||!failed.getAsJsonObject("error").getAsJsonArray("completedEffects").toString().contains("sourceBrowserPresented")||failed.toString().contains("SYNTHETIC-V2-PRIVATE"))throw new AssertionError("effects/error");
   var denied=execute(a,"",false,true);if(!denied.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"))throw new AssertionError("privacy granted browser");
   if(sessions!=5||sources.size()!=2||pages!=4||credentials!=0||nativeHTTP!=0||!routes.equals(List.of("GET /get","POST /post")))throw new AssertionError("wrong route counts");
   System.out.println("ORDINARY_V2_BROWSER_OK sessions=5 sources=2 pages=4 HTTP=2 GET=1 POST=1 true=2 DOM=1 acceptedThenThrow=1 sensitiveSearchRefused=1 credentials=0 genericHTTPHost=0");
  }finally{LegadoRuntime.setHostCallback(null);server.stop(0);}
 }
}
