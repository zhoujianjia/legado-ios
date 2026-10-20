from pathlib import Path
import hashlib,json,shutil
R=Path('F:/yuedu-reader');A=R/'.build/ready-browser-await-typecheck-source';B=R/'.build/native-8d-external-open-repair-step';O=R/'.build/ready-browser-await-two-compiler-repairs-source'
def read(p):return json.loads(p.read_bytes())
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
assert not O.exists();m=read(A/'preparation-v1.json');check(A/'preparation-v1.json',{'bytes':12269,'sha256':'10ee79b0250310bf29ff1da01aada2df4a895a950a7b6e61362278256237f225'})
check(B/'final-v1.json',{'bytes':2466,'sha256':'691e543d498f2517446051cee7ecf8b6bfa4612b7096af31ee04cd5aa473ea6d'})
rp=R/'.build/native-8d-external-open-independent-review/review.json';check(rp,{'bytes':3046,'sha256':'63fb9cbbf7cf398f024154eda38056eb66a47969de7339c055cd8f6e435ebc0d'})
rows=m['files'];f=read(B/'final-v1.json')['file'];assert f['path'] not in {r['path'] for r in rows}
for row in rows:
 check(A/'work'/row['path'],row['candidate'])
 if row['baseline'] is None:assert not (R/row['path']).exists()
 else:check(R/row['path'],row['baseline'])
 p=O/'work'/row['path'];p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(A/'work'/row['path'],p)
check(R/f['path'],f['baseline']);check(B/'work'/f['path'],f['candidate']);p=O/'work'/f['path'];p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(B/'work'/f['path'],p)
rows.append({'path':f['path'],'baseline':f['baseline'],'candidate':f['candidate'],'changed':True,'origin':'actual-Native8d-explicit-completion-open-overload-repair','diff':{'path':(B/'source.diff').relative_to(R).as_posix(),**fact(B/'source.diff')}})
m['files']=rows;m['status']='reviewed-Await14-plus-two-disjoint-actual-compiler-repairs-source-composed-next-controls-pending';m['changedSources']=13;m['compilerRepairs']=2;m['sourceFiles']=16;m['previousComposition']={'path':(A/'preparation-v1.json').relative_to(R).as_posix(),**fact(A/'preparation-v1.json')};m['nativeCompilerPreparation']={'path':(B/'final-v1.json').relative_to(R).as_posix(),**fact(B/'final-v1.json')};m['reviews'].append({'path':rp.relative_to(R).as_posix(),**fact(rp)});m['historicalSDK8dRecord']='docs/legado-ios/core-sdk-8d934dd-terminal-result.json';m['actualNewSwiftSDKorJNI']=0
out=O/'preparation-v1.json';out.write_bytes((json.dumps(m,ensure_ascii=False,indent=2)+'\n').encode());print(json.dumps({'manifest':fact(out),'sourceFiles':16,'changedSources':13,'SDKorJNI':0}))
