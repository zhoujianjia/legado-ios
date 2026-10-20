from pathlib import Path
import hashlib, json, re, sys
from collections import Counter
R=Path('F:/yuedu-reader'); S=R/'.build/s2-authenticated-spd-challenge-step'
sys.path.insert(0,str(R/'.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
paths=['Modules/Services/SelfRenewal/SelfRenewalDeveloperAuthentication.swift',
       'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift']
def bind(p):
    b=p.read_bytes(); return dict(path=p.relative_to(R).as_posix(),bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def functions(p):
    b=p.read_bytes(); tree=parser.parse(b); out={}; errors=[]
    def visit(n):
        if n.type in ('ERROR','MISSING') or n.is_missing: errors.append(dict(type=n.type,line=n.start_point[0]+1))
        if n.type=='function_declaration':
            name=n.child_by_field_name('name')
            if name:
                key=b[name.start_byte:name.end_byte].decode()
                out.setdefault(key,[]).append(b[n.start_byte:n.end_byte])
        for c in n.children: visit(c)
    visit(tree.root_node)
    assert not tree.root_node.has_error and not errors, errors
    return out
facts=[]
for path in paths:
    original=functions(R/path); candidate=functions(S/'work'/path)
    if path==paths[0]:
        changed={'signIn','handshake'}; added={'secondaryMode'}
    else:
        changed={'matchesIndependentPasswordAndAuthenticatedResponseVectors',
                 'submitsTrustedDeviceCodeAndRestartsAuthenticatedHandshake',
                 'refusesUnverifiedCryptoMissingMetadataAndStorageFailure','handle'}
        added={'configure'}
    assert set(candidate)-set(original)==added,(path,set(candidate)-set(original))
    actual={k for k in original if Counter(original[k])-Counter(candidate[k])}
    assert actual==changed,(path,actual)
    if path==paths[1]:
        assert len(candidate['all'])==len(original['all'])+1
    oldTests={k for k in original if k.startswith('test') or k in [
        'matchesIndependentPasswordAndAuthenticatedResponseVectors','refusesInvalidServerKeysAndWorkBudgets',
        'rejectsTamperedProofNegotiationAndTokenEnvelope','connectsOnlyThroughActualMaterialAccountValidation',
        'rejectsWrongTeamAfterValidGSACryptoWithoutPersistingCredentials',
        'submitsTrustedDeviceCodeAndRestartsAuthenticatedHandshake','cancellationTerminatesActualLoginAndClearsPendingState',
        'refusesUnverifiedCryptoMissingMetadataAndStorageFailure','appSessionAuthenticatesThroughSameVaultAndReopensStoredSession',
        'appSessionCancelsSecondaryChallengeAndRejectsOldTicket','appOwnerDrainsHeldLoginBeforeLogoutAndRejectsLateResult']}
    if path==paths[1]: assert len(oldTests)==11
    facts.append(dict(baseline=bind(R/path),candidate=bind(S/'work'/path),grammarPassed=True,
        changedFunctions=sorted(changed),addedFunctions=sorted(added),unchangedFunctionCount=len(original)-len(changed),
        swiftCompiled=False,actualTestExecutions=0))
primary=json.loads((S/'primary-binding-v1.json').read_text(encoding='utf-8-sig'))
for f in primary['files']:
    assert bind(R/f['path'])['sha256']==f['sha256']
reference=json.loads((S/'owned-spd-fixtures-reference-v1.json').read_text(encoding='utf-8-sig'))
assert len(reference['checks'])==22 and all(c['roundTrip'] and c['staleNegotiationRejected'] for c in reference['checks'])
result=dict(schema=1,status='source-ready-for-independent-review-sdk-pending',
    sourceFiles=facts,primary=bind(S/'primary-binding-v1.json'),
    fixtureReference=bind(S/'owned-spd-fixtures-reference-v1.json'),
    sourcePreparation=dict(publicFixtureGeneratorAttempts=2,initialFailure='Existing public vector was held in static base64 rather than an inline Data initializer; read-only extraction assertion failed before fixture writes.',successfulAttempts=1),
    authoredRegression=dict(unchangedDefinitionCount=11,changedDefinitions=3,publicSealedVariants=22,
        urlSessionSignedScenarios=17,additionalBadProofChallengeCases=2,actualExecutions=0),
    limits=['Tree-sitter is syntax only; no Swift compiler or actual URLSession/Keychain test executed locally.',
      'Independent Python validates fixture crypto, not the Swift production protocol.',
      'No real Apple login, SMS flow, installation, expiry extension or automatic-renewal acceptance.',
      'Rejecting contradictory outer/SPD modes and unknown explicit codes is the local admission policy, not a proven Apple contract.'],
    invariants=dict(sameAccountOwner=True,sameURLSessionTransport=True,outerErrorBeforeProof=True,proofBeforeSPDInterpretation=True,
        noNewEndpoints=True,challengeSingleUse=True,pendingSeconds=300,allNonDeviceWorkComplete=False,
        automaticSelfRenewalImplemented=False,fullLegadoCompatibilityEstablished=False,legalRedistributionClearanceEstablished=False))
for n in ['pre-review-v1.json']:
    p=R/'.build/s2-authenticated-spd-challenge-independent-review'/n
    if p.exists(): result['independentPreReview']=bind(p)
(S/'final-v1.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(status=result['status'],files=len(paths),syntaxPassed=True,swiftExecutions=0,final=bind(S/'final-v1.json')),ensure_ascii=False))
