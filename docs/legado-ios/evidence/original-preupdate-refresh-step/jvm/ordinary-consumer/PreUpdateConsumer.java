import com.google.gson.JsonObject;
import com.sun.net.httpserver.HttpServer;
import io.yuedu.legado.LegadoRuntime;
import io.yuedu.legado.originalrule.RuleEnvironment;
import io.yuedu.legado.originalrule.RulePlatform;
import io.yuedu.legado.originalrule.RulePersistenceAdapter;
import io.yuedu.legado.originalrule.RulePersistenceHost;
import io.yuedu.legado.originalrule.RulePersistenceSnapshot;
import io.legado.app.data.entities.BaseBook;
import io.legado.app.data.entities.BaseSource;
import io.legado.app.model.analyzeRule.AnalyzeRule;
import io.legado.app.model.analyzeRule.RuleDataInterface;
import kotlin.coroutines.CoroutineContext;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Outside Java classpath is the ordinary runtime JAR and these classes only. */
public final class PreUpdateConsumer {
    static void require(boolean test, String message) { if (!test) throw new AssertionError(message); }
    static JsonObject parse(String text) { return com.google.gson.JsonParser.parseString(text).getAsJsonObject(); }
    public static void main(String[] args) throws Exception {
        require(RulePlatform.class.getMethod("refreshBookInfo", BaseBook.class, BaseSource.class, CoroutineContext.class).getReturnType() == void.class, "refreshBookInfo Unit ABI");
        require(RulePlatform.class.getMethod("refreshToc", BaseBook.class, BaseSource.class, CoroutineContext.class).getReturnType() == void.class, "refreshToc Unit ABI");
        require(AnalyzeRule.class.getMethod("reGetBook").getReturnType() == void.class, "reGetBook public ABI");
        try (AnalyzeRule rule = new AnalyzeRule((RuleDataInterface)null, (BaseSource)null, true, false, (RuleEnvironment)null)) {
            rule.reGetBook(); rule.refreshTocUrl();
        }
        List<String> routes = new CopyOnWriteArrayList<>(); AtomicInteger host = new AtomicInteger(); AtomicInteger grants = new AtomicInteger();
        ExecutorService workers = Executors.newCachedThreadPool();
        HttpServer server = HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}), 0), 0);
        server.setExecutor(workers);
        server.createContext("/", exchange -> {
            String path = exchange.getRequestURI().getPath(); routes.add(path);
            String body = switch(path) {
                case "/search" -> "<div class='book'><a href='/new'>Owned</a><b>Author</b></div>";
                case "/new" -> "<h1>different</h1><h2>different</h2><a id='toc' href='/toc'>toc</a>";
                case "/toc", "/old-toc" -> "{\"rows\":[{\"name\":\"one\",\"url\":\"/chapter\"}]}";
                default -> throw new AssertionError("Unexpected public refresh HTTP route " + path);
            };
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "text/html; charset=utf-8");
            exchange.sendResponseHeaders(200, bytes.length); exchange.getResponseBody().write(bytes); exchange.close();
        });
        server.start(); String origin = "http://127.0.0.1:" + server.getAddress().getPort(); int sessions = 0;
        Map<String,byte[]> state = new HashMap<>(); long[] revision = {0};
        RulePersistenceHost stateHost = new RulePersistenceHost(new RulePersistenceAdapter() {
            public synchronized RulePersistenceSnapshot read(String owner, Set<String> keys) {
                require(owner.equals("ordinary-refresh-owner"), "same explicit owner"); Map<String,byte[]> values = new HashMap<>();
                for(String key:keys) if(state.containsKey(key)) values.put(key,state.get(key).clone());
                return new RulePersistenceSnapshot(revision[0],values);
            }
            public synchronized boolean compareAndSet(String owner,long expected,Map<String,byte[]> changes) {
                require(owner.equals("ordinary-refresh-owner"), "same explicit owner"); if(revision[0]!=expected) return false;
                changes.forEach((key,value)->{if(value==null)state.remove(key);else state.put(key,value.clone());});revision[0]++;return true;
            }
        });
        AtomicReference<String> current = new AtomicReference<>(origin+"/old");
        LegadoRuntime.setHostCallback((task, operation, raw) -> {
            JsonObject input = parse(raw);
            if(operation.equals("book.refresh.identity")) {
                require(input.get("owner").getAsString().equals("ordinary-refresh-owner"),"identity owner");
                require(input.get("sourceURL").getAsString().equals(origin),"identity source");
                require(input.get("fromBookURL").getAsString().equals(current.get()),"identity prior URL");
                require(input.get("toBookURL").getAsString().equals(origin+"/new"),"identity matched URL");
                current.set(origin+"/new");grants.incrementAndGet();JsonObject result=new JsonObject();result.addProperty("accepted",true);result.addProperty("bookURL",current.get());return result.toString();
            }
            if(operation.equals("state.read")||operation.equals("state.commit"))return stateHost.dispatch(operation,input).toString();
            if(operation.equals("task.cancel"))return "{}";
            host.incrementAndGet();throw new AssertionError("No alternate Host/HTTP is authorized: "+operation);
        });
        try {
            for (boolean fromInfo : new boolean[]{false, true}) {
                current.set(origin+"/old");
                JsonObject source = parse("{\"bookSourceType\":0,\"searchUrl\":\"/search?q={{key}}&p={{page}}\",\"ruleSearch\":{\"bookList\":\".book\",\"name\":\"a@text\",\"author\":\"b@text\",\"bookUrl\":\"a@href\"},\"ruleBookInfo\":{\"name\":\"h1@text\",\"author\":\"h2@text\",\"canReName\":\"yes\",\"tocUrl\":\"#toc@href\"},\"ruleToc\":{\"chapterList\":\"$.rows\",\"chapterName\":\"$.name\",\"chapterUrl\":\"$.url\"},\"ruleContent\":{}}");
                source.addProperty("bookSourceUrl", origin);
                source.getAsJsonObject("ruleToc").addProperty("preUpdateJs", fromInfo ? "java.refreshTocUrl();" : "java.reGetBook();java.refreshTocUrl();");
                JsonObject created = parse(LegadoRuntime.createSession(source.toString(), "{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\"ordinary-refresh-owner\"}"));
                require(created.get("ok").getAsBoolean(), created.toString()); String session = created.get("sessionId").getAsString(); sessions++;
                try {
                    JsonObject input = parse("{\"book\":{\"name\":\"Owned\",\"author\":\"Author\"},\"runPreUpdateJs\":true}");
                    JsonObject book = input.getAsJsonObject("book"); book.addProperty("origin", origin); book.addProperty("bookUrl", origin + "/old"); book.addProperty("tocUrl", origin + "/old-toc"); input.addProperty("isFromBookInfo", fromInfo);
                    JsonObject reply = parse(LegadoRuntime.execute(session, UUID.randomUUID().toString(), "toc", input.toString()));
                    require(reply.get("ok").getAsBoolean(), reply.toString()); JsonObject result = reply.getAsJsonObject("result");
                    require(result.getAsJsonArray("chapters").size() == 1, "actual TOC result");
                    require(result.getAsJsonObject("book").get("name").getAsString().equals("Owned"), "canReName false");
                    require(result.getAsJsonObject("book").get("bookUrl").getAsString().equals(origin + (fromInfo ? "/old" : "/new")), "actual URL selection");
                } finally { LegadoRuntime.closeSession(session); }
            }
            require(routes.equals(List.of("/search", "/new", "/new", "/toc", "/old-toc")), "exact original refresh order " + routes);
            require(host.get() == 0, "no Native/alternate owner");
            require(grants.get()==1,"one checked identity grant");
            System.out.println("{\"sessions\":" + sessions + ",\"httpRequests\":" + routes.size() + ",\"alternateNativeCalls\":" + host.get() + ",\"identityGrants\":"+grants.get()+",\"publicNullCalls\":2,\"UnitABI\":true}");
        } finally { LegadoRuntime.setHostCallback(null); server.stop(0); workers.shutdownNow(); require(workers.awaitTermination(3,TimeUnit.SECONDS), "HTTP worker drain"); }
    }
}
