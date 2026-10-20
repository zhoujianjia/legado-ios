from pathlib import Path
from datetime import datetime,timezone
import ast,base64,hashlib,json,re,sys
ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'.tools/swift-syntax-python'))
from tree_sitter import Language,Parser
import tree_sitter_swift
PARSER=Parser(Language(tree_sitter_swift.language()))
def item(p):
    b=p.read_bytes();return {'path':p.relative_to(ROOT).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def json_read(name):return json.loads((OUT/name).read_text())
mapping={
'SelfRenewalIPAUnpacker.swift':'Modules/Services/SelfRenewal/SelfRenewalIPAUnpacker.swift',
'SelfRenewalSigningMaterialVault.swift':'Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift',
'SelfRenewalControlledMachOSigner.swift':'Modules/Services/SelfRenewal/SelfRenewalControlledMachOSigner.swift',
'SelfRenewalControlledPackageSigner.swift':'Modules/Services/SelfRenewal/SelfRenewalControlledPackageSigner.swift',
'SelfRenewalPackageResourceUpdater.swift':'Modules/Services/SelfRenewal/SelfRenewalPackageResourceUpdater.swift',
'SelfRenewalControlledPackageSignerTests.swift':'Tests/iOS/yuedu appTests/SelfRenewalControlledPackageSignerTests.swift',
'SelfRenewalControlledPackageFixture.swift':'Tests/iOS/yuedu appTests/SelfRenewalControlledPackageFixture.swift',
'SelfRenewalSDKOwnedPackageFixture.swift':'Tests/iOS/yuedu appTests/SelfRenewalSDKOwnedPackageFixture.swift',
'generate-owned-package-fixtures.py':'scripts/reader-experience/owned-package-fixture/generate-independent-package-fixtures.py',
}
for path in sorted((OUT/'work/sdk-fixture-tools').iterdir()):
    if path.is_file():mapping['sdk-fixture-tools/'+path.name]='scripts/reader-experience/owned-package-fixture/'+path.name
sources=[];grammar=[]
for name,intended in mapping.items():
    p=OUT/'work'/name;b=p.read_bytes()
    assert not re.search(br'-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',b),p
    entry={**item(p),'intendedPath':intended}
    if p.suffix=='.swift':
        stack=[PARSER.parse(b).root_node];errors=[]
        while stack:
            node=stack.pop()
            if node.type=='ERROR' or node.is_missing:errors.append({'type':node.type,'start':list(node.start_point),'end':list(node.end_point)})
            stack.extend(node.children)
        assert not errors,(name,errors)
        grammar.append({**entry,'errors':errors})
    elif p.suffix=='.py':ast.parse(b)
    snapshot=OUT/'sources'/intended;snapshot.parent.mkdir(parents=True,exist_ok=True);snapshot.write_bytes(b)
    sources.append(entry)
assert len(sources)==14 and len(grammar)==9
methods=re.findall(r'    @Test\([^\n]+\)\n    func (\w+)\(', (OUT/'work/SelfRenewalControlledPackageSignerTests.swift').read_text())
assert len(methods)==len(set(methods))==11
fixture=json_read('fixture-generation.json')
assert fixture['actualOpenSSLCMSVerifications']==38 and fixture['SwiftExecutions']==fixture['SDKExecutions']==0
# Exact public bytes embedded in Swift must equal their independent raw outputs.
text=(OUT/'work/SelfRenewalControlledPackageFixture.swift').read_text()
values={name:base64.b64decode(''.join(raw.split())) for name,raw in re.findall(r'static let (\w+)Base64 = """(.*?)"""',text,re.S)}
for raw in fixture['outputs']:
    data=values[raw['name']]
    assert len(data)==raw['bytes'] and hashlib.sha256(data).hexdigest()==raw['sha256'],raw['name']
for cms in fixture['CMS']:
    p=OUT/'owned-public-vectors'/(cms['name']+'.cms')
    assert item(p)['sha256']==cms['sha256']
    content=OUT/'owned-public-vectors'/(cms['name']+'.content');verified=OUT/'owned-public-vectors'/(cms['name']+'.verified')
    assert content.read_bytes()==verified.read_bytes()
    assert hashlib.sha256(content.read_bytes()).hexdigest()==cms['verifiedContentSHA256']
prior_paths=['Modules/Services/SelfRenewal/SelfRenewalIPAUnpacker.swift','Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift','Modules/Services/SelfRenewal/SelfRenewalControlledMachOSigner.swift']
base=[item(ROOT/path) for path in prior_paths]
primary=[]
for p in sorted((OUT/'primary').iterdir()):
    if p.is_file():primary.append(item(p))
record={
'schema':1,'preparedAt':datetime.now(timezone.utc).isoformat(),
'integrationState':'ignored-work-only-awaiting-root-review-and-coherent-merge',
'baseSourceStage':'44528e085bc57dcffc5699af293328729e513a02',
'sourceBinding':{'files':sources,'fileCount':len(sources),'appAndTestSwiftSourceCount':8,'macOSGeneratorSwiftSourceCount':1,'canonicalBaseFilesReadOnly':base},
'grammar':{'sourceCount':len(grammar),'errors':0,'files':grammar,'meaning':'Syntax grammar only; not Swift typecheck, Security/Keychain or SDK execution.'},
'nativeTests':{'suite':'SelfRenewalControlledPackageSignerTests','definedMethods':methods,'definedCount':len(methods),'executed':0,'passed':0,
 'sameJobSDKMethod':'signsSDKProducedMainExtensionsAndFrameworkInSameJob','requirements':'Run the fixed SDK producer before xcodebuild and include public owned-sdk-package.json as an XCTest bundle resource. Missing producer output fails the selected method.'},
'independentOwnedFixtureExecution':{'record':item(OUT/'fixture-generation.json'),'actualOpenSSLCMSVerifications':38,'actualRawPageAndSpecialSlotAudits':12,'actualResourceHashAudits':12,'actualZipCRCReadAll':4,'actualDynamicSymbolTableLayoutAudits':2,'privateKeysExported':0,'privateKeyFiles':0,'SwiftExecutions':0,'SDKExecutions':0},
'sdkProducer':{'sourceClosed':True,'localExecutionCount':0,'localReason':'Windows host has no macOS/Xcode SDK. Producer definitions and AST/Swift syntax checks are not an SDK verdict.',
 'invocation':'python3 scripts/reader-experience/owned-package-fixture/generate-sdk-owned-package.py --output <empty-controlled-public-output>',
 'outputResource':'owned-sdk-package.json','outputManifest':'sdk-produced-fixture-manifest.json',
 'actualRequiredActions':['xcrun clang produces device arm64 main/two extensions/framework','synthetic certificate chain and real temporary Keychain identity','codesign actual original CMS, never count adHoc as authenticated','OpenSSL independently verifies each actual detached primary CD CMS against explicit owned root','publish public raw MachOs/IPA/logs/source-command-hash manifest only','delete the one generated temporary Keychain; private keys/P12 only memory or Keychain'],
 'toolScope':'Existing OpenSSL 3 only; no package install, Apple account, real profile or credential import.'},
'implementedBoundaries':['same original IPA snapshot digest/bytes exposed as sealed Result facts without a second input read','one scoped actor serializes sync IO and holds exclusive detached verifier/archive workers across awaits','scope close prohibits new IO then cancels/drains active worker before any cleanup; actual gate test definitions cover callback return and throw','same existing snapshot/validator/Readium/OwnedTree extraction path; existing file-only SHA CAS replacement and random same-directory rename','unique Vault live lease before mutation, before each signing and before publication, plus actual sealed identity equals namespace baseline','raw profile CMS bytes are copied only from the verified Published inputs with path/count/SHA binding','deepest-first component resource hashes/nested selected authenticated CD hints and real Mach-O resigning','old external slots authenticate old executable; only new slot3 resources supplied for rebuilt executable','exact raw XML rules/rules2 values and requirement text preserved; key enumeration/tie order checked after reparse','MH_EXECUTE/MH_DYLIB and LC_DYSYMTAB table ranges/indexes checked; table/content offsets remain unchanged','new code permissions normalized755 and ordinary file644; source extraction never inherits untrusted ZIP mode','actual ZIP output is re-extracted and whole AppMaterial-verified through same path; only pinned read-only unlinked FD bytes escape','all original non-mutated file SHA256s retained including omitted files and bound again under exclusive archive worker'],
'knownLimits':['No Swift or SDK method executed locally. macOS keychain importer, actual clang/codesign output and whole package positive need concentrated SDK verdict.','Controlled pilot and bounded normal-layout support are not full S3. Fat/arm64e/encryption/unsupported load commands/unsupported CD and dylib forms fail typed.','Main plus exact Widget/Share roles and at most16 framework components; arbitrary other code/dylibs/components unsupported.','XML CodeResources only; binary/UTF16/comment/CDATA/internal-DTD envelopes typed unsupported, never reordered heuristically.','Classic stored output only, bounded payload/header budget <=256MiB and per entry<=64MiB; no ZIP64 or compressed output.','No real Apple account, signing-purpose/device/profile authority, remote revocation, unattended renewal or installation authorization.','Vault generation CAS remains within one injected actor; multi-process transaction/recovery authority belongs to S5. Borrowed SecKey handles cannot be forcibly revoked.'],
'acceptance':{'appleSigningAuthorityEstablished':False,'accountIdentityEstablished':False,'deviceEligibilityEstablished':False,'replacementAuthorized':False,'fullS3Complete':False,'SDKAccepted':False,'wholeFeatureAcceptanceCount':0},
'primarySources':primary,
'auxiliaryEvidence':[item(OUT/'fixture-generation.json'),item(OUT/'work/generate-owned-package-fixtures.py'),item(OUT/'freeze.py')]
}
(OUT/'grammar.json').write_text(json.dumps(record['grammar'],indent=2)+'\n')
raw=json.dumps(record,indent=2).encode()+b'\n';(OUT/'preparation.json').write_bytes(raw)
print(json.dumps({'preparation':str((OUT/'preparation.json').relative_to(ROOT)).replace('\\','/'),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'sources':len(sources),'swiftGrammarSources':len(grammar),'nativeMethodsDefined':len(methods),'SDKExecuted':0}))
