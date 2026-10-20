from pathlib import Path
import hashlib
import json
import subprocess

ROOT=Path('F:/yuedu-reader');GIT='D:/app/Git/cmd/git.exe'
OUT=ROOT/'.build/consolidated-sdk-v2-native-repair-checkpoint/submission-v1.json'
def git(*args):return subprocess.check_output([GIT,*args],cwd=ROOT)
def read(p):return json.loads((ROOT/p).read_bytes())
def check(row,field=None):
    raw=(ROOT/row['path']).read_bytes();expected=row if field is None else row[field]
    assert len(raw)==expected['bytes'] and hashlib.sha256(raw).hexdigest()==expected['sha256'],row['path']
assert not OUT.exists()
source=git('rev-parse','HEAD').decode().strip();assert source.startswith('8d934dd')
status=git('status','--porcelain').decode().splitlines();assert all(line=='?? debug.log' for line in status),status
assert subprocess.run([GIT,'diff','--cached','--quiet'],cwd=ROOT).returncode==0
plan=read('docs/legado-ios/completion-plan.json');assert plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']==[]
for key in ['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']:assert plan[key] is False
record=read('docs/legado-ios/core-native-reader-v2-sdk-checkpoint.json')
assert record['status']=='reviewed-Native210-production-and-fixture-repairs-integrated-with-ready-V2-one-unified-cohort-pending'
assert record['counts']=={'AppDefinitions':463,'AppLeaves':466,'coreInputs':330,'NativeOriginalDefinitions':21,'NativeMainJSDefinitions':1,'nativeInputs':131,'PackageMethods':24,'PackageCompileInputs':16,'PackageControls':7,'PackageAllInputs':23}
assert len(record['sourceFiles'])==13 and len(record['sourceOwnerUnion'])==24 and record['review']['findings']==[]
for row in record['sourceFiles']:check(row,'candidate')
for row in record['sourceOwnerUnion']:check(row)
for row in record['preservedEvidence']:check(row)
tags=['reader-renewal-'+source[:7],'legado-native-reader-test-'+source[:7]]
for tag in tags:
    assert subprocess.run([GIT,'show-ref','--verify','--quiet','refs/tags/'+tag],cwd=ROOT).returncode==1
    assert not git('ls-remote','--tags','origin','refs/tags/'+tag).strip(),tag
subprocess.run([GIT,'push','origin','legado-ios-prototype'],cwd=ROOT,check=True)
for tag in tags:subprocess.run([GIT,'tag',tag,source],cwd=ROOT,check=True)
subprocess.run([GIT,'push','origin',*['refs/tags/'+tag for tag in tags]],cwd=ROOT,check=True)
OUT.write_bytes((json.dumps({'sourceCommit':source,'tags':tags,'counts':record['counts'],'newIPATag':False,'browserIncluded':False,'actualSDKOrJNIResultYet':False,'terminal210Repolled':False},indent=2)+'\n').encode())
print(json.dumps({'sourceCommit':source,'tags':tags,'newIPATag':False}))
