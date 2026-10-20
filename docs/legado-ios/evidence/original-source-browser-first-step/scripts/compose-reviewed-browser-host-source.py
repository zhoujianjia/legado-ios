from pathlib import Path
import difflib,hashlib,json,subprocess
ROOT=Path('F:/yuedu-reader');GIT='D:/app/Git/cmd/git.exe'
STAGE=ROOT/'.build/original-source-login-browser-host-step';OUT=ROOT/'.build/ready-browser-host-final-source'
def fact(raw):return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def read(p):return json.loads(p.read_bytes())
def check(p,r):assert fact(p.read_bytes())=={k:r[k] for k in ('bytes','sha256')},str(p)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
assert not OUT.exists()
head=subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip();assert head.startswith('46123fb')
status=subprocess.check_output([GIT,'status','--porcelain'],cwd=ROOT).decode().splitlines();assert all(x=='?? debug.log' for x in status),status
fp=STAGE/'final-v1.json';check(fp,{'bytes':18446,'sha256':'189e1d74a3e1677a5444a26720ec59e1475c9a6f34afd08506192726cdeeed42'})
reviews=[(ROOT/'.build/original-source-login-browser-source-independent-review/review.json',16986,'d63c583975b9fc4307dd7763f287f0aa013587c0efac6406af2a48e93e380f05'),(ROOT/'.build/original-source-login-browser-source-independent-review/execution-review-v1.json',14603,'1652a56be35eef971180760b7fe96dad463f0da5ea65d556afb91d4ff0a578f2')]
for p,size,sha in reviews:check(p,{'bytes':size,'sha256':sha})
m=read(fp);sources={};ported='Packages/LegadoRuntime/vendor/original-rule/manifest.json'
for row in m['files']:
    path=row['path'];src=STAGE/'source-snapshot-v1/work'/path;check(src,row['candidate'])
    if path!=ported:
        if row['baseline'] is None:assert not (ROOT/path).exists()
        else:check(ROOT/path,row['baseline'])
    sources[path]=src.read_bytes()
for row in m['unchangedInputs']:
    check(ROOT/row['path'],row);check(STAGE/'source-snapshot-v1/work'/row['path'],row)
    sources[row['path']]=(ROOT/row['path']).read_bytes()
assert len(sources)==11
base_bytes=subprocess.check_output([GIT,'show','8cebe2023d0f3b9b3d8143d964b0c9bb2a6e7978:'+ported],cwd=ROOT)
author_old=json.loads(base_bytes);author_new=json.loads(sources[ported]);current_raw=(ROOT/ported).read_bytes();current=json.loads(current_raw)
assert len(author_old['portedSources'])==len(author_new['portedSources'])==len(current['portedSources'])==58
assert fact(base_bytes)==next(r['baseline'] for r in m['files'] if r['path']==ported)
oldrows={r['path']:r for r in author_old['portedSources']};newrows={r['path']:r for r in author_new['portedSources']}
changed={p for p in oldrows if oldrows[p]!=newrows[p]};assert len(changed)==4
merged=json.loads(current_raw)
for row in merged['portedSources']:
    if row['path'] in changed:
        assert row==oldrows[row['path']]
        assert {k:v for k,v in row.items() if k not in ('bytes','sha256')}=={k:v for k,v in newrows[row['path']].items() if k not in ('bytes','sha256')}
        row.update({k:newrows[row['path']][k] for k in ('bytes','sha256')})
for key in current:
    if key!='portedSources':assert merged[key]==current[key]
assert sum(a!=b for a,b in zip(current['portedSources'],merged['portedSources']))==4
reader_path='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleWebBookState.kt'
assert next(r for r in merged['portedSources'] if r['path']==reader_path)==next(r for r in current['portedSources'] if r['path']==reader_path)
assert next(r for r in merged['portedSources'] if r['path']==reader_path)['sha256']=='81c25a8ce0a566314cd9af53449928786672b9c451cc321cf3c7d651baf18267'
sources[ported]=(json.dumps(merged,ensure_ascii=False,indent=2)+'\n').encode()
for row in merged['portedSources']:
    raw=sources.get(row['path'],(ROOT/row['path']).read_bytes());assert fact(raw)=={k:row[k] for k in ('bytes','sha256')},row['path']
rows=[]
for path,raw in sources.items():
    dst=OUT/'work'/path;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(raw)
    old=(ROOT/path).read_bytes() if (ROOT/path).exists() else b''
    diff=OUT/'diffs'/(path+'.diff');diff.parent.mkdir(parents=True,exist_ok=True);diff.write_bytes(''.join(difflib.unified_diff(old.decode().splitlines(True),raw.decode().splitlines(True),fromfile='a/'+path,tofile='b/'+path)).encode())
    rows.append({'path':path,'baseline':fact(old) if old else None,'candidate':fact(raw),'changed':old!=raw,'diff':{'path':diff.relative_to(ROOT).as_posix(),**fact(diff.read_bytes())}})
write(OUT/'preparation-v1.json',{'schemaVersion':1,'status':'Browser-first-slice11-composed-with-current-Reader58-manifest-awaiting-coherent-next-checkpoint','canonicalParentObserved':head,'authorManifest':{'path':fp.relative_to(ROOT).as_posix(),**fact(fp.read_bytes())},'reviews':[{'path':p.relative_to(ROOT).as_posix(),**fact(p.read_bytes())} for p,_,_ in reviews],'files':rows,'portedSources':58,'changedPortedRows':sorted(changed),'retainedReaderMetadataRepairRow':True,'actualCombinedSDKorJNI':0,'BrowserAwaitIncluded':False,'current8dCloudSourceUnchanged':True,'operations':{'canonical':False,'Git':False,'cloud':False}})
print(json.dumps({'sources':11,'changed':sum(r['changed'] for r in rows),'portedRows':58,'changedPortedRows':4,'manifest':fact((OUT/'preparation-v1.json').read_bytes())}))
