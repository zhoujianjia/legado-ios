import hashlib
import json
import re
from pathlib import Path

stage=Path('F:/yuedu-reader/.build/s2-certificate-reuse-step')
def read(branch,rel): return (stage/branch/rel).read_text(encoding='utf-8')
vault='Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift'
account='Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountClient.swift'
tests='Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift'
checks=[]
def check(name,condition):
    checks.append({'name':name,'passed':bool(condition)})
    if not condition: raise AssertionError(name)

old=read('rawbaseline',vault);new=read('work',vault)
rebuilt=new
start=rebuilt.index('    /// Certificate-only refresh capability.')
end=rebuilt.index('    /// Account enrollment is scoped',start)
rebuilt=rebuilt[:start]+rebuilt[end:]
start=rebuilt.index('    /// Expired profiles do not force another certificate issue.')
end=rebuilt.index('    /// Called only after the App has refused unresolved account intent',start)
rebuilt=rebuilt[:start]+rebuilt[end:]
check('all existing Vault implementation bytes remain exact after removing only new capability and two methods',rebuilt==old)

old=read('rawbaseline',account);new=read('work',account)
rebuilt=new
start=rebuilt.index('            if let reusable = try await vault.reusableSigningIdentity')
end=rebuilt.index('            let csr = try await vault.certificateSigningRequest',start)
rebuilt=rebuilt[:start]+rebuilt[end:]
csr='''            let csr = try await vault.certificateSigningRequest(in: namespace, keyID: keyID,
                expectedGeneration: expectedGeneration, commonName: account.commonName, emailAddress: account.pin.email)
            try check(operationEpoch)
'''
check('CSR request creation remains one exact block',rebuilt.count(csr)==1)
rebuilt=rebuilt.replace(csr,'',1)
anchor='            let appIDs = try await request(.appIDs,'
rebuilt=rebuilt.replace(anchor,csr+anchor,1)
start=rebuilt.index('    private func downloadProfiles(')
end=rebuilt.index('    /// A read-only certificate-list reconciliation never submits another CSR.',start)
helper=rebuilt[start:end]
loop=helper[helper.index('        var profiles: [Vault.ProfileInput] = []'):helper.index('        return profiles')]
rebuilt=rebuilt[:start]+rebuilt[end:]
call='''        let profiles = try await downloadProfiles(identifiers: identifiers, credentials: credentials,
            operationEpoch: operationEpoch, profileIntent: &profileIntent)
'''
check('existing enrollment profile loop extracted exactly once',rebuilt.count(call)==1)
rebuilt=rebuilt.replace(call,loop,1)
check('all other Account code exact including pending intent reconciliation and post-commit finalization',rebuilt==old)

pat=r'@Test[^\n]*\n\s*func ([^(]+)'
oldtests=read('rawbaseline',tests);newtests=read('work',tests)
oldnames=re.findall(pat,oldtests);newnames=re.findall(pat,newtests)
added=[n for n in newnames if n not in oldnames]
check('15 original test identities preserve order',[n for n in newnames if n in oldnames]==oldnames and len(oldnames)==15)
check('exactly four authored no-argument regression identities',len(added)==4)
changed=[]
for name in oldnames:
    method=re.compile(r'^    func '+re.escape(name)+r'\(.*?^    }',re.M|re.S)
    before=method.search(oldtests);after=method.search(newtests)
    check('existing test method remains present: '+name,before is not None and after is not None)
    if before.group()!=after.group():changed.append(name)
check('only intended old same-key issuance test body changes',changed==['excludesBaselineAndPublishedLeafWhenReusingTheKey'])
check('new regressions use no sleep or timing polling',all('Task.sleep'not in re.search(r'^    func '+re.escape(n)+r'\(.*?^    }',newtests,re.M|re.S).group()for n in added))
for rel in [vault,account,tests]:
    check('canonical source still exact baseline: '+rel,(Path('F:/yuedu-reader')/rel).read_bytes()==(stage/'rawbaseline'/rel).read_bytes())
    check('candidate uses LF: '+rel,b'\r\n'not in(stage/'work'/rel).read_bytes())
result={'validationKind':'source-byte provenance and test inventory only; not Swift grammar/type checking or runtime tests',
        'checks':checks,'failedChecks':0,'baselineTestDefinitions':15,'candidateTestDefinitions':19,
        'addedNoArgumentDefinitions':added,'changedExistingTestDefinitions':changed,
        'actualSwiftSDKExecutions':0,'actualSwiftTestExecutions':0,'actualAppleRequests':0,'cloudQueries':0}
(stage/'source-validation-v1.json').write_bytes((json.dumps(result,indent=2)+'\n').encode())
print(json.dumps({'checks':len(checks),'failed':0,'addedDefinitions':added,'SDK':0}))
