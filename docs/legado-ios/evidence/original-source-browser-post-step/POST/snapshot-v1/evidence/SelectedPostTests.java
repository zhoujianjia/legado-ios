import org.junit.runner.*;
import org.junit.runner.notification.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
public final class SelectedPostTests {
 public static void main(String[] args)throws Exception{
  String[][] cases={
   {"OriginalSourceLoginBrowserPostTest","defaultTrueReusesSinglePostBodyAfterRedirectAndKeepsInitialUrlAndHeaders"},
   {"OriginalSourceLoginBrowserPostTest","falseReturnsDomAndNonawaitPresentsPrefetchedHtmlWithoutSecondPost"},
   {"OriginalSourceLoginBrowserPostTest","emptyPrefetchIsNotMissingAndOversizedBodyNeverReachesPage"},
   {"OriginalSourceLoginBrowserPostTest","cancellationDuringRealPostRetainsMaySendButNeverPresentsOrWritesCredentials"},

   {"OriginalSourceLoginBrowserAwaitTest","domResponseUsesActualFinalUrlBodyAndOriginalSyntheticRawResponse"},
   {"OriginalSourceLoginBrowserAwaitTest","defaultTrueRefetchUsesOriginalHttpAndFirstHeaderSnapshotButOwnerResponseIsSynthetic200"},
   {"OriginalSourceLoginBrowserAwaitTest","presentationEmptyWrongModeAndExplicitUnsupportedNeverBecomeSuccessfulAwait"},
   {"OriginalSourceLoginBrowserAwaitTest","taskCancellationBeforeAndAfterCookieCaptureRetainsFactsAndPreventsLaterWrites"},
   {"OriginalSourceLoginBrowserTest","realRhinoUsesOriginalAnalyzeUrlAndRequiresActualPresentationBoolean"},
   {"OriginalSourceLoginBrowserTest","unsupportedHtmlPostAndNonWebSchemesDoNotFakePresentation"},
   {"OriginalSourceLoginBrowserTest","refusalAndSensitiveFailuresKeepAcceptedFactsWithoutLateSourceMutation"},
   {"OriginalSourceLoginBrowserTest","cancellationOfLivePresentationKeepsPossibleEffectAndPreventsLateWrites"}
  };
  var body=new StringBuilder();int failures=0,total=0,ignored=0;
  for(String[] c:cases){
   Class<?> type=Class.forName("io.yuedu.legado."+c[0]);String method=c[1];Result r=new JUnitCore().run(Request.method(type,method));
   total+=r.getRunCount();failures+=r.getFailureCount();ignored+=r.getIgnoreCount();
   body.append("<testcase classname=\"").append(type.getName()).append("\" name=\"").append(method).append("\" time=\"").append(r.getRunTime()/1000.0).append("\">");
   for(Failure f:r.getFailures()){String t=f.getTrace();System.out.println(method+" FAILURE "+t);body.append("<failure message=\"Actual JUnit failure\"><![CDATA[").append(t.replace("]]>","]] >")).append("]]></failure>");}
   body.append("</testcase>\n");System.out.println(method+" run="+r.getRunCount()+" failures="+r.getFailureCount()+" ignored="+r.getIgnoreCount());
  }
  String xml="<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuite name=\"io.yuedu.legado.OriginalBrowserAwaitSlice\" tests=\""+total+"\" failures=\""+failures+"\" errors=\"0\" skipped=\""+ignored+"\">\n"+body+"</testsuite>\n";
  Files.writeString(Path.of(args[0]),xml,StandardCharsets.UTF_8);if(total!=12||failures!=0||ignored!=0)System.exit(1);
 }
}
