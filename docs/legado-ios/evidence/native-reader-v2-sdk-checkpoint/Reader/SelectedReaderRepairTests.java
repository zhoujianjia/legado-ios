import org.junit.runner.*;
import org.junit.runner.notification.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Real JUnit method requests, with actual failure records and no test replacement. */
public final class SelectedReaderRepairTests {
    public static void main(String[] args)throws Exception{
        Class<?> type=Class.forName("io.yuedu.legado.OriginalWebBookExecutionTest");
        String[] methods={"lastChapterDirectoryLookupKeepsSingleChapterVariableGrantAndCurrentRestore","originalExploreJavaMapStringRequiresExplicitStringForStrictIdentity","cssSearchXpathDetailsJsonTocAndPagedContentUseSameEntitiesAndTransport"};
        if(args.length>1)methods=Arrays.copyOfRange(args,1,args.length);
        var results=new ArrayList<Result>();var body=new StringBuilder();int failures=0,total=0;
        for(String method:methods){
            Result result=new JUnitCore().run(Request.method(type,method));results.add(result);total+=result.getRunCount();failures+=result.getFailureCount();
            body.append("<testcase classname=\"").append(type.getName()).append("\" name=\"").append(method).append("\" time=\"").append(result.getRunTime()/1000.0).append("\">");
            for(Failure failure:result.getFailures()){
                String trace=failure.getTrace();System.out.println(method+" FAILURE "+trace);
                body.append("<failure message=\"Actual JUnit failure\"><![CDATA[").append(trace.replace("]]>","]] >")).append("]]></failure>");
            }
            body.append("</testcase>\n");System.out.println(method+" run="+result.getRunCount()+" failures="+result.getFailureCount()+" ignored="+result.getIgnoreCount());
        }
        String xml="<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuite name=\"io.yuedu.legado.OriginalWebBookExecutionTest\" tests=\""+total+"\" failures=\""+failures+"\" errors=\"0\" skipped=\"0\">\n"+body+"</testsuite>\n";
        Files.writeString(Path.of(args[0]),xml,StandardCharsets.UTF_8);if(total!=methods.length||failures!=0||results.stream().anyMatch(r->r.getIgnoreCount()!=0))System.exit(1);
    }
}
