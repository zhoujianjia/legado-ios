import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import io.yuedu.legado.LegadoRuntime;
import com.sun.net.httpserver.HttpServer;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.concurrent.atomic.AtomicInteger;

/** Verifies the assembled payload, rather than Gradle's separate classes/dependency paths. */
public class LegadoPayloadSmoke {
    static JsonObject checked(String json) {
        var result = JsonParser.parseString(json).getAsJsonObject();
        if (!result.get("ok").getAsBoolean()) throw new AssertionError(json);
        return result;
    }
    public static void main(String[] args) throws Exception {
        Class.forName("java.beans.Introspector");
        Class.forName("javax.xml.parsers.DocumentBuilderFactory");
        var source = new JsonObject();
        source.addProperty("bookSourceUrl", "https://fixture.invalid");
        source.addProperty("mainJs", "function search(key,page){return [{name:key,bookUrl:'fixture:book'}]};function getChapters(book){return [{title:'Chapter 1',url:'fixture:1'}]};function getContent(chapter,book,nextChapterUrl){return 'Local content'};");
        var session = checked(LegadoRuntime.createSession(source.toString())).get("sessionId").getAsString();
        try {
            var semantics = checked(LegadoRuntime.execute(session,"packaged-semantics","semanticProbe","{}"));
            if (!semantics.getAsJsonObject("result").get("e4x").getAsString().equals("ok")) throw new AssertionError(semantics);
            var search = checked(LegadoRuntime.execute(session,"packaged-search","search","{\"key\":\"fixture\",\"page\":1}"));
            if (!search.getAsJsonArray("result").get(0).getAsJsonObject().get("name").getAsString().equals("fixture")) throw new AssertionError(search);
            var toc = checked(LegadoRuntime.execute(session,"packaged-toc","toc","{\"book\":{}}"));
            var content = checked(LegadoRuntime.execute(session,"packaged-content","content","{\"book\":{},\"chapter\":{},\"nextChapterUrl\":null}"));
            if (!content.get("result").getAsString().equals("Local content")) throw new AssertionError(content);
            System.out.println("PACKAGED_PAYLOAD_OK " + semantics);
        } finally { checked(LegadoRuntime.closeSession(session)); }
        originalTraditionalSmoke(false, false);
        originalTraditionalSmoke(true, false);
        originalTraditionalSmoke(true, true);
        originalBrowserProtocolSmoke();
        originalExploreInfoMapSmoke();
        originalContentBatchRateSmoke();
    }

    // ASCII-only controlled smoke fixture. Production uses retained original
    // CookieStore/CookieManager methods, covered by the real Unicode JVM tests.
    static String textMerge(String... values) {
        var merged = new java.util.LinkedHashMap<String, String>();
        for (var raw : values) if (raw != null) for (var field : raw.split(";")) {
            var pair = field.split("=", 2);
            if (pair.length == 2 && !pair[1].isBlank()) merged.put(pair[0].trim(), pair[1].trim());
        }
        return merged.entrySet().stream().map(e -> e.getKey()+"="+e.getValue()).collect(java.util.stream.Collectors.joining("; "));
    }

