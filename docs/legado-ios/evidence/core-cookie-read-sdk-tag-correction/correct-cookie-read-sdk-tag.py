from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path('F:/yuedu-reader'); GIT='D:/app/Git/cmd/git.exe'
request=json.loads((ROOT/'docs/legado-ios/core-cookie-read-sdk-request.json').read_bytes())
COMMIT=request['sourceCommit']; TAG='reader-renewal-'+COMMIT[:7]
OUT=ROOT/'.build/renewal-discovery/cookie-read-sdk-tag-correction.json'
assert not OUT.exists() and len(COMMIT)==40 and TAG=='reader-renewal-9105b46'
assert request['sourceTag'] != TAG
assert subprocess.run([GIT,'show-ref','--verify','--quiet','refs/tags/'+TAG],capture_output=True).returncode==1
selection=json.loads((ROOT/'docs/legado-ios/evidence/core-cookie-read-sdk-checkpoint/portable-v1.json').read_bytes())
assert len(selection['sourceInputs'])==175
for row in selection['sourceInputs']:
    raw=subprocess.check_output([GIT,'show',COMMIT+':'+row['path']])
    assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
subprocess.run([GIT,'tag',TAG,COMMIT],check=True,capture_output=True)
pushed=subprocess.run([GIT,'push','origin','refs/tags/'+TAG],capture_output=True)
value={'schemaVersion':1,'recordedAtUTC':datetime.now(timezone.utc).isoformat(),
    'sourceCommit':COMMIT,'incorrectSourceTag':request['sourceTag'],'sourceTag':TAG,
    'tagDerivedFromFullCommitPrefix':True,'tagPushExitCode':pushed.returncode,
    'stdout':pushed.stdout.decode('utf-8',errors='replace'),'stderr':pushed.stderr.decode('utf-8',errors='replace'),
    'sourceChanges':0,'localTestsRepeated':0,'originalFailedTagPreserved':True,'newRunStatusObserved':False}
OUT.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
assert pushed.returncode==0
print(json.dumps({k:value[k] for k in ('sourceCommit','sourceTag','tagPushExitCode','sourceChanges','newRunStatusObserved')}))
