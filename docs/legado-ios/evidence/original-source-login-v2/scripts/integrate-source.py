from pathlib import Path
import hashlib
import json
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT=Path('F:/yuedu-reader')
STAGE=ROOT/'.build/ready-v2-native-login-composition-step'
V2=ROOT/'.build/original-source-login-v2-protocol-step'
LOGIN=ROOT/'.build/native-210-login-single-process-repair-step'
GIT='D:/app/Git/cmd/git.exe'
FLAGS=['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']
def read(p):return json.loads(p.read_bytes())
def fact(p):
    raw=p.read_bytes();return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def check(p,row):assert fact(p)=={k:row[k] for k in ['bytes','sha256']},str(p)
def write(p,value):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode())
status=subprocess.check_output([GIT,'status','--porcelain'],cwd=ROOT).decode().splitlines()
assert all(line=='?? debug.log' for line in status),status
head=subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip()
assert head=='58da225d8b78a1e191656fb3dbfce8279fdca3e3'
mp=STAGE/'preparation-v1.json'; vp=V2/'final-v1.json'; lp=LOGIN/'final-v1.json'
rp=ROOT/'.build/ready-v2-native-login-composition-independent-review/review.json'
check(mp,{'bytes':20002,'sha256':'189dde29ef364fbea3d52e67bcc1a835261793ee94f7f248cc93cc93867f9563'})
check(vp,{'bytes':20854,'sha256':'a9a5f9ce25a67af1906f97c3fe99cba55e71cef31ff63c62b9e8a8eeeb977bb5'})
check(lp,{'bytes':4255,'sha256':'d632ae4ae1fe8d09468902cf3af48ead2508b89875f16f076b29ec631b216318'})
check(rp,{'bytes':17958,'sha256':'8656dcac9f69dee8fe7dcc999b15a30f973688483cf1d2d788cbb73e135355e6'})
m,v2,login,review=read(mp),read(vp),read(lp),read(rp)
assert review['findings']==[] and review['status']=='composition-approved-no-new-source-findings-pending-unified-checkpoint'
sources={}
for row in m['files']:
    path=row['path'];check(STAGE/'work'/path,row['candidate'])
    if row['baseline'] is None:assert not (ROOT/path).exists()
    else:check(ROOT/path,row['baseline'])
    check(ROOT/row['diff']['path'],row['diff'])
    sources[path]=(STAGE/'work'/path).read_bytes()
assert len(sources)==21
for row in v2['unchangedInheritedInputs']:check(ROOT/row['path'],row)
for row in v2['references']+v2['evidence']:check(V2/row['path'],row)
meta=json.loads(sources['Packages/LegadoRuntime/vendor/original-rule/manifest.json'])
for row in meta['portedSources']:
    raw=sources[row['path']] if row['path'] in sources else (ROOT/row['path']).read_bytes()
    assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],row['path']
assert len(meta['portedSources'])==58
actual=read(V2/'actual-jvm-tests-v2.json');assert actual['actualTests']==8 and len(actual['suites'])==2
for suite in actual['suites']:
    path=V2/suite['xml']['path'];check(path,suite['xml']);doc=ET.parse(path).getroot();cases=doc.findall('testcase')
    assert len(cases)==int(doc.attrib['tests'])==4
    assert {c.attrib['name'] for c in cases}==set(suite['methods'])
    assert all(int(doc.attrib[k])==0 for k in ['failures','errors','skipped'])
    assert not doc.findall('.//failure')+doc.findall('.//error')+doc.findall('.//skipped')
jar=V2/v2['validation']['ordinaryJar']['path'];check(jar,v2['validation']['ordinaryJar'])
classes=read(V2/'ordinary-jar-production-class-binding.json')['classes'];assert len(classes)==346
with zipfile.ZipFile(jar) as archive:
    assert archive.testzip() is None
    for row in classes:
        raw=archive.read(row['path']);assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
    assert archive.read('META-INF/legado-provenance/original-rule/manifest.json')==sources['Packages/LegadoRuntime/vendor/original-rule/manifest.json']
