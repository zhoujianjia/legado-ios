import ast,hashlib,json,pathlib,re,xml.etree.ElementTree as ET,zipfile
R=pathlib.Path(__file__).resolve().parents[2];S=pathlib.Path(__file__).resolve().parent
U=R/'.build/original-general-webjs-blank-regex-step';F=U/'final-v1.json';checks=[]
helper=R/'.build/original-general-webjs-backend-independent-review/verify-v1.py';tree=ast.parse(helper.read_text())
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name in {'digest','path','fact','check','binding','walk','sourcefile'}],type_ignores=[]),str(helper),'exec'))
check('blank final exact',F.stat().st_size==10457 and digest(F.read_bytes())=='7e725827274861758270ca4a8f64908df3b1d968482e9e594b6f98f8a47ee9ba')
f=json.loads(F.read_text());root=R/f['candidateRoot'];baseline=R/f['baselineRoot']
for key in ['parent','parentIndependentReview','contract','ordinaryJar','evidence']:walk(f[key])
parent=json.loads(binding(f['parent']).read_text());pr=R/parent['candidateRoot']
for row in f['files']:
 for key,base in [('candidate',root),('baseline',baseline)]:
  b=(base/row['path']).read_bytes();check(key+' '+row['path'],len(b)==row[key]['bytes']and digest(b)==row[key]['sha256'])
 check('baseline exact approved union '+row['path'],(baseline/row['path']).read_bytes()==(pr/row['path']).read_bytes())
 binding(row['diff'])
prodpath=f['files'][0]['path'];old=(baseline/prodpath).read_bytes();new=(root/prodpath).read_bytes()
expected=old.replace(b'"sourceRegex" to sourceRegex, "overrideUrlRegex" to overrideUrlRegex,',b'"sourceRegex" to sourceRegex?.takeUnless(String::isBlank),\n                "overrideUrlRegex" to overrideUrlRegex?.takeUnless(String::isBlank),')
check('only two producer emission fields normalized',old!=new and expected==new)
testpath=f['files'][1]['path'];oldt=(baseline/testpath).read_text();newt=(root/testpath).read_text()
names=lambda x:re.findall(r'@Test\s+fun\s+(\w+)',x)
check('old four test identities exact no new',names(oldt)==names(newt)and len(names(newt))==4)
def methods(s):
 starts=list(re.finditer(r'    @Test fun (\w+)',s));return {m.group(1):s[m.start():(starts[i+1].start()if i+1<len(starts)else s.rindex('\n}'))]for i,m in enumerate(starts)}
a=methods(oldt);b=methods(newt);changed=[name for name in a if a[name]!=b[name]]
check('only existing targeted method changed',changed==[f['actualVectors']['targetedJUnit']])
mp=f['files'][2]['path'];om=json.loads((baseline/mp).read_text());nm=json.loads((root/mp).read_text())
check('only manifest ported source list key changes',[k for k in nm if nm[k]!=om.get(k)]==['portedSources'])
delta=[(x,y)for x,y in zip(om['portedSources'],nm['portedSources'])if x!=y]
check('one Production manifest byte row exactly',len(om['portedSources'])==len(nm['portedSources'])==60 and len(delta)==1 and delta[0][1]['path']==prodpath and delta[0][1]['sha256']==digest(new)and delta[0][1]['bytes']==len(new))
prod=json.loads(binding(f['ordinaryJar']['binding']).read_text());jar=binding(f['ordinaryJar']);base=binding(prod['baseJar'])
check('single main root',len(prod['compiledInputs'])==1)
for row in prod['compiledInputs']:
 p=binding(row);check('actual production source frozen exact',p.read_bytes()==new)
compile=json.loads((U/'compile-v1/commands.json').read_text());check('actual K2 exit0',compile['exitCode']==0);binding(compile['log'])
fresh=prod['recompiledClasses'];ret=prod['retainedClasses'];fn={x['path']for x in fresh}
check('11fresh401retained412 class closure',len(fresh)==11 and len(ret)==401 and len(fn|{x['path']for x in ret})==412)
with zipfile.ZipFile(jar)as z,zipfile.ZipFile(base)as oldz:
 check('ZIP CRC and stable names',z.testzip()is None and len(z.namelist())==len(set(z.namelist()))and set(z.namelist())==set(oldz.namelist()))
 for group in ['recompiledClasses','retainedClasses','unchangedResources']:
  for row in prod[group]:
   d=z.read(row['path']);check(group+' '+row['path'],len(d)==row['bytes']and digest(d)==row['sha256'])
   if group=='recompiledClasses':check('actual K2 output '+row['path'],d==(U/'compile-v1/classes'/row['path']).read_bytes()and sourcefile(d)==row['sourceFile'])
   else:check('unchanged parent bytes '+row['path'],d==oldz.read(row['path']))
 check('only nonfresh changed entry manifest',[n for n in z.namelist()if n not in fn and z.read(n)!=oldz.read(n)]==['META-INF/legado-provenance/original-rule/manifest.json'])
 check('embedded original manifest exact',z.read('META-INF/legado-provenance/original-rule/manifest.json')==(root/mp).read_bytes())
 check('Base64 ABI all retained exact',all(any(x['sourceFile']==source for x in ret)for source in ['RulePlatform.kt','RuleBase64.kt','BaseSource.kt','RuleModels.kt','OriginalSourceLoginHost.kt','AnalyzeRule.kt','AnalyzeUrl.kt']))
