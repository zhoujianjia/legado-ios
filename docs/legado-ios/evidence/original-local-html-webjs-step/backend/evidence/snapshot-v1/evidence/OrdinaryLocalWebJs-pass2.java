import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import io.yuedu.legado.LegadoRuntime;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Public ordinary-JAR consumer. The browser ACK is a synthetic Host boundary,
 * never evidence that UIKit/WK rendered or ran the supplied HTML. */
public final class OrdinaryLocalWebJs {
 static final Gson gson=new Gson();
 static final ExecutorService workers=Executors.newCachedThreadPool();
 static final Map<String,String> state=new ConcurrentHashMap<>();
 static final AtomicInteger calls=new AtomicInteger(), commits=new AtomicInteger(), browsers=new AtomicInteger(), credentials=new AtomicInteger(), genericHttp=new AtomicInteger(), cancelSignals=new AtomicInteger();
 static final List<String> routes=Collections.synchronizedList(new ArrayList<>());
 static final List<String> sessions=new ArrayList<>();
 static String origin,source,owner,session;
 static volatile JsonObject packet;
 static volatile BrowserAction onBrowser;
 static volatile CountDownLatch holdRead,releaseRead,writeAccepted,releaseWrite;
 static volatile CountDownLatch cancelObserved;
 static volatile String watchedCancelledTask;
 interface BrowserAction { String run(String task,JsonObject input) throws Exception; }
 static JsonObject obj(String raw){return JsonParser.parseString(raw).getAsJsonObject();}
 static void check(boolean b,String why){if(!b)throw new AssertionError(why);}
 static JsonObject ok(JsonObject reply){check(reply.get("ok").getAsBoolean(),"expected success "+reply);return reply.getAsJsonObject("result");}
 static JsonObject execute(String sid,String task,String op,JsonObject input){calls.incrementAndGet();return obj(LegadoRuntime.execute(sid,task,op,input.toString()));}
 static String task(){return "webjs-"+UUID.randomUUID();}
 static JsonObject request(String page,String method,String...params){var input=new JsonObject();input.addProperty("pageId",page);input.addProperty("method",method);input.addProperty("timeoutMs",10000);var values=new JsonArray();for(String v:params)values.add(v);input.add("params",values);return input;}
 static JsonObject child(String sid,String page,String method,String...params){return execute(sid,task(),"webJsRequest",request(page,method,params));}
 static JsonObject remoteChild(String sid,String page,String method,String...params)throws Exception{return workers.submit(()->child(sid,page,method,params)).get(15,TimeUnit.SECONDS);}
 static String value(JsonObject reply){var result=ok(reply);check(result.get("kind").getAsString().equals("string"),"string result kind");return result.get("value").isJsonNull()?null:result.get("value").getAsString();}
 static JsonObject run(String sid,String page,String js,String id){var in=request(page,"request",js);in.addProperty("function","run");in.addProperty("requestId",id);return execute(sid,task(),"webJsRequest",in);}
 static String runValue(String sid,String page,String js,boolean success)throws Exception{
  String id="req_"+UUID.randomUUID().toString().replace("-","");var reply=workers.submit(()->run(sid,page,js,id)).get(15,TimeUnit.SECONDS);var r=ok(reply);check(r.get("kind").getAsString().equals("callback")&&r.get("requestId").getAsString().equals(id)&&r.get("success").getAsBoolean()==success,"callback identity/terminal "+reply);
  String result=value(remoteChild(sid,page,"cache.getFromMemory",id));ok(remoteChild(sid,page,"cache.deleteMemory",id));check(value(remoteChild(sid,page,"cache.getFromMemory",id))==null,"callback result not deleted");return result;
 }
 static void error(JsonObject reply,String code){check(!reply.get("ok").getAsBoolean()&&reply.getAsJsonObject("error").get("code").getAsString().equals(code),"expected "+code+" "+reply);}
 static String create(boolean v2){var src=obj("{\"enabledCookieJar\":true,\"ruleContent\":{},\"ruleSearch\":{\"bookList\":\"class.none\"}}");src.addProperty("bookSourceUrl",source);src.addProperty("header","{\"X-Synthetic\":\"same-page-owner\"}");src.addProperty("loginUi",v2?"{\"version\":2}":"[]");src.addProperty("loginUrl",v2?"function loginUi(s){return {rows:[]};} function loginAction(a,s,f){java.startBrowser('"+origin+"/v2','V2','<html><body>V2 local</body></html>');return {};}":"var localPrelude=true;");var made=obj(LegadoRuntime.createSession(src.toString(),"{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"cookieAccess\":\"app-owner-text\",\"stateOwner\":"+gson.toJson(owner)+"}"));check(made.get("ok").getAsBoolean(),"create "+made);String id=made.get("sessionId").getAsString();sessions.add(id);return id;}
 static JsonObject action(String sid,String script){var in=obj("{\"credentials\":{},\"isLongClick\":false,\"timeoutMs\":15000}");in.addProperty("action",script);return execute(sid,task(),"loginAction",in);}
 static void closePage(String sid,String page){var in=new JsonObject();in.addProperty("pageId",page);in.addProperty("timeoutMs",10000);check(ok(execute(sid,task(),"webJsPageClose",in)).get("closed").getAsBoolean(),"page close missing ACK");}
 static String page(){return packet.getAsJsonObject("localPage").get("pageId").getAsString();}
 static String host(String task,String op,String raw){try{
  if(op.equals("task.cancel")){cancelSignals.incrementAndGet();if(task.equals(watchedCancelledTask)&&cancelObserved!=null)cancelObserved.countDown();return "{}";}
  var in=obj(raw);check(in.get("owner").getAsString().equals(owner),"source owner changed");
  if(op.equals("state.read")){
   if(holdRead!=null&&in.getAsJsonArray("keys").toString().contains("held")){holdRead.countDown();check(releaseRead.await(15,TimeUnit.SECONDS),"read not released");}
   var out=new JsonObject();out.addProperty("revision",commits.get());var values=new JsonObject();for(var k:in.getAsJsonArray("keys"))if(state.containsKey(k.getAsString()))values.addProperty(k.getAsString(),state.get(k.getAsString()));out.add("values",values);return out.toString();
  }
  if(op.equals("state.commit")){
   synchronized(state){if(in.get("revision").getAsInt()!=commits.get())return "{\"committed\":false}";for(var entry:in.getAsJsonObject("changes").entrySet()){if(entry.getValue().isJsonNull())state.remove(entry.getKey());else state.put(entry.getKey(),entry.getValue().getAsString());}commits.incrementAndGet();}
   if(writeAccepted!=null){writeAccepted.countDown();check(releaseWrite.await(15,TimeUnit.SECONDS),"write not released");}
   return "{\"committed\":true,\"hostEffects\":[\"sourceStateMayCommit\",\"sourceStateCommitted\"]}";
  }
  if(op.equals("cookie.owner.text")){check(in.get("action").getAsString().equals("get")||in.get("action").getAsString().equals("session"),"unexpected cookie mutation");return "{\"cookie\":\"synthetic=page\"}";}
  if(op.equals("source.browser")){browsers.incrementAndGet();packet=in.deepCopy();check(in.get("sourceURL").getAsString().equals(source),"browser source changed");var meta=in.getAsJsonObject("localPage");check(meta!=null&&meta.get("sessionId").getAsString().equals(session)&&meta.get("parentTaskId").getAsString().equals(task),"page provenance");for(String key:List.of("javaName","cacheName","resultName"))check(meta.get(key).getAsString().matches("[A-Za-z][A-Za-z0-9]*"),"unsafe JS name");return onBrowser==null?"{\"presented\":true,\"hostEffects\":[\"sourceBrowserMayPresent\",\"sourceBrowserPresented\"]}":onBrowser.run(task,in);}
  if(op.equals("source.login-info")){credentials.incrementAndGet();throw new AssertionError("unrequested credentials");}
  if(op.equals("http.request")){genericHttp.incrementAndGet();throw new AssertionError("HTTP moved to Host");}
  throw new AssertionError("Unexpected Host "+op);
 }catch(Exception e){throw new RuntimeException(e);}}
 public static void main(String[]args)throws Exception{
  var http=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);http.createContext("/",e->{try{routes.add(e.getRequestMethod()+" "+e.getRequestURI().getPath());check("same-page-owner".equals(e.getRequestHeaders().getFirst("X-Synthetic")),"source Header owner lost");check(e.getRequestHeaders().getFirst("Cookie").contains("synthetic=page"),"Cookie owner lost");if(e.getRequestMethod().equals("POST"))check(new String(e.getRequestBody().readAllBytes(),StandardCharsets.UTF_8).equals("field=synthetic"),"POST body changed");String body=e.getRequestURI().getPath().equals("/empty")?"":e.getRequestMethod().equals("POST")?"<html>POST replacement</html>":"network-value";byte[]b=body.getBytes(StandardCharsets.UTF_8);e.sendResponseHeaders(200,b.length==0?-1:b.length);if(b.length>0)e.getResponseBody().write(b);}finally{e.close();}});http.start();origin="http://127.0.0.1:"+http.getAddress().getPort();source=origin+"/source";owner="localwebjs:"+source;LegadoRuntime.setHostCallback(OrdinaryLocalWebJs::host);
  try{
   session=create(false);String html="<html><head data-synthetic='yes'></head><body>local</body></html>";
   ok(action(session,"java.startBrowser('"+origin+"/initial','Local',"+gson.toJson(html)+");"));String page=page();check(packet.get("prefetchedHTML").getAsString().contains("const java = window."+packet.getAsJsonObject("localPage").get("javaName").getAsString()),"original JS2 aliases absent");check(packet.get("prefetchedHTML").getAsString().indexOf("<script>")>packet.get("prefetchedHTML").getAsString().indexOf("<head"),"head insertion changed");check(routes.isEmpty(),"GET explicit HTML unexpectedly fetched");
   check(runValue(session,page,"java.setContent('{\"value\":\"retained\"}'); String(java.getString('$.value'))+'|'+(book===null)+'|'+(chapter===null)+'|'+(typeof java.setContent)",true).equals("retained|true|true|function"),"AnalyzeRule/null book/chapter binding");
   check(runValue(session,page,"java.getString('$.value')",true).equals("retained"),"page parser state did not survive producer");
   check(runValue(session,page,"null",true).equals("null"),"run null must stringify");check(runValue(session,page,"throw Error('synthetic-script-error')",false).contains("synthetic-script-error"),"ordinary error not cached");
   check(value(remoteChild(session,page,"cache.getFromMemory","missing"))==null,"memory missing not null");ok(remoteChild(session,page,"cache.putMemory","plain","value"));check(value(remoteChild(session,page,"cache.getFromMemory","plain")).equals("value"),"same memory owner");
   ok(remoteChild(session,page,"cache.put","durable","cache-value"));check(value(remoteChild(session,page,"cache.get","durable")).equals("cache-value"),"same persistent cache owner");ok(remoteChild(session,page,"cache.delete","durable"));check(value(remoteChild(session,page,"cache.get","durable"))==null,"cache deletion");
   check(value(remoteChild(session,page,"java.put","source-variable","synthetic-source")).equals("synthetic-source"),"source put");check(value(remoteChild(session,page,"java.get","source-variable")).equals("synthetic-source"),"onearg source get");
   check(value(remoteChild(session,page,"java.ajax",origin+"/ajax")).equals("network-value"),"same-session HTTP failed");check(routes.equals(List.of("GET /ajax")),"unexpected HTTP route "+routes);
   error(remoteChild(session,page,"java.get",origin+"/wrong","{}"),"UNSUPPORTED_CAPABILITY");error(remoteChild(session,page,"unknown"),"UNSUPPORTED_CAPABILITY");error(obj(LegadoRuntime.execute(session,task(),"webJsRequest",request("forged","cache.get","x").toString())),"INVALID_BROWSER_PAGE");
   String other=create(false);error(remoteChild(other,page,"cache.get","x"),"INVALID_BROWSER_PAGE");
   // The parent Rhino remains blocked in Host, while an independent worker uses
   // the same page/session and releases its context before returning callbacks.
   onBrowser=(parent,in)->{String p=in.getAsJsonObject("localPage").get("pageId").getAsString();error(child(session,p,"cache.get","x"),"INVALID_BROWSER_REENTRY");check(runValue(session,p,"'await-child'",true).equals("await-child"),"child blocked by parent");ok(remoteChild(session,p,"cache.put","await-effect","accepted"));return "{\"mode\":\"response\",\"finalURL\":\""+origin+"/dom\",\"body\":\"<html>actual-host-boundary</html>\"}";};
   var awaited=action(session,"var r=java.startBrowserAwait('"+origin+"/await','Await',false,'');if(String(r.body())!=='<html>actual-host-boundary</html>')throw Error('body');");ok(awaited);check(awaited.getAsJsonArray("completedEffects").toString().contains("sourceStateCommitted"),"child effect not retained in active parent");String awaitedPage=page();error(remoteChild(session,awaitedPage,"cache.get","x"),"INVALID_BROWSER_PAGE");onBrowser=null;
   // POST overwrites prepared injection exactly once; present empty disables
   // bridge but preserves the explicit page lease until close.
   String post=origin+"/post,{\"method\":\"POST\",\"body\":\"field=synthetic\"}";
   ok(action(session,"java.startBrowser("+gson.toJson(post)+",'Post','<head>injected-before-post</head>');"));String postPage=page();check(packet.get("prefetchedHTML").getAsString().equals("<html>POST replacement</html>"),"POST reinjected/replaced incorrectly");check(runValue(session,postPage,"'post-bridge'",true).equals("post-bridge"),"nonempty POST bridge missing");closePage(session,postPage);
   String empty=origin+"/empty,{\"method\":\"POST\",\"body\":\"field=synthetic\"}";ok(action(session,"java.startBrowser("+gson.toJson(empty)+",'Empty','');"));String emptyPage=page();check(packet.has("prefetchedHTML")&&packet.get("prefetchedHTML").getAsString().isEmpty(),"empty POST lost presence");error(remoteChild(session,emptyPage,"cache.get","x"),"UNSUPPORTED_CAPABILITY");closePage(session,emptyPage);
   String v2=create(true);session=v2;ok(execute(v2,task(),"loginV2Action",obj("{\"action\":\"start\",\"stateJSON\":\"{}\",\"form\":{},\"timeoutMs\":10000}")));check(runValue(v2,page(),"'v2-page'",true).equals("v2-page"),"V2 public localHTML missing");closePage(v2,page());session=sessions.get(0);
   // Explicit close must wait a real accepted Host callback, retain its effects
   // on the cancelled child, and reject all subsequent page work.
   ok(action(session,"java.startBrowser('"+origin+"/held','Held','<body>held</body>');"));String heldPage=page();writeAccepted=new CountDownLatch(1);releaseWrite=new CountDownLatch(1);String childTask=task();watchedCancelledTask=childTask;cancelObserved=new CountDownLatch(1);var writing=workers.submit(()->execute(session,childTask,"webJsRequest",request(heldPage,"cache.put","held-commit","accepted")));check(writeAccepted.await(10,TimeUnit.SECONDS),"write never accepted");var closing=workers.submit(()->{closePage(session,heldPage);return true;});
   check(cancelObserved.await(10,TimeUnit.SECONDS),"page close omitted native child cancellation");check(!closing.isDone(),"close ACK before actual child callback");releaseWrite.countDown();var rejected=writing.get(10,TimeUnit.SECONDS);error(rejected,"CANCELLED");check(rejected.getAsJsonObject("error").getAsJsonArray("completedEffects").toString().contains("sourceStateCommitted"),"accepted effect lost after cancellation");check(closing.get(10,TimeUnit.SECONDS),"close did not drain");writeAccepted=null;releaseWrite=null;cancelObserved=null;watchedCancelledTask=null;error(remoteChild(session,heldPage,"cache.get","held-commit"),"INVALID_BROWSER_PAGE");closePage(session,heldPage);
   // Cancelling the parent seals its children without joining on the caller or
   // sole timer thread. Its worker then issues native child cancellation and
   // remains draining until the actually issued callback returns.
   var browserEntered=new CountDownLatch(1);var releaseBrowser=new CountDownLatch(1);onBrowser=(parent,in)->{browserEntered.countDown();check(releaseBrowser.await(15,TimeUnit.SECONDS),"parent not released");return "{\"mode\":\"response\",\"finalURL\":\""+origin+"/cancelled\",\"body\":\"<html>cancelled</html>\"}";};
   String parentTask=task();var parentInput=obj("{\"credentials\":{},\"isLongClick\":false,\"timeoutMs\":15000}");parentInput.addProperty("action","java.startBrowserAwait('"+origin+"/parent-cancel','Cancel',false,'<html>cancel</html>');");var parentPending=workers.submit(()->execute(session,parentTask,"loginAction",parentInput));check(browserEntered.await(10,TimeUnit.SECONDS),"parent not in browser Host");String cancelledPage=page();holdRead=new CountDownLatch(1);releaseRead=new CountDownLatch(1);String readingTask=task();watchedCancelledTask=readingTask;cancelObserved=new CountDownLatch(1);int before=commits.get();var reading=workers.submit(()->execute(session,readingTask,"webJsRequest",request(cancelledPage,"cache.put","held-late-write","must-not-write")));check(holdRead.await(10,TimeUnit.SECONDS),"child read not entered");var cancelParent=workers.submit(()->LegadoRuntime.cancel(parentTask));check(obj(cancelParent.get(5,TimeUnit.SECONDS)).get("ok").getAsBoolean(),"parent cancellation blocked on child");releaseBrowser.countDown();check(cancelObserved.await(10,TimeUnit.SECONDS),"parent worker omitted child native cancellation");check(!parentPending.isDone(),"parent ended before child drain");releaseRead.countDown();error(reading.get(10,TimeUnit.SECONDS),"CANCELLED");error(parentPending.get(10,TimeUnit.SECONDS),"CANCELLED");check(commits.get()==before,"cancelled child wrote after held read");error(remoteChild(session,cancelledPage,"cache.get","held-late-write"),"INVALID_BROWSER_PAGE");holdRead=null;releaseRead=null;cancelObserved=null;watchedCancelledTask=null;onBrowser=null;
   closePage(session,page);error(remoteChild(session,page,"cache.get","plain"),"INVALID_BROWSER_PAGE");check(credentials.get()==0&&genericHttp.get()==0,"new credential/HTTP owner");check(routes.equals(List.of("GET /ajax","POST /post","POST /empty")),"repeated POST/hidden HTTP "+routes);
   System.out.println("LOCAL_WEBJS_PUBLIC_OK sessions="+sessions.size()+" publicCalls="+calls.get()+" browserWireACK="+browsers.get()+" checkedStateCommits="+commits.get()+" realHTTP=3 GET=1 POST=2 credentials=0 genericHTTPHost=0 parentBlockedChild=1 retainedPageAnalyzeRule=1 cancellationDrain=1 JUnit=0 UIKit=0");
  }finally{if(releaseWrite!=null)releaseWrite.countDown();if(releaseRead!=null)releaseRead.countDown();for(String id:sessions)check(obj(LegadoRuntime.closeSession(id)).get("ok").getAsBoolean(),"session close failed");LegadoRuntime.setHostCallback(null);http.stop(0);workers.shutdownNow();}
 }
}
