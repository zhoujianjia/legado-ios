import org.junit.runner.*;
import org.junit.runner.notification.*;
import java.nio.file.*;
import java.util.*;
public final class PolicyJUnitRunner {
 public static void main(String[] args)throws Exception {
  var xml=new StringBuilder(); var core=new JUnitCore(); var failures=new HashMap<String,String>();
  core.addListener(new RunListener(){
   public void testFailure(Failure f){failures.put(f.getDescription().getMethodName(),f.getTrace());}
   public void testFinished(Description d){xml.append("<testcase classname=\"").append(d.getClassName()).append("\" name=\"").append(d.getMethodName()).append("\">");String f=failures.get(d.getMethodName());if(f!=null)xml.append("<failure>").append(f.replace("&","&amp;").replace("<","&lt;")).append("</failure>");xml.append("</testcase>\n");}
  });
  Result r=core.run(Class.forName("io.yuedu.legado.OriginalGeneralWebJsTest"));
  Files.writeString(Path.of(args[0]),"<?xml version=\"1.0\" encoding=\"UTF-8\"?><testsuite tests=\""+r.getRunCount()+"\" failures=\""+r.getFailureCount()+"\" skipped=\""+r.getIgnoreCount()+"\">\n"+xml+"</testsuite>\n");
  for(Failure f:r.getFailures())System.out.println(f.getTrace());System.out.println("ACTUAL_JUNIT tests="+r.getRunCount()+" failures="+r.getFailureCount()+" skipped="+r.getIgnoreCount());if(!r.wasSuccessful())System.exit(1);
 }
}
