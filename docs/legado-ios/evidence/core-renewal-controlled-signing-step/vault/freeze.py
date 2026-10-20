from datetime import datetime, timezone
import ast
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift

mapping = {
    'SelfRenewalSigningMaterialVault.swift': 'Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift',
    'SelfRenewalSigningOwnedPKIFixture.swift': 'Tests/iOS/yuedu appTests/SelfRenewalSigningOwnedPKIFixture.swift',
    'SelfRenewalSigningMaterialVaultTests.swift': 'Tests/iOS/yuedu appTests/SelfRenewalSigningMaterialVaultTests.swift',
}
parser = Parser(Language(tree_sitter_swift.language()))
sources = []
for name, destination in mapping.items():
    path = OUT / 'work' / name
    raw = path.read_bytes()
    errors, stack = [], [parser.parse(raw).root_node]
    while stack:
        node = stack.pop()
        if node.type == 'ERROR' or node.is_missing:
            errors.append({'kind': node.type, 'start': list(node.start_point), 'end': list(node.end_point)})
        stack.extend(node.children)
    assert not errors, (name, errors)
    snapshot = OUT / 'sources' / destination
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    snapshot.write_bytes(raw)
    sources.append({'path': str(path.relative_to(ROOT)).replace('\\', '/'), 'intendedPath': destination,
                    'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'grammarErrors': errors})
test = (OUT / 'work/SelfRenewalSigningMaterialVaultTests.swift').read_text()
methods = re.findall(r'    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(', test)
assert len(methods) == len(set(methods)) == 7
for name in ['SelfRenewalSigningMaterialVault.swift', 'SelfRenewalSigningOwnedPKIFixture.swift']:
    source = (OUT / 'work' / name).read_text()
    exports = re.findall(r'SecKeyCopyExternalRepresentation\(([^,]+),', source)
    assert exports == ['publicKey'], (name, exports)
generator = (OUT / 'generate-owned-public-vectors.py').read_text()
assert not any(isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'private_bytes'
               for node in ast.walk(ast.parse(generator)))
vectors = json.loads((OUT / 'fixture-generation.json').read_text())
assert vectors['privateKeyExports'] == vectors['privateKeyFiles'] == vectors['sdkMethodsExecuted'] == 0
assert len(vectors['certificateTrustChecks']) == 2 and len(vectors['cmsSignatureChecks']) == 6
for item in vectors['outputs']:
    raw = (OUT / item['path']).read_bytes()
    assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256']
primary = json.loads((OUT / 'primary/sources.json').read_text())
for item in primary:
    assert 'error' not in item
    raw = (OUT / 'primary' / item['path']).read_bytes()
    assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256']
reused = []
for path in ['Modules/Core/RuleEngine/ModernParser/Login/KeychainHelper.swift',
             'Modules/Services/SelfRenewal/SelfRenewalApplicationMaterialVerifier.swift',
             'Modules/Services/SelfRenewal/SelfRenewalProvisioningProfileVerifier.swift',
             'Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift',
             'Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialFixture.swift',
             'Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift']:
    raw = (ROOT / path).read_bytes()
    reused.append({'path': path, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'modifiedByThisStep': False})
grammar = {'schema': 1, 'files': sources, 'sourceCount': 3, 'errors': 0,
           'meaning': 'Syntax grammar only; no Swift typecheck, Security/Keychain call or SDK execution.'}
(OUT / 'grammar.json').write_text(json.dumps(grammar, indent=2) + '\n')
record = {
    'schema': 1, 'stage': 'S2 single-owner software-Keychain signing material lifecycle',
    'frozenAtUTC': datetime.now(timezone.utc).isoformat(), 'integrationState': 'work-only-awaiting-root-review-and-merge',
    'earlierSDKSourceExcludesTheseFiles': '478b69d6a1074e9a1d82c2b55e522b0d39e23f8a',
    'sourceBinding': {'files': sources, 'count': 3, 'snapshots': 'sources/'},
    'reusedUnmodifiedDependencies': reused, 'publicPrimarySources': primary,
    'preparedNativeTests': {'suite': 'SelfRenewalSigningMaterialVaultTests', 'methodCount': 7,
        'methods': [name + '()' for name in methods], 'executedSDKMethods': 0, 'acceptedSDKMethods': 0},
    'localValidation': {'swiftGrammarFiles': 3, 'swiftGrammarErrors': 0, 'swiftTypecheck': False,
        'independentOpenSSLCertificateChainChecks': 2, 'independentOpenSSLCMSSignatureChecks': 6,
        'independentTamperedCMSRejected': 1, 'privateKeyExports': 0, 'privateKeyFiles': 0,
        'swiftOrKeychainExecution': False, 'simulatorTests': False, 'deviceTests': False},
    'limits': {'openNamespaces': 8, 'keysPerNamespaceIncludingJournal': 4, 'bundles': 8,
        'certificatesPerChain': 8, 'certificateBytes': 65536, 'profileBytes': 65536,
        'totalPublicMaterialBytes': 262144, 'manifestUTF8Bytes': 524288},
    'implemented': [
        'Single injected actor owns lifecycle operations; no shared twin or second S3 key manager.',
        'SecKeyCreateRandomKey creates permanent software RSA2048 private key with random module namespace/key UUID applicationTag, AfterFirstUnlockThisDeviceOnly, no sync, sign-only usage requests; public key is explicitly nonpermanent.',
        'Only public SecKey representations are requested. Private keys remain Security objects and are never encoded, logged, embedded or written as files.',
        'Public cert/profile bytes and generation journal reuse KeychainHelper under a dedicated service and exact random owned account; locked/missing reads fail closed.',
        'Pending key journal is persisted before key creation; ready publication follows. Failure cleans only its newly generated exact key tag and leaves previous public material/key intact; pending entries support explicit recovery.',
        'Sealed existing ApplicationMaterialVerifier result fixes team, app, groups/default keychain groups and signed profile entitlement allowance digest.',
        'Candidate certificate chain is actually verified anchors-only/date/no-network, selected chain must match input leaf-to-anchor DER, and leaf public key must match the persisted private key public hash.',
        'Every candidate profile passes existing verifyModern outer and inner CMS plus DER validity and developer-certificate hash checks, then matches pinned team/prefix/App ID pattern and full profile Entitlements digest.',
        'Complete candidate validation precedes single-manifest generation publication; failure or cancellation observed before publication preserves the previous published material.',
        'Lease reopens exact SecKey tag and revalidates actual material at current clock; generation guards are checked before signing and before later signed-byte publication.',
        'Local revoke invalidates generation/published record before exact-item deletion; deletion errors never restore revoked publication. Destruction touches only keys recorded in this random module namespace.',
        'Shared S3 KeyMaterial DTO is defined here with SecKey plus leaf-to-anchor certificate DER; raw DTO construction grants no authorization.',
        'Owned native test definitions cover real Keychain protection attributes/generation/publication/reopen/signature verification/scoped revoke, stale/observed cancellation, identity/expiry/key mismatch, save failure, pending-journal recovery and scoped budgets.',
    ],
    'transactionSemantics': [
        'Generation CAS is only within one injected actor owner. KeychainHelper load-compare-save is not cross-actor or cross-process atomic CAS; S5 still needs sole-owner orchestration or stronger transaction support.',
        'One generic-password item is the publication boundary. No atomic transaction across multiple key items and manifest is promised; pending journal tracks recoverable key-generation gaps.',
        'A successful synchronous publication save is acknowledged. No post-commit CancellationError pretends the accepted save was rolled back.',
        'Software keys may be exportable to other in-process code. This module requests no private export; it does not claim SecureEnclave or enforced nonextractability.',
        'SecItemDelete removes the stored item but cannot invalidate already retained SecKey references. Retained raw key handles are not commit capabilities; caller must recheck lease at signing/publish boundaries.',
        'Current clock and explicit local anchors are configuration, not Apple account, trusted time, remote revocation or provisioning-purpose proof.',
    ],
    'unfinished': [
        'All seven native methods are definitions only; actual Keychain persistence, Swift compilation and SDK runtime remain unverified until a later centralized SDK run.',
        'New source is not in earlier 478b69d/78-method/68-input SDK run; independent Python/OpenSSL checks do not execute the Swift helper, vault or Security APIs.',
        'No real Apple account, login/password/token, second factor, free-team certificate/profile request, remote Apple revocation/OCSP/CRL, Apple certificate purpose or full entitlement authorization is implemented.',
        'No App dependency lifecycle/UI/account coordinator or cross-process transaction owner is integrated in this step.',
        'Private signing keys are software Security keys for simulator-compatible tests, not a SecureEnclave/hardware portability promise.',
        'S3 package orchestration must validate live leases before signing and before output commit; install/device/account/replacement authority remains absent.',
    ],
    'authorizationClaims': {'appleSigningAuthorityEstablished': False, 'remoteRevocationEstablished': False,
        'accountIdentityEstablished': False, 'replacementAuthorized': False},
    'scope': {'productionOrTestTargetsModified': False, 'existingVerifiersModified': False,
        'ipaFilesModified': False, 'ciModified': False, 'docsModified': False, 'gitOperations': 0,
        'realAccountsOrCredentialsRead': False, 'userArchivesOrPrivateSourcesRead': False},
    'evidence': [],
}
for path in ['grammar.json', 'fixture-generation.json', 'generate-owned-public-vectors.py', 'freeze.py', 'primary/sources.json']:
    raw = (OUT / path).read_bytes()
    record['evidence'].append({'path': path, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
raw = json.dumps(record, indent=2).encode() + b'\n'
(OUT / 'preparation.json').write_bytes(raw)
print(json.dumps({'status': record['integrationState'], 'swiftSources': len(sources), 'grammarErrors': 0,
    'nativeMethodsDefined': len(methods), 'nativeMethodsExecuted': 0,
    'preparationBytes': len(raw), 'preparationSHA256': hashlib.sha256(raw).hexdigest(), 'methods': methods}))
