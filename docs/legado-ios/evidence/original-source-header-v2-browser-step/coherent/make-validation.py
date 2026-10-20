from pathlib import Path
R=Path('F:/yuedu-reader');S=Path(__file__).parent
p=R/'.build/original-source-login-v2-browser-step/validate-bounded.py';s=p.read_text(encoding='utf-8')
s=s.replace("resume='--resume-after-prod'in sys.argv;E.mkdir(exist_ok=resume)","resume=False;E.mkdir(exist_ok=False)")
a=s.index("manifest=W/");z=s.index("commands=",a)
s=s[:a]+'''manifest=W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json';m=json.loads(manifest.read_text(encoding='utf-8'));count=0
for row in m['portedSources']:
 if row.get('path')in changed:
  assert fact(W/row['path'])=={k:row[k]for k in ('bytes','sha256')};count+=1
assert count==3
'''+s[z:]
s=s.replace('legado-runtime-v2-browser.jar','legado-runtime-header-v2-browser.jar')
s=s.replace("kind='Three-source exact K2 overlay on POST91d3 ordinaryJAR; NOT fresh Gradle'","kind='Coherent Header+V2Browser three-source exact K2 overlay on POST91d3 ordinaryJAR; NOT fresh Gradle'")
a=s.index("run([*common,'-Xfriend-paths='+str(jar)");z=s.index("cp=os.pathsep",a)
s=s[:a]+'''testRoots=[W/(tr+n)for n in ['OriginalSourceLoginHeaderTest.kt','AppCookieOwnerTextTest.kt','OriginalSourceLoginV2BrowserTest.kt']]+[R/(tr+n)for n in ['OriginalSourceLoginBrowserPostTest.kt','OriginalSourceLoginBrowserAwaitTest.kt','OriginalSourceLoginBrowserTest.kt','FileRulePersistenceAdapter.kt']]
run([*common,'-Xfriend-paths='+str(jar),'-classpath',os.pathsep.join(map(str,[jar,junit,hamcrest])),'-d',str(tests),*testRoots],'compile-tests.log')
'''+s[z:]
s=s.replace('SelectedV2BrowserTests','SelectedUnionTests').replace('junit-v2-browser.log','junit-union.log').replace('tests=6','tests=23')
(S/'validate-union.py').write_text(s,encoding='utf-8',newline='\n')
runner=(R/'.build/original-source-login-v2-browser-step/SelectedV2BrowserTests.java').read_text(encoding='utf-8')
a=runner.index('  String[] methods=');z=runner.index('  var body=',a)
cases=[]
import re
for file in [R/'.build/original-source-login-header-step/SelectedHeaderTests.java',R/'.build/original-source-login-browser-post-step/SelectedPostTests.java']:
 cases += re.findall(r'\{"([A-Za-z0-9]+)","([A-Za-z0-9]+)"\}',file.read_text(encoding='utf-8'))
v2=re.search(r'String\[\] methods=\{([^}]+)\}',runner).group(1);cases += [('OriginalSourceLoginV2BrowserTest',n)for n in re.findall(r'"([A-Za-z0-9]+)"',v2)]
assert len(cases)==23 and len(set(cases))==23
block='  String[][] cases={'+','.join('{"'+c+'","'+m+'"}'for c,m in cases)+'};\n'
runner=runner[:a]+block+runner[z:]
runner=runner.replace('SelectedV2BrowserTests','SelectedUnionTests').replace('  Class<?> type=Class.forName("io.yuedu.legado.OriginalSourceLoginV2BrowserTest");\n','')
runner=runner.replace('for(String method:methods){','for(String[] c:cases){Class<?> type=Class.forName("io.yuedu.legado."+c[0]);String method=c[1];').replace('total!=methods.length','total!=cases.length').replace('name=\\"io.yuedu.legado.OriginalSourceLoginV2BrowserTest','name=\\"io.yuedu.legado.CoherentHeaderV2Browser')
(S/'SelectedUnionTests.java').write_text(runner,encoding='utf-8',newline='\n')
print('prepared exact23 selectors')