inputs=read(V2/'actual-jvm-compilation-inputs.json')['inputs'];assert len(inputs)==127
for row in inputs:
    path=row['path'];actual_path=V2/'validation-root'/path;check(actual_path,row)
    raw=sources[path] if path in sources else (ROOT/path).read_bytes()
    if path=='Packages/LegadoRuntime/jvm/build.gradle.kts':raw+=b'\ntasks.test {maxHeapSize="128m";minHeapSize="16m";jvmArgs("-XX:+UseSerialGC","-XX:MaxMetaspaceSize=128m")}\n'
    assert actual_path.read_bytes()==raw,path
base=ROOT/'docs/legado-ios/evidence/original-source-login-v2'
record_path=ROOT/'docs/legado-ios/core-original-source-login-v2-step.json'
assert not base.exists() and not record_path.exists()
items={}
def add(src,name):
    assert src.is_file(),str(src)
    if name in items:assert items[name]==src
    else:items[name]=src
for src,name in [(vp,'whole-preparation.json'),(mp,'root-composition.json'),(rp,'composition-independent-review.json'),(lp,'root-native-login-repair.json'),(STAGE/'preserved-preparation-attempts.json','root-composition-attempts.json')]:add(src,name)
for row in v2['evidence']:add(V2/row['path'],row['path'])
for suite in actual['suites']:add(V2/suite['xml']['path'],suite['xml']['path'])
for src,name in [
    (ROOT/'.build/original-source-login-v2-app-independent-review/review.json','whole-independent-review.json'),
    (ROOT/'.build/original-source-login-v2-protocol-independent-review/backend-review-v3.json','backend-independent-review.json'),
    (ROOT/'.build/native-210-login-single-process-independent-review/review.json','root-native-login-independent-review.json'),
    (ROOT/'.build/original-source-login-v2-app-root-review/preliminary-v1/review.json','root-source-close-race-before-fix.json'),
    (V2/'app-final-v1.json','history/app-preparation-v1.json'),
    (V2/'backend-final-v1.json','history/backend-preparation-v1.json'),
    (V2/'backend-final-v2.json','history/backend-preparation-v2.json'),
    (LOGIN/'preparation-v1.json','history/root-login-preparation-v1.json'),
    (ROOT/'.build/compose-ready-v2-and-native-login-repair.py','scripts/compose-source.py'),
    (ROOT/'.build/prepare-native-210-login-single-process-repair.py','scripts/prepare-native-login.py'),
    (ROOT/'.build/finalize-native-210-login-repair.py','scripts/finalize-native-login.py'),
    (ROOT/'.build/integrate-reviewed-v2-and-native-login-repair.py','scripts/integrate-source.py'),
]:add(src,name)
evidence=[]
for name,src in items.items():
    raw=src.read_bytes();text=raw.decode('utf-16' if raw[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig')
    normalized='\n'.join(line.rstrip(' \t') for line in text.splitlines()).rstrip('\n')
    dst=base/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes((normalized+'\n' if normalized else '').encode())
    evidence.append({'path':dst.relative_to(ROOT).as_posix(),**fact(dst),'originalEvidence':{'path':src.relative_to(ROOT).as_posix(),**fact(src)},'normalization':'BOM-aware decode, UTF8/LF, trailing horizontal and empty EOF whitespace removed; raw byte facts retained'})
record={'schemaVersion':1,'recordedOn':'2026-10-21','status':'actual-V2-same-form-consumer-and-single-JVM-login-repair-integrated-unified-SDK-pending','reviewedCanonicalParent':head,'wholeV2Preparation':fact(vp),'rootComposition':fact(mp),'sourceFiles':m['files'],'V2ChangedSources':20,'totalComposedSources':21,'sourceOverlap':m['overlaps'],'scope':v2['scope'],'rootNativeRepair':login['scope'],'validation':v2['validation'],'newTestDefinitions':v2['newTestDefinitions'],'NativeLoginInfoMethodsAfterComposition':10,'rootReview':'Independently verified21 candidates/baselines/diffs and the three approved parent/composition reviews. All nine Root-reviewed Native methods and the new V2 Native method retain byte-identical function bodies; the changed Fixture uses the existing App owner and process-scoped JVM. Checked58 ported production hashes,127 actual JVM compilation inputs (one explicit validation-only heap stanza), exact8 XML method identities/zero failures,346 actual compiled JAR class byte bindings and embedded manifest/CRC. Existing JVM/Java/packaging results are reused at exact hashes, not repeated or promoted to Swift/SDK/JNI acceptance. V2 original parser, exact GSON marker admission, checked login-before-close, transient session/state projection, nullable select slots and owned rapid-source/close drainage are connected in the actual same View. Root credential owner now records an accepted irreversible commit before synchronous revision notifications can cancel its caller.','fixedReviewFindings':['Existing exhaustive Swift operation switch omitted new V2 cases.','Legal nullable select options could not decode into nonnullable Swift elements.','Source change during close could skip reload while the old exit still owned the drain.','Rapid A-to-B-wait-to-C source changes could publish the first pending replacement.','Native fixtures attempted another JVM/Host context after the product process already started.','Accepted Keychain notification could precede the irreversible Committed fact.'],'futureUnifiedCheckpoint':{'AppDefinitions':463,'AppExecutionLeaves':466,'NativeOriginalMethods':21,'NativeSeparateMainJSMethods':1,'freshPackageMethods':24,'newExplicitPackageFlagRequired':'loginv2','sourceClosureCounts':'Must be recomputed with Native reader repair and countgate controls; old324/115/22 does not describe this source.','actualAccepted':False},'preservedEvidence':evidence,'limits':v2['limits'],'queuedNativeRepair':'The actual210 Native terminal13 failures still require source/fixture/gate corrections and fresh execution. This source integration does not mark them passed.','deliveredBuild14Unchanged':True,'untrackedDebugLog':'Unrelated debug.log is untouched and not staged or used as evidence.',**{k:False for k in FLAGS}}
plan_path=ROOT/'docs/legado-ios/completion-plan.json';plan=read(plan_path);cloud=plan['execution']['cloudTriggerPolicy']
assert cloud['onlyLiveSDKHandles']==[] and all(plan[k] is False for k in FLAGS)
plan['activeBatchRecord']=record_path.relative_to(ROOT).as_posix()
steps=plan['execution']['stepByStep'];steps['originalLoginV2ActualConsumer']={'record':record_path.relative_to(ROOT).as_posix(),'changedProductionAndTestSources':21,'actualJVMMethodsPassed':8,'ordinaryJavaSessions':5,'newAppDefinitions':0,'newNativeDefinition':1,'newPackageDefinition':1,'actualSDKOrJNIExecuted':False}
steps['queuedReadyProductionForNextUnifiedCheckpoint']={'record':record_path.relative_to(ROOT).as_posix(),'AppDefinitions':463,'AppExecutionLeaves':466,'NativeOriginal':21,'NativeMainJS':1,'freshPackage':24,'sourceCountsPendingNativeReaderAndControls':True,'requiresActualNativeFailureRepairs':True}
c2=next(row for row in steps['steps'] if row['id']=='C2');c2['implementationEvidence'].append({'record':record_path.relative_to(ROOT).as_posix(),'scope':'Original V2 parser/admission and actual same-form UI, transient state/session/errors/countdown/nullable options and checked explicit login/close are integrated, with rapid source/close drainage. Exact JVM8/ordinary Java5 passed before later Native reader repairs; actual Swift/Package/JNI remains pending.'})
c2['nextActionZh']='把已就绪的V2登录与当前Native目录变量、测试夹具及数量门禁修复统一绑定并验证；浏览器宿主继续独立开发，完整书源兼容仍未完成。'
cloud['nextPlannedCheckpoint']='Ready V2 and Root single-process/accepted-effect-order sources are integrated while confirmedNative210 fixes are underway, avoiding another full SDK rebuild. Finish and review real directory/fixture repairs and bind one coherent App463/466, Native21+separateMainJS1 and fresh explicit Package loginv224 checkpoint with new exact source inventories. Preserve every old mode and required App signer. Browser work remains excluded; no old job repoll, per-item or device tag.'
for path,raw in sources.items():
    dst=ROOT/path;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(raw)
write(record_path,record);write(plan_path,plan)
paths=[ROOT/p for p in sources]+[base/name for name in items]+[record_path,plan_path]
assert len(paths)==len(set(paths))
write(STAGE/'canonical-roster.json',[{'path':p.relative_to(ROOT).as_posix(),**fact(p)} for p in paths])
subprocess.run([GIT,'diff','--check'],cwd=ROOT,check=True)
print(json.dumps({'reviewedPaths':len(paths),'sourceFiles':21,'actualJVMMethodsPassed':8,'reusedCompiledJarClassesVerified':346,'nextNativeOriginal':21,'nextFreshPackage':24,'actualSwiftSDKJNI':0,'newTags':0}))
