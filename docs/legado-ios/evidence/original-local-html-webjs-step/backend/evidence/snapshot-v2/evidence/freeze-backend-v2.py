from pathlib import Path
import datetime,difflib,hashlib,json,shutil
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';B=S/'rawbaseline';D=S/'snapshot-v2';assert not D.exists();D.mkdir()
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def ref(p):return dict(path=p.relative_to(R).as_posix(),**fact(p))
def copy(p,to):to.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,to);assert fact(p)==fact(to)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
first=json.loads((S/'backend-final-v1.json').read_text(encoding='utf-8'));m=json.loads(json.dumps(first));m['version']=2;m['frozenUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();m['supersedes']=ref(S/'backend-final-v1.json');m['candidateRoot']='snapshot-v2/work';m['baselineRoot']='snapshot-v2/rawbaseline';m['baseline']['interface']=ref(S/'interface-v4.json')
files=[]
for row in first['files']:
 rel=row['path'];p=W/rel;b=B/rel;copy(p,D/'work'/rel)
 if b.exists():copy(b,D/'rawbaseline'/rel)
 diff=D/'diffs'/(rel+'.diff');diff.parent.mkdir(parents=True,exist_ok=True);diff.write_text(''.join(difflib.unified_diff(b.read_text(encoding='utf-8').splitlines(keepends=True)if b.exists()else[],p.read_text(encoding='utf-8').splitlines(keepends=True),fromfile='a/'+rel if b.exists()else'/dev/null',tofile='b/'+rel)),encoding='utf-8',newline='\n')
 files.append(dict(path=rel,baseline=fact(b)if b.exists()else None,candidate=fact(p),baselineSnapshot='snapshot-v2/rawbaseline/'+rel if b.exists()else None,candidateSnapshot='snapshot-v2/work/'+rel,diff=dict(path=diff.relative_to(S).as_posix(),**fact(diff))))
m['files']=files
assert len(files)==8
changed=[r['path']for r in files if r['candidate']!=next(o['candidate']for o in first['files']if o['path']==r['path'])]
assert len(changed)==2 and any(p.endswith('OriginalWebJsPageRuntime.kt')for p in changed)and any(p.endswith('manifest.json')for p in changed)
comp5=json.loads((S/'compile-attempt5/commands.json').read_text());comp6=json.loads((S/'compile-attempt6/commands.json').read_text());assert comp5['exitCode']==comp6['exitCode']==0
for row in comp5['sources']:
 if row['path'].endswith('OriginalWebJsPageRuntime.kt'):continue
 assert fact(Path(row['path']))=={k:row[k]for k in ('bytes','sha256')}
for row in comp6['sources']:assert fact(Path(row['path']))=={k:row[k]for k in ('bytes','sha256')}
jar=S/'ordinary-v4/legado-runtime-local-webjs.jar';copy(jar,D/'legado-runtime.jar');m['ordinaryJar']=dict(path='snapshot-v2/legado-runtime.jar',**fact(jar))
commands=json.loads((S/'ordinary-v4/ordinary-commands.json').read_text());assert all(r['exitCode']==0 for r in commands['commands']);assert commands['jar']['sha256']==fact(jar)['sha256'];assert fact(S/'OrdinaryLocalWebJs.java')=={k:commands['source'][k]for k in ('bytes','sha256')}
evidence=[dict(**r,inheritedFromBackendV1=True)for r in first['evidence']]
names=['backend-final-v1.json','interface-v4.json','prepare-interface-v4.py','compile-production-v6.py','assemble-ordinary-v4.py','run-ordinary-v5.py','verify-packaging-v3.py','freeze-backend-v2.py','actual-jvm-compilation-inputs.json','ordinary-jar-inspected-v3.json','packaging-tests-v3.log','OrdinaryLocalWebJs.java','compile-attempt6/commands.json','compile-attempt6/compile.log','ordinary-v4/production-binding.json','ordinary-v4/ordinary-commands.json','ordinary-v4/compile-consumer.log','ordinary-v4/execute-consumer.log']
for name in names:
 p=S/name;to=D/'evidence'/name;copy(p,to);evidence.append(dict(path=to.relative_to(S).as_posix(),**fact(to)))
m['evidence']=evidence;m['consumer']=dict(path='snapshot-v2/evidence/OrdinaryLocalWebJs.java',**fact(S/'OrdinaryLocalWebJs.java'),scope='Final81-call independent ordinary Java process: final89f770 JAR plus consumer classes only; no JUnit/test dirs/UIKit. Eleven source.browser synthetic Host calls are not presentation ACKs.')
m['counts']['finalOrdinaryJavaPublicCalls']=81;m['counts']['finalCheckedStateCommits']=7
m['wire']['requestMethods'][0]='request(run/ajaxAwait/connectAwait/getStringAwait), <=64 wire args then original first6; direct methods <=6'
m['wire']['requestMethods'].append('cache.get(key,onlyDisk=false) preserves disk/memory distinction')
m['history'].append(dict(kind='Independent source review P2',supersededVersion=1,changedSources=changed,cause='Direct cache.get silently ignored original second onlyDisk Boolean. Existing RuleCache already supports it.',fix='Forward actual Boolean to same RuleCache.get; no cache owner/store added. Async request additionally retains original first-six truncation under explicit64-wire limit.',actualRegression='Disk value plus different memory overlay: default/false returns memory; true returns disk. Seven async params truncate to original six and callback uses same cache consume/delete.',compilation='Only Page Kotlin source recompiled in attempt6 against bound072f ordinary JAR. Other six candidate main source outputs are reused exact attempt5; final59 recompiled-union blobs and349 df6f retained blobs are separately bound.',unchangedValidation='Prior60/63/69/72-call runs remain historical passes against their own exact JARs and sources. Final81-call run+six packaging guards use final89f770 JAR. No old JVM suite rerun.' ))
m['actualVectors'].extend(['cache.get onlyDisk=true returns actual persistent disk value despite explicit different same-owner memory overlay; default/false retain memory priority.', 'Original request accepts7 synthetic string params and truncates to original first6; callback result is consumed/deleted through existing memory.'])
m['limits'][0]='Precise combined seven-source K2 overlay on coherent df6f ordinary JAR, NOT fresh Gradle: six main outputs exact attempt5, Page review-P2 source exact attempt6 (one-source compiler on bound072f intermediateJAR). 118 other main source inputs and349 retained production blobs exact df6f. Existing module metadata retained; no new top-level declaration.'
m['limits']=[s.replace('128-page request/child controls','Page/request/child controls')for s in m['limits']]
write(S/'backend-final-v2.json',m);print(json.dumps(ref(S/'backend-final-v2.json')))
