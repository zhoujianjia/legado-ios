from pathlib import Path
import hashlib,json
R=Path('F:/yuedu-reader');S=Path(__file__).parent
paths=['Modules/Services/SelfRenewal/SelfRenewalAuthenticatedDeviceStream.swift','Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationFixture.swift','Tests/iOS/yuedu appTests/SelfRenewalInstallationRecoveryTests.swift','Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests.swift']
for p in paths:
 b=(R/p).read_bytes()
 for folder in ['rawbaseline','work']:
  dest=S/folder/p;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(b)
def edit(p,old,new,n=1):
 path=S/'work'/p;txt=path.read_text(encoding='utf-8');assert txt.count(old)==n,(p,txt.count(old));path.write_text(txt.replace(old,new),encoding='utf-8',newline='\n')
edit(paths[0],'''                guard var clientState = (SSLClientCertificateState(rawValue: 0) as SSLClientCertificateState?) else {
                    throw Failure.missingMutualAuthentication
                }
                try status(SSLGetClientCertificateState(tls, &clientState))
                // Public header: None=0, Requested=1, Sent=2, Rejected=3.
                guard clientState.rawValue == 2 else { throw Failure.missingMutualAuthentication }''','''                if !server {
                    guard var clientState = (SSLClientCertificateState(rawValue: 0) as SSLClientCertificateState?) else {
                        throw Failure.missingMutualAuthentication
                    }
                    try status(SSLGetClientCertificateState(tls, &clientState))
                    // The client must have received CertificateRequest and sent
                    // its configured identity (public header: CertSent = 2).
                    guard clientState.rawValue == 2 else { throw Failure.missingMutualAuthentication }
                }
                // Server authentication is established by alwaysAuthenticate,
                // the fresh client-auth break, the actual pinned peer chain
                // verified above and completion of the TLS proof of possession.
                // Apple's SecureTransport implementation writes clientCertState
                // only in its client-side CertificateRequest callback; using
                // that field here rejects an otherwise authenticated server.
                // See Apple Security db15acbe, tlsCallbacks.c/sslContext.c.
                // No absent or mismatched client certificate passes verifyPeer.''')
fixture=S/'work'/paths[1];txt=fixture.read_text(encoding='utf-8');marker='                peerTask {\n';assert txt.count(marker)==3
for signal in ['signal','removalSignal','lookupSignal']:
 replacement='                peerTask {\n                    // The event producer owns termination even when the action\n                    // is waiting for an event this peer failed before emitting.\n                    defer { '+signal+'.continuation.finish() }\n'
 txt=txt.replace(marker,replacement,1)
 # Prevent the next replacement from selecting this already-expanded opening.
 txt=txt.replace(replacement,replacement.replace('peerTask {','peerTask { // owns '+signal),1)
txt=txt.replace('peerTask { // owns signal','peerTask {').replace('peerTask { // owns removalSignal','peerTask {').replace('peerTask { // owns lookupSignal','peerTask {')
fixture.write_text(txt,encoding='utf-8',newline='\n')
recovery=S/'work'/paths[2];txt=recovery.read_text(encoding='utf-8');assert txt.count('await Self.interrupt(')==7;txt=txt.replace('await Self.interrupt(','try await Self.interrupt(')
txt=txt.replace('partial: Bool = true) async -> Error {','partial: Bool = true) async throws -> Error {')
old='''        return await rejected { try await c.upgrade(archive: archive, beforeCreation: { try await state.plan($0) }) }'''
new='''        let error = await rejected { try await c.upgrade(archive: archive, beforeCreation: { try await state.plan($0) }) }
        // Recovery checks require a real owned remote intent. A prior TLS or
        // service failure is a failed precondition, not cleanup/delete authority.
        let current = await state.value()
        try #require(current.record.phase == .uploadIntent)
        _ = try #require(current.record.submission)
        return error''';assert txt.count(old)==1;txt=txt.replace(old,new)
old='''                var changed = expected.record
                changed.submission = Journal.Submission(remotePackagePath: "PublicStaging/reader-renewal-00000000-0000-1000-8000-000000000000.ipa",
                    deviceCertificateSHA256: expected.record.submission!.deviceCertificateSHA256)'''
new='''                let submission = try #require(expected.record.submission)
                var changed = expected.record
                changed.submission = Journal.Submission(remotePackagePath: "PublicStaging/reader-renewal-00000000-0000-1000-8000-000000000000.ipa",
                    deviceCertificateSHA256: submission.deviceCertificateSHA256)''';assert txt.count(old)==1;txt=txt.replace(old,new)
old='''                    let event = await events.next()
                    #expect(event == true)'''
new='''                    let event = await events.next()
                    if event != true { running.cancel(); _ = await running.result }
                    try #require(event == true)''';assert txt.count(old)==1;txt=txt.replace(old,new)
recovery.write_text(txt,encoding='utf-8',newline='\n')
edit(paths[3],'''            let received = await events.next()
            #expect(received != nil)''','''            let received = await events.next()
            if received != true { operation.cancel(); _ = await operation.result }
            try #require(received == true)''')
edit(paths[3],'''            let sent = await replies.next()
            #expect(sent != nil && context.observed.snapshot.lookupRepliesSent == 1)''','''            let sent = await replies.next()
            let replyCount = context.observed.snapshot.lookupRepliesSent
            if sent != true || replyCount != 1 { operation.cancel(); _ = await operation.result }
            try #require(sent == true && replyCount == 1)''')
edit(paths[3],'''            #expect(error as? Transport.Failure == .cancelled)
            #expect(context.observed.snapshot.upgradeRequests == 0)''','''            #expect(error as? Transport.Failure == .cancelled)
            // The actual socket peer has exited after cancellation. Its event
            // stream must terminate before the enclosing action returns.
            let finished = await replies.next()
            #expect(finished == nil)
            #expect(context.observed.snapshot.upgradeRequests == 0)''')
print('WROTE_FOUR_CANDIDATES',json.dumps(paths))
