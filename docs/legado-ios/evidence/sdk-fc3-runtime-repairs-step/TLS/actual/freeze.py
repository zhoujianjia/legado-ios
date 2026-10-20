from pathlib import Path
import datetime,difflib,hashlib,json,re,shutil,sys
R=Path('F:/yuedu-reader');S=Path(__file__).parent;D=S/'snapshot-v1';D.mkdir(exist_ok=False)
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
def f(p):b=p.read_bytes();return {'path':str(p.relative_to(R)).replace('\\','/'),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def save(p,o):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
def grammar(b):
 t=parser.parse(b);pending=[t.root_node];errors=[]
 while pending:
  n=pending.pop()
  if n.is_error or n.is_missing:errors.append({'type':n.type,'start':list(n.start_point),'end':list(n.end_point)})
  pending+=n.children
 return errors
files=[];grammars=[];tests=[]
for src in sorted((S/'work').rglob('*.swift')):
 rel=src.relative_to(S/'work');before=S/'rawbaseline'/rel;ck=(R/rel).read_bytes();assert ck==before.read_bytes(),str(rel)
 for directory,p in [('work',src),('rawbaseline',before)]:
  dest=D/directory/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
 a=before.read_text(encoding='utf-8');b=src.read_text(encoding='utf-8');diff=''.join(difflib.unified_diff(a.splitlines(keepends=True),b.splitlines(keepends=True),fromfile='a/'+rel.as_posix(),tofile='b/'+rel.as_posix()))
 dp=D/'diffs'/(rel.as_posix()+'.diff');dp.parent.mkdir(parents=True,exist_ok=True);dp.write_text(diff,encoding='utf-8',newline='\n')
 files.append({'path':rel.as_posix(),'baseline':f(D/'rawbaseline'/rel),'candidate':f(D/'work'/rel),'diff':f(dp)})
 for label,p in [('baseline',before),('candidate',src)]:grammars.append({'source':rel.as_posix(),'variant':label,'errors':grammar(p.read_bytes())})
 if '@Test'in a:
  pat=r'(?m)^\s*@Test(?:\([^\r\n]*\))?\s+(?:@MainActor\s+)?func\s+(\w+)\(([^)]*)\)'
  old=re.findall(pat,a);new=re.findall(pat,b);assert old==new;assert len(old)==len(re.findall(r'(?m)^\s*@Test\b',a))
  tests.append({'path':rel.as_posix(),'unchangedDefinitions':len(old),'declarations':old})
assert len(files)==4 and len(grammars)==8 and all(not v['errors']for v in grammars)
save(D/'evidence/grammar.json',{'roots':8,'newErrors':0,'facts':grammars,'scope':'Tree-sitter syntax only; not Swift typechecking/SDK/TLS execution'})
save(D/'evidence/test-identities.json',{'newDefinitions':0,'facts':tests})
prod=(S/'work/Modules/Services/SelfRenewal/SelfRenewalAuthenticatedDeviceStream.swift').read_text(encoding='utf-8');oldprod=(S/'rawbaseline/Modules/Services/SelfRenewal/SelfRenewalAuthenticatedDeviceStream.swift').read_text(encoding='utf-8')
# Only the final client-cert-state check/comment block changes in production.
start=oldprod.index('                guard var clientState =');end=oldprod.index('                var version =',start)
newstart=prod.index('                if !server {\n                    guard var clientState =');newend=prod.index('                var version =',newstart)
assert prod[:newstart]==oldprod[:start]and prod[newend:]==oldprod[end:]
fixture=(S/'work/Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationFixture.swift').read_text(encoding='utf-8')
assert all(f'defer {{ {n}.continuation.finish() }}'in fixture for n in ['signal','removalSignal','lookupSignal'])
recovery=(S/'work/Tests/iOS/yuedu appTests/SelfRenewalInstallationRecoveryTests.swift').read_text(encoding='utf-8')
assert 'submission!'not in recovery and len(re.findall(r'try await Self.interrupt\(',recovery))==7 and not re.search(r'(?<!try )await Self.interrupt\(',recovery)
primary=json.loads((S/'primary-binding.json').read_bytes());assert len([v for v in primary['files']if v['path'].endswith('.c')])==9
primaryC=list((S/'primary/OSX/libsecurity_ssl/lib').glob('*.c'));assign=[]
for p in primaryC:
 for i,line in enumerate(p.read_text().splitlines(),1):
  if re.search(r'\bclientCertState\s*=(?!=)',line):assign.append({'path':p.name,'line':i,'text':line.strip()})
assert assign==[{'path':'tlsCallbacks.c','line':69,'text':'myCtx->clientCertState = kSSLClientCertRequested;'}]
shutil.copytree(S/'primary',D/'primary');shutil.copyfile(S/'primary-binding.json',D/'primary-binding.json')
log=R/'.build/sdk-fc3b01c-terminal/extracted-12307712232/reader-renewal-probe/currentcore-tests.log';lines=log.read_text(encoding='utf-8',errors='replace').splitlines()
vectors=[]
needles=['missingMutualAuthentication','SelfRenewalInstallationRecoveryTests.swift:149: Fatal error','SelfRenewalInstallationRecoveryTests.swift:135:','SelfRenewalInstallationRecoveryTests.swift:142:']
for i,line in enumerate(lines,1):
 if any(x in line for x in needles)and ('recorded an issue'in line or 'Fatal error'in line):vectors.append({'line':i,'text':line[:3000]})
save(D/'evidence/actual-fc3-failure-excerpts.json',{'rawWholeLog':f(log),'matches':vectors,'actualStateOrRoleCapturedInLog':False,'sourceInferenceNotLocalTLSPass':True})
save(D/'evidence/primary-state-analysis.json',{'primaryBinding':f(D/'primary-binding.json'),'serverPublicHeaderPromisesSent':True,'completePinnedDirectoryCSourceCount':9,'clientStateAssignments':assign,'assignmentRoleAssertion':'tlsCallbacks.c67 asserts kSSLClientSide before the only assignment','serverGetter':'sslContext.c1744-1754 reports Sent only when internal clientCertState was Requested plus peerSecTrust exists','scope':'Primary implementation explains why a server-only readiness decision must use actual fresh pinned client trust and completed mutual handshake, not the client-only state field. Raw role/state was not captured in historical fc3; future actual SDK remains necessary.'})
for name in ['implement.py','primary.py','freeze.py']:shutil.copyfile(S/name,D/'evidence'/name)
save(D/'evidence/source-invariants.json',{'productionChange':'Only final role-aware state gate block; all socket/handshake/time/limits/key-possession/CA-DER-date trust verification unchanged byte-for-byte outside block','clientStillRequiresSent':True,'serverStillAlwaysAuthenticateFreshClientAuthPinnedTrustCompletedTLS12':True,'streamFinishOwnedByEachProducingPeer':True,'noNewTimerOrBudgetRelaxation':True,'recoveryHelpersRequireRealUploadIntentAndSubmission':True,'oldTestDefinitionsRetained':sum(v['unchangedDefinitions']for v in tests),'newTestDefinitions':0})
result={'version':1,'frozenUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Actual fc3 TLS server-state rejection hypothesis constrained by pinned official primary; proven test-event producer termination deadlock and recovery precondition/unwrap fixes. No local SecureTransport/Swift SDK execution.','candidateRoot':'snapshot-v1/work','baselineRoot':'snapshot-v1/rawbaseline','files':files,'primary':f(D/'primary-binding.json'),'actualSDKSource':'fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a','actualFailureEvidence':f(D/'evidence/actual-fc3-failure-excerpts.json'),
 'securityContract':{'clientCertificateSentRequired':True,'serverRequiresConfiguredAlwaysAuth':True,'serverFreshPeerAuthenticationBreakRequired':True,'bothPeerChainCAPinDERPinDateChecksRetained':True,'completeTLSHandshakeKeyPossessionRequired':True,'TLS12AndNoCacheNoRenegotiationRetained':True,'noTLSFallbackNoTrustRelaxation':True},
 'testChanges':{'definitionsAdded':0,'definitionsRetained':sum(v['unchangedDefinitions']for v in tests),'cancelRegression':'Existing cancellation test now waits for the actual peer-owned lookup stream to finish after its cancelled network operation has drained. No timer/sleep.','failureHandling':'Early event termination cancels and drains existing operation before #require stops the test; recovery interrupt requires real uploadIntent/submission before cleanup checks; forced unwrap removed.'},
 'validation':{'treeSitterRoots':8,'syntaxErrors':0,'productionOutsideHunkByteExact':True,'testIdentitiesExact':True,'SwiftSDKTestsExecuted':0,'TLSHandshakesExecutedHere':0,'cloudOrGitMutation':False},
 'evidence':[f(p)for p in sorted((D/'evidence').rglob('*'))if p.is_file()],
 'futureHarness':'All four source paths already exist; no added @Test/selector/parameter leaf/source path. Rebind final4 bytes in a future coherent SDK closure; no new tag or current snapshot change performed.',
 'limits':['Official source pin explains legacy role-state mismatch but historical log did not record numericstate/side; do not call a local reproduced or SDK-proven fix','Event-stream/forceunwrap defects are source-proven; actual regressions remain pending Swift SDK','No physicaldevice/Apple pairing/installation/automaticrenewal acceptance','No increase to budgets, security downgrade, new owner/VM/store/transport']}
save(S/'final-v1.json',result);print('FROZEN',f(S/'final-v1.json'),'defs',result['testChanges']['definitionsRetained'])
