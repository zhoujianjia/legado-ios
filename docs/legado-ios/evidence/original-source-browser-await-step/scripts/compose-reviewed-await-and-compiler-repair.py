from pathlib import Path
import difflib,hashlib,json,subprocess
ROOT=Path('F:/yuedu-reader');GIT='D:/app/Git/cmd/git.exe';AWAIT=ROOT/'.build/original-source-login-browser-await-step';FIX=ROOT/'.build/sdk-8d-login-ui-form-typecheck-repair-step';OUT=ROOT/'.build/ready-browser-await-typecheck-source'
def fact(raw):return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def check(p,r):assert fact(p.read_bytes())=={k:r[k] for k in ('bytes','sha256')},str(p)
def read(p):return json.loads(p.read_bytes())
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
assert not OUT.exists()
head=subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip();assert head=='498144fceb3f5a9222f549ecd3d1ff1e15754473'
assert all(x=='?? debug.log' for x in subprocess.check_output([GIT,'status','--porcelain'],cwd=ROOT).decode().splitlines())
mp=AWAIT/'final-v1.json';fp=FIX/'final-v1.json'
check(mp,{'bytes':20899,'sha256':'127b01c4442e18d10d0ce3855cc9cef38d109b3d8753c4dc303264f33aeb22c4'});check(fp,{'bytes':3062,'sha256':'f2ade48b48db66e1aea31d37425877ac3f264874ea730000879a4e33b164a61b'})
reviews=[(ROOT/'.build/original-source-login-browser-await-independent-review/review.json',25847,'4daf8f69a151d0b54eb114a3c4eb9f2564e8b0695d681203f5eabb39344ebd76'),(ROOT/'.build/sdk-8d-login-ui-form-typecheck-independent-review/review.json',3485,'5b928832341ce6a29fe7f3456584290f1aed8a6734829ffe22e4b585c246f793')]
for p,size,sha in reviews:check(p,{'bytes':size,'sha256':sha})
m,f=read(mp),read(fp);sources={};origins={}
for r in m['files']:
    path=r['path'];p=AWAIT/'snapshot-v1/work'/path;check(p,r['candidate'])
    if r['baseline'] is None:assert not (ROOT/path).exists()
    else:check(ROOT/path,r['baseline'])
    sources[path]=p.read_bytes();origins[path]='reviewed-whole-Await-v1'
for r in m['unchangedInputs']:
    check(ROOT/r['path'],r);sources[r['path']]=(ROOT/r['path']).read_bytes();origins[r['path']]='unchanged-reviewed-Await-dependency'
r=f['file'];assert r['path'] not in sources;check(ROOT/r['path'],r['baseline']);check(FIX/'work'/r['path'],r['candidate']);sources[r['path']]=(FIX/'work'/r['path']).read_bytes();origins[r['path']]='actual-SDK-compiler-expression-repair'
assert len(sources)==15
ported='Packages/LegadoRuntime/vendor/original-rule/manifest.json';manifest=json.loads(sources[ported]);assert len(manifest['portedSources'])==58
for r in manifest['portedSources']:
    raw=sources[r['path']] if r['path'] in sources else (ROOT/r['path']).read_bytes();assert fact(raw)=={k:r[k] for k in ('bytes','sha256')},r['path']
rows=[]
for path,raw in sources.items():
    p=OUT/'work'/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(raw)
    before=(ROOT/path).read_bytes() if (ROOT/path).exists() else b'';d=OUT/'diffs'/(path+'.diff');d.parent.mkdir(parents=True,exist_ok=True);d.write_bytes(''.join(difflib.unified_diff(before.decode().splitlines(True),raw.decode().splitlines(True),fromfile='a/'+path,tofile='b/'+path)).encode())
    rows.append({'path':path,'baseline':fact(before) if before else None,'candidate':fact(raw),'changed':raw!=before,'origin':origins[path],'diff':{'path':d.relative_to(ROOT).as_posix(),**fact(d.read_bytes())}})
write(OUT/'preparation-v1.json',{'schemaVersion':1,'status':'reviewed-Await14-plus-disjoint-actual-compiler-repair1-source-composed-next-controls-pending','canonicalParent':head,'AwaitPreparation':{'path':mp.relative_to(ROOT).as_posix(),**fact(mp.read_bytes())},'compilerPreparation':{'path':fp.relative_to(ROOT).as_posix(),**fact(fp.read_bytes())},'reviews':[{'path':p.relative_to(ROOT).as_posix(),**fact(p.read_bytes())} for p,_,_ in reviews],'files':rows,'changedSources':sum(r['changed'] for r in rows),'unchangedInheritedSources':3,'portedSources':58,'sourceOverlap':0,'nativeOriginalMethodsNext':23,'separateMainJS':1,'AppDefinitionsUnchanged':463,'AppLeavesUnchanged':466,'PackageMethodsUnchanged':24,'actualNewSwiftSDKorJNI':0,'operations':{'canonical':False,'Git':False,'cloud':False}})
print(json.dumps({'sourceFiles':15,'changedSources':sum(r['changed'] for r in rows),'manifest':fact((OUT/'preparation-v1.json').read_bytes()),'newTags':0}))
