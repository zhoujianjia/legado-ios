import org.junit.runner.*;
import org.junit.runner.notification.*;
import java.nio.file.*;
import java.util.*;
public final class OneMethodRunner {
 private static String esc(String text){return text.replace("&","&amp;").replace("<","&lt;").replace("\"","&quot;");}
 public static void main(String[] args)throws Exception{
  var xml=new StringBuilder();var failures=new LinkedHashMap<String,String>();var results=new ArrayList<Result>();var core=new JUnitCore();
  core.addListener(new RunListener(){
   public void testFailure(Failure failure){failures.put(failure.getDescription().getClassName()+"/"+failure.getDescription().getMethodName(),failure.getTrace());}
   public void testFinished(Description d){String key=d.getClassName()+"/"+d.getMethodName();xml.append("<testcase classname=\"").append(esc(d.getClassName())).append("\" name=\"").append(esc(d.getMethodName())).append("\">");if(failures.containsKey(key))xml.append("<failure>").append(esc(failures.get(key))).append("</failure>");xml.append("</testcase>\n");}
  });
  for(int i=1;i<args.length;i++){String[] target=args[i].split("/",2);results.add(core.run(Request.method(Class.forName(target[0]),target[1])));}
  int count=results.stream().mapToInt(Result::getRunCount).sum(),failed=results.stream().mapToInt(Result::getFailureCount).sum(),ignored=results.stream().mapToInt(Result::getIgnoreCount).sum();
  Files.writeString(Path.of(args[0]),"<?xml version=\"1.0\" encoding=\"UTF-8\"?><testsuite tests=\""+count+"\" failures=\""+failed+"\" skipped=\""+ignored+"\">\n"+xml+"</testsuite>\n");
  for(var entry:failures.entrySet())System.out.println(entry.getKey()+"\n"+entry.getValue());
  System.out.println("ACTUAL_JUNIT tests="+count+" failures="+failed+" skipped="+ignored);
  if(count!=1||failed!=0||ignored!=0)System.exit(1);
 }
}
