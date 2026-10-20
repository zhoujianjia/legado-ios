from pathlib import Path
import hashlib,json,zipfile
R=Path.cwd(); S=R/'.build/original-base64-flags-step'; O=Path(__file__).parent
checks=[]
def ok(value,label):
    assert value,label
    checks.append(label)
def fact(path):
    data=path.read_bytes(); return dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
def bound(row,base=S):
    p=base/row['path']; ok(fact(p)=={k:row[k] for k in ('bytes','sha256')},str(p)); return p
f=json.loads((S/'final-v1.json').read_bytes())
ok(fact(S/'final-v1.json')==dict(bytes=28240,sha256='27b823893c1989359f754d11e2fc80def917ed55cd8cd6eec23da21b6f4e7df4'),'frozen final')
for row in f['evidence']: bound(row)
for row in f['files']:
    bound(row['baseline']); bound(row['candidate']); bound(row['diff'])
    ok(fact(R/row['path'])=={k:row['baseline'][k] for k in ('bytes','sha256')},'live baseline '+row['path'])
for key in ('ordinaryJar','executedOrdinaryJar'): bound(f[key])
for row in f['parents']: bound(row,R)
primary=json.loads(bound(f['primary']).read_bytes())
for row in primary['sourceBaselines']+primary['lockedOriginal']: bound(row,R)
a=primary['androidPrimary']; src=bound(a['source'],R).read_bytes(); license=bound(a['license'],R).read_bytes()
ok(hashlib.sha1(b'blob '+str(len(src)).encode()+b'\0'+src).hexdigest()==a['gitBlobSHA1'],'Android Git blob')
oracle=json.loads(bound(f['oracle']).read_bytes()); oracleSource=bound(oracle['compiledOracle'],R).read_bytes()
expected=src
for line in oracle['removedLines']:
    ok(expected.count((line+'\n').encode())==1,'one removed annotation '+line)
    expected=expected.replace((line+'\n').encode(),b'')
ok(expected==oracleSource,'complete Android oracle exact except3 annotations')
old=json.loads((S/f['files'][2]['baseline']['path']).read_bytes()); new=json.loads((S/f['files'][2]['candidate']['path']).read_bytes())
ok(old['originalSources']==new['originalSources'] if 'originalSources' in old else True,'originalSource records unchanged when present')
for key in ('licenseFiles','runtimeResources'):
    ok(old.get(key)==new.get(key),'manifest '+key)
inputs=json.loads((S/'snapshot-v1/evidence/actual-jvm-compilation-inputs.json').read_bytes())['inputs']
candidate={row['path']:S/row['candidate']['path'] for row in f['files']}
ok(len(inputs)==128,'125main plus3 controls')
for row in inputs: bound(row,Path('.')) if row['path'].startswith('.build/') else ok(fact(candidate.get(row['path'],R/row['path']))=={k:row[k] for k in ('bytes','sha256')},'compile input '+row['path'])
parent=R/f['parents'][1]['path']
with zipfile.ZipFile(parent) as p, zipfile.ZipFile(S/f['executedOrdinaryJar']['path']) as e, zipfile.ZipFile(S/f['ordinaryJar']['path']) as z:
    for jar in (p,e,z): ok(jar.testzip() is None,'JAR CRC '+str(jar.filename)); ok(len(jar.namelist())==len(set(jar.namelist())),'unique entries '+str(jar.filename))
    ok(set(e.namelist())==set(z.namelist()),'final executed entry set')
    differences=[name for name in e.namelist() if e.read(name)!=z.read(name)]
    ok(differences==['META-INF/legado-provenance/original-rule/manifest.json'],'post-execution only metadata')
    ok(z.read(differences[0])==(S/f['files'][2]['candidate']['path']).read_bytes(),'embedded final manifest exact')
    licenseName='META-INF/legado-provenance/licenses/htmlunit-core-js/5.3.0-legado.4/LICENSE-APACHE-2.0.txt'
    candidates=[n for n in z.namelist() if n.endswith('htmlunit-core-js/5.3.0-legado.4/LICENSE-APACHE-2.0.txt')]
    ok(len(candidates)==1 and z.read(candidates[0])==license,'full existing Apache license exact')
    classes=json.loads((S/'snapshot-v1/evidence/production-class-binding.json').read_bytes())
    ok(len(classes['classes'])==408,'408 project production classes')
    fresh=retained=0
    for row in classes['classes']:
        name=row['path']; data=e.read(name)
        ok(dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())=={k:row[k] for k in ('bytes','sha256')},'production class '+name)
        ok(name in p.namelist(),'no new class '+name)
        if row['compiledThisIncrement']: fresh+=1
        else:
            retained+=1; ok(data==p.read(name),'exact retained '+name)
    ok((fresh,retained)==(39,369),'39fresh369retained')
    ok(not any(n.startswith('android/util/Base64') for n in z.namelist()),'oracle absent from product')
    otherChanged=[n for n in p.namelist() if n not in z.namelist() or p.read(n)!=z.read(n)]
    ok(not any(not(n.endswith('.class') or n.endswith('.kotlin_module') or n.endswith('original-rule/manifest.json')) for n in otherChanged),'no unrelated resource/license changes')
source=(S/f['files'][1]['candidate']['path']).read_text(encoding='utf-8'); base=(S/f['files'][1]['baseline']['path']).read_text(encoding='utf-8')
ok(source.startswith(base[:base.rfind('}')]),'old Hutool implementation exact')
actual=json.loads((S/'snapshot-v1/evidence/actual-public-oracle.json').read_bytes())
ok(actual==f['actual'],'actual consumer counts match final')
report=dict(version=1,reviewer='root independent of implementation author',frozenInput=fact(S/'final-v1.json'),checksPassed=len(checks),checks=checks,decision='accepted at ordinary JVM Base64 signature scope',reviewedImplementation='Six-state Android decoder and encode wrap/padding/url flags; original Hutool String/charset body unchanged; all five RuleJsExtensions implementers recompiled for return-descriptor ABI.',actual=actual,postExecutionChanges=differences,limits=f['proofLimits'],testsRerun=0,SDK_JNI=0)
(O/'review-v1.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(checks=len(checks),decision=report['decision'],sourceFiles=3,SDK_JNI=0)))
