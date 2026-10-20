import org.junit.runner.*;
import org.junit.runner.notification.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
public final class SelectedV2BrowserTests {
 public static void main(String[]args)throws Exception{
  String[] methods={"v2UsesSameSourceApiForDefaultGetPostAndNonawaitUi","falseReturnsAtomicDomForBothHttpMethods","acceptedBrowserEffectsSurviveScriptFailureAndHtmlRemainsUnsupported","cancellationDrainsCurrentTaskAndRetainsActualPostFacts","sensitiveSearchNeverInheritsPreviousOrFutureLoginAdmission","concurrentTaskCannotBorrowActiveLoginBrowserAdmission"};
  if(args.length>1)methods=java.util.Arrays.copyOfRange(args,1,args.length);
  var body=new StringBuilder();int total=0,failures=0,skipped=0;
  Class<?> type=Class.forName("io.yuedu.legado.OriginalSourceLoginV2BrowserTest");
  for(String method:methods){var result=new JUnitCore().run(Request.method(type,method));total+=result.getRunCount();failures+=result.getFailureCount();skipped+=result.getIgnoreCount();body.append("<testcase classname=\"").append(type.getName()).append("\" name=\"").append(method).append("\" time=\"").append(result.getRunTime()/1000.0).append("\">");for(Failure f:result.getFailures()){String t=f.getTrace();System.out.println(method+" FAILURE "+t);body.append("<failure><![CDATA[").append(t.replace("]]>","]] >")).append("]]></failure>");}body.append("</testcase>\n");System.out.println(method+" run="+result.getRunCount()+" failures="+result.getFailureCount()+" skipped="+result.getIgnoreCount());}
  Files.writeString(Path.of(args[0]),"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuite name=\"io.yuedu.legado.OriginalSourceLoginV2BrowserTest\" tests=\""+total+"\" failures=\""+failures+"\" errors=\"0\" skipped=\""+skipped+"\">\n"+body+"</testsuite>\n",StandardCharsets.UTF_8);
  if(total!=methods.length||failures!=0||skipped!=0)System.exit(1);
 }
}
