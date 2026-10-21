from pathlib import Path
import contextlib,hashlib,importlib.util,io,json,shutil,subprocess,unittest
from unittest.mock import patch
R=Path('F:/yuedu-reader');S=R/'.build/s3-owned-temp-root-repair';REL='scripts/reader-experience/test-full-application-signing-tools.py'
METHOD='test_required_resource_hashes_and_cleanup_are_bound_without_minimal_substitution'
assert not S.exists();S.mkdir()
def fact(p):
 b=p.read_bytes();return {'path':p.relative_to(R).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def put(p,d):p.write_bytes((json.dumps(d,ensure_ascii=False,indent=2)+'\n').encode())
old=(R/REL).read_bytes();assert old.count(b'            root = Path(name)\n')==1
new=old.replace(b'            root = Path(name)\n',b'            # Resolve this owned temporary root before checking child resources;\n            # system temp-directory aliases must not change the input policy.\n            root = Path(name).resolve(strict=True)\n')
ps=S/'create-owned-junction.ps1';ps.write_bytes(b'param([string]$fixtureAliasPath,[string]$fixturePhysicalPath)\n$ErrorActionPreference = "Stop"\nNew-Item -ItemType Junction -Path $fixtureAliasPath -Target $fixturePhysicalPath | Out-Null\n')
results=[]
for label,data in [('baseline',old),('candidate',new)]:
 dest=S/label/REL;dest.parent.mkdir(parents=True);dest.write_bytes(data)
 tool=dest.with_name('full-application-signing-tools.py');shutil.copyfile(R/'scripts/reader-experience/full-application-signing-tools.py',tool)
 physical=S/(label+'-physical');physical.mkdir();alias=S/(label+'-alias')
 assert physical.resolve().is_relative_to(S.resolve()) and alias.absolute().is_relative_to(S.absolute()) and not alias.exists()
 subprocess.run(['powershell','-NoProfile','-NonInteractive','-File',str(ps),str(alias),str(physical)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 assert alias.is_junction() and alias.resolve(strict=True)==physical.resolve(strict=True)
 spec=importlib.util.spec_from_file_location('owned_temp_fixture_'+label,dest);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 log=io.StringIO()
 with patch.object(module.tempfile,'TemporaryDirectory',return_value=contextlib.nullcontext(str(alias))):
  result=unittest.TextTestRunner(stream=log,verbosity=2).run(module.FullApplicationSigningProtocolTests(METHOD))
 (S/(label+'-existing-method.log')).write_bytes(log.getvalue().replace('\r\n','\n').encode())
 if label=='baseline':assert len(result.errors)==1 and not result.failures and 'Symlinked full-application input/output is forbidden' in result.errors[0][1]
 else:assert result.wasSuccessful() and result.testsRun==1 and not result.skipped
 results.append({'kind':label,'method':'FullApplicationSigningProtocolTests.'+METHOD,'executed':result.testsRun,'errors':len(result.errors),'failures':len(result.failures),'skipped':len(result.skipped),'actualOwnedJunction':True,'physicalRootVerified':True,'log':fact(S/(label+'-existing-method.log'))})
diff=subprocess.run(['D:/app/Git/cmd/git.exe','diff','--no-index','--',str(S/'baseline'/REL),str(S/'candidate'/REL)],stdout=subprocess.PIPE);assert diff.returncode==1
(S/'fixture-only.diff').write_bytes(diff.stdout)
put(S/'final-v1.json',{'schemaVersion':1,'status':'candidate-one-existing-method-alias-regression-passed','files':[{'path':REL,'baseline':fact(S/'baseline'/REL),'candidate':fact(S/'candidate'/REL)}],'productionToolUnchanged':fact(R/'scripts/reader-experience/full-application-signing-tools.py'),'reason':'The real Mac Native job failed this resource protocol test when checked rejected a symlink ancestor. Canonicalize only the test-owned temporary root. The raw log does not identify which system alias; this local actual NTFS-junction replay reproduces rejection and verifies the fix.','actualExecutions':results,'actualDistinctMethods':1,'actualRelevantCandidatePassed':1,'actualMacReruns':0,'actualSDKOrSigningExecuted':0,'baselineCloudRun':39537665402,'baselineCloudJob':119017948098,'fullDeviceBuildReached':False,'productionChanges':0,'newTestDefinitions':0,'diff':fact(S/'fixture-only.diff'),'sourceHelper':fact(Path(__file__)),'canonicalWrites':False,'newTags':0})
print(json.dumps({'candidate':fact(S/'final-v1.json'),'actualDistinctMethod':1,'baselineAliasErrors':1,'candidateAliasPass':1,'productionChanges':0,'actualMacReruns':0}))
