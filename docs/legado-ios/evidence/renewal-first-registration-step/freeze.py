from pathlib import Path
import json,hashlib,re,difflib,shutil,datetime
R=Path('F:/yuedu-reader');S=R/'.build/s2-first-registration-step';W=S/'work';F=S/'snapshot-v1/work'
assert not (S/'final-v1.json').exists()
def fact(p):
 b=p.read_bytes();return {'path':p.relative_to(R).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
baseline=json.loads((S/'baseline-v2.json').read_text());files=[];checks=[]
for row in baseline['files']:
 path=row['path'];a=(S/'rawbaseline'/path).read_bytes();b=(W/path).read_bytes()
 assert a==(R/path).read_bytes(),path
 assert a!=b,path
 assert b.decode('utf-8').endswith('\n') and b'\r' not in b,path
 dest=F/path;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(W/path,dest)
 diff=S/'diffs-v1'/(path+'.diff');diff.parent.mkdir(parents=True,exist_ok=True)
 diff.write_text(''.join(difflib.unified_diff(a.decode('utf-8').splitlines(True),b.decode('utf-8').splitlines(True),fromfile='a/'+path,tofile='b/'+path)),encoding='utf-8',newline='\n')
 files.append({'path':path,'baseline':row['baseline'],'candidate':fact(dest),'diff':fact(diff)})
 checks.append({'check':'canonical remains exact raw baseline and immutable candidate copied exactly','path':path,'passed':True})
sources={row['path']:(W/row['path']).read_text() for row in files}
account=sources['Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountClient.swift'];installer=sources['Modules/Services/SelfRenewal/SelfRenewalAuthenticatedInstallationClient.swift'];vault=sources['Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift'];owner=sources['Modules/Services/SelfRenewal/SelfRenewalAppOwner.swift'];app=sources['Modules/Services/SelfRenewal/SelfRenewalAppSession.swift']
def method(source,name):
 at=source.index('    static func '+name+'(');end=source.index('\n    }',at)+6;return source[at:end]
old=(S/'rawbaseline/Modules/Services/SelfRenewal/SelfRenewalAuthenticatedInstallationClient.swift').read_text()
for name in ['openSession','startService','stopSession']:
 assert method(old,name)==method(installer,name)
 checks.append({'check':'exact existing TLS/session/service implementation preserved','function':name,'passed':True})
assert account.index('guard loaded.record.pending == nil')<account.index('let identifiers = try await prepareRegistration')
assert account.index('let preparedCSR =')<account.index('let identifiers = try await prepareRegistration')
assert 'registrationGeneration: generation, pairedDevice: pairedDevice' in account
assert 'try check(epoch); try validateCredentials(credentials); try pairedDevice?.check()' in account
assert 'request.timeoutInterval = min(30, try pairedDevice.remainingSeconds())' in account
assert account.count('requiredDeviceIdentifier: pairedDevice?.identifier')==3
pub=vault.index('    func publish(in namespace:')
assert vault.index('let (key, verifiedProfiles) = try verify(candidate',pub)<vault.index('if let device = requiredDeviceIdentifier',pub)<vault.index('session.manifest.published = candidate',pub)
assert 'Data(identifier.utf8) == Data(device.utf8)' in vault
assert 'RegistrationCleanupFailure { return classify(failure.underlying)' in owner
assert 'if let failure = error as? SelfRenewalDeveloperAccountClient.PublicationFinalizationFailure' in owner
assert 'samePhysicalDeviceVerified: Bool { false }' in installer and 'noVPNRouteVerified: Bool { false }' in installer
assert 'fileprivate init(identifier:' in installer and 'private let lifetime:' in installer
assert 'lifetime.end()\n            do { try stopSession' in installer
assert 'if reconcile { published = try await account.reconcilePendingMaterials(pairedDevice: observation) }' in app
assert 'RegistrationFinalizationFailure<Vault.Lease>' in app
for s in [account,installer,app,vault,owner]: assert 'JSContext(' not in s
newtests=[];testFacts=[]
for row in files:
 if not row['path'].startswith('Tests/'):continue
 a=(S/'rawbaseline'/row['path']).read_text();b=(W/row['path']).read_text()
 def defs(s):return re.findall(r'@Test(?:\([^\n]*\))?\s*\n\s*func\s+(\w+)',s)
 before=defs(a);after=defs(b);added=[x for x in after if x not in before]
 assert set(before)<=set(after)
 newtests += [{'path':row['path'],'method':x} for x in added]
 testFacts.append({'path':row['path'],'oldDefinitions':len(before),'finalDefinitions':len(after),'addedMethods':added,'oldDefinitionsRetained':True})
assert len(newtests)==4,newtests
assert 'case .missing: properties.removeValue(forKey: "ProvisionedDevices")' in sources['Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift']
assert 'problem == .cancelled' in sources['Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift']
html=(S/'primary/apple-supported-capabilities-ios.html').read_text();i=html.index('<p>App groups</p>');lo=html.rfind('<tr>',0,i);hi=html.index('</tr>',i)+5;groupRow=html[lo:hi]
assert groupRow.count('icon-checksolid')==3 and groupRow.count('alt="yes"')==3
primary=[]
urls={
 'AltSign-1-ALTAppleAPI.m':'https://raw.githubusercontent.com/rileytestut/AltSign/1c44cfdcafc1ef301c9a0a20a96be0983bb5a003/AltSign/Apple%20API/ALTAppleAPI.m',
 'ALTCapabilities.m':'https://raw.githubusercontent.com/rileytestut/AltSign/1c44cfdcafc1ef301c9a0a20a96be0983bb5a003/AltSign/Capabilities/ALTCapabilities.m',
 'SideStore-FetchProvisioningProfilesOperation.swift':'https://raw.githubusercontent.com/SideStore/SideStore/d97ec133719d79916675bdaf722b82a8d091d545/SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift',
 'apple-supported-capabilities-ios.html':'https://developer.apple.com/help/account/reference/supported-capabilities-ios',
 'libimobiledevice-lockdown.c':'https://raw.githubusercontent.com/libimobiledevice/libimobiledevice/fa0f79190142bc309307967c058f89c1b36eb6b8/src/lockdown.c',
 'idevice-lockdown.rs':'https://raw.githubusercontent.com/SideStore/idevice/3e55c8486b2057e40c1f74aaaa1155c82341cf76/idevice/src/services/lockdown.rs',
}
for p in (S/'primary').iterdir():
 if p.suffix in ['.m','.h'] and p.name not in urls:urls[p.name]='https://raw.githubusercontent.com/rileytestut/AltSign/1c44cfdcafc1ef301c9a0a20a96be0983bb5a003/AltSign/Model/Apple%20API/'+p.name
 primary.append(dict(fact(p),url=urls.get(p.name),localCopyOrNetworkPin=True))
(S/'primary-binding-v2.json').write_text(json.dumps({'files':primary,'AltSignMasterCurrentMatchesPin':'1c44cfdcafc1ef301c9a0a20a96be0983bb5a003','SideStoreApplePrivateAPIsCurrentMatchesPin':'03beb1aa42991ccdad6214dee77e72282bef461f','SideStoreCurrentDevelopTree':'d97ec133719d79916675bdaf722b82a8d091d545','AppleAppGroups':{'rawLines':{'columns':[2319,2322,2325],'row':[2366,2378],'freeAppleDeveloperLegend':3016},'columns':['ADP','ADEP','Apple Developer'],'yesFigures':3,'currentAccountServerAcceptance':False}},indent=2)+'\n',encoding='utf-8')
(S/'source-check-v2.json').write_text(json.dumps({'kind':'source/provenance assertions only, not parser or SDK acceptance','checks':checks,'testDefinitions':testFacts,'newDefinitions':newtests,'SDKExecutions':0,'SwiftGrammarRuns':0,'controlledTLSExecutions':0,'AppleAccountRequests':0},indent=2)+'\n',encoding='utf-8')
final={'schemaVersion':1,'status':'frozen production candidate; independent review and Apple SDK/runtime execution required','sourceRoot':F.relative_to(R).as_posix(),'baselineCanonicalPrefix':'590a0c8','baseline':fact(S/'baseline-v2.json'),'files':files,'productionSources':5,'testSources':4,'scope':[
 'Same authenticated account/transport/credential record/Vault; exact original main/widget/share IDs and original shared App Group only, no bundle/group rename, deletion, wildcard registration or certificate revocation.',
 'refreshMaterials and remote pending-CSR reconciliation prepare exact AppIDs/groups. Device registration additionally requires the privately constructed live TLS paired-target observation.',
 'Lockdown StartSession and mTLS are unchanged. GetValue UniqueDeviceID runs before account operation; one absolute bounded socket lifetime/cancellation and real StopSession/close. No StartService or provider downgrade.',
 'New registration requests check epoch/credentials/namespace generation and optional paired lifetime at actual transport dispatch after fresh anisette await. Existing account validation/certificate/profile request guard semantics remain; this does not add those checks to every old Apple request.',
 'A paired target must occur as an exact UTF8 String in every authenticated inner-DER ProvisionedDevices array before Vault publication, both newCSR and reused-certificate profile refresh. No raw outer XML authorization.',
 'Native and App error consumers retain original operation errors plus StopSession cleanup failures and acknowledged completed Lease; an accepted mutation is not rolled back by later local failure.'
 ],'protocolBinding':fact(S/'primary-binding-v2.json'),'sourceChecks':fact(S/'source-check-v2.json'),'newAppTestDefinitions':newtests,'newNativeDefinitions':0,'newPackageDefinitions':0,'actualExecution':{'SwiftTypecheck':0,'SwiftGrammarParser':0,'AppTests':0,'controlledTLS':0,'URLProtocolTests':0,'realAppleAccountRequests':0,'realDevice':0,'cloudOperations':0,'canonicalOrGitWrites':0},'necessaryFutureValidation':[
 'Apple SDK compile all 9 final source bytes and execute four new App methods plus affected existing AccountClient/AccountSession methods and existing authenticated transport/session tests.',
 'The actual Apple account and Personal Team must accept the exact identifiers/capability and issue valid device-containing profiles; public/private-protocol primary is not server permission evidence.',
 'Paired peer authentication is not same-physical-device proof, no-VPN proof, service transport/installation permission, code replacement, cold launch, user-data preservation or unattended before-expiry renewal.'
 ],'knownLimits':[
 'Registration mutation facts are conservative call intents plus parsed accepted ACK kinds. No atomic rollback, durable remote transaction, cross-process exactly-once guarantee or automatic write retry. A later explicit operation first relists and reuses exact remote identity; absent/stale remote lists may still lead to a typed duplicate/conflict response.',
 'No configured paired device means no hardware registration or profile target assertion; the original account/material-only branch remains available and cannot claim device eligibility.',
 'Device identifier input is only the authenticated peer String; bounded ASCII alphanumeric/hyphen up to128 bytes is an explicit embedding bound, not a claim to enumerate every future UDID layout. Synthetic tests cover old40hex and modern8-16 layouts, not observed physical devices.',
 'Registration supports bounded original list actions without inventing pagination. Explicit truncated/hasMore/next metadata rejects; absence is original endpoint shape, not a new complete-history attestation.',
 'State/certificate/profile publication stays in existing owners. No pairing import, signing key serialization, new network/store/VM, entitlement stripping, new installation provider or extra OS privilege.'
 ],'history':{'sourceCheckV1':fact(S/'source-check-v1.json'),'preparationFailures':['Two inline PowerShell/Python quote/syntax read-edit attempts failed before writing files or executing tests; corrected with explicit patch/script files.'],'WindowsSwiftParser':'Not run per Root instruction; no grammar result is being treated as SDK typechecking.'},'completionClaimsAllFalse':{'automaticSelfRenewalImplemented':False,'automaticSelfRenewalVerified':False,'fullLegadoCompatibilityEstablished':False,'allNonDeviceWorkComplete':False}}
(S/'final-v1.json').write_text(json.dumps(final,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
print(json.dumps(fact(S/'final-v1.json')))
