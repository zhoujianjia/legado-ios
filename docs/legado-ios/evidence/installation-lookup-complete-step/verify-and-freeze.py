from pathlib import Path
import datetime,difflib,hashlib,json,re,sys
R=Path('F:/yuedu-reader');S=R/'.build/s4-authenticated-installation-gap-step'
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
def rf(b):return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def fact(p):return {'path':p.relative_to(S).as_posix(),**rf(p.read_bytes())}
def save(p,x):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((json.dumps(x,ensure_ascii=False,indent=2)+'\n').encode())
paths=['Modules/Services/SelfRenewal/SelfRenewalAuthenticatedInstallationClient.swift','Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationFixture.swift','Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests.swift']
grammars=[];trees={};files=[]
for root in ['rawbaseline','work']:
 for path in paths:
  p=S/root/path;b=p.read_bytes();tree=parser.parse(b);stack=[tree.root_node];errors=[];functions={}
  while stack:
   n=stack.pop()
   if n.type=='ERROR' or n.is_missing:errors.append({'type':n.type,'missing':n.is_missing,'line':n.start_point.row+1})
   if n.type=='function_declaration':
    name=n.child_by_field_name('name');assert name is not None
    functions.setdefault(b[name.start_byte:name.end_byte].decode(),[]).append(b[n.start_byte:n.end_byte])
   stack.extend(n.children)
  assert not errors,(path,errors)
  grammars.append({'root':root,'path':path,**rf(b),'errors':errors,'rootHasError':tree.root_node.has_error})
  trees[root,path]=functions
save(S/'swift-grammar.json',{'scope':'Tree-sitter syntax only, not Swift SDK typechecking or test execution','roots':grammars,'errors':0})
prod=paths[0];old=(S/'rawbaseline'/prod).read_bytes();new=(S/'work'/prod).read_bytes()
start=b'    private static func lookupOn(';end=b'    static func startService('
assert old.split(start)[0]==new.split(start)[0] and old.split(end)[1]==new.split(end)[1]
oldFunctions=trees['rawbaseline',prod];newFunctions=trees['work',prod]
assert oldFunctions.keys()==newFunctions.keys()
assert [n for n in oldFunctions if oldFunctions[n]!=newFunctions[n]]==['lookupOn']
test=paths[2];oldTests=trees['rawbaseline',test];newTests=trees['work',test]
names=re.findall(r'@Test\s+func (\w+)\(', (S/'rawbaseline'/test).read_text(encoding='utf-8'))
assert names==re.findall(r'@Test\s+func (\w+)\(', (S/'work'/test).read_text(encoding='utf-8')) and len(names)==7
changed=[n for n in oldTests if oldTests[n]!=newTests[n]]
assert set(changed)=={'requiresTerminalCompleteAndExactPostUpgradeLookupIdentity','cancellationWakesActualStalledTLSHandshakeWithoutLateWrites','enforcesActualFrameProgressDeadlineAndArchiveBudgets'}
for n in changed:
 assert len(oldTests[n])==len(newTests[n])==1
 assert newTests[n][0].startswith(oldTests[n][0].rstrip()[:-1].rstrip())
for path in paths:
 b=(S/'rawbaseline'/path).read_bytes();a=(S/'work'/path).read_bytes();assert (R/path).read_bytes()==b
 dp=S/'diffs'/(path+'.diff');dp.parent.mkdir(parents=True,exist_ok=True)
 dp.write_bytes(''.join(difflib.unified_diff(b.decode().splitlines(True),a.decode().splitlines(True),fromfile='a/'+path,tofile='b/'+path)).encode())
 files.append({'path':path,'baseline':rf(b),'candidate':rf(a),'diff':fact(dp)})
primary=json.loads((S/'primary-binding.json').read_bytes())
for row in primary['files']:
 p=R/row['path'];assert rf(p.read_bytes())=={k:row[k]for k in ('bytes','sha256')}
