import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import io.yuedu.legado.LegadoRuntime;

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
        source.addProperty("mainJs", "function search(key,page){return [{name:key,bookUrl:'fixture:book'}]};function getChapters(book){return [{title:'Chapter 1',chapterUrl:'fixture:1'}]};function getContent(chapter,book,nextChapterUrl){return 'Local content'};");
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
    }
}
