from pathlib import Path
from datetime import datetime, timezone
from urllib.request import Request, urlopen
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / '.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift

FILES = [
    'Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift',
    'Modules/Services/SelfRenewal/SelfRenewalProvisioningProfileVerifier.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalCMSVerifierTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalProvisioningProfileVerifierTests.swift',
]
REFERENCES = {
    'rfc5652.txt': 'https://www.rfc-editor.org/rfc/rfc5652.txt',
    'CMSDecoder.h': 'https://raw.githubusercontent.com/apple-oss-distributions/Security/main/CMS/CMSDecoder.h',
    'tn3125.json': 'https://developer.apple.com/tutorials/data/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles.json',
}


def main():
    version = sys.argv[1] if len(sys.argv) > 1 else 'v1'
    assert re.fullmatch(r'v[0-9]+', version)
    parser = Parser(Language(tree_sitter_swift.language()))
    sources = []
    methods = {}
    snapshots = HERE / ('sources-' + version)
    snapshots.mkdir()
    for name in FILES:
        raw = (ROOT / name).read_bytes()
        tree = parser.parse(raw)
        errors = []
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            if node.type == 'ERROR' or node.is_missing:
                errors.append({'type':node.type,'start':list(node.start_point),'end':list(node.end_point)})
            stack.extend(node.children)
        assert not errors, (name, errors)
        (snapshots / Path(name).name).write_bytes(raw)
        sources.append({'path':name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'grammarErrors':[]})
        if name.endswith('Tests.swift'):
            methods[Path(name).stem] = re.findall(r'    @Test\([^\n]+\)\n    func ([A-Za-z0-9_]+)\(',raw.decode('utf-8'))
    assert len(methods['SelfRenewalCMSVerifierTests']) == 7
    assert len(methods['SelfRenewalProvisioningProfileVerifierTests']) == 2
    references = []
    primary = HERE / 'primary'
    primary.mkdir(exist_ok=True)
    for filename, url in REFERENCES.items():
        path = primary / filename
        if path.exists():
            raw = path.read_bytes()
        else:
            with urlopen(Request(url,headers={'User-Agent':'Yuedu-owned-CMS-profile-materials'}),timeout=30) as response:
                raw = response.read(262_145)
            assert len(raw) <= 262_144
            path.write_bytes(raw)
        references.append({'URL':url,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),
            'path':path.relative_to(ROOT).as_posix()})
    fixture = json.loads((HERE/'fixture-generation.json').read_bytes())
    assert fixture['CMSPositiveCasesVerified'] == 6 and fixture['CMSTamperRejected'] == 1
    result = {'recordedAtUTC':datetime.now(timezone.utc).isoformat(),
        'status':'production-wired-prepared-not-Swift-SDK-executed','sourceInputs':sources,
        'grammarParsedFiles':5,'preparedSwiftTests':methods,'preparedSwiftMethods':9,
        'actualSwiftSDKBuilds':0,'actualSwiftTestExecutions':0,
        'ownedOpenSSLVerification':{'positiveCMSCases':6,'tamperedCMSRejected':1,'record':'fixture-generation.json'},
        'productionConnection':'ProvisioningProfileVerifier.read -> existing inventory -> same no-follow readOwnedMaterial -> CMS actual SecKey signature and explicit-anchor SecTrust -> signed plist summary.',
        'newDependencies':False,'privateKeysTrackedOrCopiedToEvidence':False,
        'trustScope':'Explicit supplied roots, anchor-only, no network fetch, fixed caller verification date. Generic X.509 validation is not Apple provisioning policy or revocation proof.',
        'supportedCMS':['DER SignedData data content','issuer+serial or SKI signer','all signers verified','encapsulated/detached content','signedAttrs contentType/messageDigest and complete DER SET bytes','direct no-attributes signatures','RSA PKCS1v15 SHA1/256/384/512','ECDSA X962 SHA1/256/384/512'],
        'remaining':['BER indefinite/constructed content','RSA-PSS and other algorithms','Apple provisioning signer policy and configured production anchors','DER-Encoded-Profile authority','entitlement/device/App/Team matching','revocation and authenticated timestamps','CMS CodeDirectory/hash-agility integration','resource seal and trusted replacement adapter','real SDK execution'],
        'accountIdentityEstablished':False,'replacementAuthorized':False,
        'signingInstallationOrRenewalImplemented':False,'physicalDeviceOperationRequested':False,
        'primaryReferences':references}
    (HERE/('preparation-' + version + '.json')).write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':result['status'],'grammarParsedFiles':5,'preparedSwiftMethods':9,
        'actualSwiftSDKExecutions':0,'OpenSSLPositiveCases':6,'OpenSSLTamperRejected':1}))


if __name__ == '__main__': main()