    /** Controlled host fixture for assembled-JAR wiring only; durability is verified separately
     * with the test-only file owner and new JVM processes. No fixture enters the runtime JAR. */
    static void originalTraditionalSmoke(boolean appCookieOwner, boolean textCookieOwner) throws Exception {
        var ownerReads = new AtomicInteger();
        var ownerWrites = new AtomicInteger();
        var ownerResponses = new AtomicInteger();
        var cookieRaw = new HashMap<String, String>();
        var cookieSession = new HashMap<String, String>();
        var rfcSnapshotReads = new AtomicInteger();
        var lastChapterRequests = new AtomicInteger();
        var server = HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}), 0), 0);
        server.createContext("/", exchange -> {
            var path = exchange.getRequestURI().getPath();
            if (textCookieOwner && path.equals("/start")) {
                if (!String.valueOf(exchange.getRequestHeaders().getFirst("Cookie")).contains("seed=owned")) throw new AssertionError("Missing original raw text");
                exchange.getResponseHeaders().add("Location", "/search");
                exchange.getResponseHeaders().add("Set-Cookie", "packaged=1; Path=/private; Max-Age=3600; HttpOnly");
                exchange.sendResponseHeaders(302, -1); exchange.close(); return;
            }
            var body = switch (path) {
                case "/search" -> "<a class='book' href='/book'>Original</a>";
                case "/book" -> "<h1>Updated</h1><a id='toc' href='/toc'>toc</a>";
                case "/toc" -> "{\"chapters\":[{\"name\":\"One\",\"url\":\"/one\"}],\"next\":[\"/toc2\"]}";
                case "/toc2" -> "{\"chapters\":[{\"name\":\"Two\",\"url\":\"/two\"}],\"next\":[]}";
                case "/one" -> "<div id='text'>first</div><a class='next' href='/one2'>next</a>";
                case "/one2" -> "<div id='text'>lastREMOVE</div><a class='next' href='/two'>chapter</a>";
                case "/two" -> { lastChapterRequests.incrementAndGet(); yield "<div id='text'>second</div>"; }
                default -> throw new AssertionError(path);
            };
            if (path.equals("/search") && !textCookieOwner) exchange.getResponseHeaders().add("Set-Cookie", "packaged=1; Path=/");
            else if (!String.valueOf(exchange.getRequestHeaders().getFirst("Cookie")).contains("packaged=1"))
                throw new AssertionError("Missing same-session cookie");
            var bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "text/html; charset=utf-8");
            exchange.sendResponseHeaders(200, bytes.length);
            try (var output = exchange.getResponseBody()) { output.write(bytes); }
            finally { exchange.close(); }
        });
        server.start();
        var values = new HashMap<String, String>();
        var revision = new long[]{0};
        LegadoRuntime.setHostCallback((task, operation, raw) -> {
            if (operation.equals("task.cancel")) return "{}";
            synchronized (values) {
                var request = JsonParser.parseString(raw).getAsJsonObject();
                if (!request.get("owner").getAsString().equals("packaged-owner")) throw new AssertionError("Wrong owner");
                var response = new JsonObject();
                if (operation.equals("cookie.owner.text") && textCookieOwner) {
                    var domain = request.get("domain").getAsString();
                    var action = request.get("action").getAsString();
                    if (action.equals("get")) { ownerReads.incrementAndGet(); response.addProperty("cookie", textMerge(cookieRaw.get(domain), cookieSession.get(domain))); }
                    else if (action.equals("session")) response.addProperty("cookie", cookieSession.getOrDefault(request.get("url").getAsString(), ""));
                    else {
                        if (action.equals("set")) cookieRaw.put(domain, request.get("cookie").getAsString());
                        else if (action.equals("replace")) cookieRaw.put(domain, textMerge(cookieRaw.get(domain), request.get("cookie").getAsString()));
                        else if (action.equals("response")) {
                            ownerResponses.incrementAndGet();
                            var parsed = request.getAsJsonArray("cookies").get(0).getAsJsonObject();
                            if (!parsed.get("hostOnly").getAsBoolean() || !parsed.get("httpOnly").getAsBoolean() || !parsed.get("path").getAsString().equals("/private")) throw new AssertionError("Response provenance lost");
                            cookieRaw.put(domain, textMerge(cookieRaw.get(domain), request.get("persistentText").getAsString()));
                            cookieSession.put(domain, textMerge(cookieSession.get(domain), request.get("sessionText").getAsString()));
                        } else throw new AssertionError(action);
                        ownerWrites.incrementAndGet(); response.addProperty("committed", true);
                    }
                } else if (operation.equals("cookie.owner.read") && appCookieOwner) {
                    ownerReads.incrementAndGet();
                    if (request.get("purpose").getAsString().equals("getCookie") && !request.get("domain").getAsString().equals("example.co.uk")) throw new AssertionError("Wrong original PSL domain");
                    response.addProperty("cookie", "packaged=1");
                } else if (operation.equals("state.read")) {
                    response.addProperty("revision", revision[0]); var selected = new JsonObject();
                    for (var key : request.getAsJsonArray("keys")) {
                        if (JsonParser.parseString(key.getAsString()).getAsJsonArray().get(1).getAsString().equals("cookies")) rfcSnapshotReads.incrementAndGet();
                        var value = values.get(key.getAsString()); if (value != null) selected.addProperty(key.getAsString(), value);
                    }
                    response.add("values", selected);
                } else if (operation.equals("state.commit")) {
                    var matches = request.get("revision").getAsLong() == revision[0];
                    if (matches) {
                        for (var change : request.getAsJsonObject("changes").entrySet()) {
                            if (change.getValue().isJsonNull()) values.remove(change.getKey());
                            else values.put(change.getKey(), change.getValue().getAsString());
                        }
                        revision[0]++;
                    }
                    response.addProperty("committed", matches);
                } else throw new AssertionError(operation);
                return response.toString();
            }
        });
        String session = null;
        try {
            var origin = "http://127.0.0.1:" + server.getAddress().getPort();
            var source = JsonParser.parseString("""
                {"ruleSearch":{"bookList":".book","name":"text","bookUrl":"href"},
                 "ruleBookInfo":{"name":"@XPath://h1/text()","tocUrl":"#toc@href","canReName":"yes"},
                 "ruleToc":{"chapterList":"$.chapters","chapterName":"$.name","chapterUrl":"$.url","nextTocUrl":"$.next"},
                 "ruleContent":{"content":"#text@html","nextContentUrl":".next@href","replaceRegex":"##REMOVE##"}}
                """).getAsJsonObject();
            source.addProperty("bookSourceUrl", origin); source.addProperty("searchUrl", "/search?q={{key}}");
            if (textCookieOwner) {
                source.addProperty("enabledCookieJar", true);
                source.addProperty("searchUrl", "/start?q={{key}}");
                source.addProperty("header", "@js:if(source.get('cookieSmoke')!='done'){cookie.setCookie(baseUrl,'seed=owned');source.put('cookieSmoke','done')}; ({Cookie:'packaged=authored'})");
            } else if (appCookieOwner) {
                source.addProperty("enabledCookieJar", false);
                source.addProperty("header", "@js:({'X-Owner':cookie.getCookie('https://sub.example.co.uk','packaged')})");
            }
            var options = JsonParser.parseString("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\"packaged-owner\"}").getAsJsonObject();
            if (appCookieOwner) options.addProperty("cookieAccess", textCookieOwner ? "app-owner-text" : "app-owner-read");
            session = checked(LegadoRuntime.createSession(source.toString(), options.toString())).get("sessionId").getAsString();
            var found = checked(LegadoRuntime.execute(session, "packaged-original-search", "search", "{\"key\":\"owned\"}")).getAsJsonObject("result").getAsJsonArray("books");
            if (found.size() != 1) throw new AssertionError(found);
            var input = new JsonObject(); input.add("book", found.get(0));
            var book = checked(LegadoRuntime.execute(session, "packaged-original-details", "details", input.toString())).getAsJsonObject("result").getAsJsonObject("book");
            if (!book.get("name").getAsString().equals("Updated")) throw new AssertionError(book);
            input.add("book", book);
            var toc = checked(LegadoRuntime.execute(session, "packaged-original-toc", "toc", input.toString())).getAsJsonObject("result");
            var chapters = toc.getAsJsonArray("chapters"); if (chapters.size() != 2) throw new AssertionError(toc);
            input.add("book", toc.get("book")); input.add("chapter", chapters.get(0)); input.addProperty("needSave", false);
            var first = checked(LegadoRuntime.execute(session, "packaged-original-content-one", "content", input.toString())).getAsJsonObject("result").get("content").getAsString();
            if (!first.contains("first") || !first.contains("last") || first.contains("REMOVE") || lastChapterRequests.get() != 0) throw new AssertionError(first);
            input.add("chapter", chapters.get(1));
            var second = checked(LegadoRuntime.execute(session, "packaged-original-content-two", "content", input.toString())).getAsJsonObject("result").get("content").getAsString();
            if (!second.contains("second") || lastChapterRequests.get() != 1) throw new AssertionError(second);
            if (textCookieOwner) {
                if (ownerReads.get() < 7 || ownerWrites.get() != 2 || ownerResponses.get() != 1 || rfcSnapshotReads.get() != 0) throw new AssertionError("Cookie text/response seam was bypassed");
                System.out.println("PACKAGED_APP_COOKIE_OWNER_TEXT_OK books=1 chapters=2 tocPages=2 firstChapterPages=2 redirectResponseCommits=1 rfcSnapshotReads=0");
            } else if (appCookieOwner) {
                if (ownerReads.get() < 14 || rfcSnapshotReads.get() != 0) throw new AssertionError("Cookie read seam was bypassed");
                System.out.println("PACKAGED_APP_COOKIE_OWNER_READ_OK books=1 chapters=2 tocPages=2 firstChapterPages=2 rfcSnapshotReads=0");
            } else System.out.println("PACKAGED_ORIGINAL_TRADITIONAL_OK books=1 chapters=2 tocPages=2 firstChapterPages=2 sameCookie=true");
        } finally {
            if (session != null) checked(LegadoRuntime.closeSession(session));
            LegadoRuntime.setHostCallback(null); server.stop(0);
        }
    }

    /** Public original protocol in the assembled ordinary payload. This callback
     * fixture does not execute WebKit, Foundation or native persistence. */
    static void originalBrowserProtocolSmoke() throws Exception {
        var operations = new java.util.ArrayList<String>();
        var fail = new boolean[]{false};
        var requests = new AtomicInteger();
        var server = HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);
        server.createContext("/", exchange -> {
            requests.incrementAndGet();
            var bytes = "<a class='book' href='/book'>Browser</a>".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200,bytes.length);
            try (var body=exchange.getResponseBody()) { body.write(bytes); } finally { exchange.close(); }
        }); server.start();
        LegadoRuntime.setHostCallback((task, operation, raw) -> {
            if (operation.equals("task.cancel")) return "{}";
            var input = JsonParser.parseString(raw).getAsJsonObject();
            if (!input.get("owner").getAsString().equals("browser-smoke-owner") || !input.has("deadlineEpochMs")) throw new AssertionError("Wrong Cookie task owner/deadline");
            if (operation.equals("state.read")) return "{\"revision\":0,\"values\":{}}";
            if (operation.equals("state.commit")) return "{\"committed\":true}";
            if (!operation.equals("cookie.owner.text")) throw new AssertionError(operation);
            var action = input.get("action").getAsString();
            if (action.equals("get") || action.equals("session")) return "{\"cookie\":\"\"}";
            operations.add(action);
            if (fail[0]) return "{\"ok\":false,\"error\":{\"code\":\"STATE_IO\",\"message\":\"Issued native effect; no rollback claim\",\"completedEffects\":[\"webKitCookieMutationIssued\"]}}";
            if (action.equals("webSet") && input.getAsJsonArray("pieces").size()!=2) throw new AssertionError("Original splitting lost");
            if (action.equals("webRemove") && !input.getAsJsonArray("domains").get(1).getAsString().equals("example.co.uk")) throw new AssertionError("Original removal target lost");
            return "{\"committed\":true}";
        });
        String session=null;
        try {
            var origin="http://127.0.0.1:"+server.getAddress().getPort();
            var source=JsonParser.parseString("{\"ruleSearch\":{\"bookList\":\".book\",\"name\":\"text\",\"bookUrl\":\"href\"},\"enabledCookieJar\":false}").getAsJsonObject();
            source.addProperty("bookSourceUrl",origin); source.addProperty("searchUrl",origin+"/search");
            source.addProperty("header","@js:cookie.setWebCookie('https://reader.example.co.uk/path','a=1; ; b=2'); cookie.removeCookie('https://reader.example.co.uk/path'); cookie.clear(); ({})");
            session=checked(LegadoRuntime.createSession(source.toString(),"{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\"browser-smoke-owner\",\"cookieAccess\":\"app-owner-text\"}")).get("sessionId").getAsString();
            checked(LegadoRuntime.execute(session,"ordinary-browser-success","search","{\"key\":\"owned\"}"));
            if (!operations.equals(java.util.List.of("webSet","remove","webRemove","clear")) || requests.get()!=1) throw new AssertionError(operations);
            fail[0]=true;
            var error=JsonParser.parseString(LegadoRuntime.execute(session,"ordinary-browser-partial","search","{\"key\":\"owned\"}")).getAsJsonObject();
            if (error.get("ok").getAsBoolean() || !error.getAsJsonObject("error").get("code").getAsString().equals("STATE_IO") || !error.getAsJsonObject("error").getAsJsonArray("completedEffects").get(0).getAsString().equals("webKitCookieMutationIssued") || requests.get()!=1) throw new AssertionError(error);
            System.out.println("PACKAGED_APP_COOKIE_OWNER_BROWSER_PROTOCOL_OK orderedActions=4 partialEffectsPreserved=true actualWebKitExecuted=false");
        } finally { if(session!=null)checked(LegadoRuntime.closeSession(session)); LegadoRuntime.setHostCallback(null); server.stop(0); }
    }

    /** Assembled-JAR public business/lifecycle smoke with one controlled Host
     * and loopback. This in-memory callback fixture does not assert native disk
     * persistence, App integration, Android, JNI or Swift SDK execution. */
    static void originalExploreInfoMapSmoke() throws Exception {
        var values=new HashMap<String,String>(); var revision=new long[]{0};
        var requests=new AtomicInteger(); var writes=new AtomicInteger();
        var server=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);
        server.createContext("/", exchange -> {
            requests.incrementAndGet();
            var query=exchange.getRequestURI().getRawQuery();
            if(query==null || !query.contains("genre=owned"))throw new AssertionError("InfoMap did not reach original URL JS");
            var bytes=("<a class='book' href='/book'>"+(query.contains("p=2")?"P2":"P1")+"</a>").getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200,bytes.length);
            try(var body=exchange.getResponseBody()){body.write(bytes);}finally{exchange.close();}
        });server.start();
        var origin="http://127.0.0.1:"+server.getAddress().getPort();
        LegadoRuntime.setHostCallback((task,operation,raw)->{
            if(operation.equals("task.cancel"))return "{}";
            var input=JsonParser.parseString(raw).getAsJsonObject();
            if(!input.get("owner").getAsString().equals("ordinary-explore-owner") || !input.has("deadlineEpochMs"))throw new AssertionError("Missing actual exploration owner/deadline");
            var out=new JsonObject();
            synchronized(values){
                if(operation.equals("explore.owner.scope"))out.addProperty("scope","ordinary-owned-backing-source-revision");
                else if(operation.equals("state.read")){
                    out.addProperty("revision",revision[0]);var selected=new JsonObject();
                    for(var key:input.getAsJsonArray("keys")){var value=values.get(key.getAsString());if(value!=null)selected.addProperty(key.getAsString(),value);}
                    out.add("values",selected);
                }else if(operation.equals("state.commit")){
                    var matches=input.get("revision").getAsLong()==revision[0];
                    if(matches){for(var e:input.getAsJsonObject("changes").entrySet()){if(e.getValue().isJsonNull())values.remove(e.getKey());else values.put(e.getKey(),e.getValue().getAsString());}revision[0]++;writes.incrementAndGet();}
                    out.addProperty("committed",matches);
                }else throw new AssertionError(operation);
            }return out.toString();
        });
        var source=JsonParser.parseString("{\"enabledCookieJar\":false,\"ruleExplore\":{\"bookList\":\".book\",\"name\":\"text\",\"bookUrl\":\"href\"}}").getAsJsonObject();source.addProperty("bookSourceUrl",origin+"/source");
        java.util.function.BiFunction<String,String,JsonObject> call=(operation,input)->{
            var session=checked(LegadoRuntime.createSession(source.toString(),"{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\"ordinary-explore-owner\"}")).get("sessionId").getAsString();
            try{return checked(LegadoRuntime.execute(session,"ordinary-explore-"+java.util.UUID.randomUUID(),operation,input)).getAsJsonObject("result");}
            finally{checked(LegadoRuntime.closeSession(session));}
        };
        try{
            call.apply("exploreContext","{\"action\":\"open\"}");
            call.apply("exploreContext","{\"action\":\"evaluate\",\"script\":\"infoMap.put('genre','owned'); infoMap.save(); 'ready'\"}");
            for(int page=1;page<=2;page++){
                var input=new JsonObject();input.addProperty("page",page);
                input.addProperty("url","@js:infoMap.put('page',String(page)); '"+origin+"/list?p='+page+'&genre='+infoMap.get('genre')");
                var book=call.apply("explore",input.toString()).getAsJsonArray("books").get(0).getAsJsonObject();
                if(!book.get("name").getAsString().equals("P"+page))throw new AssertionError(book);
            }
            var saved=call.apply("exploreContext","{\"action\":\"savePending\"}");
            if(saved.get("needSave").getAsBoolean() || !saved.getAsJsonObject("infoMap").get("page").getAsString().equals("2") || writes.get()!=1 || requests.get()!=2)throw new AssertionError(saved);
            if(values.keySet().stream().noneMatch(k->k.contains("infoMap_")))throw new AssertionError("Original CacheManager key not persisted");
            System.out.println("PACKAGED_ORIGINAL_EXPLORE_INFOMAP_OK pages=2 sameContextAcrossSessions=true explicitSave=true nativeExecuted=false");
        }finally{LegadoRuntime.setHostCallback(null);server.stop(0);}
    }

    /** Internal original embedding contract in the ordinary JAR only. This does
     * not authorize the public App batch/body-save route or claim JNI/native IO.
     * Real file restart/generation/cancellation checks live in the JVM suite. */
    static void originalContentBatchRateSmoke() throws Exception {
        var values=new HashMap<String,String>(); var revision=new long[]{0};
        var requests=new AtomicInteger(); var writes=new AtomicInteger();
        var server=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);
        server.createContext("/", exchange -> {
            var n=requests.incrementAndGet();
            if(exchange.getRequestURI().getPath().equals("/chapter-0"))exchange.getResponseHeaders().add("Set-Cookie","batch=owned; Path=/");
            else if(!String.valueOf(exchange.getRequestHeaders().getFirst("Cookie")).contains("batch=owned"))throw new AssertionError("Batch lost the same HTTP Cookie jar");
            var bytes=("body-"+exchange.getRequestURI().getPath()).getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200,bytes.length);
            try(var out=exchange.getResponseBody()){out.write(bytes);}finally{exchange.close();}
        });server.start();
        var origin="http://127.0.0.1:"+server.getAddress().getPort();
        var owner="ordinary-batch-owner";var taskID="ordinary-batch-task";
        var publicGrant=new java.util.concurrent.atomic.AtomicBoolean(false);
        LegadoRuntime.setHostCallback((task,operation,raw)->{
            var input=JsonParser.parseString(raw).getAsJsonObject();
            if((!task.equals(taskID) && !task.equals("ordinary-public-batch")) || !input.get("owner").getAsString().equals(owner) || !input.has("deadlineEpochMs"))throw new AssertionError("Batch changed owner/task/deadline");
            var out=new JsonObject();
            synchronized(values){
                if(operation.equals("content.batch.authorize")){
                    if(!input.get("sourceURL").getAsString().equals(origin) || !input.get("bookURL").getAsString().equals(origin+"/book") || input.getAsJsonArray("chapters").size()!=3)throw new AssertionError("Public batch changed identity");
                    if(publicGrant.get())out.addProperty("authorized",true);
                    else {out.addProperty("ok",false);var error=new JsonObject();error.addProperty("code","UNSUPPORTED_CAPABILITY");error.addProperty("message","No App body generation grant");out.add("error",error);}
                }
                else if(operation.equals("explore.owner.scope"))out.addProperty("scope","ordinary-batch-backing-source-revision");
                else if(operation.equals("state.read")){
                    out.addProperty("revision",revision[0]);var selected=new JsonObject();
                    for(var key:input.getAsJsonArray("keys")){var value=values.get(key.getAsString());if(value!=null)selected.addProperty(key.getAsString(),value);}
                    out.add("values",selected);
                }else if(operation.equals("state.commit")){
                    var matches=input.get("revision").getAsLong()==revision[0];
                    if(matches){for(var e:input.getAsJsonObject("changes").entrySet()){if(e.getValue().isJsonNull())values.remove(e.getKey());else values.put(e.getKey(),e.getValue().getAsString());}revision[0]++;writes.incrementAndGet();}
                    out.addProperty("committed",matches);
                }else throw new AssertionError(operation);
            }return out.toString();
        });
        var sourceJson=new JsonObject();sourceJson.addProperty("bookSourceUrl",origin);sourceJson.addProperty("enabledCookieJar",true);sourceJson.addProperty("concurrentRate","12/60000");
        var contentRule=new JsonObject();contentRule.addProperty("contentBatch","for(var i=0;i<2;i++){if(!java.cacheContent(result.get(i),java.ajax(result.get(i).getAbsoluteURL())))throw new Error('save failed')}");sourceJson.add("ruleContent",contentRule);
        var options=new io.yuedu.legado.RuntimeSessionOptions("jvm-okhttp",null,owner,"existing","session-jar");
        var session=new io.yuedu.legado.RuntimeSession("ordinary-batch-session",sourceJson,options);
        var job=kotlinx.coroutines.JobKt.Job((kotlinx.coroutines.Job)null);
        var task=new io.yuedu.legado.RuntimeTask(taskID,session,job,System.currentTimeMillis()+15000,null);
        var environment=LegadoRuntime.INSTANCE.originalRuleEnvironment$io_yuedu_legado_runtime(task);
        try {
            var source=LegadoRuntime.INSTANCE.originalBookSource$io_yuedu_legado_runtime(task,environment);
            var bookJson=new JsonObject();bookJson.addProperty("origin",origin);bookJson.addProperty("bookUrl",origin+"/book");bookJson.addProperty("tocUrl",origin+"/toc");bookJson.addProperty("name","Batch");bookJson.addProperty("author","Owned");
            var book=io.yuedu.legado.OriginalRuleDto.INSTANCE.book(bookJson,environment,origin);
            var chapters=new java.util.ArrayList<io.legado.app.data.entities.BookChapter>();
            for(int i=0;i<3;i++){
                var chapter=new JsonObject();chapter.addProperty("bookUrl",book.getBookUrl());chapter.addProperty("url",origin+"/chapter-"+i);chapter.addProperty("title","C"+i);chapter.addProperty("baseUrl",book.getTocUrl());chapter.addProperty("index",i);
                chapters.add(io.yuedu.legado.OriginalRuleDto.INSTANCE.chapter(chapter,environment,book));
            }
            environment.getWebBook().publish$io_yuedu_legado_runtime(book.getBookUrl(),chapters);
            var missing=session.withCurrentTask$io_yuedu_legado_runtime(task,()->{
                try {
                    return kotlinx.coroutines.BuildersKt.<java.util.List<io.legado.app.data.entities.BookChapter>>runBlocking(job,
                        (scope,continuation)->io.legado.app.model.webBook.WebBook.INSTANCE.getContentBatchAwait(source,book,chapters,continuation));
                }catch(InterruptedException e){throw new RuntimeException(e);}
            });
            if(missing.size()!=1 || missing.get(0)!=chapters.get(2))throw new AssertionError("Batch did not return original missing chapter identity");
            for(int i=0;i<2;i++){
                var chapter=chapters.get(i);var state=environment.getWebBook();
                var body=state.getContent$io_yuedu_legado_runtime(book,chapter,state.contentSaveToken$io_yuedu_legado_runtime(book,chapter));
                if(!("body-/chapter-"+i).equals(body))throw new AssertionError("Batch did not save original body through the same owner");
            }
            var record=new io.legado.app.help.ConcurrentRateLimiter(source).getConcurrentRecordBlocking();
            if(record.getFrequency()!=4 || requests.get()!=2 || writes.get()<3)throw new AssertionError("Batch and nested HTTP did not share the original rate window");
            var publicSession=checked(LegadoRuntime.createSession(sourceJson.toString(),"{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\""+owner+"\"}")).get("sessionId").getAsString();
            try {
                var input=new JsonObject();input.add("book",bookJson);var inputChapters=new com.google.gson.JsonArray();
                for(var chapter:chapters)inputChapters.add(io.yuedu.legado.OriginalRuleDto.INSTANCE.chapter(chapter));
                input.add("chapters",inputChapters);
                var denied=JsonParser.parseString(LegadoRuntime.execute(publicSession,"ordinary-public-batch","contentBatch",input.toString())).getAsJsonObject();
                if(denied.get("ok").getAsBoolean() || !denied.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"))throw new AssertionError("Public App batch must remain ungranted");
                publicGrant.set(true);
                var actual=checked(LegadoRuntime.execute(publicSession,"ordinary-public-batch","contentBatch",input.toString())).getAsJsonObject("result");
                if(actual.has("contents") || actual.getAsJsonArray("missingChapters").size()!=1 || actual.getAsJsonArray("missingChapters").get(0).getAsJsonObject().get("index").getAsInt()!=2)throw new AssertionError("Public batch must return original missing chapters");
                System.out.println("PACKAGED_ORIGINAL_PUBLIC_BATCH_OK publicJson=true saved=2 missing=1 explicitOwner=true appExecuted=false nativeExecuted=false");
            }finally{checked(LegadoRuntime.closeSession(publicSession));}
            System.out.println("PACKAGED_ORIGINAL_BATCH_RATE_OK saved=2 missing=1 sameOwner=true rateAdmissions=4 publicAppSaveEnabled=false nativeExecuted=false");
        }finally{environment.close();job.cancel(null);session.getClosed().set(true);session.getHttp().close();LegadoRuntime.setHostCallback(null);server.stop(0);}
    }
}
