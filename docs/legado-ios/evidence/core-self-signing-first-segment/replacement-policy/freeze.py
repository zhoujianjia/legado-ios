"""Freeze two owned new sources and static evidence; no SDK/tests/Git/CI."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys

OUT=Path(__file__).resolve().parent
ROOT=OUT.parents[2]
sys.path.insert(0,str(ROOT/'.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift
PARSER=Parser(Language(tree_sitter_swift.language()))
FILES=('Modules/Services/SelfRenewal/SelfRenewalReplacementPolicy.swift',
       'Tests/iOS/yuedu appTests/SelfRenewalReplacementPolicyTests.swift')
METHODS=('rejectsAccountTeamAndBundleMappingChanges','rejectsMissingDuplicateOrIncompleteBundleInventory',
         'rejectsChangedOrUnknownEntitlementGroups','rejectsUnverifiedExpiredOrInvalidCandidateMaterial',
         'sameVersionAndBuildYieldOnlyMetadataPreflight')
def sha(raw):return hashlib.sha256(raw).hexdigest()
def encoded(value):return (json.dumps(value,indent=2)+'\n').encode()
def write(path,raw):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('xb') as stream:stream.write(raw)
def ref(path):
    raw=path.read_bytes();return dict(path=str(path.relative_to(ROOT)).replace('\\','/'),bytes=len(raw),sha256=sha(raw))
def errors(node):
    found=[]
    if node.type=='ERROR' or node.is_missing:found.append(dict(type=node.type,missing=node.is_missing,line=node.start_point.row+1))
    for child in node.children:found.extend(errors(child))
    return found
files=[];grammar=[]
for relative in FILES:
    path=ROOT/relative;raw=path.read_bytes();issues=errors(PARSER.parse(raw).root_node)
    assert not issues
    files.append(ref(path));grammar.append(dict(**ref(path),errors=issues,passed=True))
    write(OUT/'source'/relative,raw)
production=(ROOT/FILES[0]).read_text(encoding='utf-8')
test=(ROOT/FILES[1]).read_text(encoding='utf-8')
observed=re.findall(r'@Test\([^\n]*\)\s+func\s+(\w+)\(\)',test)
assert observed==list(METHODS) and 'arguments:' not in test
assert not re.search(r'FileManager|Data\s*\(\s*contentsOf|URLSession|UserDefaults|SecItem|Bundle\.main|Date\s*\(\s*\)|UUID\s*\(\s*\)|Task\b|DispatchQueue',production)
write(OUT/'grammar-final.json',encoded(dict(scope='Tree-sitter only, not Swift SDK/type checking or runtime',
    files=grammar,passed=True,actualSwiftSDKBuilds=0,actualSwiftTests=0)))
record=dict(schemaVersion=1,recordedAtUTC=datetime.now(timezone.utc).isoformat(),
    status='pure-metadata-preflight-source-preparation-SDK-execution-pending',files=files,
    contract=dict(inputTrust='platformAdapterAssertion is solely a future real adapter prerequisite, not proof created by constructing a value. No real production adapter or account/certificate/profile inspection was added.',
        inputInventory='Complete supported application/widget/share identity inventory; each role and bundle ID once, explicit parent and prefix relationships, same Team within each snapshot and exact mapping between snapshots. Extra/unknown extensions must not be omitted by the future adapter.',
        identity='Opaque non-secret account binding plus per-role Team/App-ID-prefix/application-identifier comparisons; Team and App ID prefix are not assumed identical.',
        entitlements='Known arrays required; nil unknown is rejected, empty known arrays are allowed. App Group sets match; keychain arrays including the default first group match. Duplicate/wildcard/invalid or oversized groups reject.',
        renewalVersionScope='Same version AND build deliberately allowed. Any different per-role version/build is outside this narrow renewal policy, not a judgment that all upgrades/downgrades are prohibited.',
        validity='Caller provides now. Each candidate interval is finite, ordered and valid at notBefore-inclusive/expiresAt-exclusive evaluation. An old installed authorization expiry does not prevent recovery identity comparison.',
        result='metadataCompatible ReplacementPreflightPlan or fixed enum rejection. The plan binds both input snapshot IDs, three role mappings and earliest candidate authorization expiry. It executes nothing.',
        gates='Authenticated transport, real signing adapter, revalidation of actual candidate/identities at use, installation and data-retention verification remain required; this does not integrate or bypass signerIntegration.',
        dataBounds=dict(bundles=3,groupsPerKindPerBundle=32,identifierUTF8Bytes=255,versionBuildTokenBytes=64,accountBindingBytes=128),
        rejectionPrivacy='Only fixed snapshot kinds/roles/field categories/reasons, no account or Team values.',
        effects='Pure synchronous value comparison: no IO, clock access, logging, Task/queue, persistence, signer/install call, UI or probe mutation.'),
    plannedTests=dict(suite='SelfRenewalReplacementPolicyTests',methods=list(METHODS),
        methodIdentities=['SelfRenewalReplacementPolicyTests/'+name+'()' for name in METHODS],
        methodCount=5,expectedExecutions=5,parameterized=False,actualExecutions=0,
        inputs='Owned synthetic adapter assertions only; no cryptographic, certificate/profile, account or device verification.'),
    actualVerification=dict(grammarFiles=2,grammarPassed=True,grammar=ref(OUT/'grammar-final.json'),
        methodIdentitySourceCheck=True,purePathStaticScreen=True,SwiftTypechecks=0,SwiftSDKBuilds=0,SwiftTests=0,iOSTests=0,
        newNetworkOrCIOrGitOperationsByFreezer=0),
    primaryReferences=json.loads((OUT/'primary/index.json').read_bytes()),
    acceptedRealityClaims=dict(cryptographicVerificationPerformed=False,deviceVerificationPerformed=False,
        signingPerformed=False,installationPerformed=False,renewalProven=False,automaticSelfRenewalImplemented=False),
    remaining=['Independent review of frozen sources','Actual Apple SDK compilation and five source-bound real Swift test executions',
        'Future real platform adapters must establish trustworthy immutable snapshots and complete inventories before use',
        'Authenticated install transport, signer, installation and data preservation remain separate unimplemented/unaccepted gates'])
write(OUT/'preparation.json',encoded(record))
print(json.dumps(dict(files=files,preparation=ref(OUT/'preparation.json'),grammar=ref(OUT/'grammar-final.json'),
    plannedMethods=5,actualSwiftSDKAndTests=0),indent=2))