reference=(S/'primary/installation_proxy.c').read_text(encoding='utf-8')
assert 'res = instproxy_perform_command(client, command, INSTPROXY_COMMAND_TYPE_SYNC, instproxy_copy_lookup_result_cb' in reference
callback=reference.split('static void instproxy_copy_lookup_result_cb',1)[1].split('instproxy_error_t instproxy_lookup',1)[0]
assert '*result = plist_copy(node);' in callback and 'plist_dict_merge' not in callback
stream=R/'Modules/Services/SelfRenewal/SelfRenewalAuthenticatedDeviceStream.swift'
facts={'schemaVersion':1,'scope':'Source/API/fixture interaction observations, not executed Swift or mirrored protocol-test pass','production':{'onlyChangedMethod':'SelfRenewalAuthenticatedInstallationClient.lookupOn','unchangedOtherProductionFunctions':sorted(n for n in oldFunctions if n!='lookupOn'),'transportOwner':{'path':stream.relative_to(R).as_posix(),**rf(stream.read_bytes())},'TLSAndStartServicePolicyUnchanged':True,'samePlistChannelDeadlineCancellationAndSocket':True,'maximumMessages':256,'maximumResponseBytes':8388608,'errorFrameRejectedBeforeResultProcessing':True,'sameOrSeparateCompleteAndLookupResultAccepted':True,'multipleResultSemantics':'Last complete LookupResult snapshot replaces the prior one, matching upstream callback; not dictionary merging. Single BundleID guard remains strict.','lookupAndReceiptPublishedOnlyAfterComplete':True,'priorUpgradeReportedCompleteFailureCleanupPreserved':True,'profileAndAuthorityFalseFlagBytesUnchanged':True},'fixture':{'sameOwnedLoopbackTLSAndKeys':True,'defaultLookupRepliesNowIncludeStatusComplete':True,'customReplyPacketsGoThroughActualPlistChannelSendAndTLSStream':True,'lookupCancellationSynchronization':'Per-fixture AsyncStream yielded after actual reply send, then peer blocks on same TLS stream; no sleep/poll or fabricated ACK.','rejectedPeerJoinMode':'Existing lookupOnly/unusedInput modes join deliberately rejected peers; normal success peer checks remain intact.','newOwnersStoresFallbacks':0},'definitions':{'suite':'SelfRenewalAuthenticatedInstallationClientTests','namesUnchanged':names,'newDefinitions':0,'changedExistingMethods':changed,'unaffectedMethodsByteExact':sorted(set(oldTests)-set(changed))},'newVectors':['LookupResult without Status, intermediate status, separate Complete','Matching interim result replaced by empty final snapshot','Empty interim result replaced by matching final snapshot','Matching result plus late same-frame Error/Complete rejected','Matching interim result followed by EOF rejected','Complete without any LookupResult rejected','Upgrade Complete then Lookup interim/late Error cannot publish success Receipt','Cancellation after actual interim reply wakes pending TLS receive and drains operation','257 Lookup status frames exceed existing256 budget','43 frames each with200000 payload characters exceed existing8MiB budget with each frame below262144-byte cap'],'executed':{'syntaxRoots':6,'syntaxErrors':0,'SwiftSDK':0,'Native':0,'controlledTLSVectors':0,'JVM':0,'device':0},'limits':['The new controlled TLS definitions have not run on an Apple SDK; grammar and source observations are not typechecking or runtime success.','Source comparison demonstrates intended sequencing, not a real iPhone service response or installation authorization.','No installed profile/digest, same physical device, no-VPN route or unattended renewal proof is added.']}
save(S/'source-api-fixture-facts.json',facts)
contract={'schemaVersion':1,'upstream':primary,'localBounds':[{'path':prod,'baseline':rf(old),'legacyLookupLines':[301,310],'startServiceLines':[312,320]},{'path':'Modules/Services/SelfRenewal/SelfRenewalAuthenticatedDeviceStream.swift',**rf(stream.read_bytes()),'authenticateLines':[254,312]}],'primaryContract':[{'file':'installation_proxy.c','lines':[307,381],'claim':'Synchronous command processing reads until Complete or an error. Missing Status alone is not terminal.'},{'file':'installation_proxy.c','lines':[568,619],'claim':'Lookup uses that synchronous loop; callback retains each supplied LookupResult by replacement, not merge.'},{'file':'service.c','lines':[55,75],'claim':'Generic service client performs service TLS when ssl_enabled=1.'},{'file':'lockdown.c','lines':[1285,1305],'claim':'StartService yields port and EnableServiceSSL, not a same-physical-device/profile installation guarantee.'}],'retainedDirectTCPPolicy':'Local provider still rejects missing/false EnableServiceSSL and independently performs pinned fresh mutual TLS on the session, AFC and installation_proxy streams. Supporting unauthenticated/plaintext services would need a separately authenticated mux/tunnel provider, not a relaxed boolean guard.','candidate':'Bounded synchronous Lookup stream completion with final observation publication after Complete; other TLS and installation authority policies unchanged.'}
save(S/'contract-v1.json',contract)
evidence=[fact(S/x)for x in ['primary-binding.json','contract-v1.json','source-api-fixture-facts.json','swift-grammar.json','verify-and-freeze.py','patch-tests.py']]
out={'schemaVersion':1,'frozenUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'S4 bounded Lookup terminal-completion production candidate; Swift SDK/runtime execution pending','scope':'Exactly one production method plus existing controlled real-TLS fixture and existing test vectors; no service TLS downgrade, new owner, new helper-only path, or profile verification claim','files':files,'evidence':evidence,'primaryFiles':primary['files'],'definitionCount':7,'newDefinitions':0,'affectedExistingDefinitions':changed,'validation':facts['executed'],'sourceContract':'contract-v1.json','interactionFacts':'source-api-fixture-facts.json','limits':facts['limits'],'operations':{'canonical':False,'Git':False,'cloud':False,'privatePairingOrCredentialsRead':False,'newStore':False,'newTransportOwner':False},'flags':{'fullS4Complete':False,'SwiftSDKPassed':False,'controlledTLSExecutionPassed':False,'installedRenewedProfileVerified':False,'selfRenewalVerified':False,'unattendedRenewalVerified':False}}
p=S/'final-v1.json';save(p,out);print(json.dumps({'manifest':fact(p),'files':len(files),'syntaxRoots':6,'syntaxErrors':0,'changedExistingDefinitions':changed,'SwiftSDK':0}))
