from pathlib import Path
import hashlib,json,subprocess
R=Path('F:/yuedu-reader');G='D:/app/Git/cmd/git.exe';S=R/'.build/consolidated-sdk-browser-await-two-repairs-checkpoint';O=S/'submission-v1.json'
def git(*args):return subprocess.check_output([G,*args],cwd=R)
def read(p):return json.loads(p.read_bytes())
def check(p,r):
 b=p.read_bytes();assert len(b)==r['bytes'] and hashlib.sha256(b).hexdigest()==r['sha256'],str(p)
assert not O.exists();source=git('rev-parse','HEAD').decode().strip()
assert all(l=='?? debug.log' for l in git('status','--porcelain').decode().splitlines())
plan=read(R/'docs/legado-ios/completion-plan.json');assert plan['execution']['cloudTriggerPolicy']['onlyLiveSDKHandles']==[]
for key in ['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']:assert plan[key] is False
record=read(R/'docs/legado-ios/core-original-source-browser-await-step.json');assert record['rootReview']['findings']==[] and record['changedSourceFiles']==18
assert record['countsForNextCheckpoint']['coreInputs']==334 and record['countsForNextCheckpoint']['nativeInputs']==136
for row in record['sourceFiles']:check(R/row['path'],row['candidate'])
for row in record['preservedEvidence']:check(R/row['path'],row)
for name in ['SDK','Native']:
 p=R/('docs/legado-ios/core-sdk-8d934dd-terminal-result.json' if name=='SDK' else 'docs/legado-ios/core-native-8d934dd-terminal-result.json');m=read(p);assert m['queryAgain'] is False
tags=['reader-renewal-'+source[:7],'legado-native-reader-test-'+source[:7]]
for tag in tags:
 assert subprocess.run([G,'show-ref','--verify','--quiet','refs/tags/'+tag],cwd=R).returncode==1
 assert not git('ls-remote','--tags','origin','refs/tags/'+tag).strip()
subprocess.run([G,'push','origin','legado-ios-prototype'],cwd=R,check=True)
for tag in tags:subprocess.run([G,'tag',tag,source],cwd=R,check=True)
subprocess.run([G,'push','origin',*['refs/tags/'+t for t in tags]],cwd=R,check=True)
O.write_bytes((json.dumps({'sourceCommit':source,'tags':tags,'counts':record['countsForNextCheckpoint'],'newIPATag':False,'GETAwaitIncluded':True,'POSTIncluded':False,'actualSwiftSDKOrJNIResultYet':False,'oldTerminalJobsRepolled':False},indent=2)+'\n').encode())
print(json.dumps({'sourceCommit':source,'tags':tags,'newIPATag':False}))
