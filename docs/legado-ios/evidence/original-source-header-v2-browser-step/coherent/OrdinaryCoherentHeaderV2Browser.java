import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import io.yuedu.legado.LegadoRuntime;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
public final class OrdinaryCoherentHeaderV2Browser {
 static String origin,source,session;static int browser,headerCommits,cookieMutations,credentials,nativeHTTP;
 static final Map<String,String> headers=new HashMap<>(),cookies=new HashMap<>();static final List<String> routes=new ArrayList<>();
 static JsonObject obj(String raw){return JsonParser.parseString(raw).getAsJsonObject();}
 static JsonObject ok(String raw){var out=obj(raw);if(!out.get("ok").getAsBoolean())throw new AssertionError(out);return out;}
 static String entry(String value){var e=new JsonObject();e.addProperty("deadline",0);e.addProperty("data",Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)));return Base64.getEncoder().encodeToString(e.toString().getBytes(StandardCharsets.UTF_8));}
 static void check(boolean b,String message){if(!b)throw new AssertionError(message);}
 static JsonObject call(String operation,JsonObject input,boolean success){var out=obj(LegadoRuntime.execute(session,"coherent-"+UUID.randomUUID(),operation,input.toString()));check(out.get("ok").getAsBoolean()==success,"wrong terminal "+out);return out;}
 public static void main(String[]args)throws Exception{
  var server=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);server.createContext("/",e->{try{routes.add(e.getRequestMethod()+" "+e.getRequestURI().getPath());check("synthetic-combined".equals(e.getRequestHeaders().getFirst("Authorization")),"new checked Header missing from JVM HTTP");check(e.getRequestHeaders().getFirst("Cookie").contains("login=synthetic"),"same Cookie owner missing");String body=new String(e.getRequestBody().readAllBytes(),StandardCharsets.UTF_8);if(e.getRequestMethod().equals("POST"))check(body.equals("field=synthetic"),"POST body changed");byte[]b="<html>coherent-network</html>".getBytes(StandardCharsets.UTF_8);e.sendResponseHeaders(201,b.length);e.getResponseBody().write(b);}finally{e.close();}});server.start();origin="http://127.0.0.1:"+server.getAddress().getPort();source=origin+"/source";
  LegadoRuntime.setHostCallback((task,operation,raw)->{
   if(operation.equals("task.cancel"))return "{}";var in=obj(raw);check(in.get("owner").getAsString().equals("coherent:"+source),"owner changed");
   if(operation.equals("state.read")){var values=new JsonObject();for(var key:in.getAsJsonArray("keys")){var parts=JsonParser.parseString(key.getAsString()).getAsJsonArray();if(parts.size()==3&&parts.get(1).getAsString().equals("cache-text")&&parts.get(2).getAsString().equals("loginHeader_"+source)&&headers.containsKey(source))values.addProperty(key.getAsString(),entry(headers.get(source)));}var out=new JsonObject();out.addProperty("revision",0);out.add("values",values);return out.toString();}
   if(operation.equals("state.commit")){check(in.getAsJsonObject("changes").entrySet().stream().noneMatch(e->e.getKey().contains("loginHeader_")),"raw Header fell into generic CAS");return "{\"committed\":true}";}
   if(operation.equals("source.login-header")){check(in.get("taskId").getAsString().equals(task)&&in.get("sourceURL").getAsString().equals(source)&&in.get("cookieAccess").getAsString().equals("app-owner-text"),"Header provenance changed");check(in.get("action").getAsString().equals("put"),"unexpected Header operation");String value=in.get("value").getAsString();check(!Objects.equals(headers.get(source),value),"unexpected no-op Header ACK");headers.put(source,value);headerCommits++;return "{\"committed\":true,\"hostEffects\":[\"sourceLoginHeaderMayCommit\",\"sourceLoginHeaderCommitted\"]}";}
   if(operation.equals("cookie.owner.text")){String action=in.get("action").getAsString(),domain=in.get("domain").getAsString();if(action.equals("get")||action.equals("session")){var out=new JsonObject();out.addProperty("cookie",action.equals("session")?"":cookies.getOrDefault(domain,""));return out.toString();}check(action.equals("replace"),"unexpected Cookie mutation "+action);cookies.put(domain,in.get("cookie").getAsString());cookieMutations++;return "{\"committed\":true,\"hostEffects\":[\"cookieText\"]}";}
   if(operation.equals("source.browser")){browser++;check(in.get("sourceURL").getAsString().equals(source),"browser source changed");check(in.getAsJsonObject("headers").get("Authorization").getAsString().equals("synthetic-combined"),"new Header missing from browser snapshot");check(in.get("awaitsResult").getAsBoolean()&&in.get("refetchAfterSuccess").getAsBoolean(),"mode changed");return "{\"mode\":\"refetchConfirmed\",\"hostEffects\":[\"sourceBrowserMayPresent\",\"sourceBrowserPresented\"]}";}
   if(operation.equals("source.login-info")){credentials++;throw new AssertionError("implicit credential owner");}
   if(operation.equals("http.request")){nativeHTTP++;throw new AssertionError("generic HTTP owner");}
   throw new AssertionError("unexpected Host "+operation);
  });
  try{
   var src=obj("{\"loginUi\":\"{\\\"version\\\":2}\",\"enabledCookieJar\":true,\"ruleContent\":{},\"ruleSearch\":{\"bookList\":\"class.none\"}}");src.addProperty("bookSourceUrl",source);
   String header="{\"Cookie\":\"login=synthetic\",\"Authorization\":\"synthetic-combined\"}",deniedHeader="{\"Cookie\":\"login=synthetic\",\"Authorization\":\"denied-search\"}";
   String post=origin+"/post,{\"method\":\"POST\",\"body\":\"field=synthetic\"}";
   src.addProperty("loginUrl","function loginUi(s){return {rows:[{name:'Ready',type:'label'}]};}function loginAction(a,s,f){if(java!==source)throw Error('binding');source.putLoginHeader('"+header+"');var u=a==='post'?'"+post+"':'"+origin+"/get';var r=java.startBrowserAwait(u,'Combined');if(String(r.body())!=='<html>coherent-network</html>'||r.code()!==200)throw Error('response');return {state:{done:true}};}");
   src.addProperty("searchUrl","@js:source.putLoginHeader('"+deniedHeader+"');source.startBrowser('"+origin+"/forbidden','Not login');'"+origin+"/search';");
   session=ok(LegadoRuntime.createSession(src.toString(),"{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"cookieAccess\":\"app-owner-text\",\"stateOwner\":\"coherent:"+source+"\"}")).get("sessionId").getAsString();
   var action=obj("{\"action\":\"get\",\"stateJSON\":\"{}\",\"form\":{},\"timeoutMs\":20000}");call("loginV2Action",action,true);
   var denied=call("search",obj("{\"key\":\"synthetic\",\"page\":1,\"timeoutMs\":20000}"),false);check(denied.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"),"Header privacy granted browser");check(denied.getAsJsonObject("error").getAsJsonArray("completedEffects").toString().contains("sourceLoginHeaderCommitted"),"search Header effect lost");
   action.addProperty("action","post");call("loginV2Action",action,true);
   check(browser==2&&headerCommits==3&&credentials==0&&nativeHTTP==0,"wrong Host owners/counts");check(routes.equals(List.of("GET /get","POST /post")),"browser/search repeated HTTP "+routes);
   System.out.println("COHERENT_PUBLIC_V2_HEADER_BROWSER_OK sessions=1 calls=3 V2Actions=2 sensitiveSearchDenied=1 headerCommits=3 browserWireACK=2 realHTTP=2 GET=1 POST=1 sameOwner=1 credentials=0 genericHTTPHost=0 UIKIT_EXECUTION=0");
  }finally{if(session!=null)ok(LegadoRuntime.closeSession(session));LegadoRuntime.setHostCallback(null);server.stop(0);}
 }
}
