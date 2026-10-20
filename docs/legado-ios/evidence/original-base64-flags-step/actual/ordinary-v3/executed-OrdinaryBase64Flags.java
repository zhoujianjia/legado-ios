import com.google.gson.*;
import io.yuedu.legado.LegadoRuntime;
import io.yuedu.legado.originalrule.RuleJsExtensions;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Fixture-only independent AOSP oracle; only the production ordinary JAR is on the runtime dependency path. */
public final class OrdinaryBase64Flags {
 static final Gson G=new Gson();static int calls,checks,decodeVectors,encodeVectors,nullableVectors,hostCalls;
 static String session;
 static String quote(String value){return G.toJson(value);}
 static void check(boolean value,String name){if(!value)throw new AssertionError(name);}
 static JsonObject obj(String s){return JsonParser.parseString(s).getAsJsonObject();}
 static JsonObject ok(String s){var o=obj(s);check(o.get("ok").getAsBoolean(),"runtime terminal "+o);return o;}
 static JsonObject execute(String code){var in=new JsonObject();in.addProperty("action",code);in.add("credentials",new JsonObject());in.addProperty("isLongClick",false);in.addProperty("timeoutMs",30000);calls++;return obj(LegadoRuntime.execute(session,"base64-"+UUID.randomUUID(),"loginAction",in.toString()));}
 static void run(String code,boolean analyzer,String label){
  if(analyzer)code="if(String(java.getString("+quote("@js:"+code+";'analyzer-complete';")+",''))!=='analyzer-complete')throw Error('analyzer result');";
  var out=execute(code);check(out.get("ok").getAsBoolean(),label+" "+out);check(out.getAsJsonObject("result").get("executed").getAsBoolean(),"action skipped "+label);
 }
 static void assertString(StringBuilder b,String expression,String expected,String label){b.append("if(String(").append(expression).append(")!==").append(quote(expected)).append(")throw Error(").append(quote(label)).append(");");checks++;}
 static void assertThrows(StringBuilder b,String expression,String label){b.append("var rejected=false;try{").append(expression).append(";}catch(e){rejected=true;}if(!rejected)throw Error(").append(quote(label)).append(");");checks++;}
 static boolean blank(String s){return s==null||s.chars().allMatch(c->Character.isWhitespace((char)c)||Character.isSpaceChar((char)c));}
 static void assertBytes(StringBuilder b,String expression,byte[] expected,String label){
  b.append("var bytes=").append(expression).append(';');
  if(expected==null)b.append("if(bytes!==null)throw Error(").append(quote(label+" nullable")).append(");");
  else{b.append("if(bytes===null||Object.prototype.toString.call(bytes)!=='[object JavaArray]'||bytes.length!==").append(expected.length).append(")throw Error(").append(quote(label+" byte[] type/length")).append(");");for(int i=0;i<expected.length;i++)b.append("if(Number(bytes[").append(i).append("])!==").append(expected[i]).append(")throw Error(").append(quote(label+" signed byte "+i)).append(");");}
  checks++;
 }
 static void byteVector(StringBuilder b,String input,int flags,boolean noFlags){
  String expression="java.base64DecodeToByteArray("+quote(input)+(noFlags?"":","+flags)+")";
  byte[] expected=null;boolean bad=false;try{if(!blank(input))expected=android.util.Base64.decode(input,flags);}catch(IllegalArgumentException e){bad=true;}
  if(bad)assertThrows(b,expression,"bad bytes "+flags);else assertBytes(b,expression,expected,"bytes "+flags);nullableVectors++;
 }
 static void abi()throws Exception{
  for(Class<?> type:new Class<?>[]{RuleJsExtensions.class,io.legado.app.data.entities.BaseSource.class,io.legado.app.data.entities.BookSource.class,io.yuedu.legado.originalrule.OriginalSourceLoginHost.class,io.legado.app.model.analyzeRule.AnalyzeRule.class,io.legado.app.model.analyzeRule.AnalyzeUrl.class}){
   check(type.getMethod("base64Decode",String.class,int.class).getReturnType()==String.class,"flags String ABI "+type);
   check(type.getMethod("base64DecodeToByteArray",String.class).getReturnType()==byte[].class,"byte[] ABI "+type);
   check(type.getMethod("base64DecodeToByteArray",String.class,int.class).getReturnType()==byte[].class,"flags byte[] ABI "+type);
   check(Arrays.stream(type.getMethods()).filter(m->m.getName().startsWith("base64")).noneMatch(m->m.getReturnType()==Void.class),"old Void forwarder "+type);
  }
 }
 public static void main(String[] args)throws Exception{
  LegadoRuntime.setHostCallback((task,operation,input)->{if(operation.equals("task.cancel"))return "{}";hostCalls++;throw new AssertionError("unexpected Host "+operation);});
  var source=new JsonObject();source.addProperty("bookSourceUrl","https://synthetic-base64.invalid/source");source.addProperty("loginUrl","var base64Prelude=true;");source.add("ruleContent",new JsonObject());
  session=ok(LegadoRuntime.createSession(source.toString(),"{\"sourceMode\":\"original-traditional\",\"httpTransport\":\"jvm-okhttp\",\"stateOwner\":\"synthetic-base64-owner\"}")).get("sessionId").getAsString();
  try{
   if(args.length>0&&args[0].equals("baseline")){
    for(String action:List.of("java.base64Decode('TQ==',0);","java.base64DecodeToByteArray('gP8=',0);","java.base64Encode('a',0);")){var out=execute(action);check(!out.get("ok").getAsBoolean(),"baseline unexpectedly supported");System.out.println("BASELINE_PUBLIC_COUNTEREXAMPLE "+out);}
    check(hostCalls==0,"baseline Host");System.out.println("BASELINE_PUBLIC_CALLS=3 unsupported=3 host=0");return;
   }
   abi();
   var flags=new ArrayList<Integer>();for(int i=0;i<32;i++)flags.add(i);flags.addAll(List.of(64,1<<30,Integer.MIN_VALUE,Integer.MAX_VALUE,-1,-9));
   var texts=List.of("","a","ab","abc","阅读éÿ\u0000","a".repeat(56),"b".repeat(57),"c".repeat(58),"d".repeat(114),"e".repeat(115),"🦊".repeat(40));
   var inputs=List.of("","TQ==","TQ","TWE=","TWE","TWFu","gP8=","--__","++//","T?Q==","TQ==!é","A","AA=","=","AAAA=","AA===","A=AA","AA==A","AA= =","AĀA","\u0000"," \t\r\n ","\u2003","\u00a0","_w==","/w==");
   for(int flag:flags){for(boolean analyzer:new boolean[]{false,true}){
    var script=new StringBuilder();
    for(String text:texts){String expected=android.util.Base64.encodeToString(text.getBytes(StandardCharsets.UTF_8),flag);assertString(script,"java.base64Encode("+quote(text)+","+flag+")",expected,"encode "+flag);encodeVectors++;}
    for(String input:inputs){
     boolean bad=false;String expected=null;try{expected=new String(android.util.Base64.decode(input,flag),StandardCharsets.UTF_8);}catch(IllegalArgumentException e){bad=true;}
     String expression="java.base64Decode("+quote(input)+","+flag+")";
     if(bad)assertThrows(script,expression,"decode "+flag);else assertString(script,expression,expected,"decode "+flag);decodeVectors++;
     byteVector(script,input,flag,false);
    }
    byteVector(script,null,flag,false);
    // BookSource has its own Kotlin forwarding methods in addition to the form host and AnalyzeRule.
    assertString(script,"source.base64Encode('a',"+flag+")",android.util.Base64.encodeToString(new byte[]{97},flag),"source encode");
    assertBytes(script,"source.base64DecodeToByteArray('gP8=',"+flag+")",android.util.Base64.decode("gP8=",flag),"source signed bytes");
    run(script.toString(),analyzer,"flags="+flag+" AnalyzeRule="+analyzer);
   }}
   for(boolean analyzer:new boolean[]{false,true}){
    var script=new StringBuilder();for(String input:inputs)byteVector(script,input,0,true);byteVector(script,null,0,true);
    for(String text:texts)assertString(script,"java.base64Encode("+quote(text)+")",android.util.Base64.encodeToString(text.getBytes(StandardCharsets.UTF_8),2),"default NO_WRAP");
    assertString(script,"java.base64Decode('SGVsbG8=')","Hello","Hutool UTF8");
    assertString(script,"java.base64Decode('//8=','ISO-8859-1')","ÿÿ","Hutool charset");
    assertString(script,"java.base64Decode('1tDOxA==','GB18030')","中文","Hutool GB18030");
    assertString(script,"java.bytesToStr(java.base64DecodeToByteArray('//8='),'ISO-8859-1')","ÿÿ","byte[] charset");
    assertThrows(script,"java.base64Decode(null)","Hutool null");
    assertThrows(script,"java.base64Decode('TQ==','not-a-charset')","Hutool charset rejection");
    assertThrows(script,"java.base64Decode('TQ==','0')","String charset overload differs from flags");
    assertThrows(script,"java.base64Decode(null,0)","flags String nonnull");
    run(script.toString(),analyzer,"no-flags/nullable/charset AnalyzeRule="+analyzer);
   }
   check(hostCalls==0,"unexpected Host/HTTP");
   var result=new JsonObject();result.addProperty("publicLoginActionCalls",calls);result.addProperty("originalAnalyzeRuleCalls",calls/2);result.addProperty("oracleChecks",checks);result.addProperty("encodeVectors",encodeVectors);result.addProperty("decodeVectors",decodeVectors);result.addProperty("nullableByteArrayVectors",nullableVectors);result.addProperty("flags",flags.size());result.addProperty("abiClasses",6);result.addProperty("hostCalls",hostCalls);result.addProperty("httpCalls",0);result.addProperty("sessions",1);result.addProperty("SDK_JNI",0);System.out.println("BASE64_PUBLIC_ORACLE_SUCCESS "+result);
  }finally{ok(LegadoRuntime.closeSession(session));LegadoRuntime.setHostCallback(null);}
 }
}
