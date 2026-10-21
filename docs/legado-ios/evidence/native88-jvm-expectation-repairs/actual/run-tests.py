from pathlib import Path
import hashlib,json,subprocess,time,zipfile
R=Path('F:/yuedu-reader');S=Path(__file__).resolve().parent;E=S/'execution-v1';assert not E.exists();E.mkdir()
def rf(b):return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def fact(p):return {'path':p.relative_to(R).as_posix(),**rf(p.read_bytes())}
def save(p,x):p.write_bytes((json.dumps(x,indent=2)+'\n').encode())
parent=json.loads((R/'.build/original-general-webjs-blank-regex-step/policy-tests-v1/commands.json').read_bytes())
jar=R/'.build/original-general-webjs-blank-regex-step/ordinary-jar/legado-runtime-general-base64.jar';assert rf(jar.read_bytes())=={'bytes':10915918,'sha256':'6b759cb645a2a033edd51a29d3f34f1d61d34ceadbe2b3ac960ea2a35df0b5e4'}
draft=json.loads((S/'draft-v2.json').read_bytes());sources=[S/'work'/row['path']for row in draft['files']]
for p,row in zip(sources,draft['files']):assert rf(p.read_bytes())==row['candidate']
classes=E/'classes';classes.mkdir();compiler=parent['commands'][0]['argv'];index=compiler.index('-d')
argv=compiler[:index]+['-d',str(classes)]+[str(p)for p in sources];argv[argv.index('-module-name')+1]='native88c-five-method-fixtures'
commands=[]
def run(name,argv):
 t=time.monotonic();p=subprocess.run(argv,cwd=R,capture_output=True,timeout=90);log=E/(name+'.log');log.write_bytes(p.stdout+p.stderr);commands.append({'argv':argv,'exitCode':p.returncode,'seconds':round(time.monotonic()-t,3),'log':fact(log)});save(E/'commands.json',{'scope':'Only five changed test roots and five exact methods; no production compilation/fullGradle/old353 replay','runtimeJar':fact(jar),'sources':[fact(p)for p in sources],'commands':commands});assert p.returncode==0,(name,(p.stdout+p.stderr).decode('utf8',errors='replace')[-5000:])
run('compile-tests',argv)
javac=parent['commands'][1]['argv'];classpath=javac[javac.index('-classpath')+1]
run('compile-runner',[javac[0],'-J-Xmx64m','-classpath',classpath,'-d',str(classes),str(S/'FiveMethodsRunner.java')])
targets=[
 'io.yuedu.legado.OriginalAnalyzeRuleTest/hutoolStringBase64OverloadsKeepWhitespaceUrlSafeAndCharsetBehavior',
 'io.yuedu.legado.OriginalSourceLoginBrowserAwaitTest/presentationEmptyWrongModeAndExplicitUnsupportedNeverBecomeSuccessfulAwait',
 'io.yuedu.legado.OriginalSourceLoginBrowserTest/unsupportedHtmlPostAndNonWebSchemesDoNotFakePresentation',
 'io.yuedu.legado.OriginalSourceLoginV2BrowserTest/acceptedBrowserEffectsSurviveScriptFailureAndHtmlRemainsUnsupported',
 'io.yuedu.legado.OriginalUrlExecutionTest/unsupportedOptionsHeadersAndUnmigratedMainJsStayTypedBeforeHttp',
]
with zipfile.ZipFile(jar)as z:
 for target in targets:assert target.split('/')[0].replace('.','/')+'.class'not in z.namelist()
java=compiler[0];run('execute-tests',[java,'-Xms16m','-Xmx160m','-XX:MaxMetaspaceSize=128m','-XX:+UseSerialGC','-XX:ActiveProcessorCount=2','-cp',str(classes)+';'+classpath,'FiveMethodsRunner',str(E/'actual-tests.xml'),*targets])
print(json.dumps({'commands':fact(E/'commands.json'),'XML':fact(E/'actual-tests.xml'),'tests':5,'productionRootsCompiled':0}))
