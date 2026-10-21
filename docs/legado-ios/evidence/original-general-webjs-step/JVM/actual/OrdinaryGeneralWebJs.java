import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import io.yuedu.legado.LegadoRuntime;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Real public ordinary-JAR execution with a synthetic native Host. No claim
 * that UIKit/WK was executed: only actual HTTP and JVM owner/policy are tested. */
public final class OrdinaryGeneralWebJs {
 static final Gson G=new Gson(); static final ExecutorService WORK=Executors.newCachedThreadPool();
 static final Map<String,String> STATE=new ConcurrentHashMap<>(); static final List<String> SESSIONS=new ArrayList<>();
 static final List<String> ROUTES=Collections.synchronizedList(new ArrayList<>());
 static final AtomicInteger CALLS=new AtomicInteger(), BROWSERS=new AtomicInteger(), REV=new AtomicInteger(), COOKIES=new AtomicInteger();
 static String origin,source,owner,sid; static volatile JsonObject packet; static volatile Behavior behavior;
 interface Behavior {String run(String task,JsonObject input)throws Exception;}
 static JsonObject obj(String s){return JsonParser.parseString(s).getAsJsonObject();}
 static void check(boolean b,String why){if(!b)throw new AssertionError(why);}
 static JsonObject ok(JsonObject r){check(r.get("ok").getAsBoolean(),"expected success "+r);return r.getAsJsonObject("result");}
 static void error(JsonObject r,String code){check(!r.get("ok").getAsBoolean()&&r.getAsJsonObject("error").get("code").getAsString().equals(code),"expected "+code+" "+r);}
 static String id(){return "general-"+UUID.randomUUID();}
 static JsonObject exec(String session,String task,String op,JsonObject in){CALLS.incrementAndGet();return obj(LegadoRuntime.execute(session,task,op,in.toString()));}
 static JsonObject exec(String op,JsonObject in){return exec(sid,id(),op,in);}
 static JsonObject input(String page,String method,String...params){var in=new JsonObject();in.addProperty("pageId",page);in.addProperty("method",method);in.addProperty("timeoutMs",10000);var a=new JsonArray();for(var p:params)a.add(p);in.add("params",a);return in;}
 static JsonObject child(String page,String op,String method,String...params)throws Exception{return WORK.submit(()->exec(op,input(page,method,params))).get(12,TimeUnit.SECONDS);}
 static JsonObject policy(String page,String method,String...params)throws Exception{return child(page,"generalWebPolicy",method,params);}
 static JsonObject bridge(String page,String method,String...params)throws Exception{return child(page,"webJsRequest",method,params);}
 static String value(JsonObject r){var v=ok(r);check(v.get("kind").getAsString().equals("string"),"string kind");return v.get("value").isJsonNull()?null:v.get("value").getAsString();}
 static String page(){return packet.getAsJsonObject("page").get("pageId").getAsString();}
 static JsonObject evaluate(String script){var in=obj("{\"action\":\"evaluate\",\"timeoutMs\":15000}");in.addProperty("script",script);return exec("exploreContext",in);}
 static String evaluation(String script){return ok(evaluate(script)).get("result").getAsString();}
 static String quote(String s){return G.toJson(s);}
 static String complete(JsonObject in,String raw)throws Exception{
  String p=in.getAsJsonObject("page").get("pageId").getAsString();value(policy(p,"configure","true"));
  var accepted=obj(value(policy(p,"evaluate",raw)));check(!accepted.get("retry").getAsBoolean(),"unexpected retry");
  var r=new JsonObject();r.addProperty("url",in.get("url").isJsonNull()?"about:blank":in.get("url").getAsString());r.add("body",accepted.get("body"));r.addProperty("redirected",false);return r.toString();
 }
 static String create(String name,String searchRule){var src=obj("{\"enabledCookieJar\":true,\"ruleContent\":{},\"ruleSearch\":{\"bookList\":\"class.book\",\"name\":\"tag.a@text\",\"bookUrl\":\"tag.a@href\"}}");
  src.addProperty("bookSourceUrl",source);src.addProperty("bookSourceName",name);src.addProperty("searchUrl",origin+"/search");
  if(searchRule!=null)src.getAsJsonObject("ruleSearch").addProperty("name",searchRule);
  src.addProperty("header","{\"X-Synthetic\":\"same-general-owner\",\"User-Agent\":\"exact-UA\",\"user-agent\":\"other-UA\",\"CookieJar\":\"internal\",\"proxy\":\"\"}");
  var opts=obj("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"cookieAccess\":\"app-owner-text\",\"userAgent\":\"embedding-UA\"}");opts.addProperty("stateOwner",owner);
  var r=obj(LegadoRuntime.createSession(src.toString(),opts.toString()));check(r.get("ok").getAsBoolean(),"create "+r);String s=r.get("sessionId").getAsString();SESSIONS.add(s);return s;
 }
 static String host(String task,String op,String raw){try{
  if(op.equals("task.cancel"))return "{}";var in=obj(raw);check(in.get("owner").getAsString().equals(owner),"wrong owner");
  if(op.equals("explore.owner.scope"))return "{\"scope\":\"general-scope\"}";
  if(op.equals("state.read")){var out=new JsonObject();out.addProperty("revision",REV.get());var vals=new JsonObject();for(var k:in.getAsJsonArray("keys"))if(STATE.containsKey(k.getAsString()))vals.addProperty(k.getAsString(),STATE.get(k.getAsString()));out.add("values",vals);return out.toString();}
  if(op.equals("state.commit")){synchronized(STATE){if(in.get("revision").getAsInt()!=REV.get())return "{\"committed\":false}";for(var e:in.getAsJsonObject("changes").entrySet())if(e.getValue().isJsonNull())STATE.remove(e.getKey());else STATE.put(e.getKey(),e.getValue().getAsString());REV.incrementAndGet();}return "{\"committed\":true,\"hostEffects\":[\"sourceStateCommitted\"]}";}
  if(op.equals("cookie.owner.text")){String a=in.get("action").getAsString();if(a.equals("get")||a.equals("session"))return "{\"cookie\":\"synthetic=general\"}";check(a.equals("set"),"unexpected cookie mutation "+in);COOKIES.incrementAndGet();check(in.get("url").getAsString().equals(source),"cookie tag became target URL");return "{\"committed\":true,\"hostEffects\":[\"cookieText\"]}";}
  if(op.equals("source.webview")){BROWSERS.incrementAndGet();packet=in.deepCopy();check(in.get("sourceURL").getAsString().equals(source)&&in.get("sessionId").getAsString().equals(sid)&&in.get("taskId").getAsString().equals(task),"browser provenance");check(in.getAsJsonObject("page").get("parentTaskId").getAsString().equals(task),"page task mismatch");check(in.get("userAgent").getAsString().equals("exact-UA"),"exact UA priority lost");var extra=in.getAsJsonObject("additionalHeaders");for(var k:extra.keySet())check(!List.of("user-agent","cookiejar","proxy").contains(k.toLowerCase(Locale.ROOT)),"internal header leaked");return behavior==null?complete(in,quote("general-result")):behavior.run(task,in);}
  throw new AssertionError("unexpected Host/new authority "+op);
 }catch(Exception e){throw new RuntimeException(e);}}
 public static void main(String[]args)throws Exception{
  var http=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);http.createContext("/",e->{try{
   ROUTES.add(e.getRequestMethod()+" "+e.getRequestURI().getPath());check("same-general-owner".equals(e.getRequestHeaders().getFirst("X-Synthetic")),"HTTP source headers missing");
   String path=e.getRequestURI().getPath();if(path.equals("/redirect")){e.getResponseHeaders().set("Location",origin+"/must-not-follow");e.getResponseHeaders().set("X-Redirect","kept");e.sendResponseHeaders(302,-1);return;}
   String body="<div class='book'><a href='/book'>HTTP Name</a></div>";if(e.getRequestMethod().equals("POST")){
    var bytes=e.getRequestBody().readAllBytes();if(path.equals("/json")){check(new String(bytes,StandardCharsets.UTF_8).equals("{\n  \"k\": 1\n}"),"JSON body changed: "+G.toJson(new String(bytes,StandardCharsets.UTF_8)));check(e.getRequestHeaders().getFirst("Content-Type").equals("application/json; charset=UTF-8"),"browser JSON branch kept authored type");body="<html>POST JSON</html>";}
    else {check(new String(bytes,StandardCharsets.UTF_8).equals("a=b"),"form body changed");body="<html>POST form</html>";}
   }if(path.equals("/xml")){e.getResponseHeaders().set("Content-Type","application/xml");body="<root>no browser</root>";}
   byte[]bytes=body.getBytes(StandardCharsets.UTF_8);e.sendResponseHeaders(200,bytes.length);e.getResponseBody().write(bytes);
  }catch(Throwable failure){failure.printStackTrace();throw failure;}finally{e.close();}});http.start();origin="http://127.0.0.1:"+http.getAddress().getPort();source=origin+"/source";owner="general:"+source;LegadoRuntime.setHostCallback(OrdinaryGeneralWebJs::host);
  try{
   sid=create("general",null);ok(exec("exploreContext",obj("{\"action\":\"open\"}")));
   check(evaluation("String(java.webView('<html>first</html>', '"+origin+"/base', null))").equals("general-result"),"three arg delegate ABI");String closedPage=page();error(bridge(closedPage,"cache.get","x"),"INVALID_BROWSER_PAGE");
   check(packet.get("initialDelayMs").getAsInt()==1000&&!packet.get("isRule").getAsBoolean(),"basic delay/authority");
   behavior=(t,in)->{String p=page();value(policy(p,"configure","true"));error(bridge(p,"cache.get","forbidden"),"UNSUPPORTED_CAPABILITY");error(bridge(p,"policy.configure","true"),"UNSUPPORTED_CAPABILITY");error(bridge(p,"configure","true"),"UNSUPPORTED_CAPABILITY");var forged=input(p,"request");forged.addProperty("function","policy.configure");forged.addProperty("requestId","req_forbidden");error(WORK.submit(()->exec("webJsRequest",forged)).get(10,TimeUnit.SECONDS),"UNSUPPORTED_CAPABILITY");
    for(String raw:Arrays.asList(null,"","null")){var a=obj(value(policy(p,"evaluate",raw)));check(a.get("retry").getAsBoolean(),"raw null accepted");}var a=obj(value(policy(p,"evaluate","\"\"")));check(a.get("body").getAsString().isEmpty(),"quoted empty changed");return "{\"url\":\""+origin+"/empty\",\"body\":\"\",\"redirected\":false}";};
   check(evaluation("String(java.webView('<html>empty</html>','"+origin+"/empty','',true))").isEmpty(),"four arg empty result changed");check(packet.get("initialDelayMs").getAsInt()==100&&packet.get("cacheFirst").getAsBoolean(),"empty js delay/cachefirst");behavior=null;
   String negative=origin+"/negative,{\"webView\":true,\"webViewDelayTime\":-1}";
   check(evaluation("String(java.ajax("+quote(negative)+"))").equals("general-result"),"negative URL delay failed");
   check(packet.get("delayTime").getAsLong()==0&&packet.get("initialDelayMs").getAsLong()==1000&&packet.get("js").isJsonNull(),"URL negative delay must clamp before default900ms");
   String form=origin+"/form,{\"method\":\"POST\",\"body\":\"a=b\",\"webView\":true,\"webJs\":\"document.title\",\"webViewDelayTime\":123,\"bodyJs\":\"throw Error('must not transform browser')\"}";
   check(evaluation("String(java.ajax("+quote(form)+"))").equals("general-result"),"URL browser route failed");check(packet.get("html").getAsString().equals("<html>POST form</html>")&&packet.get("js").getAsString().equals("document.title")&&packet.get("initialDelayMs").getAsInt()==223,"POST body/JS/delay changed");
   String json=origin+"/json,{\"method\":\"POST\",\"body\":{\"k\":1},\"headers\":{\"Content-Type\":\"text/synthetic\"},\"webView\":true}";String jsonActual=evaluation("String(java.ajax("+quote(json)+"))");check(jsonActual.equals("general-result"),"JSON browser failed: "+jsonActual);
   int before=BROWSERS.get();String redirect=origin+"/redirect,{\"method\":\"POST\",\"body\":\"a=b\",\"webView\":true,\"followRedirects\":false}";check(evaluation("var r=java.connect("+quote(redirect)+");r.code()+'|'+r.header('X-Redirect')").equals("302|kept"),"raw 302/headers lost");check(BROWSERS.get()==before&&!ROUTES.toString().contains("must-not-follow"),"redirect opened/followed browser");
   String ignored=origin+"/xml,{\"webView\":false,\"webJs\":\"throw Error('ignored')\",\"webViewDelayTime\":2}";check(evaluation("String(java.ajax("+quote(ignored)+"))").startsWith("<?xml version=\"1.0\"?>"),"ordinary HTTP transform changed");check(BROWSERS.get()==before,"disabled webView used Host");
   behavior=(t,in)->{String p=page();value(policy(p,"configure","true"));check(value(policy(p,"navigation",origin+"/capture/42")).equals("true"),"Java full-match predicate");return "{\"url\":\""+origin+"/initial\",\"body\":\""+origin+"/capture/42\",\"redirected\":false}";};
   check(evaluation("String(java.webViewGetOverrideUrl(null,'"+origin+"/initial','', '.*capture/[0-9]+',false,7))").equals(origin+"/capture/42"),"sniffer route/identity");
   behavior=(t,in)->"{\"ok\":false,\"error\":{\"code\":\"UNSUPPORTED_CAPABILITY\",\"message\":\"WK full resource interception unavailable\"}}";error(evaluate("java.webViewGetSource(null,'"+origin+"/initial',null,'.*mp3')"),"UNSUPPORTED_CAPABILITY");
   behavior=(t,in)->"{\"url\":\""+origin+"/fake\",\"body\":\"fakeACK\",\"redirected\":false}";error(evaluate("java.webView('<html>fake</html>','"+origin+"/fake',null)"),"INVALID_WEBVIEW_POLICY");
   // Actual WebBook search invokes AnalyzeRule @webjs (not legacy JS2).
   sid=create("rule","tag.a@text@webjs:document.title");behavior=(t,in)->{check(in.get("isRule").getAsBoolean()&&in.get("cacheFirst").getAsBoolean(),"@rule routing");check(in.get("timeoutMs").getAsLong()<=10000&&in.get("resultJSON").isJsonPrimitive(),"rule budget/result JSON");check(in.get("injectionString").getAsString().startsWith("try{var cache=")&&!in.get("html").getAsString().contains("JSBridgeCallbacks"),"JS2 substituted for original injection");String p=page();value(policy(p,"configure","true"));check(value(bridge(p,"cache.getFromMemory","webview_result")).equals(in.get("resultJSON").getAsString()),"previous result not original GSON String");check(value(bridge(p,"source.getKey")).equals(source),"registered source interface");ok(policy(p,"cookie",origin+"/search","observed=WK"));var a=obj(value(policy(p,"evaluate",quote("WK Name"))));return "{\"url\":\""+origin+"/search\",\"body\":"+G.toJson(a.get("body").getAsString())+",\"redirected\":false}";};
   var books=ok(exec("search",obj("{\"key\":\"synthetic\",\"page\":1,\"timeoutMs\":15000}"))).getAsJsonArray("books");check(books.size()==1&&books.get(0).getAsJsonObject().get("name").getAsString().equals("WK Name"),"actual @webjs search output");check(COOKIES.get()==1,"cookie tag publication missing");
   behavior=(t,in)->{String p=page();value(policy(p,"configure","false"));check(value(bridge(p,"cache.getFromMemory","webview_result")).equals(in.get("resultJSON").getAsString()),"unregistered rule cache missing");error(bridge(p,"source.getKey"),"UNSUPPORTED_CAPABILITY");error(bridge(p,"java.get","x"),"UNSUPPORTED_CAPABILITY");var a=obj(value(policy(p,"evaluate",quote("unregistered"))));return "{\"url\":\""+origin+"/search\",\"body\":"+G.toJson(a.get("body").getAsString())+",\"redirected\":false}";};ok(exec("search",obj("{\"key\":\"synthetic\",\"timeoutMs\":15000}")));
   // A cyclic DOM previous result is not silently converted to a string.
   sid=create("cyclic-result","@webjs:document.title");error(exec("search",obj("{\"key\":\"synthetic\",\"timeoutMs\":15000}")),"UNSUPPORTED_CAPABILITY");
   // Held real synchronous Host return after cancellation cannot publish body.
   sid=SESSIONS.get(0);var entered=new CountDownLatch(1);var release=new CountDownLatch(1);behavior=(t,in)->{entered.countDown();check(release.await(10,TimeUnit.SECONDS),"held Host not released");return "{\"url\":\""+origin+"/held\",\"body\":\"late\",\"redirected\":false}";};String parent=id();var in=obj("{\"action\":\"evaluate\",\"timeoutMs\":15000}");in.addProperty("script","java.webView('<html>held</html>','"+origin+"/held',null)");var pending=WORK.submit(()->exec(sid,parent,"exploreContext",in));check(entered.await(10,TimeUnit.SECONDS),"parent not blocked");check(obj(LegadoRuntime.cancel(parent)).get("ok").getAsBoolean(),"cancel failed");release.countDown();error(pending.get(12,TimeUnit.SECONDS),"CANCELLED");error(bridge(page(),"cache.get","x"),"INVALID_BROWSER_PAGE");
   check(ROUTES.equals(List.of("POST /form","POST /json","POST /redirect","GET /xml","GET /search","GET /search","GET /search")),"HTTP repeated/moved "+ROUTES);
   System.out.println("GENERAL_WEBJS_PUBLIC_OK sessions="+SESSIONS.size()+" publicCalls="+CALLS.get()+" syntheticBrowserHostCalls="+BROWSERS.get()+" realHTTP=7 POST=3 GET=4 cookieTagMutations="+COOKIES.get()+" sameOwnerStateACKs="+REV.get()+" JUnit=0 WK=0 SDK=0");
  }finally{for(String s:SESSIONS)check(obj(LegadoRuntime.closeSession(s)).get("ok").getAsBoolean(),"close session");LegadoRuntime.setHostCallback(null);http.stop(0);WORK.shutdownNow();}
 }
}
