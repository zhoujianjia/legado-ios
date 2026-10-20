import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import io.yuedu.legado.LegadoRuntime;
import io.yuedu.legado.originalrule.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.CopyOnWriteArrayList;

/** Public ordinary-JAR caller. Its explicit synthetic embedding owner grants one chapter. */
public final class OrdinaryReaderRepairSmoke {
    private static final class Owner implements RulePersistenceAdapter {
        private long revision;
        private final Map<String,byte[]> values = new HashMap<>();
        public synchronized RulePersistenceSnapshot read(String owner, Set<String> keys) {
            if (!owner.equals("reader-repair-owner")) throw new AssertionError("Wrong embedding owner");
            Map<String,byte[]> selected = new HashMap<>();
            for (String key:keys) if(values.containsKey(key)) selected.put(key,values.get(key).clone());
            return new RulePersistenceSnapshot(revision,selected);
        }
        public synchronized boolean compareAndSet(String owner,long expected,Map<String,byte[]> changes) {
            if (!owner.equals("reader-repair-owner")) throw new AssertionError("Wrong embedding owner");
            if(expected!=revision)return false;
            changes.forEach((k,v)->{if(v==null)values.remove(k);else values.put(k,v.clone());});
            revision++;return true;
        }
    }
    private static JsonObject object(String json){return JsonParser.parseString(json).getAsJsonObject();}
    private static JsonObject checked(String json){var o=object(json);if(!o.get("ok").getAsBoolean())throw new AssertionError(o.getAsJsonObject("error").toString());return o;}
    private static JsonObject execute(String session,String operation,JsonObject input){return object(LegadoRuntime.execute(session,"reader-repair-"+UUID.randomUUID(),operation,input.toString()));}
    private static boolean restricted;
    private static int sessions,scopeCalls;
    private static String open(JsonObject source){
        var options=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\"reader-repair-owner\"}");
        sessions++;return checked(LegadoRuntime.createSession(source.toString(),options.toString())).get("sessionId").getAsString();
    }
    public static void main(String[] args)throws Exception{
        var requests=new CopyOnWriteArrayList<String>();var variableReads=new CopyOnWriteArrayList<String>();
        var host=new RulePersistenceHost(new Owner());
        var server=HttpServer.create(new InetSocketAddress(InetAddress.getByAddress(new byte[]{127,0,0,1}),0),0);
        server.createContext("/",e->{
            String path=e.getRequestURI().getPath();requests.add(path);
            String body=switch(path){
                case "/toc"->"<a href='/first'>First</a><a href='/last'>Last</a>";
                case "/last"->"<div id='text'>last-granted-body</div><a class='next' href='/first'>boundary</a>";
                default->"unexpected route";
            };
            byte[] bytes=body.getBytes(StandardCharsets.UTF_8);e.getResponseHeaders().add("Content-Type","text/html; charset=utf-8");
            e.sendResponseHeaders(path.equals("/toc")||path.equals("/last")?200:500,bytes.length);e.getResponseBody().write(bytes);e.close();
        });server.start();String origin="http://127.0.0.1:"+server.getAddress().getPort();
        LegadoRuntime.setHostCallback((task,operation,raw)->{
            if(operation.equals("task.cancel"))return "{}";
            var input=object(raw);
            if(operation.equals("explore.owner.scope")){scopeCalls++;return "{\"scope\":\"reader-repair-explore-scope\"}";}
            if(!operation.equals("state.read")&&!operation.equals("state.commit"))throw new AssertionError("Unexpected host operation: "+operation);
            if(restricted&&operation.equals("state.read"))for(JsonElement value:input.getAsJsonArray("keys")){
                JsonArray key=JsonParser.parseString(value.getAsString()).getAsJsonArray();
                if(key.size()>=5&&key.get(1).getAsString().equals("variables")&&key.get(2).getAsString().equals("chapter")){
                    String url=key.get(4).getAsString();variableReads.add(url);
                    if(!url.equals("/last"))return "{\"ok\":false,\"error\":{\"code\":\"UNSUPPORTED_CAPABILITY\",\"message\":\"Only the current chapter is granted\"}}";
                }
            }
            return host.dispatch(operation,input).toString();
        });
        try{
            var source=object("{\"bookSourceName\":\"OrdinaryReaderRepair\",\"enabledCookieJar\":false,\"ruleToc\":{\"chapterList\":\"a\",\"chapterName\":\"text\",\"chapterUrl\":\"href\"},\"ruleContent\":{\"content\":\"#text@html\",\"nextContentUrl\":\".next@href\",\"title\":\"@js:chapter.putVariable('parsed','yes');String(chapter.title)\"}}");
            source.addProperty("bookSourceUrl",origin);
            var book=object("{\"name\":\"Book\",\"author\":\"Author\"}");book.addProperty("bookUrl",origin+"/book");book.addProperty("tocUrl",origin+"/toc");book.addProperty("origin",origin);
            String session=open(source);JsonObject toc;
            try{var input=new JsonObject();input.add("book",book);toc=checked(execute(session,"toc",input).toString()).getAsJsonObject("result");}
            finally{checked(LegadoRuntime.closeSession(session));}
            var chapters=toc.getAsJsonArray("chapters");if(chapters.size()!=2)throw new AssertionError("Lost TOC metadata");
            JsonObject first=chapters.get(0).getAsJsonObject(),last=chapters.get(1).getAsJsonObject();
            if(!first.get("url").getAsString().equals("/first")||!last.get("url").getAsString().equals("/last"))throw new AssertionError("TOC raw route identity changed");
            restricted=true;session=open(source);
            try{
                var input=new JsonObject();input.add("book",toc.get("book"));input.add("chapter",last);input.add("nextChapterUrl",JsonNull.INSTANCE);input.addProperty("needSave",false);
                var result=checked(execute(session,"content",input).toString()).getAsJsonObject("result");
                if(!result.get("content").getAsString().equals("\u3000\u3000\u3000\u3000last-granted-body\n\u3000\u3000"))throw new AssertionError("Original formatting changed");
                if(variableReads.isEmpty()||variableReads.stream().anyMatch(u->!u.equals("/last")))throw new AssertionError("Directory metadata read foreign chapter variables");
                var variables=object(result.getAsJsonObject("chapter").get("variable").getAsString());
                if(!variables.get("parsed").getAsString().equals("yes"))throw new AssertionError("Current chapter variables were not retained");
                input.add("chapter",first);var denied=execute(session,"content",input);
                if(denied.get("ok").getAsBoolean()||!denied.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"))throw new AssertionError("Foreign current chapter gained authority");
            }finally{checked(LegadoRuntime.closeSession(session));}
            restricted=false;session=open(source);
            try{
                checked(execute(session,"exploreContext",object("{\"action\":\"open\"}")).toString());
                var evaluation=checked(execute(session,"exploreContext",object("{\"action\":\"evaluate\",\"script\":\"infoMap.put('genre','first');JSON.stringify([infoMap.get('genre')==='first',String(infoMap.get('genre'))==='first'])\"}")).toString()).getAsJsonObject("result");
                if(!evaluation.get("result").getAsString().equals("[false,true]")||!evaluation.getAsJsonObject("infoMap").get("genre").getAsString().equals("first"))throw new AssertionError("Original Java Map string identity premise failed");
            }finally{checked(LegadoRuntime.closeSession(session));}
            if(!requests.equals(List.of("/toc","/last"))||sessions!=3||scopeCalls!=2)throw new AssertionError("Wrong transport/session ownership facts");
            System.out.println("ORDINARY_READER_REPAIR_OK sessions=3 HTTP=2 currentChapterVariables=retained foreignChapter=denied exploreStrictIdentity=false coercion=true");
        }finally{LegadoRuntime.setHostCallback(null);server.stop(0);}
    }
}
