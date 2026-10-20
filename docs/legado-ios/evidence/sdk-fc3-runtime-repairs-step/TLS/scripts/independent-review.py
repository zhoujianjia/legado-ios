from pathlib import Path
import hashlib,json,re
R=Path.cwd(); S=R/'.build/renewal-fc3-tls-recovery-repair-step'; O=Path(__file__).parent
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def read(p): return json.loads(p.read_bytes())
f=read(S/'final-v1.json'); checks=[]
def ok(condition,label):
    assert condition,label
    checks.append(label)
ok(fact(S/'final-v1.json')==dict(bytes=8414,sha256='a622cf022ad3403d12ebcbb94a8ba4bbd1b206f5f81bfcc762fdaf994a4cb557'),'frozen4source input')
for row in f['files']:
    for kind in ('baseline','candidate','diff'):
        sub=row[kind]; ok(fact(R/sub['path'])=={k:sub[k] for k in ('bytes','sha256')},kind+' '+row['path'])
    ok(fact(R/row['path'])=={k:row['baseline'][k] for k in ('bytes','sha256')},'current canonical baseline '+row['path'])
for row in f['evidence']:
    ok(fact(R/row['path'])=={k:row[k] for k in ('bytes','sha256')},'evidence '+row['path'])
primary=read(R/f['primary']['path']); ok(primary['commit']=='db15acbe6a7f257a859ad9a3bb86097bfe0679d9','pinned official Security source')
for row in primary['files']:
    p=S/'snapshot-v1'/row['path']; ok(fact(p)=={k:row[k] for k in ('bytes','sha256')},'primary '+row['path'])
row=f['files'][0]; old=(R/row['baseline']['path']).read_text(); new=(R/row['candidate']['path']).read_text()
ok(old.split('                guard var clientState')[0]==new.split('                if !server {')[0],'all handshake setup and fresh peer auth unchanged')
ok(old.split('                var version = SSLProtocol.tlsProtocol12',1)[1]==new.split('                var version = SSLProtocol.tlsProtocol12',1)[1],'all negotiated protocol peer verification socket and transport remainder unchanged')
ok('guard clientState.rawValue == 2 else { throw Failure.missingMutualAuthentication }' in new,'client strict certificate-sent retained')
ok('guard freshPeerAuthentication else' in new and new.count('try verifyPeer(tls, expectedPeerDER: expectedPeerDER, rootDER: rootDER, at: date)')==2,'fresh break and repeated exact peer verification')
ok('if server { try status(SSLSetClientSideAuthenticate(tls, .alwaysAuthenticate)) }' in new,'server requests mandatory certificate')
crypto=(S/'snapshot-v1/primary/OSX/libsecurity_ssl/lib/sslCrypto.c').read_text()
ok('if(ctx->protocolSide == kSSLServerSide)' in crypto and 'if (ctx->breakOnClientAuth)' in crypto and 'err = errSSLClientAuthCompleted;' in crypto,'server break documented in actual primary implementation')
fixture=(R/f['files'][2]['candidate']['path']).read_text(); baseline=(R/f['files'][2]['baseline']['path']).read_text()
for signal in ('signal','removalSignal','lookupSignal'):
    ok(fixture.count('defer { '+signal+'.continuation.finish() }')==1,'actual producer finishes '+signal)
ok(fixture.count('peerTask {')==baseline.count('peerTask {')==3,'same three actual peer tasks')
recover=(R/f['files'][3]['candidate']['path']).read_text(); ok('expected.record.submission!' not in recover,'unsafe forceunwrap removed')
ok('try #require(current.record.phase == .uploadIntent)' in recover and '_ = try #require(current.record.submission)' in recover,'recovery only after real owned upload intent')
ok('if event != true { running.cancel(); _ = await running.result }' in recover,'failed event prerequisite cancels and drains operation')
identities=read(S/'snapshot-v1/evidence/test-identities.json'); ok(identities['newDefinitions']==0 and sum(x['unchangedDefinitions'] for x in identities['facts'])==13,'same13 definitions')
report=dict(version=1,reviewer='root independent of candidate author',input=dict(path=str(S/'final-v1.json'),**fact(S/'final-v1.json')),verdict='approved-source-repair-pending-real-SDK-TLS-execution',checksPassed=len(checks),checks=checks,findings=[],remainingConfirmedFindings=[],manualReview='Server branch is fixture-peer use of same Stream, while live installation client retains strictSent. Mandatory client authentication, fresh auth break, trust/CA/exactDER/date verification and complete TLS1.2 handshake remain prerequisites. No peer certificate still fails verifyPeer. Existing Socket/cancel/deadline and verification functions are byte-exact. Producer-owned finish resolves actual event wait cycle; test failure cannot invent cleanup authority.',limits=f['limits'],actualSDKHere=0,testsRerun=0,optionalFollowup='Non-secret role/numeric client state on actual rejection may help next SDK diagnosis; does not alter this source-level safety decision.')
(O/'review-v1.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n'); print(json.dumps(dict(checks=len(checks),verdict=report['verdict'],SDK=0)))
