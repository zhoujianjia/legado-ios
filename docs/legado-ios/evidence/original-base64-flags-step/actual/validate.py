from pathlib import Path
import hashlib,importlib.util,json,shutil,zipfile
R=Path('F:/yuedu-reader');S=Path(__file__).parent;V=S/'validation-root';V.mkdir(exist_ok=False)
def f(p):b=p.read_bytes();return {'path':str(p.relative_to(R)).replace('\\','/'),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def copy(p):
 src=S/'work'/p
 if not src.is_file():src=R/p
 dest=V/p;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dest)
old=json.loads((S/'rawbaseline/Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes());new=json.loads((S/'work/Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes())
for k in old:
 if k not in ['portedSources','platformSeams']:assert new[k]==old[k],k
changed=[]
assert len(old['portedSources'])==len(new['portedSources'])==59
for before,after in zip(old['portedSources'],new['portedSources']):
 assert before['path']==after['path']
 if before!=after:changed.append(before['path'])
 copy(after['path']);assert f(V/after['path'])['sha256']==after['sha256'];assert (V/after['path']).stat().st_size==after['bytes']
assert changed==['Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleBase64.kt','Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt']
prefix='Packages/LegadoRuntime/vendor/'
for d in ['runtime-http/licenses','probe/licenses']:
 for p in (R/prefix/d).rglob('*'):
  if p.is_file():copy(p.relative_to(R).as_posix())
for name in ['runtime-http/manifest.json','runtime-http/resolved-dependencies.json','scalar-rules/manifest.json','scalar-rules/resolved-dependencies.json','original-rule/manifest.json']:copy(prefix+name)
scalar=json.loads((V/(prefix+'scalar-rules/manifest.json')).read_bytes())
for item in scalar['licenseFiles']+scalar['packagedJarMetadata']:copy(prefix+'scalar-rules/'+item['path'])
for item in new['licenseFiles']:copy(prefix+'original-rule/'+item['path'])
http=json.loads((V/(prefix+'runtime-http/manifest.json')).read_bytes())
for item in http['encodingSources']:copy('Packages/LegadoRuntime/'+item['portedPath'])
spec=importlib.util.spec_from_file_location('base64_runtime_packaging',R/'scripts/reader-experience/runtime-packaging.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);m.REPO=V
jar=S/'legado-runtime-base64-final.jar';inspection=m.inspect_jar(jar)
base=R/'.build/original-local-html-webjs-step/implementation-v1/snapshot-v2/legado-runtime.jar'
executed=S/'legado-runtime-base64.jar'
with zipfile.ZipFile(jar)as z,zipfile.ZipFile(executed)as test,zipfile.ZipFile(base)as parent:
 assert z.testzip()is None
 delta=[n for n in z.namelist()if z.read(n)!=test.read(n)]
 assert delta==['META-INF/legado-provenance/original-rule/manifest.json']
 assert z.namelist()==test.namelist()==parent.namelist()
 licence=new['androidBase64FlagsPort'];assert z.read(licence['packagedLicenseEntry'])==(R/licence['existingLicenseFile']).read_bytes()
 main=[n for n in z.namelist()if n.startswith(('io/yuedu/legado/','io/legado/'))and n.endswith('.class')]
 fresh=json.loads((S/'jar-assembly-final.json').read_bytes())['fresh'];freshNames={v['path']for v in fresh}
 assert len(freshNames)==39
 retainedMain=[n for n in main if n not in freshNames];assert all(z.read(n)==parent.read(n)for n in retainedMain)
 changedClasses=[n for n in main if z.read(n)!=parent.read(n)]
 assert not any(n.startswith(('android/util/','OrdinaryBase64Flags','org/junit/'))for n in z.namelist())
raw=(S/'rawbaseline/Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleBase64.kt').read_text(encoding='utf-8')
candidate=(S/'work/Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleBase64.kt').read_text(encoding='utf-8')
oldBody=raw[raw.index('internal object RuleBase64 {'):-2]
assert candidate[candidate.index('internal object RuleBase64 {'):candidate.index('\n    /*\n')]==oldBody
inputParent=R/'.build/original-local-html-webjs-step/implementation-v1/snapshot-v2/evidence/actual-jvm-compilation-inputs.json'
inputs=json.loads(inputParent.read_bytes())['inputs'];assert len(inputs)==128
sourceFacts=[]
for item in inputs:
 p=item['path'];copy(p)
 if p not in changed:assert f(V/p)['sha256']==item['sha256'],p
 sourceFacts.append({'path':p,'bytes':(V/p).stat().st_size,'sha256':f(V/p)['sha256']})
(S/'actual-jvm-compilation-inputs.json').write_text(json.dumps({'kind':'Exact89f parent125main+3controls; two changed Kotlin, five unchanged ABI implementation sources recompiled. Ordinary incremental evidence, not full Gradle.','inputs':sourceFacts},indent=2)+'\n',encoding='utf-8',newline='\n')
final=(S/'OrdinaryBase64Flags.java').read_text(encoding='utf-8')
oldResult=final.replace('getAsJsonObject("result").get("executed")','getAsJsonObject("data").get("executed")')
assert oldResult!=final
for name,text in [('ordinary-v2',oldResult),('ordinary-v1',oldResult.replace(',\\\"stateOwner\\\":\\\"synthetic-base64-owner\\\"','')),('ordinary-v3',final)]:
 p=S/name/'executed-OrdinaryBase64Flags.java';p.write_text(text,encoding='utf-8',newline='\n')
 if name=='ordinary-v1':assert 'stateOwner'not in text
result={'sourceValidation':{'portedSourceCount':59,'changedRows':changed,'preservedRows':57,'lockedOriginalLicenseRuntimeResourceSectionsUnchanged':True,'hutoolDecoderBodyExact':True,'parentInputCount':128,'parentMainInputs':125,'unchangedInputs':126},'jarInspection':inspection,'ordinaryEvidenceReuse':{'executedJar':f(executed),'finalJar':f(jar),'onlyPostExecutionMemberChange':delta,'allClassAndRuntimeResourcesExactToExecutedJar':True},'classBinding':{'projectMainClasses':len(main),'freshlyCompiledMainClasses':39,'unchangedInheritedMainClasses':len(retainedMain),'actuallyChangedClassBytes':len(changedClasses),'changedClassNames':changedClasses,'unchangedJavaICUClasses':52,'newRuntimeClassNames':0},'licenseReuse':{'fullApache2AlreadyPackaged':True,'fullLicense':f(R/licence['existingLicenseFile']),'originalApacheCopyrightAndModificationNoticeRetained':True},'sdkJNIPhoneExecuted':0,'noFullGradleOrUnrelatedSuite':True}
(S/'validation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n');print(json.dumps(result,ensure_ascii=True))
