import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import io.yuedu.legado.LegadoRuntime;
import java.net.*;
import java.util.*;
import java.util.concurrent.CopyOnWriteArrayList;
import java.nio.charset.StandardCharsets;
public final class OrdinaryLoginBrowserPostSmoke {
 private static int sessions,pages,credentials,nativeHTTP;
 private static String mode="refetchConfirmed",failure,peer;
 private static final List<String> routes=new CopyOnWriteArrayList<>();
 private static final Set<String> sources=new HashSet<>();
 private static JsonObject object(String s){return JsonParser.parseString(s).getAsJsonObject();}
 private static JsonObject checked(String s){var v=object(s);if(!v.get("ok").getAsBoolean())throw new AssertionError("Unexpected runtime failure");return v;}
 private static String post(String path){return peer+path+",{\"method\":\"POST\",\"body\":\"field=synthetic\"}";}
 private static JsonObject call(String source,String script,boolean success){
  var src=object("{\"loginUi\":\"[]\",\"enabledCookieJar\":false,\"ruleContent\":{}}");src.addProperty("bookSourceUrl",source);src.addProperty("loginUrl","var browserPostPrelude=true;");src.addProperty("header","{\"X-Initial\":\"synthetic-initial\"}");
  var opts=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");opts.addProperty("stateOwner","post:"+source);
  String id=checked(LegadoRuntime.createSession(src.toString(),opts.toString())).get("sessionId").getAsString();sessions++;sources.add(source);
  try{var in=object("{\"credentials\":{},\"timeoutMs\":20000}");in.addProperty("action",script);var out=object(LegadoRuntime.execute(id,"ordinary-post-"+UUID.randomUUID(),"loginAction",in.toString()));if(out.get("ok").getAsBoolean()!=success)throw new AssertionError("Wrong terminal state");return out;}
  finally{checked(LegadoRuntime.closeSession(id));}
 }
 public static void main(String[]args)throws Exception{
  var server=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);
  server.createContext("/",e->{try{
   String path=e.getRequestURI().getPath(),method=e.getRequestMethod();routes.add(method+" "+path);
   if(!"synthetic-initial".equals(e.getRequestHeaders().getFirst("X-Initial")))throw new AssertionError("Header snapshot missing");
   String body=new String(e.getRequestBody().readAllBytes(),StandardCharsets.UTF_8);
   if(method.equals("POST")&&(!body.equals("field=synthetic")||!e.getRequestHeaders().getFirst("Content-Type").startsWith("application/x-www-form-urlencoded")))throw new AssertionError("POST body or content type changed");
   if(path.equals("/original")){e.getResponseHeaders().add("Location","/landed");e.sendResponseHeaders(302,-1);}
   else{byte[]bytes=path.equals("/empty")?new byte[0]:"<html>prefetched</html>".getBytes(StandardCharsets.UTF_8);e.getResponseHeaders().add("Content-Type","text/html; charset=utf-8");e.getResponseHeaders().add("X-Peer","not-a-synthetic-result-header");e.sendResponseHeaders(202,bytes.length==0?-1:bytes.length);if(bytes.length>0)e.getResponseBody().write(bytes);}
  }finally{e.close();}});server.start();peer="http://127.0.0.1:"+server.getAddress().getPort();
  LegadoRuntime.setHostCallback((task,op,raw)->{
   if(op.equals("task.cancel"))return "{}";var input=object(raw);
   if(op.equals("state.read"))return "{\"revision\":0,\"values\":{}}";
   if(op.equals("state.commit"))return "{\"committed\":true}";
   if(op.equals("source.login-info")){credentials++;throw new AssertionError("Credential owner used implicitly");}
   if(op.equals("http.request")){nativeHTTP++;throw new AssertionError("New native HTTP owner used");}
   if(!op.equals("source.browser"))throw new AssertionError("Unexpected Host operation");pages++;
   if(!input.get("owner").getAsString().equals("post:"+input.get("sourceURL").getAsString())||!input.has("prefetchedHTML"))throw new AssertionError("Wrong owner or lost prefetch presence");
   String expected=input.get("url").getAsString().endsWith("/empty")?"":"<html>prefetched</html>";
   if(!input.get("prefetchedHTML").getAsString().equals(expected))throw new AssertionError("Prefetch body changed");
   if(!input.getAsJsonObject("headers").get("X-Initial").getAsString().equals("synthetic-initial"))throw new AssertionError("Header snapshot changed");
   var effects=JsonParser.parseString("[\"sourceBrowserMayPresent\",\"sourceBrowserPresented\"]");var out=new JsonObject();
   if(failure!=null){var err=new JsonObject();err.addProperty("code",failure);err.addProperty("message","SYNTHETIC-POST-PRIVATE");err.add("completedEffects",effects);out.addProperty("ok",false);out.add("error",err);return out.toString();}
   out.add("hostEffects",effects);if(mode.equals("presented"))out.addProperty("presented",true);else{out.addProperty("mode",mode);out.addProperty("body","<html>actual-dom</html>");out.addProperty("finalURL",peer+"/dom-final");}return out.toString();
  });
  try{
   String a=peer+"/source-a",b=peer+"/source-b";
   call(a,"var r=java.startBrowserAwait('"+post("/original")+"','POST');if(String(r.body())!=='<html>prefetched</html>'||String(r.url())!=='"+peer+"/original'||r.code()!==200||String(r.message())!=='OK'||r.headers().size()!==0)throw new Error('prefetch not reused');",true);
   mode="response";call(b,"var r=java.startBrowserAwait('"+post("/form")+"','DOM',false);if(String(r.body())!=='<html>actual-dom</html>'||String(r.url())!=='"+peer+"/dom-final')throw new Error('DOM not returned');",true);
   mode="presented";call(a,"java.startBrowser('"+post("/form")+"','Nonawait');",true);
   mode="refetchConfirmed";var empty=call(b,"java.startBrowserAwait('"+post("/empty")+"','Empty');",false);
   if(!empty.getAsJsonObject("error").get("code").getAsString().equals("BROWSER_EMPTY_RESULT"))throw new AssertionError("Empty prefetch refetched or succeeded");
   failure="BROWSER_CANCELLED";var cancelled=call(a,"java.startBrowserAwait('"+post("/form")+"','Cancelled');source.putLoginInfo('late');",false);
   var err=cancelled.getAsJsonObject("error");String facts=err.getAsJsonArray("completedEffects").toString();
   if(!err.get("code").getAsString().equals("BROWSER_CANCELLED")||cancelled.toString().contains("SYNTHETIC-POST-PRIVATE")||!facts.contains("sourceBrowserPostMaySend")||!facts.contains("sourceBrowserPostResponseReceived"))throw new AssertionError("Lost effects or leaked source text");
   if(sessions!=5||sources.size()!=2||pages!=5||credentials!=0||nativeHTTP!=0||!routes.equals(List.of("POST /original","GET /landed","POST /form","POST /form","POST /empty","POST /form")))throw new AssertionError("POST repeated or owner routing changed");
   System.out.println("ORDINARY_BROWSER_POST_OK sessions=5 sources=2 requests=6 post=5 redirectGET=1 prefetchedTrue=1 DOM=1 nonawait=1 emptyRejected=1 userCancel=1 credentials=0 genericHTTPHost=0");
  }finally{LegadoRuntime.setHostCallback(null);server.stop(0);}
 }
}