inputs=json.loads((U/'actual-jvm-compilation-inputs.json').read_text())['inputs']
check('129inputs126main125retained',len(inputs)==129 and sum('/src/main/'in x['path']for x in inputs)==126)
for row in inputs:
 p=root/row['path']
 if not p.exists():p=R/row['path']
 d=p.read_bytes();check('source input '+row['path'],len(d)==row['bytes']and digest(d)==row['sha256'])
def commands(p):
 d=json.loads(p.read_text())
 for cmd in d['commands']:
  check('actual command exit0 '+p.parent.name,cmd['exitCode']==0);binding(cmd['log'])
 return d['commands']
gc=commands(U/'ordinary-jar/ordinary-commands.json');tc=commands(U/'policy-tests-v1/commands.json')
check('actual public6417Host exact log',(U/'ordinary-jar/execute-consumer.log').read_text().strip()==f['actualVectors']['ordinaryOutput'])
consumer=(U/'OrdinaryGeneralWebJs.java').read_text();pc=(R/'.build/original-general-webjs-base64-union-step/OrdinaryGeneralWebJs.java').read_text()
start=consumer.index('   for(String blank:List.of(');end=consumer.index('   String negative=',start)
addition=consumer[start:end]
check('six actual blank vectors only consumer addition',consumer[:start]+consumer[end:]==pc)
check('emitted packet not mock policy assertion','sourceRegex' in addition and 'overrideUrlRegex' in addition and 'isJsonNull()'in addition and '\\u00a0'in addition)
xml=ET.parse(U/'policy-tests-v1/actual-tests.xml').getroot()
check('one actual changed test1/0fail0skip',xml.attrib['tests']=='1'and xml.attrib['failures']=='0'and xml.attrib['skipped']=='0'and len(xml.findall('testcase'))==1 and xml.find('testcase').attrib['name']==changed[0]and not xml.findall('.//failure')and not xml.findall('.//error'))
pack=(U/'packaging-tests.log').read_text();check('actual portable6passed',pack.count('... ok')==6 and 'Ran 6 tests'in pack and pack.strip().endswith('OK'))
report=dict(schema=1,final=fact(F),status='approved bounded wire-normalization successor',approved=True,actualReadOnlyChecks=len(checks),failedChecks=0,remainingConfirmedFindings=[],closedFinding=dict(id='P2-KOTLIN-BLANK-REGEX-WIRE',originalContract='BackstageWebView.kt172 isNullOrBlank selects ordinary evaluator; original policy already uses same Kotlin classifier',fix='Only source.webview two packet fields use nullable takeUnless(String::isBlank); nonblank bytes untouched',actualRegression='public empty/2spaces/NBSP for source and override,6cases adds18public and6Host calls; raw packet fields asserted JSONnull',authority='No Swift Unicode parser or changed admission flag'),parents=dict(union=f['parent'],review=f['parentIndependentReview']),counts=dict(changedSources=3,productionSources=1,modifiedExistingTests=1,newDefinitions=0,actualChangedJUnitPassed=1,unchangedJUnitMethodsReused=3,freshClasses=11,retainedClasses=401,totalClasses=412,mainInputs=126,totalInputs=129,portedRows=60,actualGeneralPublicCalls=64,actualSyntheticHostCalls=17,actualJVMHTTP=7,actualPOST=3,actualGET=4,actualPackagingGuards=6,Base64NotRerun=True),checks=checks,limits=f['proofLimits']+['This review did not run K2/JVM/Java/JUnit/packaging/Swift/SDK/Cloud. All execution evidence read from exact author artifacts.','Original resource HTTP(S) observation and object result branches remain unfinished; public WKWebExtension candidate research is separate and does not promote current support.'],mutations=dict(canonical=False,Git=False,cloud=False,peerStage=False,testsRerun=False))
(S/'review-v1.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps(dict(checks=len(checks),report=fact(S/'review-v1.json')),indent=2))
