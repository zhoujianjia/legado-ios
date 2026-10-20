import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import io.yuedu.legado.LegadoRuntime;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
public final class OrdinaryLoginHeaderSmoke {
 private static int sessions,headerWrites,cookieWrites,credentials,nativeHTTP,requests;
 private static boolean oldCounterfactual,rejectCookie;
 private static final Map<String,String> headers=new HashMap<>(),cookies=new HashMap<>();
 private static final List<String> order=new ArrayList<>();
 private static JsonObject object(String s){return JsonParser.parseString(s).getAsJsonObject();}
 private static JsonObject checked(String s){var v=object(s);if(!v.get("ok").getAsBoolean())throw new AssertionError("Runtime rejected source/session");return v;}
 private static String failure(String code){return "{\"ok\":false,\"error\":{\"code\":\""+code+"\",\"message\":\"SYNTHETIC-HEADER-PRIVATE\"}}";}
 private static JsonObject call(String source,String script,String mode,boolean success){
  var src=object("{\"loginUi\":\"[]\",\"enabledCookieJar\":true,\"ruleContent\":{}}");src.addProperty("bookSourceUrl",source);src.addProperty("loginUrl","var headerPrelude=true;");
  var opts=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");opts.addProperty("stateOwner","header:"+source);opts.addProperty("cookieAccess",mode);
  String id=checked(LegadoRuntime.createSession(src.toString(),opts.toString())).get("sessionId").getAsString();sessions++;
  try{var in=object("{\"credentials\":{},\"timeoutMs\":20000}");in.addProperty("action",script);var out=object(LegadoRuntime.execute(id,"ordinary-header-"+UUID.randomUUID(),"loginAction",in.toString()));if(out.get("ok").getAsBoolean()!=success)throw new AssertionError("Wrong header terminal state");return out;}
  finally{checked(LegadoRuntime.closeSession(id));}
 }
 private static String entry(String value){var e=new JsonObject();e.addProperty("deadline",0);e.addProperty("data",Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)));return Base64.getEncoder().encodeToString(e.toString().getBytes(StandardCharsets.UTF_8));}
 private static List<String> effects(JsonObject result){var target=result.get("ok").getAsBoolean()?result:result.getAsJsonObject("error");var values=target.getAsJsonArray("completedEffects");var list=new ArrayList<String>();if(values!=null)for(var value:values)list.add(value.getAsString());return list;}
 public static void main(String[]args)throws Exception{
  oldCounterfactual=args.length>0&&args[0].equals("--old-counterfactual");
  var server=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);
  server.createContext("/",e->{try{requests++;if(!"synthetic-auth".equals(e.getRequestHeaders().getFirst("Authorization"))||!e.getRequestHeaders().getFirst("Cookie").contains("login=synthetic"))throw new AssertionError("Header/Cookie did not reach original HTTP");byte[]b="header-body".getBytes(StandardCharsets.UTF_8);e.sendResponseHeaders(200,b.length);e.getResponseBody().write(b);}finally{e.close();}});server.start();String peer="http://127.0.0.1:"+server.getAddress().getPort(),a=peer+"/source-a",b=peer+"/source-b";
  LegadoRuntime.setHostCallback((task,operation,raw)->{
   if(operation.equals("task.cancel"))return "{}";var input=object(raw);String owner=input.get("owner").getAsString();String source=owner.substring("header:".length());
   if(operation.equals("state.read")){var values=new JsonObject();for(var key:input.getAsJsonArray("keys")){String wire=key.getAsString();var parts=JsonParser.parseString(wire).getAsJsonArray();if(parts.size()==3&&parts.get(1).getAsString().equals("cache-text")&&parts.get(2).getAsString().equals("loginHeader_"+source)&&headers.containsKey(source))values.addProperty(wire,entry(headers.get(source)));}var out=new JsonObject();out.addProperty("revision",0);out.add("values",values);return out.toString();}
   if(operation.equals("state.commit")){
    for(var kv:input.getAsJsonObject("changes").entrySet()){
     var parts=JsonParser.parseString(kv.getKey()).getAsJsonArray();if(parts.size()!=3||!parts.get(2).getAsString().equals("loginHeader_"+source)||!parts.get(1).getAsString().equals("cache-text"))continue;
     String value=kv.getValue().isJsonNull()?null:new String(Base64.getDecoder().decode(object(new String(Base64.getDecoder().decode(kv.getValue().getAsString()),StandardCharsets.UTF_8)).get("data").getAsString()),StandardCharsets.UTF_8);
     order.add("legacy-header");if(value!=null&&value.contains("Cookie"))return failure("UNSUPPORTED_CAPABILITY");if(value==null)headers.remove(source);else headers.put(source,value);
    }return "{\"committed\":true}";
   }
   if(operation.equals("source.login-header")){
    if(!input.get("taskId").getAsString().equals(task)||!input.get("cookieAccess").getAsString().equals("app-owner-text")||!input.get("sourceURL").getAsString().equals(source))throw new AssertionError("Producer provenance mismatch");
    String action=input.get("action").getAsString();order.add("header:"+action);String value=action.equals("put")?input.get("value").getAsString():null;boolean changed=!Objects.equals(headers.get(source),value);if(value==null)headers.remove(source);else headers.put(source,value);if(changed)headerWrites++;
    return changed?"{\"committed\":true,\"hostEffects\":[\"sourceLoginHeaderMayCommit\",\"sourceLoginHeaderCommitted\"]}":"{\"committed\":true}";
   }
   if(operation.equals("cookie.owner.text")){
    String action=input.get("action").getAsString(),domain=input.get("domain").getAsString();order.add("cookie:"+action);
    if(action.equals("get")){var out=new JsonObject();out.addProperty("cookie",cookies.getOrDefault(domain,""));return out.toString();}
    if(action.equals("session"))return "{\"cookie\":\"\"}";
    if(rejectCookie)return failure("STATE_IO");
    if(action.equals("replace")){cookies.put(domain,input.get("cookie").getAsString());cookieWrites++;}
    if(action.equals("remove")){cookies.remove(domain);cookieWrites++;}
    return action.equals("webRemove")?"{\"committed\":true}":"{\"committed\":true,\"hostEffects\":[\"cookieText\"]}";
   }
   if(operation.equals("source.login-info")){credentials++;throw new AssertionError("Header touched credentials");}
   if(operation.equals("http.request")){nativeHTTP++;throw new AssertionError("Header used native HTTP");}
   throw new AssertionError("Unexpected Host operation");
  });
  try{
   String literal="'{\"Cookie\":\"login=synthetic\",\"Authorization\":\"synthetic-auth\"}'";
   if(oldCounterfactual){var failed=call(a,"source.putLoginHeader("+literal+");","app-owner-text",false);if(!failed.getAsJsonObject("error").get("code").getAsString().equals("STATE_IO")||cookies.isEmpty()||headers.containsKey(a)||!order.equals(List.of("cookie:replace","legacy-header")))throw new AssertionError("Original Host header guard counterfactual was not reproduced");System.out.println("OLD_POST_BASE_HEADER_GUARD_REPRODUCED sessions=1 cookieCommitted=1 rawHeaderAbsent=1 stateIO=1 order=CookieThenRejectedHeader");return;}
   call(a,"source.putLoginHeader("+literal+");if(String(source.getLoginHeader())!=="+literal+")throw new Error('verbatim header lost');","app-owner-text",true);
   if(!order.equals(List.of("cookie:replace","header:put")))throw new AssertionError("Put ordering changed");
   call(b,"if(source.getLoginHeader()!==null)throw new Error('source leak');source.putLoginHeader('bare-token');source.putLoginHeader('bare-token');","app-owner-text",true);
   call(a,"if(String(java.ajax('"+peer+"/header'))!=='header-body')throw new Error('HTTP lost');","app-owner-text",true);
   rejectCookie=true;var failed=call(a,"source.removeLoginHeader();source.putLoginInfo('late');","app-owner-text",false);if(headers.containsKey(a)||cookies.isEmpty()||!effects(failed).contains("sourceLoginHeaderCommitted")||failed.toString().contains("SYNTHETIC-HEADER-PRIVATE"))throw new AssertionError("Partial remove effect lost or source text leaked");
   var denied=call(b,"source.putLoginHeader('denied');","app-owner-read",false);if(!denied.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY")||!headers.get(b).equals("bare-token"))throw new AssertionError("Read-only write admitted");
   if(sessions!=5||headerWrites!=3||cookieWrites!=1||requests!=1||credentials!=0||nativeHTTP!=0)throw new AssertionError("Wrong owners or no-op write count");
   System.out.println("ORDINARY_LOGIN_HEADER_OK sessions=5 sources=2 realHTTP=1 headerChanged=3 duplicateHeaderWrites=0 cookieWrites=1 partialFailure=1 readOnlyRejected=1 credentials=0 genericHTTPHost=0");
  }finally{LegadoRuntime.setHostCallback(null);server.stop(0);}
 }
}
