from pathlib import Path
import hashlib,json,subprocess
R=Path('F:/yuedu-reader');A=R/'.build/original-source-login-browser-post-step';O=R/'.build/ready-browser-post-source';G='D:/app/Git/cmd/git.exe'
def fact(p):
 b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def read(p):return json.loads(p.read_bytes())
def check(p,r):assert fact(p)=={k:r[k] for k in ('bytes','sha256')},str(p)
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(v,ensure_ascii=False,indent=2)+'\n').encode())
assert not O.exists();mp=A/'final-v2.json';check(mp,{'bytes':18097,'sha256':'cf642f24b6f8a9fceec2feb2c34427d6c6e4c65909dcd45c80cb625c9b7749fc'})
rp=R/'.build/original-source-login-browser-post-independent-review/review.json';check(rp,{'bytes':21052,'sha256':'8425d5c135837b431c422fcf02179003660d5b74092011fcc8e89448735c4f29'})
m=read(mp);assert len(m['files'])==9
for row in m['files']:
 p=row['path'];check(A/'snapshot-v2/work'/p,row['candidate'])
 if row['baseline'] is None:assert not (R/p).exists()
 else:check(R/p,row['baseline'])
 dst=O/'work'/p;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes((A/'snapshot-v2/work'/p).read_bytes());check(A/row['diff']['path'],row['diff'])
for row in m['evidence']:check(A/row['path'],row)
record={'schemaVersion':1,'status':'reviewed-original-POST9-source-composed-next-controls-and-actual-Native-stale-guard-repair-pending','canonicalParent':subprocess.check_output([G,'rev-parse','HEAD'],cwd=R).decode().strip(),'sourcePreparation':{'path':mp.relative_to(R).as_posix(),**fact(mp)},'sourceReview':{'path':rp.relative_to(R).as_posix(),**fact(rp)},'files':m['files'],'changedSources':9,'AppDefinitionsUnchanged':463,'AppLeavesUnchanged':466,'NativeOriginalNext':24,'MainJSSeparate':1,'PackageMethodsUnchanged':24,'actualSwiftSDKOrJNI':0,'operations':{'canonical':False,'Git':False,'cloud':False}}
write(O/'preparation-v1.json',record);print(json.dumps({'manifest':fact(O/'preparation-v1.json'),'sources':9,'NativeNext':24}))
