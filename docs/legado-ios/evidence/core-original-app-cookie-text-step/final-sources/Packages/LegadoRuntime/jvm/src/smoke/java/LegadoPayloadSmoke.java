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
}
