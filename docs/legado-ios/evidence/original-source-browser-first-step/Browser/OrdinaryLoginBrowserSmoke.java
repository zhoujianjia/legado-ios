import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import java.util.*;

/** External production-JAR consumer. Synthetic UI acknowledgements check only
 * the JVM wire contract, never real UIKit presentation or browser navigation. */
public final class OrdinaryLoginBrowserSmoke {
    private static int sessions,pages,accepted,credentialCalls,httpCalls,stateReads;
    private static boolean presented=true;
    private static JsonObject object(String text){return JsonParser.parseString(text).getAsJsonObject();}
    private static JsonObject checked(String text){var x=object(text);if(!x.get("ok").getAsBoolean())throw new AssertionError("Unexpected runtime failure");return x;}
    private static JsonObject call(String origin,String script,boolean hasOwner,boolean success){
        var source=object("{\"loginUi\":\"[]\",\"enabledCookieJar\":false,\"ruleContent\":{}}");
        source.addProperty("bookSourceUrl",origin);source.addProperty("loginUrl","var browserPrelude=true;");
        source.addProperty("header","{\"X-Source\":\"synthetic-header\"}");
        var options=object("{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\"}");if(hasOwner)options.addProperty("stateOwner","browser:"+origin);
        String id=checked(LegadoRuntime.createSession(source.toString(),options.toString())).get("sessionId").getAsString();sessions++;
        try {
            var input=object("{\"credentials\":{\"password\":\"\"},\"timeoutMs\":20000}");input.addProperty("action",script);
            var reply=object(LegadoRuntime.execute(id,"outside-browser-"+UUID.randomUUID(),"loginAction",input.toString()));
            if(reply.get("ok").getAsBoolean()!=success)throw new AssertionError("Wrong browser terminal state");return reply;
        }finally{checked(LegadoRuntime.closeSession(id));}
    }
    public static void main(String[] args){
        LegadoRuntime.setHostCallback((task,operation,raw)->{
            if(operation.equals("task.cancel"))return "{}";
            var input=object(raw);
            if(operation.equals("state.read")){stateReads++;return "{\"revision\":0,\"values\":{}}";}
            if(operation.equals("source.login-info")){credentialCalls++;throw new AssertionError("Browser cannot save credentials implicitly");}
            if(operation.equals("http.request")){httpCalls++;throw new AssertionError("Browser cannot use a generic HTTP host");}
            if(!operation.equals("source.browser"))throw new AssertionError("Unknown browser host operation");
            var origin=input.get("sourceURL").getAsString();if(!input.get("owner").getAsString().equals("browser:"+origin))throw new AssertionError("Wrong source owner");
            if(!input.get("url").getAsString().equals("https://synthetic-browser.invalid/page")||!input.getAsJsonObject("headers").get("X-Source").getAsString().equals("synthetic-header"))throw new AssertionError("Original AnalyzeUrl URL/header missing");
            pages++;if(presented)accepted++;
            return presented?"{\"presented\":true,\"hostEffects\":[\"sourceBrowserMayPresent\",\"sourceBrowserPresented\"]}":"{\"presented\":false,\"hostEffects\":[\"sourceBrowserMayPresent\"]}";
        });
        try {
            String a="https://ordinary-browser-a.invalid",b="https://ordinary-browser-b.invalid";
            var good=call(a,"java.startBrowser('https://synthetic-browser.invalid/page','A');",true,true);
            if(!good.getAsJsonObject("result").get("executed").getAsBoolean())throw new AssertionError("Action skipped presentation");
            var thrown=call(b,"java.startBrowser('https://synthetic-browser.invalid/page','B');throw new Error('SYNTHETIC-BROWSER-PRIVATE');",true,false);
            if(!thrown.getAsJsonObject("error").get("code").getAsString().equals("SCRIPT_ERROR")||thrown.toString().contains("SYNTHETIC-BROWSER-PRIVATE")||!thrown.getAsJsonObject("error").getAsJsonArray("completedEffects").toString().contains("sourceBrowserPresented"))throw new AssertionError("Post-presentation error lost fact or leaked source text");
            presented=false;var refused=call(a,"java.startBrowser('https://synthetic-browser.invalid/page','Refused');",true,false);
            if(!refused.getAsJsonObject("error").get("code").getAsString().equals("BROWSER_NOT_PRESENTED"))throw new AssertionError("Refusal became success");
            var html=call(a,"java.startBrowser('https://synthetic-browser.invalid/page','Local','');",true,false);
            if(!html.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"))throw new AssertionError("Local WebJS pretended plain page");
            var awaited=call(a,"java.startBrowserAwait('https://synthetic-browser.invalid/page','Awaited');",true,false);
            if(!awaited.getAsJsonObject("error").get("code").getAsString().equals("UNSUPPORTED_CAPABILITY"))throw new AssertionError("Awaited browser pretended plain page");
            if(sessions!=5||pages!=3||accepted!=2||credentialCalls!=0||httpCalls!=0)throw new AssertionError("Unexpected owner routing");
            System.out.println("ORDINARY_LOGIN_BROWSER_OK sessions=5 sources=2 presentationRequests=3 syntheticAccepted=2 refused=1 unsupported=2 credentialCalls=0 genericHTTPCalls=0 stateReads="+stateReads);
        }finally{LegadoRuntime.setHostCallback(null);}
    }
}
