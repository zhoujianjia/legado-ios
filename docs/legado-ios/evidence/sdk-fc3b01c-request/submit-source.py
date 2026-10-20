from pathlib import Path
import datetime,hashlib,json,subprocess
R=Path('F:/yuedu-reader');G='D:/app/Git/cmd/git.exe';S=R/'.build/consolidated-sdk-header-v2-browser-checkpoint';O=S/'submission-v1.json'
def git(*args):return subprocess.check_output([G,*args],cwd=R)
def read(p):return json.loads(p.read_bytes())
def check(p,row):
 b=p.read_bytes();assert len(b)==row['bytes']and hashlib.sha256(b).hexdigest()==row['sha256'],str(p)
assert not O.exists();source=git('rev-parse','HEAD').decode().strip();assert all(x=='?? debug.log'for x in git('status','--porcelain').decode().splitlines())
plan=read(R/'docs/legado-ios/completion-plan.json');cloud=plan['execution']['cloudTriggerPolicy'];assert cloud['onlyLiveSDKHandles']==[]
assert cloud['latestSDKTerminal']['runID']==39501414740 and cloud['latestSDKTerminal']['queryAgain']is False
assert cloud['latestOriginalNativeTerminal']['runID']==39501416076 and cloud['latestOriginalNativeTerminal']['queryAgain']is False
for key in ['allNonDeviceWorkComplete','automaticSelfRenewalImplemented','fullLegadoCompatibilityEstablished','legalRedistributionClearanceEstablished']:assert plan[key]is False
record=read(R/'docs/legado-ios/core-original-source-header-v2-browser-step.json');assert record['sourceReviewFindings']==[]and record['changedSourceFiles']==15
c=record['countsForNextCheckpoint'];assert c['coreInputs']==338 and c['nativeInputs']==140 and c['uniqueInputUnion']==356 and c['NativeOriginalDefinitions']==26 and c['AppLeaves']==466
for row in record['sourceFiles']:check(R/row['path'],row['candidate'])
for row in record['preservedEvidence']:check(R/row['path'],row)
tags=['reader-renewal-'+source[:7],'legado-native-reader-test-'+source[:7]]
for tag in tags:
 assert subprocess.run([G,'show-ref','--verify','--quiet','refs/tags/'+tag],cwd=R).returncode==1
 assert not git('ls-remote','--tags','origin','refs/tags/'+tag).strip()
subprocess.run([G,'push','origin','legado-ios-prototype'],cwd=R,check=True)
for tag in tags:subprocess.run([G,'tag',tag,source],cwd=R,check=True)
subprocess.run([G,'push','--atomic','origin',*['refs/tags/'+t for t in tags]],cwd=R,check=True)
O.write_bytes((json.dumps({'schemaVersion':1,'submittedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceCommit':source,'tags':tags,'counts':c,'newIPATag':False,'POSTHeaderV2BrowserIncluded':True,'bothActual7576FailureRepairsIncluded':True,'actualSwiftSDKOrJNIResultYet':False,'oldTerminalJobsRepolled':False},indent=2)+'\n').encode())
print(json.dumps({'sourceCommit':source,'tags':tags,'newIPATag':False}))
