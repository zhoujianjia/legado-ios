import Foundation
import Security
import Testing
@testable import yuedu_app

@Suite("GSA fixed vectors and same actual account transport", .serialized)
struct SelfRenewalDeveloperAuthenticationTests {
    private typealias Auth = SelfRenewalDeveloperAuthentication
    private typealias Client = SelfRenewalDeveloperAccountClient
    private typealias SRP = SelfRenewalGSASRP
    private typealias Vault = SelfRenewalSigningMaterialVault
    private typealias PKI = SelfRenewalSigningOwnedPKIFixture

    @Test("both password protocols match independent Python, SRP proofs, authenticated SPD and 16-byte-IV GCM")
    func matchesIndependentPasswordAndAuthenticatedResponseVectors() async throws {
        try await Self.offMain {
            for v in try Vectors.all() {
                let srp = try SRP(random: { try v.bytes(v.privateA) })
                #expect(srp.clientPublic == (try v.bytes(v.A)))
                let key = try SRP.passwordKey(password: v.password, salt: v.bytes(v.salt), iterations: v.iterations, protocolName: v.kind)
                #expect(key == (try v.bytes(v.passwordKey)))
                let proof = try srp.respond(username: v.username, passwordKey: key, salt: v.bytes(v.salt), serverPublic: v.bytes(v.B))
                #expect(proof.clientProof == (try v.bytes(v.M1)))
                #expect(proof.expectedServerProof == (try v.bytes(v.M2)))
                #expect(proof.sessionKey == (try v.bytes(v.K)))
                try proof.verify(serverProof: v.bytes(v.M2), protocolName: v.kind, spd: v.bytes(v.spd), sc: v.bytes(v.sc), negotiation: v.bytes(v.np))
                let spd = try PropertyListSerialization.propertyList(from: proof.decryptSPD(v.bytes(v.spd)), options: [], format: nil)
                #expect((spd as? [String: Any])?["adsid"] as? String == v.dsid)
                #expect(try SRP.appTokenChecksum(key: v.bytes(v.sk), dsid: v.dsid) == v.bytes(v.checksum))
                let token = try PropertyListSerialization.propertyList(from: SRP.decryptAppToken(v.bytes(v.encryptedToken), key: v.bytes(v.sk)), options: [], format: nil)
                #expect((token as? [String: Any])?["t"] != nil)
                #expect(!String(reflecting: srp).contains(v.privateA))
                #expect(!String(describing: proof).contains(v.K))
                for signed in try SignedVectors.all().filter({ $0.protocol == v.protocol }) {
                    let sealed = try v.bytes(signed.spd)
                    try proof.verify(serverProof: v.bytes(v.M2), protocolName: v.kind, spd: sealed,
                        sc: v.bytes(v.sc), negotiation: v.bytes(signed.np))
                    let fields = try #require(PropertyListSerialization.propertyList(from: proof.decryptSPD(sealed), options: [], format: nil) as? [String: Any])
                    #expect(fields["adsid"] as? String == v.dsid)
                    #expect(fields["GsIdmsToken"] as? String == v.idms)
                    #expect(fields["status-code"] != nil || signed.name == "dangling")
                    do {
                        try proof.verify(serverProof: v.bytes(v.M2), protocolName: v.kind, spd: sealed,
                            sc: v.bytes(v.sc), negotiation: v.bytes(v.np))
                        Issue.record("Changed SPD accepted with the original negotiation MAC")
                    } catch let failure as SRP.Failure { #expect(failure == .negotiation) }
                }
            }
        }
    }
    @Test("unsafe public keys and invalid password work budgets reject before secrets or network")
    func refusesInvalidServerKeysAndWorkBudgets() async throws {
        try await Self.offMain {
            let v = try Vectors.first(); let srp = try SRP(random: { try v.bytes(v.privateA) })
            for value in [Data(repeating: 0, count: 256), try v.bytes(SRP.primeHex), Data(repeating: 1, count: 255)] {
                do { _ = try srp.respond(username: v.username, passwordKey: v.bytes(v.passwordKey), salt: v.bytes(v.salt), serverPublic: value); Issue.record("Unsafe SRP public value accepted") }
                catch let failure as SRP.Failure { #expect([.invalidInput, .invalidServerPublicKey].contains(failure)) }
            }
            for count in [0, 1_000_001] {
                do { _ = try SRP.passwordKey(password: v.password, salt: v.bytes(v.salt), iterations: count, protocolName: .s2k); Issue.record("Unbounded KDF input accepted") }
                catch let failure as SRP.Failure { #expect(failure == .invalidInput) }
            }
        }
    }
    @Test("M2 negotiation MAC and GCM tag are separate mandatory gates")
    func rejectsTamperedProofNegotiationAndTokenEnvelope() async throws {
        try await Self.offMain {
            let v = try Vectors.first(); let srp = try SRP(random: { try v.bytes(v.privateA) })
            let proof = try srp.respond(username: v.username, passwordKey: v.bytes(v.passwordKey), salt: v.bytes(v.salt), serverPublic: v.bytes(v.B))
            do { try proof.verify(serverProof: Data(repeating: 0, count: 32), protocolName: v.kind, spd: v.bytes(v.spd), sc: v.bytes(v.sc), negotiation: v.bytes(v.np)); Issue.record("Bad M2 accepted") }
            catch let failure as SRP.Failure { #expect(failure == .proof) }
            do { try proof.verify(serverProof: v.bytes(v.M2), protocolName: v.kind, spd: v.bytes(v.spd), sc: v.bytes(v.sc), negotiation: Data(repeating: 0, count: 32)); Issue.record("Bad negotiation MAC accepted") }
            catch let failure as SRP.Failure { #expect(failure == .negotiation) }
            var envelope = try v.bytes(v.encryptedToken); envelope[envelope.count - 1] ^= 1
            do { _ = try SRP.decryptAppToken(envelope, key: v.bytes(v.sk)); Issue.record("Bad GCM tag accepted") }
            catch let failure as SRP.Failure { #expect(failure == .encryptedData) }
        }
    }
    @Test("actual SRP login reaches the same URLSession client account/team checks before secure storage")
    func connectsOnlyThroughActualMaterialAccountValidation() async throws {
        // Only the worker does fixture I/O, crypto and Keychain work. Every new
        // assertion is evaluated below on this actual Swift Testing task.
        let worker = Task.detached { () async throws -> LoginBoundaryFacts in
            let modes: [Mode] = [.normal, .missingM2, .missingNP, .missingSPD, .malformedSC, .badM2, .badNP]
            var positive: [Bool] = [], rejected: [[Bool]] = []
            var requesterPosts: [[Bool]] = [], providerSecondary: [Bool] = []
            var sessionLifecycles: [[Bool]] = []
            for mode in modes {
                let f = try await Fixture.make()
                do {
                    await f.peer.set(mode)
                    let auth = try await f.authentication()
                    var returnedOutcome = false, personalTeamMatched = false, authorityRemainsUnproved = false
                    var expectedFailureObserved = false
                    do {
                        let outcome = try await auth.signIn(appleID: f.vector.username, password: f.vector.password)
                        returnedOutcome = true
                        if case .connected(let observation) = outcome {
                            personalTeamMatched = observation.personalTeamMatched
                            authorityRemainsUnproved = !observation.appleSigningAuthorityEstablished && !observation.replacementAuthorized
                        }
                    } catch let failure as Auth.Failure {
                        expectedFailureObserved = [.missingM2, .missingNP, .missingSPD, .malformedSC].contains(mode)
                            && failure == .malformedResponse
                    } catch let failure as SRP.Failure {
                        expectedFailureObserved = (mode == .badM2 && failure == .proof)
                            || (mode == .badNP && failure == .negotiation)
                    }
                    let paths = await f.peer.paths()
                    let requester = await f.peer.requesterIdentityFacts()
                    requesterPosts += requester.posts; providerSecondary += requester.secondary
                    sessionLifecycles.append(f.gsaSessions.facts(expectedRequests: requester.posts.count + requester.secondary.count))
                    let stored = try f.storage.load(namespace: f.namespace.id)
                    if mode == .normal {
                        positive = [returnedOutcome && personalTeamMatched, authorityRemainsUnproved,
                            paths == ["init", "complete", "apptokens", "viewDeveloper.action", "listTeams.action"],
                            stored?.contains(f.vector.token) == true,
                            [f.vector.password, f.vector.idms, "owned-fresh-otp"].allSatisfy { stored?.contains($0) == false },
                            f.storage.successfulSaves() == 1]
                    } else {
                        rejected.append([expectedFailureObserved, !returnedOutcome,
                            paths == ["init", "complete"], stored == nil, f.storage.successfulSaves() == 0])
                    }
                    try await f.cleanup()
                } catch {
                    // Cleanup errors propagate to the parent test as real errors;
                    // detached work never records an unowned Testing issue.
                    try await f.cleanup()
                    throw error
                }
            }
            let identifiers = try await Self.accountIdentifierBoundaryFacts()
            requesterPosts += identifiers.requester.posts; providerSecondary += identifiers.requester.secondary
            sessionLifecycles += identifiers.sessionLifecycles
            let lifecycleFailures = try await Self.gsaSessionFailureFacts()
            return LoginBoundaryFacts(positive: positive, rejected: rejected, identifiers: identifiers,
                requester: RequesterIdentityFacts(posts: requesterPosts, secondary: providerSecondary),
                sessionLifecycles: sessionLifecycles, lifecycleFailures: lifecycleFailures)
        }
        let facts = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        #expect(facts.positive.count == 6)
        #expect(facts.positive.allSatisfy { $0 })
        #expect(facts.rejected.count == 6)
        #expect(facts.rejected.allSatisfy { $0.count == 5 && $0.allSatisfy { $0 } })
        #expect(facts.identifiers.positive.count == 4)
        #expect(facts.identifiers.positive.allSatisfy { $0.count == 12 && $0.allSatisfy { $0 } })
        #expect(facts.identifiers.rejected.count == 8)
        #expect(facts.identifiers.rejected.allSatisfy { $0.count == 7 && $0.allSatisfy { $0 } })
        #expect(facts.identifiers.controls.count == 34)
        #expect(facts.identifiers.controls.allSatisfy { $0 })
        #expect(facts.requester.posts.count == 51)
        #expect(facts.requester.posts.allSatisfy { $0.count == 10 && $0.allSatisfy { $0 } })
        #expect(facts.requester.secondary.count == 8)
        #expect(facts.requester.secondary.allSatisfy { $0 })
        #expect(facts.sessionLifecycles.count == 19)
        #expect(facts.sessionLifecycles.allSatisfy { $0.count == 6 && $0.allSatisfy { $0 } })
        #expect(facts.lifecycleFailures.count == 3)
        #expect(facts.lifecycleFailures.allSatisfy { $0.count == 6 && $0.allSatisfy { $0 } })
    }
    @Test("a valid GSA candidate cannot bypass the sealed personal team pin")
    func rejectsWrongTeamAfterValidGSACryptoWithoutPersistingCredentials() async throws {
        try await Self.fixture { f in
            await f.peer.set(.wrongTeam); let auth = try await f.authentication()
            do { _ = try await auth.signIn(appleID: f.vector.username, password: f.vector.password); Issue.record("Wrong team accepted") }
            catch let failure as Client.Failure { #expect(failure == .teamChanged) }
            #expect(try f.storage.load(namespace: f.namespace.id) == nil)
            #expect(await f.peer.paths() == ["init", "complete", "apptokens", "viewDeveloper.action", "listTeams.action"])
        }
    }
    @Test("trusted-device 2FA uses exact GET routes then repeats SRP; challenge is single use")
    func submitsTrustedDeviceCodeAndRestartsAuthenticatedHandshake() async throws {
        try await Self.fixture { f in
            await f.peer.set(.secondary); let auth = try await f.authentication()
            guard case .verificationRequired(let challenge) = try await auth.signIn(appleID: f.vector.username, password: f.vector.password) else { Issue.record("Missing secondary challenge"); return }
            #expect(try f.storage.load(namespace: f.namespace.id) == nil)
            guard case .connected = try await auth.submitVerificationCode("123456", challengeID: challenge.id) else { Issue.record("Secondary handshake not completed"); return }
            #expect(await f.peer.paths() == ["init", "complete", "trusteddevice", "validate", "init", "complete", "apptokens", "viewDeveloper.action", "listTeams.action"])
            do { _ = try await auth.submitVerificationCode("123456", challengeID: challenge.id); Issue.record("Consumed challenge reused") }
            catch let failure as Auth.Failure { #expect(failure == .expiredChallenge) }
        }
        for scenario in SignedScenario.allCases {
            try await Self.fixture { f in
                try await f.peer.configure(scenario)
                let auth = try await f.authentication()
                if let expected = scenario.failure {
                    do {
                        _ = try await auth.signIn(appleID: f.vector.username, password: f.vector.password)
                        Issue.record("Unsupported or malformed authenticated SPD accepted")
                    } catch let failure as Auth.Failure { #expect(failure == expected) }
                    #expect(await f.peer.paths() == ["init", "complete"])
                    #expect(try f.storage.load(namespace: f.namespace.id) == nil)
                    try await auth.clearPendingAuthentication()
                    return
                }
                let outcome = try await auth.signIn(appleID: f.vector.username, password: f.vector.password)
                if scenario == .normal {
                    guard case .connected = outcome else { Issue.record("Authenticated 200 did not connect"); return }
                    #expect(await f.peer.paths() == ["init", "complete", "apptokens", "viewDeveloper.action", "listTeams.action"])
                    #expect(try f.storage.load(namespace: f.namespace.id)?.contains(f.vector.token) == true)
                    return
                }
                guard case .verificationRequired(let challenge) = outcome else { Issue.record("Authenticated 409 did not challenge"); return }
                #expect(challenge.expiresAt == f.date.addingTimeInterval(300))
                #expect(try f.storage.load(namespace: f.namespace.id) == nil)
                let initial = ["init", "complete"] + (scenario.pushesCode ? ["trusteddevice"] : [])
                #expect(await f.peer.paths() == initial)
                if scenario == .repeatManual {
                    do {
                        _ = try await auth.submitVerificationCode("123456", challengeID: challenge.id)
                        Issue.record("Repeated secondary handshake was accepted")
                    } catch let failure as Auth.Failure { #expect(failure == .unsupportedSecondaryAuthentication) }
                    #expect(await f.peer.paths() == initial + ["validate", "init", "complete"])
                    #expect(try f.storage.load(namespace: f.namespace.id) == nil)
                } else {
                    guard case .connected = try await auth.submitVerificationCode("123456", challengeID: challenge.id) else {
                        Issue.record("Authenticated 409 did not finish the full second handshake"); return
                    }
                    #expect(await f.peer.paths() == initial + ["validate", "init", "complete", "apptokens", "viewDeveloper.action", "listTeams.action"])
                    #expect(try f.storage.load(namespace: f.namespace.id)?.contains(f.vector.token) == true)
                }
                do { _ = try await auth.submitVerificationCode("123456", challengeID: challenge.id); Issue.record("Authenticated 409 challenge reused") }
                catch let failure as Auth.Failure { #expect(failure == .expiredChallenge) }
            }
        }
    }
    @Test("actual URLSession cancellation is observed and no account token is saved")
    func cancellationTerminatesActualLoginAndClearsPendingState() async throws {
        try await Self.fixture { f in
            await f.peer.set(.holdInit); let auth = try await f.authentication()
            let task = Task {
                do { let result = try await auth.signIn(appleID: f.vector.username, password: f.vector.password); await f.peer.finished(); return result }
                catch { await f.peer.finished(); throw error }
            }
            let event = await withTaskCancellationHandler { await f.peer.firstEvent() } onCancel: { task.cancel() }
            if event == .finished { _ = try await task.value; Issue.record("Login ended before init reached peer"); return }
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled login accepted") }
            catch is CancellationError { }
            try await auth.clearPendingAuthentication()
            #expect(try f.storage.load(namespace: f.namespace.id) == nil)
            #expect(await f.peer.paths() == ["init"])
        }
    }
    @Test("proof failures missing device metadata and final Keychain failures stay failures without token leaks")
    func refusesUnverifiedCryptoMissingMetadataAndStorageFailure() async throws {
        for mode in [Mode.badM2, .badNP, .badTag, .missingSerial, .storageFailure] {
            try await Self.fixture { f in
                await f.peer.set(mode); if mode == .storageFailure { f.storage.fail = true }
                let auth = try await f.authentication(serial: mode != .missingSerial)
                do { _ = try await auth.signIn(appleID: f.vector.username, password: f.vector.password); Issue.record("Invalid login accepted") }
                catch let failure as SRP.Failure { #expect([.proof, .negotiation, .encryptedData].contains(failure)) }
                catch let failure as Auth.Failure { #expect(mode == .missingSerial && failure == .missingDeviceMetadata) }
                catch let failure as Client.Failure { #expect(mode == .storageFailure && failure == .storage) }
                let stored = try f.storage.load(namespace: f.namespace.id)
                #expect(stored == nil)
            }
        }
        for mode in [Mode.badM2, .badNP] {
            try await Self.fixture { f in
                try await f.peer.configure(.manual); await f.peer.set(mode)
                let auth = try await f.authentication()
                do { _ = try await auth.signIn(appleID: f.vector.username, password: f.vector.password); Issue.record("Unverified SPD created a challenge") }
                catch let failure as SRP.Failure { #expect(failure == (mode == .badM2 ? .proof : .negotiation)) }
                #expect(await f.peer.paths() == ["init", "complete"])
                #expect(try f.storage.load(namespace: f.namespace.id) == nil)
            }
        }
    }

    @Test("App login uses the actual published namespace and reopens only the verified stored account")
    func appSessionAuthenticatesThroughSameVaultAndReopensStoredSession() async throws {
        try await Self.withAppSession { f, session, root, handoff in
            let before = try await f.vault.lease(in: f.namespace)
            guard case .connected(let observed) = try await session.signInDeveloperAccount(
                appleID: f.vector.username, password: f.vector.password) else {
                Issue.record("App login did not reach actual account validation"); return
            }
            #expect(observed.personalTeamMatched)
            #expect(!observed.appleSigningAuthorityEstablished && !observed.replacementAuthorized)
            let loaded = try f.storage.load(namespace: f.namespace.id)
            let stored = try #require(loaded)
            #expect(stored.contains(f.vector.token))
            #expect(!stored.contains(f.vector.password) && !stored.contains(f.vector.idms))
            let after = try await f.vault.lease(in: f.namespace)
            #expect(after.keyID == before.keyID && after.generation == before.generation)
            try await session.close()
            let reopened = f.appSession(root: root)
            do {
                _ = try await reopened.bootstrap(handoff: handoff)
                let restored = try await reopened.observeDeveloperAccount()
                #expect(restored.personalTeamMatched)
                #expect(await f.peer.paths() == ["init", "complete", "apptokens", "viewDeveloper.action", "listTeams.action",
                    "viewDeveloper.action", "listTeams.action"])
                try await reopened.close()
            } catch {
                do { try await Task.detached { try await reopened.close() }.value } catch { Issue.record(error) }
                throw error
            }
        }
    }

    @Test("App cancellation clears the same pending 2FA state and an old ticket cannot reach validate")
    func appSessionCancelsSecondaryChallengeAndRejectsOldTicket() async throws {
        try await Self.withAppSession { f, session, _, _ in
            await f.peer.set(.secondary)
            guard case .verificationRequired(let challenge) = try await session.signInDeveloperAccount(
                appleID: f.vector.username, password: f.vector.password) else {
                Issue.record("App login did not retain a real secondary challenge"); return
            }
            let paths = await f.peer.paths()
            let cancelled = try await session.cancelDeveloperAuthentication()
            #expect(cancelled.confirmedSession == nil)
            do {
                _ = try await session.submitDeveloperVerificationCode("123456", challengeID: challenge.id)
                Issue.record("Cancelled App challenge was reusable")
            } catch let error as Auth.Failure { #expect(error == .expiredChallenge) }
            #expect(await f.peer.paths() == paths)
            #expect(try f.storage.load(namespace: f.namespace.id) == nil)
            guard case .verificationRequired(let replacement) = try await session.signInDeveloperAccount(
                appleID: f.vector.username, password: f.vector.password) else {
                Issue.record("Fresh App login could not issue a new challenge"); return
            }
            #expect(replacement.id != challenge.id)
            try await session.signOutDeveloperAccount()
            do {
                _ = try await session.submitDeveloperVerificationCode("123456", challengeID: replacement.id)
                Issue.record("Signed-out App challenge was reusable")
            } catch let error as Auth.Failure { #expect(error == .expiredChallenge) }
        }
    }

    @Test("observable App owner cancels and drains the held login before erasing credentials; old completion stays old")
    func appOwnerDrainsHeldLoginBeforeLogoutAndRejectsLateResult() async throws {
        try await Self.fixture(seedPublishedLease: true) { f in
            let inputs = try f.appInputs()
            let date = f.date, vector = f.vector
            let owner = await MainActor.run {
                SelfRenewalAppOwner(root: inputs.root, currentApplicationRoot: f.directory.appendingPathComponent("Owned.app"),
                    developerServices: inputs.services, developerAuthenticationRandom: { try vector.bytes(vector.privateA) }, clock: { date })
            }
            do {
                await owner.bootstrap(); await owner.importConfiguration(inputs.configuration)
                let configured = await owner.status
                #expect(configured?.access == .signing)
                await f.peer.set(.holdInit)
                let login = Task {
                    await owner.signInDeveloperAccount(appleID: vector.username, password: vector.password)
                    await f.peer.finished()
                }
                let event = await withTaskCancellationHandler { await f.peer.firstEvent() } onCancel: { login.cancel() }
                if event == .finished {
                    await login.value; Issue.record("App login ended before init reached the actual peer")
                } else {
                    let working = await owner.isWorking
                    #expect(working)
                    await owner.signOutDeveloperAccount()
                    await login.value
                    let state = await MainActor.run {
                        (owner.isWorking, owner.developerSession == nil, owner.developerChallenge == nil, owner.problem == nil)
                    }
                    #expect(!state.0 && state.1 && state.2 && state.3)
                    #expect(try f.storage.load(namespace: f.namespace.id) == nil)
                    #expect(await f.peer.paths() == ["init"])
                }
                try await owner.close()
            } catch {
                do { try await Task.detached { try await owner.close() }.value } catch { Issue.record(error) }
                throw error
            }
        }
    }

    nonisolated private static func withAppSession(
        _ action: @escaping @Sendable (Fixture, SelfRenewalAppSession, URL, SelfRenewalUserDataHandoff) async throws -> Void
    ) async throws {
        try await Self.fixture(seedPublishedLease: true) { f in
            let inputs = try f.appInputs()
            let session = f.appSession(root: inputs.root)
            let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
            do {
                _ = try await session.bootstrap(handoff: handoff)
                _ = try await session.configure(from: inputs.configuration, handoff: handoff)
                try await action(f, session, inputs.root, handoff)
                try await session.close()
            } catch {
                do { try await Task.detached { try await session.close() }.value } catch { Issue.record(error) }
                throw error
            }
        }
    }

    private struct LoginBoundaryFacts: Sendable {
        let positive: [Bool]
        let rejected: [[Bool]]
        let identifiers: IdentifierBoundaryFacts
        let requester: RequesterIdentityFacts
        let sessionLifecycles: [[Bool]]
        let lifecycleFailures: [[Bool]]
    }
    private enum GSAClientFixture {
        static let providerClientInfo = "<OwnedModel1,1> <Owned OS;1;A> <OwnedProvider/1>"
        static let requesterUserAgent = "akd/1.0 CFNetwork/808.1.4"
    }
    private struct RequesterIdentityFacts: Sendable {
        let posts: [[Bool]]
        let secondary: [Bool]
    }
    private struct IdentifierBoundaryFacts: Sendable {
        let positive: [[Bool]]
        let rejected: [[Bool]]
        let controls: [Bool]
        let requester: RequesterIdentityFacts
        let sessionLifecycles: [[Bool]]
    }
    /// All new opaque-ID checks return plain facts to the parent @Test. Crypto,
    /// fixture I/O and URLProtocol callbacks never own new Testing assertions.
    nonisolated private static func accountIdentifierBoundaryFacts() async throws -> IdentifierBoundaryFacts {
        let vectors = try Vectors.all()
        var positive: [[Bool]] = [], rejected: [[Bool]] = [], controls: [Bool] = []
        var requesterPosts: [[Bool]] = [], providerSecondary: [Bool] = []
        var sessionLifecycles: [[Bool]] = []
        for sample in try IdentifierVectors.all() {
            guard let vector = vectors.first(where: { $0.protocol == sample.protocol }) else { throw FixtureFailure.invalid }
            let f = try await Fixture.make(vector: vector)
            do {
                await f.peer.configureIdentifier(sample)
                let auth = try await f.authentication()
                if sample.name == "opaque" || sample.name == "maximum" {
                    let checksumMatches = try SRP.appTokenChecksum(key: vector.bytes(vector.sk), dsid: sample.adsid) == vector.bytes(sample.checksum)
                    var challenged = false, expiryMatches = false, noEarlyStorage = false
                    var connected = false, authorityRemainsUnproved = false
                    if case .verificationRequired(let challenge) = try await auth.signIn(appleID: vector.username, password: vector.password) {
                        challenged = true; expiryMatches = challenge.expiresAt == f.date.addingTimeInterval(300)
                        noEarlyStorage = try f.storage.load(namespace: f.namespace.id) == nil && f.storage.successfulSaves() == 0
                        if case .connected(let observation) = try await auth.submitVerificationCode("123456", challengeID: challenge.id) {
                            connected = observation.personalTeamMatched
                            authorityRemainsUnproved = !observation.appleSigningAuthorityEstablished && !observation.replacementAuthorized
                        }
                    }
                    let stored = try f.storage.load(namespace: f.namespace.id)
                    var storedIdentityMatches = false
                    if let stored,
                       let record = try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any],
                       let credentials = record["credentials"] as? [String: Any], let pin = record["pin"] as? [String: Any] {
                        storedIdentityMatches = credentials["dsid"] as? String == sample.adsid && pin["dsid"] as? String == sample.adsid
                    }
                    let paths = await f.peer.paths(), requests = await f.peer.identifierRequestChecks()
                    positive.append([checksumMatches, challenged, expiryMatches, noEarlyStorage, connected, authorityRemainsUnproved,
                        paths == ["init", "complete", "trusteddevice", "validate", "init", "complete", "apptokens", "viewDeveloper.action", "listTeams.action"],
                        requests.count == 31 && requests.allSatisfy { $0 }, storedIdentityMatches,
                        stored?.contains(vector.token) == true,
                        [vector.password, vector.idms, "owned-fresh-otp"].allSatisfy { stored?.contains($0) == false },
                        f.storage.successfulSaves() == 1])
                } else {
                    var checksumRejected = false, expectedFailure = false, returnedOutcome = false
                    do { _ = try SRP.appTokenChecksum(key: vector.bytes(vector.sk), dsid: sample.adsid) }
                    catch let failure as SRP.Failure { checksumRejected = failure == .invalidInput }
                    do { _ = try await auth.signIn(appleID: vector.username, password: vector.password); returnedOutcome = true }
                    catch let failure as Auth.Failure { expectedFailure = failure == .malformedResponse }
                    let paths = await f.peer.paths(), requests = await f.peer.identifierRequestChecks()
                    rejected.append([checksumRejected, expectedFailure, !returnedOutcome, paths == ["init", "complete"],
                        requests.count == 7 && requests.allSatisfy { $0 },
                        try f.storage.load(namespace: f.namespace.id) == nil, f.storage.successfulSaves() == 0])
                }
                let requester = await f.peer.requesterIdentityFacts()
                requesterPosts += requester.posts; providerSecondary += requester.secondary
                sessionLifecycles.append(f.gsaSessions.facts(expectedRequests: requester.posts.count + requester.secondary.count))
                try await f.cleanup()
            } catch {
                try await f.cleanup()
                throw error
            }
        }
        guard let vector = vectors.first else { throw FixtureFailure.invalid }
        for scalar in Array(0...31) + [127, 0x85] {
            let identifier = "Public" + String(UnicodeScalar(scalar)!) + "-Fixture"
            var refused = false
            do { _ = try SRP.appTokenChecksum(key: vector.bytes(vector.sk), dsid: identifier) }
            catch let failure as SRP.Failure { refused = failure == .invalidInput }
            controls.append(refused)
        }
        return IdentifierBoundaryFacts(positive: positive, rejected: rejected, controls: controls,
            requester: RequesterIdentityFacts(posts: requesterPosts, secondary: providerSecondary), sessionLifecycles: sessionLifecycles)
    }
    nonisolated private static func gsaSessionFailureFacts() async throws -> [[Bool]] {
        var rejected: [[Bool]] = []
        for boundary in 0...2 {
            let f = try await Fixture.make()
            do {
                var expectedFailure = false, returnedOutcome = false
                if boundary == 2 {
                    var request = URLRequest(url: URL(string: "https://gsa.apple.com/not-allowlisted")!)
                    request.httpMethod = "GET"
                    do { _ = try await f.transport.send(request); returnedOutcome = true }
                    catch let failure as SelfRenewalDeveloperAccountTransportFailure { expectedFailure = failure == .wrongEndpoint }
                } else {
                    await f.peer.set(boundary == 0 ? .http503 : .holdInit)
                    let auth = try await f.authentication()
                    if boundary == 0 {
                        do { _ = try await auth.signIn(appleID: f.vector.username, password: f.vector.password); returnedOutcome = true }
                        catch let failure as Auth.Failure { expectedFailure = failure == .http(503) }
                    } else {
                        let operation = Task { try await auth.signIn(appleID: f.vector.username, password: f.vector.password) }
                        _ = await f.peer.firstEvent()
                        operation.cancel()
                        do { _ = try await operation.value; returnedOutcome = true }
                        catch is CancellationError { expectedFailure = true }
                    }
                }
                let paths = await f.peer.paths()
                let expectedRequests = boundary == 2 ? 0 : 1
                let lifecycle = f.gsaSessions.facts(expectedRequests: expectedRequests)
                rejected.append([expectedFailure, !returnedOutcome, paths == (boundary == 2 ? [] : ["init"]),
                    try f.storage.load(namespace: f.namespace.id) == nil, f.storage.successfulSaves() == 0,
                    lifecycle.count == 6 && lifecycle.allSatisfy { $0 }])
                try await f.cleanup()
            } catch {
                try await f.cleanup()
                throw error
            }
        }
        return rejected
    }
    private enum Mode: Sendable { case normal, wrongTeam, secondary, holdInit, http503, badM2, badNP, badTag, missingSerial, storageFailure, missingM2, missingNP, missingSPD, malformedSC }
    private enum SignedScenario: String, CaseIterable, Sendable {
        case manual, trusted, matchedTrusted, normal, manualConflict, trustedConflict, normalConflict
        case sms, absolute, empty, typedURL, textCode, boolCode, unexpected, dangling, repeatManual, outerError
        var payload: String {
            switch self {
            case .matchedTrusted, .trustedConflict: return "trusted"
            case .manualConflict, .repeatManual, .outerError: return "manual"
            case .normalConflict: return "normal"
            default: return rawValue
            }
        }
        var outerMode: String? {
            switch self {
            case .matchedTrusted, .manualConflict, .normalConflict: return "trustedDeviceSecondaryAuth"
            case .trustedConflict: return "secondaryAuth"
            default: return nil
            }
        }
        var pushesCode: Bool { self == .trusted || self == .matchedTrusted }
        var failure: Auth.Failure? {
            switch self {
            case .manual, .trusted, .matchedTrusted, .normal, .repeatManual: return nil
            case .typedURL, .textCode, .boolCode, .dangling: return .malformedResponse
            case .outerError: return .incorrectCredentials
            default: return .unsupportedSecondaryAuthentication
            }
        }
    }
    private enum FixtureFailure: Error { case invalid }
    private actor Peer {
        let vector: Vector; let team: String
        private var mode: Mode = .normal, validated = false
        private var signedScenario: SignedScenario?
        private var signedVector: SignedVector?
        private var identifierVector: IdentifierVector?
        private var identifierChecks: [Bool] = []
        private var requesterPosts: [[Bool]] = []
        private var providerSecondary: [Bool] = []
        private var history: [String] = []
        enum Event: Sendable, Equatable { case initArrived, finished }
        private var event: Event?; private var waiters: [CheckedContinuation<Event, Never>] = []
        init(vector: Vector, team: String) { self.vector = vector; self.team = team }
        func set(_ mode: Mode) { self.mode = mode }
        func configure(_ scenario: SignedScenario) throws {
            signedVector = try #require(SignedVectors.all().first { $0.protocol == vector.protocol && $0.name == scenario.payload })
            signedScenario = scenario
        }
        func configureIdentifier(_ value: IdentifierVector) { identifierVector = value }
        func identifierRequestChecks() -> [Bool] { identifierChecks }
        func httpStatusCode() -> Int { mode == .http503 ? 503 : 200 }
        func requesterIdentityFacts() -> RequesterIdentityFacts { RequesterIdentityFacts(posts: requesterPosts, secondary: providerSecondary) }
        func paths() -> [String] { history }
        func firstEvent() async -> Event { if let event { return event }; return await withCheckedContinuation { waiters.append($0) } }
        func finished() { observe(.finished) }
        private func observe(_ value: Event) {
            guard event == nil else { return }; event = value
            let values = waiters; waiters.removeAll(); values.forEach { $0.resume(returning: value) }
        }
        func handle(_ request: URLRequest) async throws -> Data {
            if request.url?.host == "gsa.apple.com",
               ["/auth/verify/trusteddevice", "/grandslam/GsService2/validate"].contains(request.url?.path ?? "") {
                providerSecondary.append(request.value(forHTTPHeaderField: "X-MMe-Client-Info") == GSAClientFixture.providerClientInfo)
            }
            if let identifierVector { return try handleIdentifier(request, sample: identifierVector) }
            guard let url = request.url else { throw FixtureFailure.invalid }
            if url.host == "developerservices2.apple.com" {
                #expect(request.value(forHTTPHeaderField: "X-Apple-GS-Token") == vector.token)
                let name = url.lastPathComponent; history.append(name)
                if name == "viewDeveloper.action" { return try Self.plist(["resultCode": 0, "developer": ["personId": 2001, "email": vector.username, "firstName": "Owned", "lastName": "Account"]]) }
                if name == "listTeams.action" { return try Self.plist(["resultCode": 0, "teams": [["teamId": mode == .wrongTeam ? "OTHERTEAM1" : team, "type": "Individual", "memberships": [["name": "Free Provisioning"]]]]]) }
                throw FixtureFailure.invalid
            }
            #expect(url.host == "gsa.apple.com")
            if url.path == "/auth/verify/trusteddevice" { history.append("trusteddevice"); #expect(request.httpMethod == "GET"); return try Self.plist(["ec": 0]) }
            if url.path == "/grandslam/GsService2/validate" {
                history.append("validate"); #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "security-code") == "123456")
                #expect(request.value(forHTTPHeaderField: "X-Apple-Identity-Token") == Data((vector.dsid + ":" + vector.idms).utf8).base64EncodedString())
                validated = true; return try Self.plist(["ec": "0"])
            }
            let body = try Self.body(request)
            let inner = try #require(body["Request"] as? [String: Any]); let operation = try #require(inner["o"] as? String)
            history.append(operation)
            let cpd = try #require(inner["cpd"] as? [String: Any]); #expect(cpd["X-Apple-I-SRL-NO"] as? String == "owned-public-serial")
            recordRequesterIdentity(request, cpd: cpd)
            switch operation {
            case "init":
                #expect(inner["A2k"] as? Data == (try vector.bytes(vector.A)))
                #expect(inner["u"] as? String == vector.username)
                observe(.initArrived)
                if mode == .holdInit { let pair = AsyncStream<Void>.makeStream(); for await _ in pair.stream {}; throw CancellationError() }
                return try Self.envelope(["sp": vector.kind.rawValue, "s": vector.bytes(vector.salt), "i": vector.iterations, "B": vector.bytes(vector.B), "c": "public-continuation"])
            case "complete":
                #expect(inner["M1"] as? Data == (try vector.bytes(vector.M1)))
                var status: [String: Any] = ["ec": 0]
                if mode == .secondary && !validated { status["au"] = "trustedDeviceSecondaryAuth" }
                let signed = !validated || signedScenario == .repeatManual ? signedVector : nil
                if signed != nil {
                    if let kind = signedScenario?.outerMode { status["au"] = kind }
                    if signedScenario == .outerError { status["ec"] = -22406 }
                }
                var complete: [String: Any] = try ["Status": status, "M2": mode == .badM2 ? Data(repeating: 0, count: 32) : vector.bytes(vector.M2),
                    "spd": vector.bytes(signed?.spd ?? vector.spd), "sc": vector.bytes(vector.sc),
                    "np": mode == .badNP ? Data(repeating: 0, count: 32) : vector.bytes(signed?.np ?? vector.np)]
                if mode == .missingM2 { complete.removeValue(forKey: "M2") }
                if mode == .missingNP { complete.removeValue(forKey: "np") }
                if mode == .missingSPD { complete.removeValue(forKey: "spd") }
                if mode == .malformedSC { complete["sc"] = true }
                return try Self.plist(["Response": complete])
            case "apptokens":
                #expect(inner["checksum"] as? Data == (try vector.bytes(vector.checksum)))
                #expect(inner["u"] as? String == vector.dsid && inner["t"] as? String == vector.idms)
                var token = try vector.bytes(vector.encryptedToken); if mode == .badTag { token[token.count - 1] ^= 1 }
                return try Self.envelope(["et": token])
            default: throw FixtureFailure.invalid
            }
        }
        private func handleIdentifier(_ request: URLRequest, sample: IdentifierVector) throws -> Data {
            guard let url = request.url else { throw FixtureFailure.invalid }
            if url.host == "developerservices2.apple.com" {
                let name = url.lastPathComponent; history.append(name)
                identifierChecks += [request.httpMethod == "POST",
                    request.value(forHTTPHeaderField: "X-Apple-I-Identity-Id") == sample.adsid,
                    request.value(forHTTPHeaderField: "X-Apple-GS-Token") == vector.token]
                if name == "viewDeveloper.action" {
                    return try Self.plist(["resultCode": 0, "developer": ["personId": 2001, "email": vector.username, "firstName": "Owned", "lastName": "Account"]])
                }
                if name == "listTeams.action" {
                    return try Self.plist(["resultCode": 0, "teams": [["teamId": team, "type": "Individual", "memberships": [["name": "Free Provisioning"]]]]])
                }
                throw FixtureFailure.invalid
            }
            guard url.host == "gsa.apple.com" else { throw FixtureFailure.invalid }
            let identityToken = Data((sample.adsid + ":" + vector.idms).utf8).base64EncodedString()
            if url.path == "/auth/verify/trusteddevice" {
                history.append("trusteddevice")
                identifierChecks += [request.httpMethod == "GET", request.value(forHTTPHeaderField: "X-Apple-Identity-Token") == identityToken]
                return try Self.plist(["ec": 0])
            }
            if url.path == "/grandslam/GsService2/validate" {
                history.append("validate")
                identifierChecks += [request.httpMethod == "GET", request.value(forHTTPHeaderField: "X-Apple-Identity-Token") == identityToken,
                    request.value(forHTTPHeaderField: "security-code") == "123456"]
                validated = true; return try Self.plist(["ec": "0"])
            }
            guard url.path == "/grandslam/GsService2" else { throw FixtureFailure.invalid }
            let body = try Self.body(request)
            guard let inner = body["Request"] as? [String: Any], let operation = inner["o"] as? String,
                  let cpd = inner["cpd"] as? [String: Any] else { throw FixtureFailure.invalid }
            history.append(operation)
            recordRequesterIdentity(request, cpd: cpd)
            identifierChecks += [request.httpMethod == "POST", cpd["X-Apple-I-SRL-NO"] as? String == "owned-public-serial"]
            switch operation {
            case "init":
                identifierChecks += [inner["A2k"] as? Data == (try vector.bytes(vector.A)), inner["u"] as? String == vector.username]
                return try Self.envelope(["sp": vector.kind.rawValue, "s": vector.bytes(vector.salt), "i": vector.iterations, "B": vector.bytes(vector.B), "c": "public-continuation"])
            case "complete":
                identifierChecks.append(inner["M1"] as? Data == (try vector.bytes(vector.M1)))
                var status: [String: Any] = ["ec": 0]
                if !validated { status["au"] = "trustedDeviceSecondaryAuth" }
                // These independent variants omit SC, as did the real device;
                // M2 and the recomputed NP remain mandatory for both handshakes.
                return try Self.plist(["Response": ["Status": status, "M2": vector.bytes(vector.M2),
                    "spd": vector.bytes(validated ? sample.finalSPD : sample.initialSPD),
                    "np": vector.bytes(validated ? sample.finalNP : sample.initialNP)]])
            case "apptokens":
                identifierChecks += [inner["u"] as? String == sample.adsid, inner["t"] as? String == vector.idms,
                    inner["checksum"] as? Data == (try vector.bytes(sample.checksum)), inner["c"] as? Data == (try vector.bytes(vector.cookie))]
                return try Self.envelope(["et": vector.bytes(vector.encryptedToken)])
            default: throw FixtureFailure.invalid
            }
        }
        private func recordRequesterIdentity(_ request: URLRequest, cpd: [String: Any]) {
            // Facts only: assertions belong to the selected parent @Test. The
            // unchanged provider identity is also checked on the 2FA requests.
            requesterPosts.append([
                request.value(forHTTPHeaderField: "User-Agent") == GSAClientFixture.requesterUserAgent,
                request.value(forHTTPHeaderField: "X-MMe-Client-Info") == GSAClientFixture.providerClientInfo,
                cpd["X-MMe-Client-Info"] as? String == GSAClientFixture.providerClientInfo,
                request.value(forHTTPHeaderField: "X-Xcode-Version") == nil,
                cpd["X-Apple-I-MD"] as? String == "owned-fresh-otp",
                cpd["X-Apple-I-MD-M"] as? String == "owned-machine",
                cpd["X-Apple-I-MD-LU"] as? String == "owned-user",
                cpd["X-Apple-I-MD-RINFO"] as? String == "1",
                cpd["X-Mme-Device-Id"] as? String == "owned-device",
                cpd["X-Apple-I-SRL-NO"] as? String == "owned-public-serial"
            ])
        }
        private static func envelope(_ value: [String: Any]) throws -> Data { var value = value; value["Status"] = ["ec": 0]; return try plist(["Response": value]) }
        private static func plist(_ value: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
        private static func body(_ request: URLRequest) throws -> [String: Any] {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); guard count > 0, data.count + count <= 65_536 else { throw FixtureFailure.invalid }; data.append(contentsOf: buffer.prefix(count)) }
            }
            guard let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw FixtureFailure.invalid }
            return decoded
        }
    }
    private final class PeerProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var peer: Peer?
        private let operationLock = NSLock(); private var operation: Task<Void, Never>?; private var stopped = false
        static func install(_ peer: Peer?) { lock.lock(); defer { lock.unlock() }; self.peer = peer }
        private static func current() -> Peer? { lock.lock(); defer { lock.unlock() }; return peer }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let peer = Self.current() else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
            let started = Task {
                do {
                    let body = try await peer.handle(request); try Task.checkCancellation()
                    let status = await peer.httpStatusCode()
                    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/x-xml-plist", "Content-Length": String(body.count)])!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
                } catch { client?.urlProtocol(self, didFailWithError: URLError(error is CancellationError ? .cancelled : .badServerResponse)) }
            }
            operationLock.lock(); let wasStopped = stopped; if !wasStopped { operation = started }; operationLock.unlock(); if wasStopped { started.cancel() }
        }
        override func stopLoading() { operationLock.lock(); stopped = true; let value = operation; operation = nil; operationLock.unlock(); value?.cancel() }
    }
    private final class Storage: @unchecked Sendable, SelfRenewalDeveloperSessionStorage {
        private let base = SelfRenewalDeveloperKeychainSessionStorage()
        private let lock = NSLock(); private var shouldFail = false; private var saves = 0
        var fail: Bool { get { lock.lock(); defer { lock.unlock() }; return shouldFail } set { lock.lock(); defer { lock.unlock() }; shouldFail = newValue } }
        func load(namespace: UUID) throws -> String? { try base.load(namespace: namespace) }
        func save(namespace: UUID, value: String) throws {
            guard !fail else { throw Client.Failure.storage }; try base.save(namespace: namespace, value: value)
            lock.lock(); saves += 1; lock.unlock()
        }
        func successfulSaves() -> Int { lock.lock(); defer { lock.unlock() }; return saves }
        func cleanup(_ namespace: UUID) throws { guard KeychainHelper.delete(account: namespace.uuidString, service: "com.yuedu.selfRenewal.developerSession.v1", synchronizable: false) else { throw Client.Failure.storage } }
    }
    /// Retain the actual sessions until facts are collected: bare object IDs
    /// could be reused after deallocation and falsely suggest pool reuse.
    private final class GSASessionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [URLSession] = []
        private var invalidated: [ObjectIdentifier] = []
        private var configurations: [Bool] = []
        func observe(_ event: SelfRenewalDeveloperURLSessionTransport.GSASessionEvent, session: URLSession) {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .created:
                created.append(session)
                let configuration = session.configuration
                configurations.append(configuration.urlCache == nil && configuration.httpCookieStorage == nil
                    && configuration.urlCredentialStorage == nil && !configuration.httpShouldSetCookies
                    && configuration.httpMaximumConnectionsPerHost == 1
                    && configuration.timeoutIntervalForRequest == 30 && configuration.timeoutIntervalForResource == 30
                    && configuration.protocolClasses?.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(PeerProtocol.self) }) == true)
            case .invalidated: invalidated.append(ObjectIdentifier(session))
            }
        }
        func facts(expectedRequests: Int) -> [Bool] {
            lock.lock(); defer { lock.unlock() }
            let identifiers = created.map { ObjectIdentifier($0) }
            return [created.count == expectedRequests, invalidated.count == expectedRequests,
                Set(identifiers).count == expectedRequests, Set(invalidated) == Set(identifiers),
                Set(invalidated).count == invalidated.count,
                configurations.count == expectedRequests && configurations.allSatisfy { $0 }]
        }
    }
    private final class Fixture: @unchecked Sendable {
        let directory: URL; let material: SelfRenewalApplicationMaterialVerifier.Materials
        let date = Date(timeIntervalSince1970: 1_792_540_800)
        let vault: Vault; let namespace: Vault.Namespace; let vector: Vector; let peer: Peer; let anchors: [Data]
        let storage = Storage(); let transport: SelfRenewalDeveloperURLSessionTransport
        let gsaSessions: GSASessionRecorder
        init(directory: URL, material: SelfRenewalApplicationMaterialVerifier.Materials, vault: Vault, namespace: Vault.Namespace, vector: Vector, anchors: [Data]) {
            self.directory = directory; self.material = material; self.vault = vault; self.namespace = namespace; self.vector = vector; self.anchors = anchors
            peer = Peer(vector: vector, team: material.bundles[0].slices[0].teamIdentifier)
            let recorder = GSASessionRecorder(); gsaSessions = recorder
            transport = SelfRenewalDeveloperURLSessionTransport(protocolClasses: [PeerProtocol.self], gsaSessionObservation: { event, session in
                recorder.observe(event, session: session)
            })
        }
        private func anisette(serial: Bool = true) -> @Sendable () async throws -> Client.Anisette {
            let date = date
            return {
                var value = Client.Anisette(machineID: "owned-machine", oneTimePassword: "owned-fresh-otp", localUserID: "owned-user", routingInfo: 1,
                    deviceID: "owned-device", clientInfo: GSAClientFixture.providerClientInfo, issuedAt: date, locale: "en_US", timeZone: "UTC")
                if serial { value.deviceSerialNumber = "owned-public-serial" }; return value
            }
        }
        func authentication(serial: Bool = true) async throws -> Auth {
            let date = date, anisette = anisette(serial: serial)
            let client = try await Client.open(vault: vault, namespace: namespace, identity: material, issuerChainDER: [], transport: transport,
                storage: storage, freshAnisette: anisette, clock: { date })
            let vector = vector
            return Auth(account: client, transport: transport, freshAnisette: anisette, clock: { date }, random: { try vector.bytes(vector.privateA) })
        }
        func appInputs() throws -> (root: URL, configuration: URL, services: SelfRenewalAppSession.DeveloperServices) {
            let root = directory.appendingPathComponent("SelfRenewalApp")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let configuration = directory.appendingPathComponent("app-session-configuration.json")
            let proposed = SelfRenewalAppSession.Configuration(schema: 1, namespaceID: namespace.id,
                codeAnchors: anchors, profileAnchors: anchors, device: nil)
            try JSONEncoder().encode(proposed).write(to: configuration)
            return (root, configuration, SelfRenewalAppSession.DeveloperServices(transport: transport, storage: storage,
                freshAnisette: anisette()))
        }
        func appSession(root: URL) -> SelfRenewalAppSession {
            let date = date, vector = vector
            let services = SelfRenewalAppSession.DeveloperServices(transport: transport, storage: storage, freshAnisette: anisette())
            return SelfRenewalAppSession(root: root, currentApplicationRoot: directory.appendingPathComponent("Owned.app"),
                developerServices: services, developerAuthenticationRandom: { try vector.bytes(vector.privateA) }, clock: { date })
        }
        func cleanup() async throws {
            // Test cleanup must run even when the actual worker was cancelled;
            // Vault.current/destroy intentionally reject that cancelled task.
            // Await the owned cleanup task; it owns no network or new stores.
            try await Task.detached { [self] in
                PeerProtocol.install(nil)
                let generation = try await vault.generation(in: namespace)
                try await vault.destroy(namespace, expectedGeneration: generation)
                try storage.cleanup(namespace.id); try FileManager.default.removeItem(at: directory)
            }.value
        }
        static func make(seedPublishedLease: Bool = false, vector: Vector? = nil) async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-gsa-" + UUID().uuidString)
            let root = directory.appendingPathComponent("Owned.app"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var cleanupVault: Vault?; var cleanupNamespace: Vault.Namespace?
            do {
                for bundle in SelfRenewalApplicationMaterialFixture.bundles {
                    let target = bundle.relativePath == "." ? root : root.appendingPathComponent(bundle.relativePath)
                    try FileManager.default.createDirectory(at: target.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
                    for (path, encoded) in [("Info.plist", bundle.infoBase64), ("embedded.mobileprovision", bundle.profileBase64), ("_CodeSignature/CodeResources", bundle.resourcesBase64), ("Owned", bundle.codeBase64)] {
                        try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)).write(to: target.appendingPathComponent(path))
                    }
                    try Data("abc".utf8).write(to: target.appendingPathComponent("chapter.txt"))
                }
                let date = Date(timeIntervalSince1970: 1_792_540_800)
                let material = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: root, codeAnchors: [SelfRenewalCMSFixture.rootCertificate], profileAnchors: [SelfRenewalCMSFixture.rootCertificate], at: date)
                let issuer = seedPublishedLease ? try PKI.issuer(at: date) : nil
                let anchors = [SelfRenewalCMSFixture.rootCertificate] + (issuer?.certificateChainDER ?? [])
                let vault = Vault(codeAnchors: anchors, profileAnchors: anchors, clock: { date }); cleanupVault = vault
                let namespace = try await vault.create(identity: material); cleanupNamespace = namespace
                if let issuer {
                    let generation = try await vault.generation(in: namespace)
                    let key = try await vault.generateKey(in: namespace, expectedGeneration: generation)
                    let leaf = try PKI.certificate(for: key.privateKey, signedBy: issuer, at: date)
                    let profiles = try material.bundles.map { bundle -> Vault.ProfileInput in
                        let original = try #require(material.profiles.profiles.first { $0.file.relativePath == bundle.profileRelativePath })
                        return .init(componentRelativePath: bundle.componentRelativePath,
                            bytes: try PKI.profile(from: original, developerCertificate: leaf, issuer: issuer, at: date))
                    }
                    _ = try await vault.publish(in: namespace, keyID: key.id, expectedGeneration: key.generation,
                        certificateChainDER: [leaf] + issuer.certificateChainDER, profiles: profiles)
                }
                let selected: Vector
                if let vector { selected = vector } else { selected = try Vectors.first() }
                let value = Fixture(directory: directory, material: material, vault: vault, namespace: namespace, vector: selected, anchors: anchors)
                PeerProtocol.install(value.peer); return value
            } catch {
                if let vault = cleanupVault, let namespace = cleanupNamespace {
                    do {
                        try await Task.detached {
                            let generation = try await vault.generation(in: namespace)
                            try await vault.destroy(namespace, expectedGeneration: generation)
                        }.value
                    } catch { Issue.record(error) }
                }
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }; throw error
            }
        }
    }
    nonisolated private static func offMain(_ action: @escaping @Sendable () async throws -> Void) async throws {
        let worker = Task<Void, Error>.detached { try await action() }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    nonisolated private static func fixture(seedPublishedLease: Bool = false,
        _ action: @escaping @Sendable (Fixture) async throws -> Void) async throws {
        try await Self.offMain { let value = try await Fixture.make(seedPublishedLease: seedPublishedLease); do { try await action(value); try await value.cleanup() } catch { do { try await value.cleanup() } catch { Issue.record(error) }; throw error } }
    }
    private struct Vector: Decodable, Sendable {
        let `protocol`: String, username: String, password: String, privateA: String, A: String, B: String, salt: String, passwordKey: String
        let iterations: Int; let K: String, M1: String, M2: String, spd: String, sc: String, np: String, sk: String, checksum: String, encryptedToken: String
        let dsid: String, idms: String, token: String, cookie: String
        var kind: SRP.PasswordProtocol { SRP.PasswordProtocol(rawValue: `protocol`)! }
        func bytes(_ text: String) throws -> Data {
            guard text.utf8.count % 2 == 0 else { throw FixtureFailure.invalid }; var result = Data(); var offset = text.startIndex
            while offset < text.endIndex { let next = text.index(offset, offsetBy: 2); guard let byte = UInt8(text[offset..<next], radix: 16) else { throw FixtureFailure.invalid }; result.append(byte); offset = next }; return result
        }
    }
    private struct SignedVector: Decodable, Sendable {
        let `protocol`: String, name: String, spd: String, np: String
    }
    private enum SignedVectors {
        static func all() throws -> [SignedVector] {
            try JSONDecoder().decode([SignedVector].self, from: #require(Data(base64Encoded: base64)))
        }
        // Public, independently AES-CBC sealed variants of the existing SRP
        // fixtures. Each SPD has its own newly computed negotiation MAC.
        static let base64 = "W3sicHJvdG9jb2wiOiJzMmsiLCJuYW1lIjoibWFudWFsIiwic3BkIjoiMTZhY2FkYmI5Y2I4YmE1MjQ1MjU2NThkMDc2OWQ4YzJjNDA4YzZkZGU4MGYwNjc5ZjUzNTI0MzIxMzdmMDA3M2ZlMWY1M2MyOTMzNTNlMWU1ODlkZjlmYmFjYWZkMzMxYjA4N2Q3NDg4ZmVmMjI3YzdmZmFiMTAwY2FkZDE5NzBjM2MyYzdlYmNjMGFkMjZkNzQxNDI5OTdiOGVkYjFhYWZiYzk4OThkMGIxOTBhYjQwOGU0Y2IxMWEyNjQ5M2ZiODBkZWI1NGVjMTI5Zjk0ZTYwZGNlNmZlMjE2NDdlZGZjMGM5YTlmYzgyNjQ0ZTRkMzYwZjM0OGE0ODdmOWY4MmEzNDYxMWUyZWQ4ZDU3YTVlMzIzMjYzNDJhNTY3NWUwMzgzMTgyNWY2N2VkNTg5MzVmYzczMTM0OWMzMWIyODBmZmRiMzY5MjYyYzZkYzI3ZGM3OTE2ZGI5MzJiNTE5MWIxYzQzYTE2YzFlMGYyODcyNTFiN2I1NjE0YTM0ZDE3NmJlYmFhMzMzNWY5M2MxMTk0ZmIyZDAwODg5ZDM5YzM4ODU4MmI0NzQ2Y2RkMDhiZTE0MmRjNDVhMmQ3NTE1YjFlZWQ4ODA5ODljYWU5NDgzOGFlNTYyYjc5NzFjNzhiODM4ZWJkZjEwZmIwMWI1ZTUzOWMxMGYyNjRiZjg4NTJkM2U1ZDZjODBiNGQ5MjcwZjhmM2QwMGZjMGU4YzE5OTRjNDg1NzA5MGRjYjI0MDEzODQyNTVkODM0YWRlMjE3MGQ4YTZlY2YxMWRmN2VjZThjODYxYzFjODJhZDA3OWZiNDQ3YjRmOTAwZTZhN2UyMDJhOTQ4OTczOWNlMmNmNjI1Zjc0ZDM1ZjA1YzJmMWMyZjk5NjU3NWEzYzhhYjY1ZTYwNGIxM2I2OTliMzkxMjIzNzdkMTJkNjI3NTBmZDNhNDk2MzZhNzIyMWU4Y2Q3M2RmZDgwYzA3NTYyM2RmOTZjOTU4OTFjN2Q3YzdiNWNkZDMyYWE2ZTUxNzMzNTNmOGYxMTg5MmI0NGVlNjZhN2E1YWY3MTczYmQzYWYxZTNkM2E2YTIyOTczM2NlMDQ5NzU5YmJlMmUwNDUwOTAyMjNmYTJjOTM3OTg3MTllN2VlNWU0ODVjM2I4NTE3YjA0NDk1MmY2MzE4NDRhMDNhN2FhYmIxMDQ3M2NhNDE1NjhlYTYyMDI4OTAyN2YxZjk0ZDg2YzNiMjlmMjkwMDBiM2NlNTMwYjRjMDA5NWVkMTEyNmYwNDA2NDNjYWEyZDM0MmQzYWMyYTRkZmExZDc0ODdhOTdmZTFiY2Q4N2JjNDQiLCJucCI6ImQzZjc4ZTVhNDA3ZGM4ODJhZmI4ODNlMDc1MGE4MGMxN2I4YTlmM2QxNjVkMWMwZTgyY2FkNDk4NTMxYTc4ZTcifSx7InByb3RvY29sIjoiczJrIiwibmFtZSI6InRydXN0ZWQiLCJzcGQiOiIxNmFjYWRiYjljYjhiYTUyNDUyNTY1OGQwNzY5ZDhjMmM0MDhjNmRkZTgwZjA2NzlmNTM1MjQzMjEzN2YwMDczZmUxZjUzYzI5MzM1M2UxZTU4OWRmOWZiYWNhZmQzMzFiMDg3ZDc0ODhmZWYyMjdjN2ZmYWIxMDBjYWRkMTk3MGMzYzJjN2ViY2MwYWQyNmQ3NDE0Mjk5N2I4ZWRiMWFhZmJjOTg5OGQwYjE5MGFiNDA4ZTRjYjExYTI2NDkzZmI4MGRlYjU0ZWMxMjlmOTRlNjBkY2U2ZmUyMTY0N2VkZmMwYzlhOWZjODI2NDRlNGQzNjBmMzQ4YTQ4N2Y5ZjgyYTM0NjExZTJlZDhkNTdhNWUzMjMyNjM0MmE1Njc1ZTAzODMxODI1ZjY3ZWQ1ODkzNWZjNzMxMzQ5YzMxYjI4MGZmZGIzNjkyNjJjNmRjMjdkYzc5MTZkYjkzMmI1MTkxYjFjNDNhMTZjMWUwZjI4NzI1MWI3YjU2MTRhMzRkMTc2YmViYWEzMzM1ZjkzYzExOTRmYjJkMDA4ODlkMzljMzg4NTgyYjQ3NDZjZGQwOGJlMTQyZGM0NWEyZDc1MTViMWVlZDg4MDk4OWNhZTk0ODM4YWU1NjJiNzk3MWM3OGI4MzhlYmRmMTBmYjAxYjVlNTM5YzEwZjI2NGJmODg1MmQzZTVkNmM4MGI0ZDkyNzBmOGYzZDAwZmMwZThjMTk5NGM0ODU3MDkwZGNiMjQwMTM4NDI1NWQ4MzRhZGUyMTcwZDhhNmVjZjExZGY3ZWNlOGM4NjFjMWM4MmFkMDc5ZmI0NDdiNGY5MDBlNmE3ZTIwMmE5NDg5NzM5Y2UyY2Y2MjVmNzRkMzVmMDVjMmYxYzJmOTk2NTc1YTNjOGFiNjVlNjA0YjEzYjY5OWIzOTEyMjM3N2QxMmQ2Mjc1MGZkM2E0OTYzNmE3MjIxZThjZDczZGZkODBjMDc1NjIzZGY5NmM5NTg5MWM3ZDdjN2I1Y2RkMzJhYTZlNTE3MzM1M2Y4ZjExODkyYjQ0ZWU2NmE3YTVhZjcxNzNiZDNhZjFlM2QzYTZhMjI5NzMzY2UwNDk3NTliYmUyZTA0NTA5MDIyM2ZhMmM5Mzc5ODcxOWU3ZWU1ZTQ4NWMzYjg1MTdiMDQ0OTUyZjYzMTg0NGEwM2E3YWFiYjEwNDczY2E0MTU2OGVhNjIwMjg5MDI3ZjFmOTRkODZjM2IyOWYyOTAwMGIzMmI0ZWVmMDA5NTY4MTBkMzk4YzU5YTA4ZTVmNzczOWFiMzE2NGY4MDg1YzA4MzBmM2E5MGFmY2E1YWNhZWU5NDlhZjI1YWEyNzUyYzM4NmU2NDMxOThmNjQ5NjFiOWUzNWY0MzcwZTRkNTcyNTQyYjIyOWNmOTM3ZGY1NGMxNDg0ZDQxYTlmMmQyM2YyN2ExYjlhMTFlMTkzZTAzZjc2ZWJjYmI5NGI5NmRlZjk5MzJiMzhlMzllYjdhNTI2MjM2IiwibnAiOiIzNWEwZTFjNDU3ODE4YTk3MDgxNjRmNmIzZWFiMWYwNTY1NTBjNGI0MWQ1NWE0YTM3ZDY4MDE4MWI4YjQyNmEyIn0seyJwcm90b2NvbCI6InMyayIsIm5hbWUiOiJub3JtYWwiLCJzcGQiOiIxNmFjYWRiYjljYjhiYTUyNDUyNTY1OGQwNzY5ZDhjMmM0MDhjNmRkZTgwZjA2NzlmNTM1MjQzMjEzN2YwMDczZmUxZjUzYzI5MzM1M2UxZTU4OWRmOWZiYWNhZmQzMzFiMDg3ZDc0ODhmZWYyMjdjN2ZmYWIxMDBjYWRkMTk3MGMzYzJjN2ViY2MwYWQyNmQ3NDE0Mjk5N2I4ZWRiMWFhZmJjOTg5OGQwYjE5MGFiNDA4ZTRjYjExYTI2NDkzZmI4MGRlYjU0ZWMxMjlmOTRlNjBkY2U2ZmUyMTY0N2VkZmMwYzlhOWZjODI2NDRlNGQzNjBmMzQ4YTQ4N2Y5ZjgyYTM0NjExZTJlZDhkNTdhNWUzMjMyNjM0MmE1Njc1ZTAzODMxODI1ZjY3ZWQ1ODkzNWZjNzMxMzQ5YzMxYjI4MGZmZGIzNjkyNjJjNmRjMjdkYzc5MTZkYjkzMmI1MTkxYjFjNDNhMTZjMWUwZjI4NzI1MWI3YjU2MTRhMzRkMTc2YmViYWEzMzM1ZjkzYzExOTRmYjJkMDA4ODlkMzljMzg4NTgyYjQ3NDZjZGQwOGJlMTQyZGM0NWEyZDc1MTViMWVlZDg4MDk4OWNhZTk0ODM4YWU1NjJiNzk3MWM3OGI4MzhlYmRmMTBmYjAxYjVlNTM5YzEwZjI2NGJmODg1MmQzZTVkNmM4MGI0ZDkyNzBmOGYzZDAwZmMwZThjMTk5NGM0ODU3MDkwZGNiMjQwMTM4NDI1NWQ4MzRhZGUyMTcwZDhhNmVjZjExZGY3ZWNlOGM4NjFjMWM4MmFkMDc5ZmI0NDdiNGY5MDBlNmE3ZTIwMmE5NDg5NzM5Y2UyY2Y2MjVmNzRkMzVmMDVjMmYxYzJmOTk2NTc1YTNjOGFiNjVlNjA0YjEzYjY5OWIzOTEyMjM3N2QxMmQ2Mjc1MGZkM2E0OTYzNmE3MjIxZThjZDczZGZkODBjMDc1NjIzZGY5NmM5NTg5MWM3ZDdjN2I1Y2RkMzJhYTZlNTE3MzM1M2Y4ZjExODkyYjQ0ZWU2NmE3YTVhZjcxNzNiZDNhZjFlM2QzYTZhMjI5NzMzY2UwNDk3NTliYmUyZTA0NTA5MDIyM2ZhMmM5Mzc5ODcxOWU3ZWU1ZTQ4NWMzYjg1MTdiMDQ0OTUyZjYzMTg0NGEwM2E3YWFiYjEwNDczY2E0MTU2ODY0OWNlYWFmNmIyOWUyZDBmODE5M2UzNWExOTU4NjM3YWQ0NTllZTQzNmIwNzlmNjMxMmQ1Y2RlZjllMjljNTc3ZGJiOWZiM2VhOGMyOTcyYTg1MDllZTg5ZDljMjY2OCIsIm5wIjoiZjk0Nzg1YzZhYmI4NzRhYmFlM2RlZTM3YTUyZmRhYTkzNGUzNGE2MTU1NGRhNjg1YmIxYThmODI0NjFkYjhjMiJ9LHsicHJvdG9jb2wiOiJzMmsiLCJuYW1lIjoic21zIiwic3BkIjoiMTZhY2FkYmI5Y2I4YmE1MjQ1MjU2NThkMDc2OWQ4YzJjNDA4YzZkZGU4MGYwNjc5ZjUzNTI0MzIxMzdmMDA3M2ZlMWY1M2MyOTMzNTNlMWU1ODlkZjlmYmFjYWZkMzMxYjA4N2Q3NDg4ZmVmMjI3YzdmZmFiMTAwY2FkZDE5NzBjM2MyYzdlYmNjMGFkMjZkNzQxNDI5OTdiOGVkYjFhYWZiYzk4OThkMGIxOTBhYjQwOGU0Y2IxMWEyNjQ5M2ZiODBkZWI1NGVjMTI5Zjk0ZTYwZGNlNmZlMjE2NDdlZGZjMGM5YTlmYzgyNjQ0ZTRkMzYwZjM0OGE0ODdmOWY4MmEzNDYxMWUyZWQ4ZDU3YTVlMzIzMjYzNDJhNTY3NWUwMzgzMTgyNWY2N2VkNTg5MzVmYzczMTM0OWMzMWIyODBmZmRiMzY5MjYyYzZkYzI3ZGM3OTE2ZGI5MzJiNTE5MWIxYzQzYTE2YzFlMGYyODcyNTFiN2I1NjE0YTM0ZDE3NmJlYmFhMzMzNWY5M2MxMTk0ZmIyZDAwODg5ZDM5YzM4ODU4MmI0NzQ2Y2RkMDhiZTE0MmRjNDVhMmQ3NTE1YjFlZWQ4ODA5ODljYWU5NDgzOGFlNTYyYjc5NzFjNzhiODM4ZWJkZjEwZmIwMWI1ZTUzOWMxMGYyNjRiZjg4NTJkM2U1ZDZjODBiNGQ5MjcwZjhmM2QwMGZjMGU4YzE5OTRjNDg1NzA5MGRjYjI0MDEzODQyNTVkODM0YWRlMjE3MGQ4YTZlY2YxMWRmN2VjZThjODYxYzFjODJhZDA3OWZiNDQ3YjRmOTAwZTZhN2UyMDJhOTQ4OTczOWNlMmNmNjI1Zjc0ZDM1ZjA1YzJmMWMyZjk5NjU3NWEzYzhhYjY1ZTYwNGIxM2I2OTliMzkxMjIzNzdkMTJkNjI3NTBmZDNhNDk2MzZhNzIyMWU4Y2Q3M2RmZDgwYzA3NTYyM2RmOTZjOTU4OTFjN2Q3YzdiNWNkZDMyYWE2ZTUxNzMzNTNmOGYxMTg5MmI0NGVlNjZhN2E1YWY3MTczYmQzYWYxZTNkM2E2YTIyOTczM2NlMDQ5NzU5YmJlMmUwNDUwOTAyMjNmYTJjOTM3OTg3MTllN2VlNWU0ODVjM2I4NTE3YjA0NDk1MmY2MzE4NDRhMDNhN2FhYmIxMDQ3M2NhNDE1NjhlYTYyMDI4OTAyN2YxZjk0ZDg2YzNiMjlmMjkwMDBiMzJiNGVlZjAwOTU2ODEwZDM5OGM1OWEwOGU1Zjc3MzlhNDkwODAwNDA2ZDBiYjY1NGI0NjNkNjBjYzZhMTJmMTE4NGE3NTdlZjQ4NDI4M2NlMmZjYjU5MjA1MzE5ZjJlMTg2OTNlM2RlMjhmYTNhODE5NzExZTgxMDQ4NzljY2YxODA5Y2U4MTQ5ZWE1ZDY4ODMxZDdkN2MyZDFhOGIwODYiLCJucCI6ImJmZDU2NDEwMDNiOTkyMzgxYzlhNDU5MjNiYWY4ZWVlMDY0YjNkZjZmODFmMTFiNjM2YjEyNjlhNGU3YWNmNmEifSx7InByb3RvY29sIjoiczJrIiwibmFtZSI6ImFic29sdXRlIiwic3BkIjoiMTZhY2FkYmI5Y2I4YmE1MjQ1MjU2NThkMDc2OWQ4YzJjNDA4YzZkZGU4MGYwNjc5ZjUzNTI0MzIxMzdmMDA3M2ZlMWY1M2MyOTMzNTNlMWU1ODlkZjlmYmFjYWZkMzMxYjA4N2Q3NDg4ZmVmMjI3YzdmZmFiMTAwY2FkZDE5NzBjM2MyYzdlYmNjMGFkMjZkNzQxNDI5OTdiOGVkYjFhYWZiYzk4OThkMGIxOTBhYjQwOGU0Y2IxMWEyNjQ5M2ZiODBkZWI1NGVjMTI5Zjk0ZTYwZGNlNmZlMjE2NDdlZGZjMGM5YTlmYzgyNjQ0ZTRkMzYwZjM0OGE0ODdmOWY4MmEzNDYxMWUyZWQ4ZDU3YTVlMzIzMjYzNDJhNTY3NWUwMzgzMTgyNWY2N2VkNTg5MzVmYzczMTM0OWMzMWIyODBmZmRiMzY5MjYyYzZkYzI3ZGM3OTE2ZGI5MzJiNTE5MWIxYzQzYTE2YzFlMGYyODcyNTFiN2I1NjE0YTM0ZDE3NmJlYmFhMzMzNWY5M2MxMTk0ZmIyZDAwODg5ZDM5YzM4ODU4MmI0NzQ2Y2RkMDhiZTE0MmRjNDVhMmQ3NTE1YjFlZWQ4ODA5ODljYWU5NDgzOGFlNTYyYjc5NzFjNzhiODM4ZWJkZjEwZmIwMWI1ZTUzOWMxMGYyNjRiZjg4NTJkM2U1ZDZjODBiNGQ5MjcwZjhmM2QwMGZjMGU4YzE5OTRjNDg1NzA5MGRjYjI0MDEzODQyNTVkODM0YWRlMjE3MGQ4YTZlY2YxMWRmN2VjZThjODYxYzFjODJhZDA3OWZiNDQ3YjRmOTAwZTZhN2UyMDJhOTQ4OTczOWNlMmNmNjI1Zjc0ZDM1ZjA1YzJmMWMyZjk5NjU3NWEzYzhhYjY1ZTYwNGIxM2I2OTliMzkxMjIzNzdkMTJkNjI3NTBmZDNhNDk2MzZhNzIyMWU4Y2Q3M2RmZDgwYzA3NTYyM2RmOTZjOTU4OTFjN2Q3YzdiNWNkZDMyYWE2ZTUxNzMzNTNmOGYxMTg5MmI0NGVlNjZhN2E1YWY3MTczYmQzYWYxZTNkM2E2YTIyOTczM2NlMDQ5NzU5YmJlMmUwNDUwOTAyMjNmYTJjOTM3OTg3MTllN2VlNWU0ODVjM2I4NTE3YjA0NDk1MmY2MzE4NDRhMDNhN2FhYmIxMDQ3M2NhNDE1NjhlYTYyMDI4OTAyN2YxZjk0ZDg2YzNiMjlmMjkwMDBiMzJiNGVlZjAwOTU2ODEwZDM5OGM1OWEwOGU1Zjc3MzlhNWYzMGU2ZGY1NDQ5OTgxYTE5YjM4ZmU2NmY2N2Q2ZjkwNTdhNzU5ZGQzYjdhMzY2NDliYmFiOTQ2ZDAxMjNhMTczYjA2ZDJiZWMwODY1Y2U0ZDAzMjRhNjU0MjBkYzFmOThhZmVkYTg0NWRjMDA4ZDVkZTNkNjQ4MzcxYzIyYzE0YzViYmMwMGVhZjUxMmFlODA2ZDMxNTcyNDRlYjRjNyIsIm5wIjoiOTJjNmU3YzJiNmFhN2M2NWYzMjdhNTUyNWYzMDNhNDVjMzQ5M2NjOGU3ZGRkZTFlN2I2YjQ3MjYxYzFjMGRhZiJ9LHsicHJvdG9jb2wiOiJzMmsiLCJuYW1lIjoiZW1wdHkiLCJzcGQiOiIxNmFjYWRiYjljYjhiYTUyNDUyNTY1OGQwNzY5ZDhjMmM0MDhjNmRkZTgwZjA2NzlmNTM1MjQzMjEzN2YwMDczZmUxZjUzYzI5MzM1M2UxZTU4OWRmOWZiYWNhZmQzMzFiMDg3ZDc0ODhmZWYyMjdjN2ZmYWIxMDBjYWRkMTk3MGMzYzJjN2ViY2MwYWQyNmQ3NDE0Mjk5N2I4ZWRiMWFhZmJjOTg5OGQwYjE5MGFiNDA4ZTRjYjExYTI2NDkzZmI4MGRlYjU0ZWMxMjlmOTRlNjBkY2U2ZmUyMTY0N2VkZmMwYzlhOWZjODI2NDRlNGQzNjBmMzQ4YTQ4N2Y5ZjgyYTM0NjExZTJlZDhkNTdhNWUzMjMyNjM0MmE1Njc1ZTAzODMxODI1ZjY3ZWQ1ODkzNWZjNzMxMzQ5YzMxYjI4MGZmZGIzNjkyNjJjNmRjMjdkYzc5MTZkYjkzMmI1MTkxYjFjNDNhMTZjMWUwZjI4NzI1MWI3YjU2MTRhMzRkMTc2YmViYWEzMzM1ZjkzYzExOTRmYjJkMDA4ODlkMzljMzg4NTgyYjQ3NDZjZGQwOGJlMTQyZGM0NWEyZDc1MTViMWVlZDg4MDk4OWNhZTk0ODM4YWU1NjJiNzk3MWM3OGI4MzhlYmRmMTBmYjAxYjVlNTM5YzEwZjI2NGJmODg1MmQzZTVkNmM4MGI0ZDkyNzBmOGYzZDAwZmMwZThjMTk5NGM0ODU3MDkwZGNiMjQwMTM4NDI1NWQ4MzRhZGUyMTcwZDhhNmVjZjExZGY3ZWNlOGM4NjFjMWM4MmFkMDc5ZmI0NDdiNGY5MDBlNmE3ZTIwMmE5NDg5NzM5Y2UyY2Y2MjVmNzRkMzVmMDVjMmYxYzJmOTk2NTc1YTNjOGFiNjVlNjA0YjEzYjY5OWIzOTEyMjM3N2QxMmQ2Mjc1MGZkM2E0OTYzNmE3MjIxZThjZDczZGZkODBjMDc1NjIzZGY5NmM5NTg5MWM3ZDdjN2I1Y2RkMzJhYTZlNTE3MzM1M2Y4ZjExODkyYjQ0ZWU2NmE3YTVhZjcxNzNiZDNhZjFlM2QzYTZhMjI5NzMzY2UwNDk3NTliYmUyZTA0NTA5MDIyM2ZhMmM5Mzc5ODcxOWU3ZWU1ZTQ4NWMzYjg1MTdiMDQ0OTUyZjYzMTg0NGEwM2E3YWFiYjEwNDczY2E0MTU2OGVhNjIwMjg5MDI3ZjFmOTRkODZjM2IyOWYyOTAwMGIzMmI0ZWVmMDA5NTY4MTBkMzk4YzU5YTA4ZTVmNzczOWE4NzM4ZGMwZjJjZDlkNWE5YTNjYTdmZjY5YjliYThkMGJlOGU4OWJlZTViZmIyN2VhZDVlNjg0OTc5NDcxYTA5YzUyMzdhNzA0NjgzMWI3NGY5MjBiZGQ2ZWE5MTM4M2MiLCJucCI6ImQ5MTJlNGU0OTUyMjA3OWQ1YmJjZDBkODMyOWJjZGMwNjQyNGMyZmE2MzllZmEwYTUxZDdmMDRiZTc5MjVkYmIifSx7InByb3RvY29sIjoiczJrIiwibmFtZSI6InR5cGVkVVJMIiwic3BkIjoiMTZhY2FkYmI5Y2I4YmE1MjQ1MjU2NThkMDc2OWQ4YzJjNDA4YzZkZGU4MGYwNjc5ZjUzNTI0MzIxMzdmMDA3M2ZlMWY1M2MyOTMzNTNlMWU1ODlkZjlmYmFjYWZkMzMxYjA4N2Q3NDg4ZmVmMjI3YzdmZmFiMTAwY2FkZDE5NzBjM2MyYzdlYmNjMGFkMjZkNzQxNDI5OTdiOGVkYjFhYWZiYzk4OThkMGIxOTBhYjQwOGU0Y2IxMWEyNjQ5M2ZiODBkZWI1NGVjMTI5Zjk0ZTYwZGNlNmZlMjE2NDdlZGZjMGM5YTlmYzgyNjQ0ZTRkMzYwZjM0OGE0ODdmOWY4MmEzNDYxMWUyZWQ4ZDU3YTVlMzIzMjYzNDJhNTY3NWUwMzgzMTgyNWY2N2VkNTg5MzVmYzczMTM0OWMzMWIyODBmZmRiMzY5MjYyYzZkYzI3ZGM3OTE2ZGI5MzJiNTE5MWIxYzQzYTE2YzFlMGYyODcyNTFiN2I1NjE0YTM0ZDE3NmJlYmFhMzMzNWY5M2MxMTk0ZmIyZDAwODg5ZDM5YzM4ODU4MmI0NzQ2Y2RkMDhiZTE0MmRjNDVhMmQ3NTE1YjFlZWQ4ODA5ODljYWU5NDgzOGFlNTYyYjc5NzFjNzhiODM4ZWJkZjEwZmIwMWI1ZTUzOWMxMGYyNjRiZjg4NTJkM2U1ZDZjODBiNGQ5MjcwZjhmM2QwMGZjMGU4YzE5OTRjNDg1NzA5MGRjYjI0MDEzODQyNTVkODM0YWRlMjE3MGQ4YTZlY2YxMWRmN2VjZThjODYxYzFjODJhZDA3OWZiNDQ3YjRmOTAwZTZhN2UyMDJhOTQ4OTczOWNlMmNmNjI1Zjc0ZDM1ZjA1YzJmMWMyZjk5NjU3NWEzYzhhYjY1ZTYwNGIxM2I2OTliMzkxMjIzNzdkMTJkNjI3NTBmZDNhNDk2MzZhNzIyMWU4Y2Q3M2RmZDgwYzA3NTYyM2RmOTZjOTU4OTFjN2Q3YzdiNWNkZDMyYWE2ZTUxNzMzNTNmOGYxMTg5MmI0NGVlNjZhN2E1YWY3MTczYmQzYWYxZTNkM2E2YTIyOTczM2NlMDQ5NzU5YmJlMmUwNDUwOTAyMjNmYTJjOTM3OTg3MTllN2VlNWU0ODVjM2I4NTE3YjA0NDk1MmY2MzE4NDRhMDNhN2FhYmIxMDQ3M2NhNDE1NjhlYTYyMDI4OTAyN2YxZjk0ZDg2YzNiMjlmMjkwMDBiMzJiNGVlZjAwOTU2ODEwZDM5OGM1OWEwOGU1Zjc3MzlhMDJlODFiNThmMGE4NmQxZDA0NzU4NTY4NDczNWNhNmI0ZjUyNzE3MWNhZjgyNDNlNmQzMzQ3Y2M4ZTdiNGMwYjcxNjk4NDQ1ZThkMzFiNGViMGE3MTUzOGU5MmU5Y2MxIiwibnAiOiIzZDQ0NDVkMGI5NDY5MzI0YjJkMWZiNWVmYTRlN2M3MjdiZjI3ZTFkMTljMWZiZjU5MjJhOGNmYWExMWI5OWFjIn0seyJwcm90b2NvbCI6InMyayIsIm5hbWUiOiJ0ZXh0Q29kZSIsInNwZCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyZDNlNWQ2YzgwYjRkOTI3MGY4ZjNkMDBmYzBlOGMxOTk0YzQ4NTcwOTBkY2IyNDAxMzg0MjU1ZDgzNGFkZTIxNzBkOGE2ZWNmMTFkZjdlY2U4Yzg2MWMxYzgyYWQwNzlmYjQ0N2I0ZjkwMGU2YTdlMjAyYTk0ODk3MzljZTJjZjYyNWY3NGQzNWYwNWMyZjFjMmY5OTY1NzVhM2M4YWI2NWU2MDRiMTNiNjk5YjM5MTIyMzc3ZDEyZDYyNzUwZmQzYTQ5NjM2YTcyMjFlOGNkNzNkZmQ4MGMwNzU2MjNkZjk2Yzk1ODkxYzdkN2M3YjVjZGQzMmFhNmU1MTczMzUzZjhmMTE4OTJiNDRlZTY2YTdhNWFmNzE3M2JkM2FmMWUzZDNhNmEyMjk3MzNjZTA0OTc1OWJiZTJlMDQ1MDkwMjIzZmEyYzkzNzk4NzE5ZTdlZTVlNDg1YzNiODUxN2IwNDE3NmZkZThlM2VlYzJkODI0ZTZiN2Y1YmQzNDA4NzI4MTM4YTZlZTM5NmVmNDIxNjgxNGIwOTNmYzM5ZWIyMmM1ZGI2NjRlNzBhZjY5MWM1NDY4ZmMyYWIwNWQ4MWRmYTJmNTY2MTBkOTFhOWUzNDI0NDVkMmI5OGZkNmE2MTI3IiwibnAiOiI2OTQ4YzhjMTE4MWFjMWU4ODkzNzExNjlkYTdhNWU1NTdkMWJkZWYzMDJhMDIyY2YzNzg5YWM1MTA3YzYxY2JkIn0seyJwcm90b2NvbCI6InMyayIsIm5hbWUiOiJib29sQ29kZSIsInNwZCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyZDNlNWQ2YzgwYjRkOTI3MGY4ZjNkMDBmYzBlOGMxOTk0YzQ4NTcwOTBkY2IyNDAxMzg0MjU1ZDgzNGFkZTIxNzBkOGE2ZWNmMTFkZjdlY2U4Yzg2MWMxYzgyYWQwNzlmYjQ0N2I0ZjkwMGU2YTdlMjAyYTk0ODk3MzljZTJjZjYyNWY3NGQzNWYwNWMyZjFjMmY5OTY1NzVhM2M4YWI2NWU2MDRiMTNiNjk5YjM5MTIyMzc3ZDEyZDYyNzUwZmQzYTQ5NjM2YTcyMjFlOGNkNzNkZmQ4MGMwNzU2MjNkZjk2Yzk1ODkxYzdkN2M3YjVjZGQzMmFhNmU1MTczMzUzZjhmMTE4OTJiNDRlZTY2YTdhNWFmNzE3M2JkM2FmMWUzZDNhNmEyMjk3MzNjZTA0OTc1OWJiZTJlMDQ1MDkwMjIzZmEyYzkzNzk4NzE5ZTdlZTVlNDg1YzNiODUxN2IwNGIwNjM0ZGM0NDFiZjYxNDgzM2M5ZmUxYjg1NzU5NTA3YTBiZDM3NzlkMjAzMmFiNTA1OWRmMTRjMTVlNWYyMzM0NmEwY2UzYjZiZTlkODFmZDNiOTQ2NGUyYjFlMmIyNyIsIm5wIjoiN2YxZjc0ZmUwODQ3OWY5ZjNhZDg4YjJlYWJkZjViNDRjZDkwODE2NTQyNDk3Y2NjZjk1Nzc2M2JmODlhZjJlMSJ9LHsicHJvdG9jb2wiOiJzMmsiLCJuYW1lIjoidW5leHBlY3RlZCIsInNwZCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyZDNlNWQ2YzgwYjRkOTI3MGY4ZjNkMDBmYzBlOGMxOTk0YzQ4NTcwOTBkY2IyNDAxMzg0MjU1ZDgzNGFkZTIxNzBkOGE2ZWNmMTFkZjdlY2U4Yzg2MWMxYzgyYWQwNzlmYjQ0N2I0ZjkwMGU2YTdlMjAyYTk0ODk3MzljZTJjZjYyNWY3NGQzNWYwNWMyZjFjMmY5OTY1NzVhM2M4YWI2NWU2MDRiMTNiNjk5YjM5MTIyMzc3ZDEyZDYyNzUwZmQzYTQ5NjM2YTcyMjFlOGNkNzNkZmQ4MGMwNzU2MjNkZjk2Yzk1ODkxYzdkN2M3YjVjZGQzMmFhNmU1MTczMzUzZjhmMTE4OTJiNDRlZTY2YTdhNWFmNzE3M2JkM2FmMWUzZDNhNmEyMjk3MzNjZTA0OTc1OWJiZTJlMDQ1MDkwMjIzZmEyYzkzNzk4NzE5ZTdlZTVlNDg1YzNiODUxN2IwNDQ5NTJmNjMxODQ0YTAzYTdhYWJiMTA0NzNjYTQxNTY4ZDA2NzY4NzA2NTA0NmI3MmExMWNjNGQyOGQ0NmEzMjk4ZjM5YmFlNTE5N2NkZjZhYzM3MjVjNDA0NGFkNmEzMTRiMzUzYWU5MThmNDAzMjNjZjk2NGMxNTkyZDBiYTNjIiwibnAiOiIzNzU2MTI1MDFiN2Q3MGU4ZmU1MWExOTcxYTIyZjcwMWQ0NjhjMzIxZmZkYjU4ZTg0MDQ2NDdmMGIzODBjMmMwIn0seyJwcm90b2NvbCI6InMyayIsIm5hbWUiOiJkYW5nbGluZyIsInNwZCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyZDNlNWQ2YzgwYjRkOTI3MGY4ZjNkMDBmYzBlOGMxOTk0YzQ4NTcwOTBkY2IyNDAxMzg0MjU1ZDgzNGFkZTIxNzBkOGE2ZWNmMTFkZjdlY2U4Yzg2MWMxYzgyYWQwNzlmYjQ0N2I0ZjkwMGU2YTdlMjAyYTk0ODk3MzljZTJjZjYyNWY3NGQzNWYwNWMyZjFjMmY5OTY1NzVhM2M4YWI2NWU2MDRiMTNiNjk5YjM5MTIyMzc3ZDEyZDYyNzUwZmQzYTQ5NjM2YTcyMjFlOGNkNzNkZmQ4MGMwNzU2MjNkZjk2Yzk1ODkxYzdkN2M3YjVjZGQzMmFhNmU1MTczMzUzZjhmMTE4OTJiNDRlZTY2YTdhNWFmNzE3M2JkM2FmMWUzZDNhNmEyMjk3MzNjZTA0OTc1OWJiZTJlMDQ1MDkwMjIzYWZjZDllNTAyZTE3YmJlNDBjNjE5MTIwOGJiYzQ1MjBmNDExZTRlNjEwZDQ3NjU5YmFlN2I0NzU1ZjQxZDUyN2JiMjFmMDViNTdkYzkwZTBhNGM1NDY3NWEyNmI5MTUxNDdkZDNkZWRkMjJkYjZkYzdkZTZjMmY0Njc1Y2I2Mzk0ZjdlNDg4OGM4YTgzY2ZmOTZiOGY1YWExMzBhMWI2MzZkMzliYmE1MTYzNGEzNTEyYmExMDczOGFkMjlhNTUiLCJucCI6ImYzNDg1Njk2MTRhZjNkZjQ2ZTljZjdkMmE2Njg1NmQyNDFjZWY5ODg5M2E2NmMxMGFjZGI4OTQyMTgwZTFkZDAifSx7InByb3RvY29sIjoiczJrX2ZvIiwibmFtZSI6Im1hbnVhbCIsInNwZCI6ImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZjFmYzcwZTBhMDM2MDA4OTE4YjJjNDA3ODE1MGIwOTJiNDQ3NWY3NTE1YjI4MjkxNjYzMzkwNThiM2QyOWY0YWQ2NTQwZjUwNWViMTAxOGQ3ZGU1ZjIyYmQyYmZjODk4ZjMyNzU4NWFlYWUzYTFmMGNjZjFlZDFlOWNmOGE4Y2ZjNDQ2OTg4YzQ0YjA1YjFhNDVlOGQwNzI0NzIyYTk5ZTRlMGVjMmQ0NzBhN2RiNjc4YmE2ZWFiZjdkNzQ5YTM5YjI5ZWRjMWQ1NTJjZDlhM2RiMjYzZTM2NDc3MWIxNTQ4MTAwN2E2Zjc0NmRlY2Y1ZDI4NGIzMmVkYzc5YTBhNzU1NDRkYWI5ZTNlMDdkNGIzZjkyNzQ1ZjQ1ZWFlNTllZTczY2NjNTY5MmJlNjFmYTA0NmY0ZWE4MTkxMGY3NjM4MzM4YWRjMzY2MjI1YzFiMTk4ZjZmNGMxMTI2MDkzYjZiMjk4YWI3ZmI5Nzc3N2FkNDQ0OTUyNjNmOTExZTkwZTE0NWY2YmQyYzcxMWE0MmU0ZjVmOTdhYTlhZmIyYzMwMGI3ZWVkOWI4ZGMwNGYxOTc0ZTk3ZTRmNGFhZmU4ZmI0MzQ1NzI1ZGM0NjE3ZGIzZGVhOWU2NmFmOTc1MWFmIiwibnAiOiJhYmYwNjA1MWYwMjdhY2IxMGVhYmNhMGM5MzJhZjU5NGFmNzg3YzRmMGM0MjM3ZDdjMjJkYzdiZWVkZDMwYTQ5In0seyJwcm90b2NvbCI6InMya19mbyIsIm5hbWUiOiJ0cnVzdGVkIiwic3BkIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTJmMWZjNzBlMGEwMzYwMDg5MThiMmM0MDc4MTUwYjA5MmI0NDc1Zjc1MTViMjgyOTE2NjMzOTA1OGIzZDI5ZjRhZDY1NDBmNTA1ZWIxMDE4ZDdkZTVmMjJiZDJiZmM4OThmMzI3NTg1YWVhZTNhMWYwY2NmMWVkMWU5Y2Y4YThjZmM0NDY5ODhjNDRiMDViMWE0NWU4ZDA3MjQ3MjJhOTllNGUwZWMyZDQ3MGE3ZGI2NzhiYTZlYWJmN2Q3NDlhMzliMjllZGMxZDU1MmNkOWEzZGIyNjNlMzY0NzcxYjE1NDgxMDA3YTZmNzQ2ZGVjZjVkMjg0YjMyZWRjNzlhMGE3NTU0NGRhYjllM2UwN2Q0YjNmOTI3NDVmNDVlYWU1OWVlNzNjY2M1NjkyYmU2MWZhMDQ2ZjRlYTgxOTEwZjc2MzgzMzhhZGMzNjYyMjVjMWIxOThmNmY0YzExMjYwOTNiNmIyOThhYjdmYjk3Nzc3YWQ0NDQ5NTI2M2Y5MTFlOTBlMTQ1ZjZiZDJjNzExYTQyZTRmNWY5N2FhOWFmYjJjMzE2ZjAwNDZiM2JhZWEzZDVmYjBmYzk0ZWE0YTIyODk1MmFhYTU2MjcyOThmYTZjNjkzZDc4NjcwYzNiMWVjNmRjOGMwMDdlZWM3Y2I0OWUxNzJhZjcxZWNlYTQ4Y2NlOTM2NjhjMmJjOWI0Nzc3YmEwMjAwMWQxMjkwMzUxNmJlODY3ZTNmYWYzNjM0Nzc0OTk3MmZkZDNlZTUwN2U0NWYxMDkzYTUyN2NlZmZiOTI4YzhiNWM2MjZlMWVkMjcyNSIsIm5wIjoiNzEyYWZjZmYyZTg3MGJlYjUxMDBlNWZmNzZiYzg4MzdiODZjNzdmNmZlMmI2YmYzZWE1ZWI4ODRiYzlhMmI3OCJ9LHsicHJvdG9jb2wiOiJzMmtfZm8iLCJuYW1lIjoibm9ybWFsIiwic3BkIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTJmMWZjNzBlMGEwMzYwMDg5MThiMmM0MDc4MTUwYjA5MmI0NDc1Zjc1MTViMjgyOTE2NjMzOTA1OGIzZDI5ZjRhZDY1NDBmNTA1ZWIxMDE4ZDdkZTVmMjJiZDJiZmM4OThmMzI3NTg1YWVhZTNhMWYwY2NmMWVkMWU5Y2Y4YThjZmM0NDY5ODhjNDRiMDViMWE0NWU4ZDA3MjQ3MjJhOTllNGUwZWMyZDQ3MGE3ZGI2NzhiYTZlYWJmN2Q3NDlhMzliMjllZGMxZDU1MmNkOWEzZGIyNjNlMzY0NzcxYjE1NDgxMDA3YTZmNzQ2ZGVjZjVkMjg0YjMyZWRjNzlhMGE3NTU0NGRhYjllM2UwN2Q0YjNmOTI3NDVmNDVlYWU1OWVlNzNjY2M1NjkyYmU2MWZhMDQ2ZjRlYTgxOTEwZjc2MzgzMzhhZGMzNjYyMjVjMWIxOThmNmY0YzExMjYwOTNiNmIyOThhYjdmYjk3Nzc3YWQ0NDQ5NTI2M2Y5MTFlOTAzMTVjOWM1Mzc3YjgzZGFiNzc1ZmQ1NjUxODIwMmI2Njc0ZDY2ZWJkNWZjM2ZjOGU3ZDEzMmQxOGJmOGU5NjRmOWJjNzdkNzI0MmE0OTM3MzZlMzg1MDc4ZmI3YTI2NzUiLCJucCI6ImM1NzMwNTdjNzk1YzUyNjk4MWQ5ZmU3OGMzMTVlMDFmZjE3OGQ2MThhZjAzNzUyNGZjMDc3ZDBkNTFkNmE5ODgifSx7InByb3RvY29sIjoiczJrX2ZvIiwibmFtZSI6InNtcyIsInNwZCI6ImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZjFmYzcwZTBhMDM2MDA4OTE4YjJjNDA3ODE1MGIwOTJiNDQ3NWY3NTE1YjI4MjkxNjYzMzkwNThiM2QyOWY0YWQ2NTQwZjUwNWViMTAxOGQ3ZGU1ZjIyYmQyYmZjODk4ZjMyNzU4NWFlYWUzYTFmMGNjZjFlZDFlOWNmOGE4Y2ZjNDQ2OTg4YzQ0YjA1YjFhNDVlOGQwNzI0NzIyYTk5ZTRlMGVjMmQ0NzBhN2RiNjc4YmE2ZWFiZjdkNzQ5YTM5YjI5ZWRjMWQ1NTJjZDlhM2RiMjYzZTM2NDc3MWIxNTQ4MTAwN2E2Zjc0NmRlY2Y1ZDI4NGIzMmVkYzc5YTBhNzU1NDRkYWI5ZTNlMDdkNGIzZjkyNzQ1ZjQ1ZWFlNTllZTczY2NjNTY5MmJlNjFmYTA0NmY0ZWE4MTkxMGY3NjM4MzM4YWRjMzY2MjI1YzFiMTk4ZjZmNGMxMTI2MDkzYjZiMjk4YWI3ZmI5Nzc3N2FkNDQ0OTUyNjNmOTExZTkwZTE0NWY2YmQyYzcxMWE0MmU0ZjVmOTdhYTlhZmIyYzMxNmYwMDQ2YjNiYWVhM2Q1ZmIwZmM5NGVhNGEyMjg5NWE2MjIyNDI0MzcxOGMxZjIwM2RkNzk1ODY1YmRhNjRmZWQ3ODM4YWRiNGUwYTdjZjMxNDA1ODczZDk2OTUyYzMxNjFiNTVkOGZiNGMzYjE2NjZlZDE2OTNiYTI1YTU3YWMwZTNjNjUyOTQxYzFlM2QxYTYwMTEwOGY3MmQ2N2M2IiwibnAiOiIxNTEwYzUyZGFiMDE3N2IxNThlMjA2OTBmZDJjNzYwYjQ0ZGQyY2I4YzE3N2FkMTY1NDY0Y2ZiZjM5NzJhMmY3In0seyJwcm90b2NvbCI6InMya19mbyIsIm5hbWUiOiJhYnNvbHV0ZSIsInNwZCI6ImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZjFmYzcwZTBhMDM2MDA4OTE4YjJjNDA3ODE1MGIwOTJiNDQ3NWY3NTE1YjI4MjkxNjYzMzkwNThiM2QyOWY0YWQ2NTQwZjUwNWViMTAxOGQ3ZGU1ZjIyYmQyYmZjODk4ZjMyNzU4NWFlYWUzYTFmMGNjZjFlZDFlOWNmOGE4Y2ZjNDQ2OTg4YzQ0YjA1YjFhNDVlOGQwNzI0NzIyYTk5ZTRlMGVjMmQ0NzBhN2RiNjc4YmE2ZWFiZjdkNzQ5YTM5YjI5ZWRjMWQ1NTJjZDlhM2RiMjYzZTM2NDc3MWIxNTQ4MTAwN2E2Zjc0NmRlY2Y1ZDI4NGIzMmVkYzc5YTBhNzU1NDRkYWI5ZTNlMDdkNGIzZjkyNzQ1ZjQ1ZWFlNTllZTczY2NjNTY5MmJlNjFmYTA0NmY0ZWE4MTkxMGY3NjM4MzM4YWRjMzY2MjI1YzFiMTk4ZjZmNGMxMTI2MDkzYjZiMjk4YWI3ZmI5Nzc3N2FkNDQ0OTUyNjNmOTExZTkwZTE0NWY2YmQyYzcxMWE0MmU0ZjVmOTdhYTlhZmIyYzMxNmYwMDQ2YjNiYWVhM2Q1ZmIwZmM5NGVhNGEyMjg5NWRiZDg4NzQwMTI1YjRkNTNmOWYxOGI2OTAxMjNhY2Y5ODliNjgzZmFhY2Y5ODlmOGE1NDg1ZGNhYjQxMmQ4NjVlZjdlZDk0YjEzMjAyNzQyNWNhYjA5NDRkZTRkNzg2NjZlZmJmYjM1MWFiMDJiYmVmZmU3OGNlMTJkMDYyNTBlYjkzZjYzNTA5MWQ2MDFiNzdhYzQwNzFjNjM0MTc0ZTIiLCJucCI6IjAzM2YyNDNmODNiMjY0YzI5MDQwMTY4NTU2NWYxMWY0M2NlMGM0OGE1ZmQ5ZGZmZDQ2NDlkYWZlNjM5ZjMzMDUifSx7InByb3RvY29sIjoiczJrX2ZvIiwibmFtZSI6ImVtcHR5Iiwic3BkIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTJmMWZjNzBlMGEwMzYwMDg5MThiMmM0MDc4MTUwYjA5MmI0NDc1Zjc1MTViMjgyOTE2NjMzOTA1OGIzZDI5ZjRhZDY1NDBmNTA1ZWIxMDE4ZDdkZTVmMjJiZDJiZmM4OThmMzI3NTg1YWVhZTNhMWYwY2NmMWVkMWU5Y2Y4YThjZmM0NDY5ODhjNDRiMDViMWE0NWU4ZDA3MjQ3MjJhOTllNGUwZWMyZDQ3MGE3ZGI2NzhiYTZlYWJmN2Q3NDlhMzliMjllZGMxZDU1MmNkOWEzZGIyNjNlMzY0NzcxYjE1NDgxMDA3YTZmNzQ2ZGVjZjVkMjg0YjMyZWRjNzlhMGE3NTU0NGRhYjllM2UwN2Q0YjNmOTI3NDVmNDVlYWU1OWVlNzNjY2M1NjkyYmU2MWZhMDQ2ZjRlYTgxOTEwZjc2MzgzMzhhZGMzNjYyMjVjMWIxOThmNmY0YzExMjYwOTNiNmIyOThhYjdmYjk3Nzc3YWQ0NDQ5NTI2M2Y5MTFlOTBlMTQ1ZjZiZDJjNzExYTQyZTRmNWY5N2FhOWFmYjJjMzE2ZjAwNDZiM2JhZWEzZDVmYjBmYzk0ZWE0YTIyODk1YjI0NWJlZDFkOWE2MDViMDQ1MTg2NTk1OTU3OTVkZDE0ZDliMDFjN2MzYWFkNDA4ZDg1MjQ1ODRjNjcwZGQyNTdlMjA5ODk3YjhjN2RlYjI2ZTczYWU0MGU4MTdlODczIiwibnAiOiJjZjY1Y2Q0NDdhZDc4ZDg3ZTdjMTRjMmNjY2I1Yzk1MmFmOGNhNzllNjc4MDBiNDJiYjMzNmY1ZGNkYTU3N2JjIn0seyJwcm90b2NvbCI6InMya19mbyIsIm5hbWUiOiJ0eXBlZFVSTCIsInNwZCI6ImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZjFmYzcwZTBhMDM2MDA4OTE4YjJjNDA3ODE1MGIwOTJiNDQ3NWY3NTE1YjI4MjkxNjYzMzkwNThiM2QyOWY0YWQ2NTQwZjUwNWViMTAxOGQ3ZGU1ZjIyYmQyYmZjODk4ZjMyNzU4NWFlYWUzYTFmMGNjZjFlZDFlOWNmOGE4Y2ZjNDQ2OTg4YzQ0YjA1YjFhNDVlOGQwNzI0NzIyYTk5ZTRlMGVjMmQ0NzBhN2RiNjc4YmE2ZWFiZjdkNzQ5YTM5YjI5ZWRjMWQ1NTJjZDlhM2RiMjYzZTM2NDc3MWIxNTQ4MTAwN2E2Zjc0NmRlY2Y1ZDI4NGIzMmVkYzc5YTBhNzU1NDRkYWI5ZTNlMDdkNGIzZjkyNzQ1ZjQ1ZWFlNTllZTczY2NjNTY5MmJlNjFmYTA0NmY0ZWE4MTkxMGY3NjM4MzM4YWRjMzY2MjI1YzFiMTk4ZjZmNGMxMTI2MDkzYjZiMjk4YWI3ZmI5Nzc3N2FkNDQ0OTUyNjNmOTExZTkwZTE0NWY2YmQyYzcxMWE0MmU0ZjVmOTdhYTlhZmIyYzMxNmYwMDQ2YjNiYWVhM2Q1ZmIwZmM5NGVhNGEyMjg5NTRhMDE3MjRlMjFlZDEwNjJlMzg4ZmNlODdkMWI4MDZjNGZjNDAyZDNhMGMyZDdjMmFiMDVkOWJmZGYzMjUzYTRmYmE4OGY3NzBhYTgzYWVhNTA5NDEzNjU2ZjVlMzA5ZSIsIm5wIjoiZWM5YTc3MGE4NzgzNWY3NGZhYTE3ZDRmNzU0YjRiMTBmMDE3ZGNhNTQ4MWM2MTA0ZDNiOTZkNmY2ZmFlNGExNiJ9LHsicHJvdG9jb2wiOiJzMmtfZm8iLCJuYW1lIjoidGV4dENvZGUiLCJzcGQiOiJlNzJhZTUxMzk0NjFmMDgwY2I1ZDczMTA2ZTVkMTUyOTY2ZmVmY2UxNTc5YmE0MTEyMzVlOWE4MWFiNzFlZjEyNDdmNTlkMjU5MzFlZjJkNDVmOGFiNTJlZTEyNDc1OGEyMTM3NTgyMjA4ZGU0MmNkZGJkYTIwNjRjNDQyNDU3MjM2N2Q4YmE4ZGFmM2EwNzY4YjEyM2I0ZjUxZmQ3MjY1NWY1MjFjMTJhZjM0NTFjZTkzMDkzMzViOTUxMjI1NzQyZDVlNDJiNmI4NzlkMDg0YzUwMWY2NGI0MWM3ZDIzODJmN2QyNTY4MjZlNzJlZWFkM2Q5NTlmZmQ4Y2RlODIxZGM3MTlkZTliMWU5MzQ3YTg0YmViNDUzMjE2MTg3YjNkMzcxZjgwOWU5MTZjYjIwYTY3NGRmN2Q0ZDRkOWZmYWE3Yzc0ZDA0NjczODZkN2E4YjA3MjhkOWQzMjE4NjZhODZjZTA2NmU0OTkxMmYwMGNkZTk0NzA2NDc4OTZkNmFjNmYyZWYxMTkyYjEzOTY5MDkzNmNhMDI1MDE3NmFlZTRiM2I2ZjIyNzIxYTlmODgwOGY3YmRlOGYzZWEwYjUwOGU2NGJhYmI4OTE3MzI3ODBmZWVjYWMyMDlmYmU4MTVlN2IxZGVjMWI0MGM0MTExMmMyM2M2ZGJkYmU0OGFlMmYxZmM3MGUwYTAzNjAwODkxOGIyYzQwNzgxNTBiMDkyYjQ0NzVmNzUxNWIyODI5MTY2MzM5MDU4YjNkMjlmNGFkNjU0MGY1MDVlYjEwMThkN2RlNWYyMmJkMmJmYzg5OGYzMjc1ODVhZWFlM2ExZjBjY2YxZWQxZTljZjhhOGNmYzQ0Njk4OGM0NGIwNWIxYTQ1ZThkMDcyNDcyMmE5OWU0ZTBlYzJkNDcwYTdkYjY3OGJhNmVhYmY3ZDc0OWEzOWIyOWVkYzFkNTUyY2Q5YTNkYjI2M2UzNjQ3NzFiMTU0ODEwMDdhNmY3NDZkZWNmNWQyODRiMzJlZGM3OWEwYTc1NTQ0ZGFiOWUzZTA3ZDRiM2Y5Mjc0NWY0NWVhZTU5ZWU3M2NjYzU2OTJiZTYxZmEwNDZmNGVhODE5MTBmNzYzODMzOGFkYzM2NjIyNWMxYjE5OGY2ZjRjMTEyNjA5M2I5NmU3ZDA5MmUxZWRkYjM5YmM2YmJlYWVkOTQ4YTY2ZDg3Mzg3Y2QxYmM2NjI0NDY5ODFjMGYyYjU5NjA0YTBiZDVmM2NmZWViY2I3NGY4ODg3NjhlZmRjMmI0NTg2ZTU2MmIzMzE5NzdkODcxNGJmNjExZDM4ZTI4NzVkOGM2YyIsIm5wIjoiYjQ0ZmFmMWU3ZGE5NDc5NWZiYmYwZWRhODA1NDIzN2NjY2Y3Y2E0OTg5ZjkxYThhZjIyMjM0ODAyODc1NjVhZSJ9LHsicHJvdG9jb2wiOiJzMmtfZm8iLCJuYW1lIjoiYm9vbENvZGUiLCJzcGQiOiJlNzJhZTUxMzk0NjFmMDgwY2I1ZDczMTA2ZTVkMTUyOTY2ZmVmY2UxNTc5YmE0MTEyMzVlOWE4MWFiNzFlZjEyNDdmNTlkMjU5MzFlZjJkNDVmOGFiNTJlZTEyNDc1OGEyMTM3NTgyMjA4ZGU0MmNkZGJkYTIwNjRjNDQyNDU3MjM2N2Q4YmE4ZGFmM2EwNzY4YjEyM2I0ZjUxZmQ3MjY1NWY1MjFjMTJhZjM0NTFjZTkzMDkzMzViOTUxMjI1NzQyZDVlNDJiNmI4NzlkMDg0YzUwMWY2NGI0MWM3ZDIzODJmN2QyNTY4MjZlNzJlZWFkM2Q5NTlmZmQ4Y2RlODIxZGM3MTlkZTliMWU5MzQ3YTg0YmViNDUzMjE2MTg3YjNkMzcxZjgwOWU5MTZjYjIwYTY3NGRmN2Q0ZDRkOWZmYWE3Yzc0ZDA0NjczODZkN2E4YjA3MjhkOWQzMjE4NjZhODZjZTA2NmU0OTkxMmYwMGNkZTk0NzA2NDc4OTZkNmFjNmYyZWYxMTkyYjEzOTY5MDkzNmNhMDI1MDE3NmFlZTRiM2I2ZjIyNzIxYTlmODgwOGY3YmRlOGYzZWEwYjUwOGU2NGJhYmI4OTE3MzI3ODBmZWVjYWMyMDlmYmU4MTVlN2IxZGVjMWI0MGM0MTExMmMyM2M2ZGJkYmU0OGFlMmYxZmM3MGUwYTAzNjAwODkxOGIyYzQwNzgxNTBiMDkyYjQ0NzVmNzUxNWIyODI5MTY2MzM5MDU4YjNkMjlmNGFkNjU0MGY1MDVlYjEwMThkN2RlNWYyMmJkMmJmYzg5OGYzMjc1ODVhZWFlM2ExZjBjY2YxZWQxZTljZjhhOGNmYzQ0Njk4OGM0NGIwNWIxYTQ1ZThkMDcyNDcyMmE5OWU0ZTBlYzJkNDcwYTdkYjY3OGJhNmVhYmY3ZDc0OWEzOWIyOWVkYzFkNTUyY2Q5YTNkYjI2M2UzNjQ3NzFiMTU0ODEwMDdhNmY3NDZkZWNmNWQyODRiMzJlZGM3OWEwYTc1NTQ0ZGFiOWUzZTA3ZDRiM2Y5Mjc0NWY0NWVhZTU5ZWU3M2NjYzU2OTJiZTYxZmEwNDZmNGVhODE5MTBmNzYzODMzOGFkYzM2NjIyNWMxYjE5OGY2ZjRjMTEyNjA5M2JjNzZiNTBkMjI5MmUzY2VmYmNkMmM3ZDc1Yzc2ZTBlYjhjNTYwZWQ4NmFiMDY3N2YzOGI0MmRlZjEzMTZhODg2ZDEzOWIzYWYwMTBiMTlhMGExNGU3OTNjZDc1M2YyNDMiLCJucCI6Ijc2OTVlMjFjZTdhNjk0ZGIwZWUxZmRlZDI1ZmQ1Y2JkMzUzMzZmMzk5MjE1ZjM4ZDcwMjA2Y2EwZWNhNGRkMDEifSx7InByb3RvY29sIjoiczJrX2ZvIiwibmFtZSI6InVuZXhwZWN0ZWQiLCJzcGQiOiJlNzJhZTUxMzk0NjFmMDgwY2I1ZDczMTA2ZTVkMTUyOTY2ZmVmY2UxNTc5YmE0MTEyMzVlOWE4MWFiNzFlZjEyNDdmNTlkMjU5MzFlZjJkNDVmOGFiNTJlZTEyNDc1OGEyMTM3NTgyMjA4ZGU0MmNkZGJkYTIwNjRjNDQyNDU3MjM2N2Q4YmE4ZGFmM2EwNzY4YjEyM2I0ZjUxZmQ3MjY1NWY1MjFjMTJhZjM0NTFjZTkzMDkzMzViOTUxMjI1NzQyZDVlNDJiNmI4NzlkMDg0YzUwMWY2NGI0MWM3ZDIzODJmN2QyNTY4MjZlNzJlZWFkM2Q5NTlmZmQ4Y2RlODIxZGM3MTlkZTliMWU5MzQ3YTg0YmViNDUzMjE2MTg3YjNkMzcxZjgwOWU5MTZjYjIwYTY3NGRmN2Q0ZDRkOWZmYWE3Yzc0ZDA0NjczODZkN2E4YjA3MjhkOWQzMjE4NjZhODZjZTA2NmU0OTkxMmYwMGNkZTk0NzA2NDc4OTZkNmFjNmYyZWYxMTkyYjEzOTY5MDkzNmNhMDI1MDE3NmFlZTRiM2I2ZjIyNzIxYTlmODgwOGY3YmRlOGYzZWEwYjUwOGU2NGJhYmI4OTE3MzI3ODBmZWVjYWMyMDlmYmU4MTVlN2IxZGVjMWI0MGM0MTExMmMyM2M2ZGJkYmU0OGFlMmYxZmM3MGUwYTAzNjAwODkxOGIyYzQwNzgxNTBiMDkyYjQ0NzVmNzUxNWIyODI5MTY2MzM5MDU4YjNkMjlmNGFkNjU0MGY1MDVlYjEwMThkN2RlNWYyMmJkMmJmYzg5OGYzMjc1ODVhZWFlM2ExZjBjY2YxZWQxZTljZjhhOGNmYzQ0Njk4OGM0NGIwNWIxYTQ1ZThkMDcyNDcyMmE5OWU0ZTBlYzJkNDcwYTdkYjY3OGJhNmVhYmY3ZDc0OWEzOWIyOWVkYzFkNTUyY2Q5YTNkYjI2M2UzNjQ3NzFiMTU0ODEwMDdhNmY3NDZkZWNmNWQyODRiMzJlZGM3OWEwYTc1NTQ0ZGFiOWUzZTA3ZDRiM2Y5Mjc0NWY0NWVhZTU5ZWU3M2NjYzU2OTJiZTYxZmEwNDZmNGVhODE5MTBmNzYzODMzOGFkYzM2NjIyNWMxYjE5OGY2ZjRjMTEyNjA5M2I2YjI5OGFiN2ZiOTc3NzdhZDQ0NDk1MjYzZjkxMWU5MDc2ZTIyYzJlOTMzMjY4MmU4MzU5MTE0YmVjZGY2NGEzMjZkMzBjNGU5YWU1YzRmMjczMDlmN2FlODRiOTdkNGJhZDYwOWFlYWY4MTAxZDRmYjc2MDAwMmMyMjA0MWNjNCIsIm5wIjoiYzEyNmU2OWU4MzEyODAzZjI3MjJlOTExZTRiZjBkZjVjY2E2NzNmY2RmNzA1M2MxN2RlMmRmYTAxYTgxMWVjOCJ9LHsicHJvdG9jb2wiOiJzMmtfZm8iLCJuYW1lIjoiZGFuZ2xpbmciLCJzcGQiOiJlNzJhZTUxMzk0NjFmMDgwY2I1ZDczMTA2ZTVkMTUyOTY2ZmVmY2UxNTc5YmE0MTEyMzVlOWE4MWFiNzFlZjEyNDdmNTlkMjU5MzFlZjJkNDVmOGFiNTJlZTEyNDc1OGEyMTM3NTgyMjA4ZGU0MmNkZGJkYTIwNjRjNDQyNDU3MjM2N2Q4YmE4ZGFmM2EwNzY4YjEyM2I0ZjUxZmQ3MjY1NWY1MjFjMTJhZjM0NTFjZTkzMDkzMzViOTUxMjI1NzQyZDVlNDJiNmI4NzlkMDg0YzUwMWY2NGI0MWM3ZDIzODJmN2QyNTY4MjZlNzJlZWFkM2Q5NTlmZmQ4Y2RlODIxZGM3MTlkZTliMWU5MzQ3YTg0YmViNDUzMjE2MTg3YjNkMzcxZjgwOWU5MTZjYjIwYTY3NGRmN2Q0ZDRkOWZmYWE3Yzc0ZDA0NjczODZkN2E4YjA3MjhkOWQzMjE4NjZhODZjZTA2NmU0OTkxMmYwMGNkZTk0NzA2NDc4OTZkNmFjNmYyZWYxMTkyYjEzOTY5MDkzNmNhMDI1MDE3NmFlZTRiM2I2ZjIyNzIxYTlmODgwOGY3YmRlOGYzZWEwYjUwOGU2NGJhYmI4OTE3MzI3ODBmZWVjYWMyMDlmYmU4MTVlN2IxZGVjMWI0MGM0MTExMmMyM2M2ZGJkYmU0OGFlMmYxZmM3MGUwYTAzNjAwODkxOGIyYzQwNzgxNTBiMDkyYjQ0NzVmNzUxNWIyODI5MTY2MzM5MDU4YjNkMjlmNGFkNjU0MGY1MDVlYjEwMThkN2RlNWYyMmJkMmJmYzg5OGYzMjc1ODVhZWFlM2ExZjBjY2YxZWQxZTljZjhhOGNmYzQ0Njk4OGM0NGIwNWIxYTQ1ZThkMDcyNDcyMmE5OWU0ZTBlYzJkNDcwYTdkYjY3OGJhNmVhYmY3ZDc0OWEzOWIyOWVkYzFkNTUyY2Q5YTNkYjI2M2UzNjQ3NzFiMTU0ODEwMDdhNmY3NDZkZWNmNWQyODRiMzJlZGM3OWEwYTc1NTQ0ZGFiOWUzZTA3ZDRiM2Y5Mjc0NWY0NWVhZTU5ZWU3M2NjYzU2OTJiZTYxZmEwNDZmNGVhODE5MTBmNzYzOTBmNDA5N2VjY2Q5OWFmNTgzYjZkYjQ2YTAwZGQwODA3NTdiMDE5MTllNzg3ZWViY2VhYWM3ZjVkYzY2NGEwZWU1MTA5Zjk0NTdmNjVmZjIyODMxYWQ4YmU5OWQyM2VjZTA3ODcxNDY1ZGEyNWU2YjIxOWY1Y2U1ZjM0ZjNkYThiMGIzYTMyYjU2Yjk0NDY4OThlMTFlYTVhZGY1ZTVkZDRkM2ZiMjUwZWNmMzY0YjU0ZjFhZDkxYjVlMWZkMWM4IiwibnAiOiIzYWNhYjE1MDBiYzY0MDdkMGM3Zjc4MjhkZGQxYWRhYTc4ZWJjMGU4YzY1YjdhZWU3Zjg0MDRiNjg2ZWExMjU4In1d"
    }
    private struct IdentifierVector: Decodable, Sendable {
        let `protocol`: String, name: String, adsid: String
        let initialSPD: String, initialNP: String, finalSPD: String, finalNP: String, checksum: String
    }
    private enum IdentifierVectors {
        private struct File: Decodable { let vectors: [IdentifierVector] }
        static func all() throws -> [IdentifierVector] {
            guard let payload = Data(base64Encoded: base64) else { throw FixtureFailure.invalid }
            return try JSONDecoder().decode(File.self, from: payload).vectors
        }
        // Public synthetic ADSIDs, independently CBC sealed with fresh NP and
        // checksum values. The original numeric reference vectors stay intact.
        // Reproduce: docs/legado-ios/evidence/renewal-opaque-adsid-step/generate-owned-vectors.py
        static let base64 = "eyJzY2hlbWFWZXJzaW9uIjoxLCJwdWJsaWNGaXh0dXJlc09ubHkiOnRydWUsIm9yaWdpbmFsVmVjdG9yU0hBMjU2IjoiZTI4ZjMzYWQwZGNhNWZlODFmMTFjYTJkY2RkZjY2ODgxZDEyMDA1NjUzYTFkZGY3NTIzOTY0NmIyYzI3YmQxZSIsInNjUHJlc2VudCI6ZmFsc2UsInZlY3RvcnMiOlt7InByb3RvY29sIjoiczJrIiwibmFtZSI6Im9wYXF1ZSIsImFkc2lkIjoiUHVibGljLUZpeHR1cmUuQURTLUlELUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktIiwiaW5pdGlhbFNQRCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyMDY2OGQwZjBiMTU3YWFmYjk1MmQyMzYzMDU3OWY1OGQ2NWIyMTY0MTFiNDY1NTliNTFlMzM4MjI3YzEwYmU4MThkNDA0NzcwYTZkOTAyNmFiMmI5Y2YyMjlkYjgyODkzNGExZTk2MmUwODVhYjE2ZDBmODQ3YjQ4YTk3NWYzOGE4MGY4OTVkYzdjZDQ3MmQ0NDhkMDBmMmU2M2YzMjMxNGJhOTA0NmVkOWE5ODA5MzJkMjVhZTQzZDc1MDJiYmIzMjgzOTExNTdhMWI2ZTY2ZTRiNzUyODdjYzZlZjE5ZGQwYTAxNjRiNjE4ODgwNGY0MmM4ZDM2MjcyOTY2NTViYzA2ZjQ0ODU0YWFkN2M5NjAwYTMwYmM5NGI0Zjg1YWU4YjAxNDc0OWRjOWViODRhOTQ5M2Q0OWE1ZmJmMDcxYWMxNTZlMDMwZTBjMGQwYWQ0YmExYTM1ZjFmMTQxZWFkNzhlYTI1OTNmNTU1M2VhOWI0ZDA0OGQ3Zjg2YmIwYTMzYmUwODBlNTIzZjRhYjlhMzY0MjUyMzFjMTY1OWNkNzRhMmQ1Y2EzNjkwN2ViZDMzMjhlYTU2NGE0MjQwNTU3N2EwMDMwMGNiNGVlNmUwZjRkZDE1MzVlZmRiNzk4ZjRkZDEzNTQ1ZGEzNWVlOTE0Yjc5OGM2ZjA0ZWFjNjk4YmViMWI0YzI3NDgzYTg3MTUyY2U5ZWZmNjRkMmE3MzhmMjBhZDdjM2IzMjA2Yjg3YTE1NWMzOGM0Mzk1ZGJiMjJkZTIwMjVjYzIzNTk3NjliZWZmNDA1YzIxY2I2MWQxMjM4MmJjZDhhM2Q3ODg4ZDRlOGQzNzBiZTk2NjQyYWE4NTAzYjliMDc1M2RhZTMyMWE4ZmIzYTM3NmMzNGE5OTg3Y2Q1NmNhZTViOWM1OGI4MTVhNDE0YWM3N2YxNDhkZmZhNWJiODAwNjM3YmE5YWI3ZDAyZmE0NGQ3ZDc0YzJlNzBkYTBlOGJkZGY4NDJiYzQ0ZDU0YWEwNTM2ZjViNmI3IiwiaW5pdGlhbE5QIjoiNjIxZTJlNWQ0M2M5NmNjZDMwMjMwNDkyYjBhZGFmYWM4NDUxNzY2NjM2MzYzZDU1ODM4MzUyMGI0NmRhMGRiOCIsImZpbmFsU1BEIjoiMTZhY2FkYmI5Y2I4YmE1MjQ1MjU2NThkMDc2OWQ4YzJjNDA4YzZkZGU4MGYwNjc5ZjUzNTI0MzIxMzdmMDA3M2ZlMWY1M2MyOTMzNTNlMWU1ODlkZjlmYmFjYWZkMzMxYjA4N2Q3NDg4ZmVmMjI3YzdmZmFiMTAwY2FkZDE5NzBjM2MyYzdlYmNjMGFkMjZkNzQxNDI5OTdiOGVkYjFhYWZiYzk4OThkMGIxOTBhYjQwOGU0Y2IxMWEyNjQ5M2ZiODBkZWI1NGVjMTI5Zjk0ZTYwZGNlNmZlMjE2NDdlZGZjMGM5YTlmYzgyNjQ0ZTRkMzYwZjM0OGE0ODdmOWY4MmEzNDYxMWUyZWQ4ZDU3YTVlMzIzMjYzNDJhNTY3NWUwMzgzMTgyNWY2N2VkNTg5MzVmYzczMTM0OWMzMWIyODBmZmRiMzY5MjYyYzZkYzI3ZGM3OTE2ZGI5MzJiNTE5MWIxYzQzYTE2YzFlMGYyODcyNTFiN2I1NjE0YTM0ZDE3NmJlYmFhMzMzNWY5M2MxMTk0ZmIyZDAwODg5ZDM5YzM4ODU4MmI0NzQ2Y2RkMDhiZTE0MmRjNDVhMmQ3NTE1YjFlZWQ4ODA5ODljYWU5NDgzOGFlNTYyYjc5NzFjNzhiODM4ZWJkZjEwZmIwMWI1ZTUzOWMxMGYyNjRiZjg4NTIwNjY4ZDBmMGIxNTdhYWZiOTUyZDIzNjMwNTc5ZjU4ZDY1YjIxNjQxMWI0NjU1OWI1MWUzMzgyMjdjMTBiZTgxOGQ0MDQ3NzBhNmQ5MDI2YWIyYjljZjIyOWRiODI4OTM0YTFlOTYyZTA4NWFiMTZkMGY4NDdiNDhhOTc1ZjM4YTgwZjg5NWRjN2NkNDcyZDQ0OGQwMGYyZTYzZjMyMzE0YmE5MDQ2ZWQ5YTk4MDkzMmQyNWFlNDNkNzUwMmJiYjMyODM5MTE1N2ExYjZlNjZlNGI3NTI4N2NjNmVmMTlkZDBhMDE2NGI2MTg4ODA0ZjQyYzhkMzYyNzI5NjY1NWJjMDZmNDQ4NTRhYWQ3Yzk2MDBhMzBiYzk0YjRmODVhZThiMDE0NzQ5ZGM5ZWI4NGE5NDkzZDQ5YTVmYmYwNzFhYzE1NmUwMzBlMGMwZDBhZDRiYTFhMzVmMWYxNDFlYWQ3OGVhMjU5M2Y1NTUzZWE5YjRkMDQ4ZDdmODZiYjBhMzNiZTA4MGU1MjNmNGFiOWEzNjQyNTIzMWMxNjU5Y2Q3NGEyZDVjYTM2OTA3ZWJkMzMyOGVhNTY0YTQyNDA1NTc3YTAwMzAwY2I0ZWU2ZTBmNGRkMTUzNWVmZGI3OThmNGRkMTM1NDVkYTM1ZWU5MTRiNzk4YzZmMDRlYWM2OThiZWIxYjRjMjc0ODNhODcxNTJjZTllZmY2NGQyYTczOGYyMGFkN2MzYjMyMDZiODdhMTU1YzM4YzQzOTVkYmIyMmQxYzJiNGUwZTRmMTA0M2FhOTkwMDYxNTRkODNmMzExNTBmMDgwZTRmYWZiMDdiOGU4ZDkwYzY3NWZiOGYwNGI1YWNkNGZkOGEyN2I0MzU0NjIxMjhhOGE3YTk0MDBlZGYiLCJmaW5hbE5QIjoiNDc2YjU2MTQzNjYyMGVjYTlmMGJkYzUwNmMxZDRjNDM0OWMxOTEzMWJmZWRlNTE4MDNmYTJlYjA3NDNmNDBmZiIsImNoZWNrc3VtIjoiNjRlZGNhZWFlNjQzZWE5Mzk1NzYyZmZlZTM2YjUzNTU5NDFmZjI1YzVlMTJkMjU2Y2Q5OGIyZmE1YjlhMDY4MiJ9LHsicHJvdG9jb2wiOiJzMmsiLCJuYW1lIjoibWF4aW11bSIsImFkc2lkIjoiUHVibGljLUZpeHR1cmUuQURTLUlELUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFgiLCJpbml0aWFsU1BEIjoiMTZhY2FkYmI5Y2I4YmE1MjQ1MjU2NThkMDc2OWQ4YzJjNDA4YzZkZGU4MGYwNjc5ZjUzNTI0MzIxMzdmMDA3M2ZlMWY1M2MyOTMzNTNlMWU1ODlkZjlmYmFjYWZkMzMxYjA4N2Q3NDg4ZmVmMjI3YzdmZmFiMTAwY2FkZDE5NzBjM2MyYzdlYmNjMGFkMjZkNzQxNDI5OTdiOGVkYjFhYWZiYzk4OThkMGIxOTBhYjQwOGU0Y2IxMWEyNjQ5M2ZiODBkZWI1NGVjMTI5Zjk0ZTYwZGNlNmZlMjE2NDdlZGZjMGM5YTlmYzgyNjQ0ZTRkMzYwZjM0OGE0ODdmOWY4MmEzNDYxMWUyZWQ4ZDU3YTVlMzIzMjYzNDJhNTY3NWUwMzgzMTgyNWY2N2VkNTg5MzVmYzczMTM0OWMzMWIyODBmZmRiMzY5MjYyYzZkYzI3ZGM3OTE2ZGI5MzJiNTE5MWIxYzQzYTE2YzFlMGYyODcyNTFiN2I1NjE0YTM0ZDE3NmJlYmFhMzMzNWY5M2MxMTk0ZmIyZDAwODg5ZDM5YzM4ODU4MmI0NzQ2Y2RkMDhiZTE0MmRjNDVhMmQ3NTE1YjFlZWQ4ODA5ODljYWU5NDgzOGFlNTYyYjc5NzFjNzhiODM4ZWJkZjEwZmIwMWI1ZTUzOWMxMGYyNjRiZjg4NTIwNjY4ZDBmMGIxNTdhYWZiOTUyZDIzNjMwNTc5ZjU4ZDY1YjIxNjQxMWI0NjU1OWI1MWUzMzgyMjdjMTBiZTgxOGQ0MDQ3NzBhNmQ5MDI2YWIyYjljZjIyOWRiODI4OTM0YTFlOTYyZTA4NWFiMTZkMGY4NDdiNDhhOTc1ZjM4YTgwZjg5NWRjN2NkNDcyZDQ0OGQwMGYyZTYzZjMyMzE0YmE5MDQ2ZWQ5YTk4MDkzMmQyNWFlNDNkNzUwMmJiYjM0ZTM0MjhkMjBlNTFiYWQxMjNlZWE5NzU5YzEyMGI1ZjczZTdlZGNmYjY0YzBjNWFkOGRjNzdkYzIxNzBjZDM4MmJjMDE1NmU0OGYxNzBlNWViMzMyMGRiYjBlZjZlOWYwNjM0NDkzNTZmMWFiYWNjNTYyYmRhMDVlNDE3YmM3ODFiYjA2MTMzZTA5YWZlMzAxNmIxNTQ3MzYwMjhiMjMzNWQ0MGM3ZWE3MWYxMzk0OWRmZGY4NTk0YjhiNzYxYmQ2MDZhY2Q3NzY0ZDViZTUwNDBmNzNiMTA4MzA3ZmJiNWIzZDkyNGUwODE1NGQ2MThkMjIwZTkwNWViMTQxNTA0NjRlNThlZThiYWE1ZjkzYzBiYmUwODQ0MTFhNjdiYzUzOWMzYzNmNzg3NGZkM2QxMTFlNjQ0YWJiYzMzMzYyNTM0ZWQyOTQ3MTVkNmE5OGM0MWE4Zjc3ZWJmNDRlMzdjZWY3MmI4YjU0YmFhNDdhYTA0NTA1ZWRkNmJlMzhhMDRkNGI4ZGU1NWIyODBhNjY0NzdiYjg0OGMwMmUxMjQxYzMwYjJhNWE2ZjBkYzMxMGQwZDhlYTlkOGMzZjk3ZGFmMTVjYTMyMDhhOTI4ZGU0M2UzNzA2YTA3ZGE3ZDM3NzliMmZjMmM2OTZiZjBiMThlOGM5OTcwYzZmNGJjNDI1MTFjZTU2ZTU5NGQ2Y2VjYzI5NDljYTE4MGQ2M2UyODgyMmM4MmE3NzU1N2M1ZGY1ODk4MTI3ZDE3ZDlkYWQ1N2I0MmRmNWNmNDFlMWY0NzcwMTIzNGNiMzk5YWNhNTIxMTcwOWNhMzc1ODY3NmU3MmIxNjVkZTJjMjQxYTk1Nzk0IiwiaW5pdGlhbE5QIjoiYjJlZTIzZTU1NDMxZTQ2Y2Y0ZTYyMDJkNjM4ZGRlNDg2NWRmYjdjYWQ5MzkxYzBlYmFlMzg4NWRlNGQxZWY2NyIsImZpbmFsU1BEIjoiMTZhY2FkYmI5Y2I4YmE1MjQ1MjU2NThkMDc2OWQ4YzJjNDA4YzZkZGU4MGYwNjc5ZjUzNTI0MzIxMzdmMDA3M2ZlMWY1M2MyOTMzNTNlMWU1ODlkZjlmYmFjYWZkMzMxYjA4N2Q3NDg4ZmVmMjI3YzdmZmFiMTAwY2FkZDE5NzBjM2MyYzdlYmNjMGFkMjZkNzQxNDI5OTdiOGVkYjFhYWZiYzk4OThkMGIxOTBhYjQwOGU0Y2IxMWEyNjQ5M2ZiODBkZWI1NGVjMTI5Zjk0ZTYwZGNlNmZlMjE2NDdlZGZjMGM5YTlmYzgyNjQ0ZTRkMzYwZjM0OGE0ODdmOWY4MmEzNDYxMWUyZWQ4ZDU3YTVlMzIzMjYzNDJhNTY3NWUwMzgzMTgyNWY2N2VkNTg5MzVmYzczMTM0OWMzMWIyODBmZmRiMzY5MjYyYzZkYzI3ZGM3OTE2ZGI5MzJiNTE5MWIxYzQzYTE2YzFlMGYyODcyNTFiN2I1NjE0YTM0ZDE3NmJlYmFhMzMzNWY5M2MxMTk0ZmIyZDAwODg5ZDM5YzM4ODU4MmI0NzQ2Y2RkMDhiZTE0MmRjNDVhMmQ3NTE1YjFlZWQ4ODA5ODljYWU5NDgzOGFlNTYyYjc5NzFjNzhiODM4ZWJkZjEwZmIwMWI1ZTUzOWMxMGYyNjRiZjg4NTIwNjY4ZDBmMGIxNTdhYWZiOTUyZDIzNjMwNTc5ZjU4ZDY1YjIxNjQxMWI0NjU1OWI1MWUzMzgyMjdjMTBiZTgxOGQ0MDQ3NzBhNmQ5MDI2YWIyYjljZjIyOWRiODI4OTM0YTFlOTYyZTA4NWFiMTZkMGY4NDdiNDhhOTc1ZjM4YTgwZjg5NWRjN2NkNDcyZDQ0OGQwMGYyZTYzZjMyMzE0YmE5MDQ2ZWQ5YTk4MDkzMmQyNWFlNDNkNzUwMmJiYjM0ZTM0MjhkMjBlNTFiYWQxMjNlZWE5NzU5YzEyMGI1ZjczZTdlZGNmYjY0YzBjNWFkOGRjNzdkYzIxNzBjZDM4MmJjMDE1NmU0OGYxNzBlNWViMzMyMGRiYjBlZjZlOWYwNjM0NDkzNTZmMWFiYWNjNTYyYmRhMDVlNDE3YmM3ODFiYjA2MTMzZTA5YWZlMzAxNmIxNTQ3MzYwMjhiMjMzNWQ0MGM3ZWE3MWYxMzk0OWRmZGY4NTk0YjhiNzYxYmQ2MDZhY2Q3NzY0ZDViZTUwNDBmNzNiMTA4MzA3ZmJiNWIzZDkyNGUwODE1NGQ2MThkMjIwZTkwNWViMTQxNTA0NjRlNThlZThiYWE1ZjkzYzBiYmUwODQ0MTFhNjdiYzUzOWMzYzNmNzg3NGZkM2QxMTFlNjQ0YWJiYzMzMzYyNTM0ZWQyOTQ3MTVkNmE5OGM0MWE4Zjc3ZWJmNDRlMzdjZWY3MmI4YjU0YmFhNDdhYTA0NTA1ZWRkNmJlMzhhMDRkNGI4ZGU1NWIyODBhNjY0NzdiYjg0OGMwMmUxMjQxYzRmYWFmZDY1NGJhNDIwNmM5Yjc4MDM0ODhhNWNjZjUzYTZjZDY0MGRiYzdjODFlNmZmYTk5ZjRiOTY5OGE5MTliYmY0N2M5M2E1MDk3ZjhlNmQzYTQ3YjA3MDg5NDIxOSIsImZpbmFsTlAiOiIxZjk2OTI2ZGJmM2ZmYWQxOGE5NjBjYjdkYTY2NTQ2ZTdmMzU1YmM1NGU3NjdmZTZkMDRkYjhmNDRjMTQwM2I5IiwiY2hlY2tzdW0iOiI1MzRhYmQ5YTczOGRjZGYxNmY2Mjg0YzZhNzJkOWVmZGMxZjM1ZjhkODYxZDg0NTNlZTA3NWQwNmQ3Yjg0NjJkIn0seyJwcm90b2NvbCI6InMyayIsIm5hbWUiOiJlbXB0eSIsImFkc2lkIjoiIiwiaW5pdGlhbFNQRCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyNDU4NGVjNzBiYzczYzlmNTIyYmFmMjE5ZDMyZDkwZTBjYzdhZWM1NGQ1YjhkMTJjMTNhMjBhNzE3NjkyYzM2NjU1NmM5NGE1ZWI4YWQ4MTMyOGJjNzRmNjk0ZjIzYzk4MjhiYzI4NjE2MDY3YTY0ZjAzZTZlMzQyMzYxOTg1ZTA1YTQ5ZTFiNjdmNThhOThiMmNhYjdlOGY0YjQ2NTRkM2ZmNjhmNTE3ZWY2ZDdmYjg5OWFlY2VjYWRjOGM2NDUyZjc1ZTVkN2ExYzVjODExYTUwYTliNzVjZTFhN2RmNDRiOTZlNzUxMmI1NDEyNzRlZTQ2ZTc2ZGZiNGZhZGI0NThmMTgwNzZlZDA1ZmY4ZTM1NDMxNWI0YjNlNzJjY2VhMWUxMDNjMTVmODRmNTVmZDQ1MWNiMGU5MmVmMGNlNGRlYTU4NjI1YTJkMmMyYzNiNWFlM2RlZTViYzI3ZDNlZmY3N2YzY2UxY2MwNzgxYjY4ZTA1YTA5MzA0OTBkZDk2MTkzZmNlODg3NjIxMDU4ZWRiMmZkN2RjZjg0MDU0YThmODIxZWMzZTM3NjUzZjBkNDdlNmQ4YTI1NjFhZjhmNjM3MjFiOWQzMDJjYjJiOTMyMjg5NzE2Njg2OWM1YjA0ZmE2MmNlN2JlM2UyYzFlNzFiMDI1MWU4NzZiMjE1OTgwYmRjMzc0Zjk2NGE2NTAwM2Q3MGI4MjFhOTBjNDQxZTliOWExODUxOWQ4ZjczN2Q0ZTQwNzk3NjNjYWQ3NWE4IiwiaW5pdGlhbE5QIjoiOTNjYjQxYzlhZjAwNjlmZmE1MGY5ODgyZmMyNmIxN2U0YTRlZDkwZWE0Y2FlNjRlN2Y4YTMzNGMyYjZkMDhjYyIsImZpbmFsU1BEIjoiMTZhY2FkYmI5Y2I4YmE1MjQ1MjU2NThkMDc2OWQ4YzJjNDA4YzZkZGU4MGYwNjc5ZjUzNTI0MzIxMzdmMDA3M2ZlMWY1M2MyOTMzNTNlMWU1ODlkZjlmYmFjYWZkMzMxYjA4N2Q3NDg4ZmVmMjI3YzdmZmFiMTAwY2FkZDE5NzBjM2MyYzdlYmNjMGFkMjZkNzQxNDI5OTdiOGVkYjFhYWZiYzk4OThkMGIxOTBhYjQwOGU0Y2IxMWEyNjQ5M2ZiODBkZWI1NGVjMTI5Zjk0ZTYwZGNlNmZlMjE2NDdlZGZjMGM5YTlmYzgyNjQ0ZTRkMzYwZjM0OGE0ODdmOWY4MmEzNDYxMWUyZWQ4ZDU3YTVlMzIzMjYzNDJhNTY3NWUwMzgzMTgyNWY2N2VkNTg5MzVmYzczMTM0OWMzMWIyODBmZmRiMzY5MjYyYzZkYzI3ZGM3OTE2ZGI5MzJiNTE5MWIxYzQzYTE2YzFlMGYyODcyNTFiN2I1NjE0YTM0ZDE3NmJlYmFhMzMzNWY5M2MxMTk0ZmIyZDAwODg5ZDM5YzM4ODU4MmI0NzQ2Y2RkMDhiZTE0MmRjNDVhMmQ3NTE1YjFlZWQ4ODA5ODljYWU5NDgzOGFlNTYyYjc5NzFjNzhiODM4ZWJkZjEwZmIwMWI1ZTUzOWMxMGYyNjRiZjg4NTI0NTg0ZWM3MGJjNzNjOWY1MjJiYWYyMTlkMzJkOTBlMGNjN2FlYzU0ZDViOGQxMmMxM2EyMGE3MTc2OTJjMzY2NTU2Yzk0YTVlYjhhZDgxMzI4YmM3NGY2OTRmMjNjOTgyOGJjMjg2MTYwNjdhNjRmMDNlNmUzNDIzNjE5ODVlMDVhNDllMWI2N2Y1OGE5OGIyY2FiN2U4ZjRiNDY1NGQzZmY2OGY1MTdlZjZkN2ZiODk5YWVjZWNhZGM4YzY0NTJmNzVlNWQ3YTFjNWM4MTFhNTBhOWI3NWNlMWE3ZGY0NGI5NmU3NTEyYjU0MTI3NGVlNDZlNzZkZmI0ZmFkYjQ1OGYxODA3NmVkMDVmZjhlMzU0MzE1YjRiM2U3MmNjZWExZTEwM2MxNWY4NGY1NWZkNDUxY2IwZTkyZWYwY2U0ZGVhNTg2MjVhMmQyYzJjM2I1YWUzZGVlNWJjMjdkM2VmZWM1OWFiZWUzZmIzYzc4ZWU3NDE4YTE1Nzg5ZTg4NDliODU2MmVmYTYxMDgzM2E2Yzg0ZDNmODhkNTI0Y2JmNDcwZWMyNDlkOWEyYzM4NTYyYzRiNWNjMTM0MWM5MTQwIiwiZmluYWxOUCI6ImFlZDBmYzAwNGM4YzQxMDBhYjUzNDMxZjlhMjI3ZDdiMzAyNTBhZWQyYmVjZWUyYjg3YjZiYTI4MWIyNjBhMGYiLCJjaGVja3N1bSI6IjM0MmZmODM3ZmM5OTA2NmY3YjcwMDRhZDgxZWU4NGIxZTI5YTllOWIxNmQ5MzZiZjdjMjNmNzM4NDM0Mzk1YzQifSx7InByb3RvY29sIjoiczJrIiwibmFtZSI6ImNvbnRyb2wiLCJhZHNpZCI6IlB1YmxpYy1GaXh0dXJlXG5JZGVudGlmaWVyIiwiaW5pdGlhbFNQRCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyMDY2OGQwZjBiMTU3YWFmYjk1MmQyMzYzMDU3OWY1OGQ5YTE4M2ZjN2NjZmM4Y2M1Y2E3YTBiZTlhYWZkM2U1ZDVmODk4NGY2NDIwMzYzYjQ3OGY2YmQwNmI0ZTk2MDBjNjMxNjkyZDhlNDg4MmI1YmJkZDFmZGM2NGU2Y2Q2M2Y3Y2MzZjdlMWU1MjIyYTVlNjYzNGI5ZjI5ZjhjZjBhNWRhOGI4NjdlYTE3NzIwZTg1N2U4Y2Y5ZTVmODE5ZTU1ZjI2NDBiZTQ2OTBiY2YyNzlkYjFlNGJiYzMzZWM2YzhkMDcxZmMyNTI0M2VmNDUzZGJjY2QyZmQxNWNmNzE0Mjc3NTNlN2QxMDFmMzhjN2IxZTgyOWFmYWI1ZmJhNjdjODY3ZTBiYWMwZjA2YzBjNTVlYjVlYmNjYjNkMjZkZDk1NGNmMjE5MGZjM2I1MGE0ZGU4ZDY0ZWMxYzFiMTY4YTYxNTUwZGNhM2Q0ZjU2ZDk5Y2M1M2E2NGUwYjI1ODczNjFlMTljNjJhMWE2MmNiNzFlOTQ4ZDg5MDZmNTE0YmNhNDU3YjE1ODk3ZTY2YzA0YTAwNDM3MDdjYjIzM2Y5OGYxZjQ5YzhlYmFmM2I3YWFkZTg0ZDVhNTU5ZTkwNGE4OGQ4MDRmMTc2NmQ1NTAxMWQ1MGEyZDA3N2Y5MTRkMGMzYTI3ZDFhYjA1MzkyMTM5YjgzMDUzNzJkYjNjNjUxOTM5NWU5ZTI4YzhlZWE2MDcxMTcxNTA2YzZiM2U5NGFjMzMwYTNmZjViZmNiM2M1ZGYyNjk0ODAxZWVlMDQyMTkwMWU1MjlhNDcwZTg0NDBhZWU5OTMyNzIzZTM5YjM2ZSIsImluaXRpYWxOUCI6ImE1ZWY3ZjJlZDkwNTQ5Mjg3ZjNkZjA2ZGI1YmI4MDUxMTJmZmE2ZTMxMDM5ZjNkNmIwNTM2MGIzZGY5N2U5Y2EiLCJmaW5hbFNQRCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyMDY2OGQwZjBiMTU3YWFmYjk1MmQyMzYzMDU3OWY1OGQ5YTE4M2ZjN2NjZmM4Y2M1Y2E3YTBiZTlhYWZkM2U1ZDVmODk4NGY2NDIwMzYzYjQ3OGY2YmQwNmI0ZTk2MDBjNjMxNjkyZDhlNDg4MmI1YmJkZDFmZGM2NGU2Y2Q2M2Y3Y2MzZjdlMWU1MjIyYTVlNjYzNGI5ZjI5ZjhjZjBhNWRhOGI4NjdlYTE3NzIwZTg1N2U4Y2Y5ZTVmODE5ZTU1ZjI2NDBiZTQ2OTBiY2YyNzlkYjFlNGJiYzMzZWM2YzhkMDcxZmMyNTI0M2VmNDUzZGJjY2QyZmQxNWNmNzE0Mjc3NTNlN2QxMDFmMzhjN2IxZTgyOWFmYWI1ZmJhNjdjODY3ZTBiYWMwZjA2YzBjNTVlYjVlYmNjYjNkMjZkZDk1NGNmMjE5MGZjM2I1MGE0ZGU4ZDY0ZWMxYzFiMTY4YTYxNTUwZGNhM2Q0ZjU2ZDk5Y2M1M2E2NGUwYjI1ODczNjFlMTljNjJhMWE2MmNiNzFlOTQ4ZDg5MDZmNTE0YmNiNjU4NTFmNDdkZjY4MDM1OWNlYWJiNGM3YmQwODM0ODE5MGU5NWQ1ZmRmOGEwYTcwMjU0YWFhZDZjODhlMmE5MzYzZjEwYTQ2NjFhNDZkOTg2MTFjNjBlNzQ1ODU3ZmQiLCJmaW5hbE5QIjoiNjUwZGUzZjkyNTg0MGJlYjJhZjNkNzVjMDFmMjMwODA0ZDIxOGViNjhiOTNjZWE2YjE2ZTRmMjNkNWFiZWZhZiIsImNoZWNrc3VtIjoiNjU3M2UxZDIyOWEzMDdkNTg1ODJmMTkyMTBhNTJiZjkzNWM4NmQ2NjlmYmNkMmY3MDlhZmNlZDhmZDM1YWM0OCJ9LHsicHJvdG9jb2wiOiJzMmsiLCJuYW1lIjoiYzEiLCJhZHNpZCI6IlB1YmxpYy1GaXh0dXJlXHUwMDg1SWRlbnRpZmllciIsImluaXRpYWxTUEQiOiIxNmFjYWRiYjljYjhiYTUyNDUyNTY1OGQwNzY5ZDhjMmM0MDhjNmRkZTgwZjA2NzlmNTM1MjQzMjEzN2YwMDczZmUxZjUzYzI5MzM1M2UxZTU4OWRmOWZiYWNhZmQzMzFiMDg3ZDc0ODhmZWYyMjdjN2ZmYWIxMDBjYWRkMTk3MGMzYzJjN2ViY2MwYWQyNmQ3NDE0Mjk5N2I4ZWRiMWFhZmJjOTg5OGQwYjE5MGFiNDA4ZTRjYjExYTI2NDkzZmI4MGRlYjU0ZWMxMjlmOTRlNjBkY2U2ZmUyMTY0N2VkZmMwYzlhOWZjODI2NDRlNGQzNjBmMzQ4YTQ4N2Y5ZjgyYTM0NjExZTJlZDhkNTdhNWUzMjMyNjM0MmE1Njc1ZTAzODMxODI1ZjY3ZWQ1ODkzNWZjNzMxMzQ5YzMxYjI4MGZmZGIzNjkyNjJjNmRjMjdkYzc5MTZkYjkzMmI1MTkxYjFjNDNhMTZjMWUwZjI4NzI1MWI3YjU2MTRhMzRkMTc2YmViYWEzMzM1ZjkzYzExOTRmYjJkMDA4ODlkMzljMzg4NTgyYjQ3NDZjZGQwOGJlMTQyZGM0NWEyZDc1MTViMWVlZDg4MDk4OWNhZTk0ODM4YWU1NjJiNzk3MWM3OGI4MzhlYmRmMTBmYjAxYjVlNTM5YzEwZjI2NGJmODg1MjA2NjhkMGYwYjE1N2FhZmI5NTJkMjM2MzA1NzlmNThkNDQxNDU0ZDRhMzZlYjhiMjNkOWI0MDczMzM5ZjI3Njg4NWUwMWNjNjAxYWYxMWJiNzg1ODZiZTJhM2YxZGQwYjM4ZTUwODg5ZjYxNjJhNjYwMTI0Y2IxNDg1NGYxNzQ5MzQwMWE3ZjllMWRkZWUyYjllZTg5YWFmM2E0ZjFhY2JhNTk1NzI0YjY4Y2VjZmVjZjk1OWJiYzlmZjlkZmNkODc5YjE0YjE3NjNlM2JmMzJiZjZlZDZhZTliYzJiM2JiOWIyN2U1OGRkN2U2MmU5MWM4OWVkN2U3YjNkY2JjMDFjOTE1YTFiY2E3ZTdmZDhiYzlhMjVmOGFjMThlZTIzNTM2OTgzN2IzNjMyNGY4ZDNmYmFmMmMxOTRkMGUxNjViYjI0OGY0YTMwM2Q4N2UxNWNjNzU0OWU0MWE2ODllZjUxZTRjOTMxZDU2OGI1NTNkYjJlNjg5MDliNjJlOTM0NTFmMTJmYWVkOTdlZTgwNzdkODI4ZGE5OWFlYjU1M2FlNmIwYzk3YTdjYTZkOTlkYzRjZGFlM2E5Y2EzMDNhMGZmYzc2YzQ1ZmEwMzdjNDQ0OGY0ZTU1MDdmZTQ2NGM2NjExZGVjMWY1NmQzNjRjMWQ5M2MwYTc3NTY1NzQwNzVlNmY5Y2RhMzYyMzBkMDEwMmQwMmE3NDVlZjM3NzA4ZTI2NjAyYThhMDIyODllODU2ZjIyNzg5NDcwODc1MDllMDdiMGZiNjJlYTc5NjBmZGMyNTRiYTZiZTViMWI5Mjg5ZTczY2RmNGIwNGM3YjY2Y2Q4MWYxOTU1YjlmZTNmYjgiLCJpbml0aWFsTlAiOiJkM2Y3YWI3YWNlN2NjYzJlNDA5ODM3M2ZjNWNmZjA4Y2VmOWUyMWI2MGQwMjFlOWUzZGU1ZjZhMmQyNGI4NGFkIiwiZmluYWxTUEQiOiIxNmFjYWRiYjljYjhiYTUyNDUyNTY1OGQwNzY5ZDhjMmM0MDhjNmRkZTgwZjA2NzlmNTM1MjQzMjEzN2YwMDczZmUxZjUzYzI5MzM1M2UxZTU4OWRmOWZiYWNhZmQzMzFiMDg3ZDc0ODhmZWYyMjdjN2ZmYWIxMDBjYWRkMTk3MGMzYzJjN2ViY2MwYWQyNmQ3NDE0Mjk5N2I4ZWRiMWFhZmJjOTg5OGQwYjE5MGFiNDA4ZTRjYjExYTI2NDkzZmI4MGRlYjU0ZWMxMjlmOTRlNjBkY2U2ZmUyMTY0N2VkZmMwYzlhOWZjODI2NDRlNGQzNjBmMzQ4YTQ4N2Y5ZjgyYTM0NjExZTJlZDhkNTdhNWUzMjMyNjM0MmE1Njc1ZTAzODMxODI1ZjY3ZWQ1ODkzNWZjNzMxMzQ5YzMxYjI4MGZmZGIzNjkyNjJjNmRjMjdkYzc5MTZkYjkzMmI1MTkxYjFjNDNhMTZjMWUwZjI4NzI1MWI3YjU2MTRhMzRkMTc2YmViYWEzMzM1ZjkzYzExOTRmYjJkMDA4ODlkMzljMzg4NTgyYjQ3NDZjZGQwOGJlMTQyZGM0NWEyZDc1MTViMWVlZDg4MDk4OWNhZTk0ODM4YWU1NjJiNzk3MWM3OGI4MzhlYmRmMTBmYjAxYjVlNTM5YzEwZjI2NGJmODg1MjA2NjhkMGYwYjE1N2FhZmI5NTJkMjM2MzA1NzlmNThkNDQxNDU0ZDRhMzZlYjhiMjNkOWI0MDczMzM5ZjI3Njg4NWUwMWNjNjAxYWYxMWJiNzg1ODZiZTJhM2YxZGQwYjM4ZTUwODg5ZjYxNjJhNjYwMTI0Y2IxNDg1NGYxNzQ5MzQwMWE3ZjllMWRkZWUyYjllZTg5YWFmM2E0ZjFhY2JhNTk1NzI0YjY4Y2VjZmVjZjk1OWJiYzlmZjlkZmNkODc5YjE0YjE3NjNlM2JmMzJiZjZlZDZhZTliYzJiM2JiOWIyN2U1OGRkN2U2MmU5MWM4OWVkN2U3YjNkY2JjMDFjOTE1YTFiY2E3ZTdmZDhiYzlhMjVmOGFjMThlZTIzNTM2OTgzN2IzNjMyNGY4ZDNmYmFmMmMxOTRkMGUxNjViYjI0OGY0YTMwM2Q4N2UxNWNjNzU0OWU0MWE2ODllZjUxZTRjOTMxZDU2OGI1NTNkYjJlNjg5MDliNjJlOTM0NTFmMTJmYWVkOTdlZTgwNzdkODI4ZGE5OWFlYjU1M2FlYWJiOGUyZDIzNDU3ZjhmNmZjNGJjMjUyZTI1Y2NkMWIwNGMyODcwYWNjMDQzMmE4MmZmZmRmOGU5NWI3ZTkzOGY2ZWQ3Yzc3ZGU2NjcwNzRmYzJlYTRlYzI1Y2EyZjNjIiwiZmluYWxOUCI6ImFjOWViNTlmNWVhZTdhYzQ4MjMwZjEzZDI1MzI4YTgxOWMyMzY5N2JkZjdlNmQ0NzAyOTNhNTFjNjMzZTBlYzIiLCJjaGVja3N1bSI6IjkyZTU2MjdlNzRjNjgyZTBlYTY0YTlkOGIyZjNlZmVkNzY0ZjNiNjE5Nzg3NzVkNDMwMmU1NzhiNjQwN2FiYjIifSx7InByb3RvY29sIjoiczJrIiwibmFtZSI6Im92ZXJzaXplZCIsImFkc2lkIjoiUHVibGljLUZpeHR1cmUuQURTLUlELUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYIiwiaW5pdGlhbFNQRCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyMDY2OGQwZjBiMTU3YWFmYjk1MmQyMzYzMDU3OWY1OGQ2NWIyMTY0MTFiNDY1NTliNTFlMzM4MjI3YzEwYmU4MThkNDA0NzcwYTZkOTAyNmFiMmI5Y2YyMjlkYjgyODkzNGExZTk2MmUwODVhYjE2ZDBmODQ3YjQ4YTk3NWYzOGE4MGY4OTVkYzdjZDQ3MmQ0NDhkMDBmMmU2M2YzMjMxNGJhOTA0NmVkOWE5ODA5MzJkMjVhZTQzZDc1MDJiYmIzNGUzNDI4ZDIwZTUxYmFkMTIzZWVhOTc1OWMxMjBiNWY3M2U3ZWRjZmI2NGMwYzVhZDhkYzc3ZGMyMTcwY2QzODRkNmFjMDUxMDFkYzgzNThmM2FkM2FhY2ExZTBjMTNiMWExYTMyYjA3OGE0OWU2MDcyZGNmOWIxMDVlMzcwM2UxZmE0YWY4MTA5NjdkZjEwZWM1OWU1NTZiNWZlYWRlZmI2Njg0MmFhMGViMTAwMTRlOTk5ZmRjYjhkZDJlNjkwZjNjMThkZjYzZDIwNTNmZGU5NmZlMzE3OWIzODRjMDMyYzU2ZGMwNGViOWUwMjliMDAwYWUyMjFjMWFmZmI5NTZkYWFiOTMwY2Y2YzVmM2U1ZmM3NmFiZTQzNjAzOTZmM2I4NDI3ODliZmJjZmViMmE2Y2JmN2E4MGE3YmJmNjc3MGMzNWM2ZTM0NDUxMmJkNjEzM2ZkNDJkOTY5YWVmZTA5NTA0NTRjNTIzNDVlOTc4MTQyMjNlMDQ2MTAzOGZmMzFmYTAzODllZjEyMDRlYTdhNzdhMzQ0MWY0MTQzYWJhZTMwNzJkMDg2MzRlZGU1ZjBkODNiNmJlNWVjMTZlNjNmZjk0NjhmZDE1ZTA1NWU5OGU0MjkwYjRjMGQxZmFhN2NhZjVlOTYzYjE0NTFjNzVkMzM2ZDdlMDM4OGVhZDhmNDZkMDcxMTE1MjI0MjdjNzkyMGMxMzlhZWU4NGQ3ZjVlN2QxYTIzYWQ4ZjYxZmUzZmJjM2I5ZTM3Nzg1MDZiYmY4OWRhZTJjMzUzNmU0MWM2NGZkNTNkN2Y3NjYyY2MyYTgxODM1YzA5ZjliYjYwYWViNDRhM2EwZTU4NTg0NSIsImluaXRpYWxOUCI6ImViMzkzOTNhY2EwZWY5ZjhkOGQ4ODhjYmI5ZTQ5NGQyZTYxZWUxODRlNTY4YmI1MTQ2NTkxMDQ2MjVmNzM5ODYiLCJmaW5hbFNQRCI6IjE2YWNhZGJiOWNiOGJhNTI0NTI1NjU4ZDA3NjlkOGMyYzQwOGM2ZGRlODBmMDY3OWY1MzUyNDMyMTM3ZjAwNzNmZTFmNTNjMjkzMzUzZTFlNTg5ZGY5ZmJhY2FmZDMzMWIwODdkNzQ4OGZlZjIyN2M3ZmZhYjEwMGNhZGQxOTcwYzNjMmM3ZWJjYzBhZDI2ZDc0MTQyOTk3YjhlZGIxYWFmYmM5ODk4ZDBiMTkwYWI0MDhlNGNiMTFhMjY0OTNmYjgwZGViNTRlYzEyOWY5NGU2MGRjZTZmZTIxNjQ3ZWRmYzBjOWE5ZmM4MjY0NGU0ZDM2MGYzNDhhNDg3ZjlmODJhMzQ2MTFlMmVkOGQ1N2E1ZTMyMzI2MzQyYTU2NzVlMDM4MzE4MjVmNjdlZDU4OTM1ZmM3MzEzNDljMzFiMjgwZmZkYjM2OTI2MmM2ZGMyN2RjNzkxNmRiOTMyYjUxOTFiMWM0M2ExNmMxZTBmMjg3MjUxYjdiNTYxNGEzNGQxNzZiZWJhYTMzMzVmOTNjMTE5NGZiMmQwMDg4OWQzOWMzODg1ODJiNDc0NmNkZDA4YmUxNDJkYzQ1YTJkNzUxNWIxZWVkODgwOTg5Y2FlOTQ4MzhhZTU2MmI3OTcxYzc4YjgzOGViZGYxMGZiMDFiNWU1MzljMTBmMjY0YmY4ODUyMDY2OGQwZjBiMTU3YWFmYjk1MmQyMzYzMDU3OWY1OGQ2NWIyMTY0MTFiNDY1NTliNTFlMzM4MjI3YzEwYmU4MThkNDA0NzcwYTZkOTAyNmFiMmI5Y2YyMjlkYjgyODkzNGExZTk2MmUwODVhYjE2ZDBmODQ3YjQ4YTk3NWYzOGE4MGY4OTVkYzdjZDQ3MmQ0NDhkMDBmMmU2M2YzMjMxNGJhOTA0NmVkOWE5ODA5MzJkMjVhZTQzZDc1MDJiYmIzNGUzNDI4ZDIwZTUxYmFkMTIzZWVhOTc1OWMxMjBiNWY3M2U3ZWRjZmI2NGMwYzVhZDhkYzc3ZGMyMTcwY2QzODRkNmFjMDUxMDFkYzgzNThmM2FkM2FhY2ExZTBjMTNiMWExYTMyYjA3OGE0OWU2MDcyZGNmOWIxMDVlMzcwM2UxZmE0YWY4MTA5NjdkZjEwZWM1OWU1NTZiNWZlYWRlZmI2Njg0MmFhMGViMTAwMTRlOTk5ZmRjYjhkZDJlNjkwZjNjMThkZjYzZDIwNTNmZGU5NmZlMzE3OWIzODRjMDMyYzU2ZGMwNGViOWUwMjliMDAwYWUyMjFjMWFmZmI5NTZkYWFiOTMwY2Y2YzVmM2U1ZmM3NmFiZTQzNjAzOTZmM2I4NDI3ODliZmJjZmViMmE2Y2JmN2E4MGE3YmJmNjc3MGMzNWM2ZTM0NDUxMmJkNjEzM2ZkNDJkOTY5YWVmZTA5NTA0NTRjNTIzNDVlOTc4MTQyMjNlMDQ2MTAzOGZmMzFmYTAzODllZjEyMDRlYTdhNzdhMzQ0MWY0MTQzYWJiMzYyYWI0ZDVjMmE4NzVkNTM5ODdhMjQ5OTEwYjYwM2IzZWY1NThiYTdlYTE3M2QwNTFiODAzNmUwNjVkY2Y3YjQ3NjdkMGQzNmUwOGViYzY0OTE2MDBhYzE1MGRiY2UiLCJmaW5hbE5QIjoiOTEzYzBhZDA3NWI0YTIzOWU1NGMzMjg5YjcxZmVkOTA0NDdmNTcxM2QwMjEyN2ZkYTFjMjZjOTAwYmRmMWU5OCIsImNoZWNrc3VtIjoiOWUyMDMzZmYxOTMyNjAwY2NlZDNlZmFlOGEzYmE1MTJlNzFjZjg3OTdhNGQzZDg4NzE2N2EwMWFmZWNjNDFkYSJ9LHsicHJvdG9jb2wiOiJzMmtfZm8iLCJuYW1lIjoib3BhcXVlIiwiYWRzaWQiOiJQdWJsaWMtRml4dHVyZS5BRFMtSUQtQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS0iLCJpbml0aWFsU1BEIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTJkMzM1NGEwZmRlMGVkYWE3YmYzZmYzYzg3ZmJjYjZjYWZkMmM5NjVkMzQ3OTIyOWQ2ZGNiYmRkOTM4YzQzMmQyM2I3ZTc0OGM1ZmJiNmNjMDQxODJiOWY0ZjlhODdhZmY1NjUyNzUyMGY3ZmVjY2NhNjhmNzJhMzc0OTU0M2U0ZmFhMTA1M2RjODQ1YjM3M2QzMmJhZTliNjdlZjlhNGQxNGFlYzBmODg0ZmFiOTk4MzUyYjQxMDk5YzlhMmQ5YmQ3ZGMzOGYwODRiZjRhNzVlOTViNmUyZDg0ZWZjNzc4MTlmZTBjZTA3ZDc1YmNhZjAyZTQ3MzFmZWRkODk1NjExMDNlYWM3YTA4MDk2NmYwOTU3Njg5MWNiMTEwZThhNWVhNzlkMmFjMmRmYmRhNzllZDA5NjlmNmZjOGZiYTg5YWM2ZTk4NDIxY2MyMjY3N2JmMzkxNDYwYzQ5NGYzMTVkMzllMjBkYTE3YWY1NzhlMjU3MmJiOGQ5MGRlOTQyNGU3NDJkZmJkMGY5ZjAzNWQ2MWIxMmJmNmI5MTA1NzJkNDI5OTg4MTFkNzNhYjIxYzBmZjc2YWE5NjIzMzdkNmMyYjM2NDZkOGMxMjg0MGM1ZDI5Y2M1YzJkMGY2YTg0YWYwMzM2NzQ5YmI5MDdlMWNkNTNiYjY3MzVmZDI4ZmI1NGM5Yjk3MjdlZDM4ZTUwMDc3MGY1OGZjZjM5YzdhMTQ3YTI2MDdhNjU5ODc0OGVmYTZhNzQ1MTNjM2RmNzc2MjYyNjM3ZTQwYzNmMzdlODdlNWVhNzQwYTQ3NzM5OGIzODQ3NDJlNDhjNTBmNDM2MzNmNzMxNTg5YmRlNDRmZmFjZTUzYWVlYjRiMDY5NmMwODdlZThlOGE5MDBmOTA5YzViYTY1ZWUyMTY2MDFmZmY5MTQwNDM0MzE1NmM1ZmFhMmU0YWU0MDZjYWE2MmJhYTAyMGNjZWNiZWQ0MGY5ZWVmZGNlNTg4YTcwZGUxOWQzZDUxNGVhZTliNWFiNGY3ZTEiLCJpbml0aWFsTlAiOiJlMjUwNTI2OTdiZjY5YzcwNmY3Y2IwM2M2Njc2ZjYzMTE0OWYyYTE0NTcxYzdkODI5NDIwZTE3NTYyMDFhMjE2IiwiZmluYWxTUEQiOiJlNzJhZTUxMzk0NjFmMDgwY2I1ZDczMTA2ZTVkMTUyOTY2ZmVmY2UxNTc5YmE0MTEyMzVlOWE4MWFiNzFlZjEyNDdmNTlkMjU5MzFlZjJkNDVmOGFiNTJlZTEyNDc1OGEyMTM3NTgyMjA4ZGU0MmNkZGJkYTIwNjRjNDQyNDU3MjM2N2Q4YmE4ZGFmM2EwNzY4YjEyM2I0ZjUxZmQ3MjY1NWY1MjFjMTJhZjM0NTFjZTkzMDkzMzViOTUxMjI1NzQyZDVlNDJiNmI4NzlkMDg0YzUwMWY2NGI0MWM3ZDIzODJmN2QyNTY4MjZlNzJlZWFkM2Q5NTlmZmQ4Y2RlODIxZGM3MTlkZTliMWU5MzQ3YTg0YmViNDUzMjE2MTg3YjNkMzcxZjgwOWU5MTZjYjIwYTY3NGRmN2Q0ZDRkOWZmYWE3Yzc0ZDA0NjczODZkN2E4YjA3MjhkOWQzMjE4NjZhODZjZTA2NmU0OTkxMmYwMGNkZTk0NzA2NDc4OTZkNmFjNmYyZWYxMTkyYjEzOTY5MDkzNmNhMDI1MDE3NmFlZTRiM2I2ZjIyNzIxYTlmODgwOGY3YmRlOGYzZWEwYjUwOGU2NGJhYmI4OTE3MzI3ODBmZWVjYWMyMDlmYmU4MTVlN2IxZGVjMWI0MGM0MTExMmMyM2M2ZGJkYmU0OGFlMmQzMzU0YTBmZGUwZWRhYTdiZjNmZjNjODdmYmNiNmNhZmQyYzk2NWQzNDc5MjI5ZDZkY2JiZGQ5MzhjNDMyZDIzYjdlNzQ4YzVmYmI2Y2MwNDE4MmI5ZjRmOWE4N2FmZjU2NTI3NTIwZjdmZWNjY2E2OGY3MmEzNzQ5NTQzZTRmYWExMDUzZGM4NDViMzczZDMyYmFlOWI2N2VmOWE0ZDE0YWVjMGY4ODRmYWI5OTgzNTJiNDEwOTljOWEyZDliZDdkYzM4ZjA4NGJmNGE3NWU5NWI2ZTJkODRlZmM3NzgxOWZlMGNlMDdkNzViY2FmMDJlNDczMWZlZGQ4OTU2MTEwM2VhYzdhMDgwOTY2ZjA5NTc2ODkxY2IxMTBlOGE1ZWE3OWQyYWMyZGZiZGE3OWVkMDk2OWY2ZmM4ZmJhODlhYzZlOTg0MjFjYzIyNjc3YmYzOTE0NjBjNDk0ZjMxNWQzOWUyMGRhMTdhZjU3OGUyNTcyYmI4ZDkwZGU5NDI0ZTc0MmRmYmQwZjlmMDM1ZDYxYjEyYmY2YjkxMDU3MmQ0Mjk5ODgxMWQ3M2FiMjFjMGZmNzZhYTk2MjMzN2Q2YzJiMzY0NmQ4YzEyODQwYzVkMjljYzVjMmQwZjZhODRhZjAzMzY3NDliYjkwN2UxY2Q1M2JiNjczNWZkMjhmYjU0YzliOTcyN2VkMzhlNTAwNzcwZjU4ZmNmMzljN2ExNDdhMjYwN2E2NTk4NzQ4ZWZhNmE3NDUxM2MzZGY3NzYyNmM4NGIxN2QyZGQzOGFjZGRjZDhjMzVmZGU1MDgwZmQxMDAyOWNmNjRhZWI3N2QzMjNhOGVhZTg0Y2U4NTA1MDdmNjE4MDAyZTI1Nzg2Yzk2MzA2NTQzZTI3MjJiNDRmNSIsImZpbmFsTlAiOiI2YmYxYTEyYzllMGU5YTIzYWE0MDE3MzA0YjMzZmRkMjAzNTg0YWQ4Y2FiZGUxNzg1ODNhMDJjNjFhMDNmZjQzIiwiY2hlY2tzdW0iOiI2NGVkY2FlYWU2NDNlYTkzOTU3NjJmZmVlMzZiNTM1NTk0MWZmMjVjNWUxMmQyNTZjZDk4YjJmYTViOWEwNjgyIn0seyJwcm90b2NvbCI6InMya19mbyIsIm5hbWUiOiJtYXhpbXVtIiwiYWRzaWQiOiJQdWJsaWMtRml4dHVyZS5BRFMtSUQtQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWCIsImluaXRpYWxTUEQiOiJlNzJhZTUxMzk0NjFmMDgwY2I1ZDczMTA2ZTVkMTUyOTY2ZmVmY2UxNTc5YmE0MTEyMzVlOWE4MWFiNzFlZjEyNDdmNTlkMjU5MzFlZjJkNDVmOGFiNTJlZTEyNDc1OGEyMTM3NTgyMjA4ZGU0MmNkZGJkYTIwNjRjNDQyNDU3MjM2N2Q4YmE4ZGFmM2EwNzY4YjEyM2I0ZjUxZmQ3MjY1NWY1MjFjMTJhZjM0NTFjZTkzMDkzMzViOTUxMjI1NzQyZDVlNDJiNmI4NzlkMDg0YzUwMWY2NGI0MWM3ZDIzODJmN2QyNTY4MjZlNzJlZWFkM2Q5NTlmZmQ4Y2RlODIxZGM3MTlkZTliMWU5MzQ3YTg0YmViNDUzMjE2MTg3YjNkMzcxZjgwOWU5MTZjYjIwYTY3NGRmN2Q0ZDRkOWZmYWE3Yzc0ZDA0NjczODZkN2E4YjA3MjhkOWQzMjE4NjZhODZjZTA2NmU0OTkxMmYwMGNkZTk0NzA2NDc4OTZkNmFjNmYyZWYxMTkyYjEzOTY5MDkzNmNhMDI1MDE3NmFlZTRiM2I2ZjIyNzIxYTlmODgwOGY3YmRlOGYzZWEwYjUwOGU2NGJhYmI4OTE3MzI3ODBmZWVjYWMyMDlmYmU4MTVlN2IxZGVjMWI0MGM0MTExMmMyM2M2ZGJkYmU0OGFlMmQzMzU0YTBmZGUwZWRhYTdiZjNmZjNjODdmYmNiNmNhZmQyYzk2NWQzNDc5MjI5ZDZkY2JiZGQ5MzhjNDMyZDIzYjdlNzQ4YzVmYmI2Y2MwNDE4MmI5ZjRmOWE4N2FmZjU2NTI3NTIwZjdmZWNjY2E2OGY3MmEzNzQ5NTQzZTRmYWExMDUzZGM4NDViMzczZDMyYmFlOWI2N2VmOWE0ZDE0YWVjMGY4ODRmYWI5OTgzNTJiNDEwOTljOWEyZDliZDA0M2M4N2Q3OTlmNjEwNTg3ZDExZThhODQzMzVhOGIzZGQyYjEzNDdiZTAxYmNlNmVjY2YyOTc5NTRkMGUyZDZhNTAyNTU5MTFiOWQ2ZmFkZjI5ZTkzNGM1MDYyYmEwNDJhYmYwMmIzY2MxNmU2MDI0NDkwZDc3MDY3MTg0M2U0N2FmMDk3N2JjOGUwNGFlY2FjMDJkNTRmNzRmMDg2MTQ5NWNhMTFjNWIzODljMjcwOGYzYjkyODY0NjcyY2QxODUxYTQ0NjJkMWZjYjI3MDJhMGIyYjhhZGVkYWJlMzNiMzZkY2I1ZGVjZWM2N2Q0ZjBiMTdjYjE1NjFhMzU0YmE5NzgwMDk2NTgzMWQ0M2U5MTg4Zjg2NjYyYmZlYTI5MGU1ZDE4NWNmMTRiYTQ5YWU5MmRkYjAwYzQ1NTM2MDRkZjI2NTViNmNjNTYyMjgxZWJhN2M0M2Q0NTJlMmRkYzJiYmU5ZDRmNjI1M2Q4MDkxZWI4OTNiNWRkMzI2ZjZiNTkwMGE0ZDFiZTE0ZDQxZTE3NDY0OGRjMGM1YjhiODgwYzgyOTZmM2IxZDE3ZjczZDllYjNmYjc5MTYzODdhYWE0YTZkMWQ4MDdiMzNjODc0MzIwYWEzYjdlZTI5ZmRlMGU2ZmFiNDU2ODk4YjExZTVkMDQ3NmJkNzdjNjEwYmVjNTk0ZGYxZWJjZTVmYWExOTg1ZTNkMGNkMDE0OTQ3NjNiZTMxOTIxY2Y3MDdhY2MwOThlMzgxMDE1NjBmNWFhM2I0NzhjYjhjZDdiMzEzMjgwZDk5NGUzOTM2MDFlNzJlMTA4OGRiNDkxYzVmNDEzYWVkNWY2ZTk5ZDAzYjE3OTIiLCJpbml0aWFsTlAiOiJiMmIwYTFmMDExNzQwNmVjMWJjNWIyMTg5NjExMTRmNGI4ZDE2MGZkN2Y2MTdlZWMwOTk5NDc1OTkzZWJhYjBjIiwiZmluYWxTUEQiOiJlNzJhZTUxMzk0NjFmMDgwY2I1ZDczMTA2ZTVkMTUyOTY2ZmVmY2UxNTc5YmE0MTEyMzVlOWE4MWFiNzFlZjEyNDdmNTlkMjU5MzFlZjJkNDVmOGFiNTJlZTEyNDc1OGEyMTM3NTgyMjA4ZGU0MmNkZGJkYTIwNjRjNDQyNDU3MjM2N2Q4YmE4ZGFmM2EwNzY4YjEyM2I0ZjUxZmQ3MjY1NWY1MjFjMTJhZjM0NTFjZTkzMDkzMzViOTUxMjI1NzQyZDVlNDJiNmI4NzlkMDg0YzUwMWY2NGI0MWM3ZDIzODJmN2QyNTY4MjZlNzJlZWFkM2Q5NTlmZmQ4Y2RlODIxZGM3MTlkZTliMWU5MzQ3YTg0YmViNDUzMjE2MTg3YjNkMzcxZjgwOWU5MTZjYjIwYTY3NGRmN2Q0ZDRkOWZmYWE3Yzc0ZDA0NjczODZkN2E4YjA3MjhkOWQzMjE4NjZhODZjZTA2NmU0OTkxMmYwMGNkZTk0NzA2NDc4OTZkNmFjNmYyZWYxMTkyYjEzOTY5MDkzNmNhMDI1MDE3NmFlZTRiM2I2ZjIyNzIxYTlmODgwOGY3YmRlOGYzZWEwYjUwOGU2NGJhYmI4OTE3MzI3ODBmZWVjYWMyMDlmYmU4MTVlN2IxZGVjMWI0MGM0MTExMmMyM2M2ZGJkYmU0OGFlMmQzMzU0YTBmZGUwZWRhYTdiZjNmZjNjODdmYmNiNmNhZmQyYzk2NWQzNDc5MjI5ZDZkY2JiZGQ5MzhjNDMyZDIzYjdlNzQ4YzVmYmI2Y2MwNDE4MmI5ZjRmOWE4N2FmZjU2NTI3NTIwZjdmZWNjY2E2OGY3MmEzNzQ5NTQzZTRmYWExMDUzZGM4NDViMzczZDMyYmFlOWI2N2VmOWE0ZDE0YWVjMGY4ODRmYWI5OTgzNTJiNDEwOTljOWEyZDliZDA0M2M4N2Q3OTlmNjEwNTg3ZDExZThhODQzMzVhOGIzZGQyYjEzNDdiZTAxYmNlNmVjY2YyOTc5NTRkMGUyZDZhNTAyNTU5MTFiOWQ2ZmFkZjI5ZTkzNGM1MDYyYmEwNDJhYmYwMmIzY2MxNmU2MDI0NDkwZDc3MDY3MTg0M2U0N2FmMDk3N2JjOGUwNGFlY2FjMDJkNTRmNzRmMDg2MTQ5NWNhMTFjNWIzODljMjcwOGYzYjkyODY0NjcyY2QxODUxYTQ0NjJkMWZjYjI3MDJhMGIyYjhhZGVkYWJlMzNiMzZkY2I1ZGVjZWM2N2Q0ZjBiMTdjYjE1NjFhMzU0YmE5NzgwMDk2NTgzMWQ0M2U5MTg4Zjg2NjYyYmZlYTI5MGU1ZDE4NWNmMTRiYTQ5YWU5MmRkYjAwYzQ1NTM2MDRkZjI2NTViNmNjNTYyMjgxZWJhN2M0M2Q0NTJlMmRkYzJiYmU5ZDRmNjI1M2Q4MDkxZWI4OTNiNWRkMzI2ZjZiNTkwMGE0ZDFiZTE0ZDQxZTE3NDY0OGRjMGM1YjhiODgwNzg4OGFjNGY4NWUyZWM5OTY0YmRjODU0NmRmOTY3YzE5YmU1Nzc1YWQzMzliZWUyYjI0NTA4YTZiZGNkNTk4NTRkZDYyMzg2YjNjYzAxZDllMGFjMGU0NTg0NDg5ZGY3IiwiZmluYWxOUCI6ImU5ZDFiNTBjZjY1ZWE2ZDU5Y2JlODE5MTYxZGE4Y2ZlMmI3ZDYxOGQ2ZmMxMjY4NTlmYzNhYTIxNGI5MjE4NjYiLCJjaGVja3N1bSI6IjUzNGFiZDlhNzM4ZGNkZjE2ZjYyODRjNmE3MmQ5ZWZkYzFmMzVmOGQ4NjFkODQ1M2VlMDc1ZDA2ZDdiODQ2MmQifSx7InByb3RvY29sIjoiczJrX2ZvIiwibmFtZSI6ImVtcHR5IiwiYWRzaWQiOiIiLCJpbml0aWFsU1BEIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTI5NDZlODA2OWI1NWUyNDAzZWYxNGI5MTlhNDk0M2IwNzk4ZDk4Njc3MjhmODExYWNlM2Y0MjM4M2NiNjA3OTViNjgzY2NhNjllZTVhNDJjMWJmODJjNzBjNzU2NGQ2OWQwOWJmNDliODEyZjY4NDMxZjM5YWYwNjY3ZjQ0NGNiNjlkZTIxYjhiYmYwNTA1MzBmMzVjN2ZhYTE3MDEwZGYzY2QxOWMwNjVkMjViOTIzOTMzMmM1ZDdiZTdjZDE5YTI0NTZmZTE0NDk2NDc0ZDZkM2M4YWI2YzZjOTVjNWEwNTQxNjQ1NDE3NWZlYzZkZWIyOTI5OGEzYzFlZjhkMjNiZDM1N2FlYWM5MjM5OTYwYjU4ZjRiMzg3N2VjOTdhZDczNGQ5YzE1ODMwZWFmNTAzODJiZTA0MjVjYmU3Y2Q0YjFiNWVjMjZiYmZhZDUyZDcyNTExNTM1YTZiMjNhODkyMzE1MDZkZDAyMmZmYzA3YmEyZDU5ZThlMzg4OTkxODQ5ODAzMDFjMzBiZDM0YjcwMDhhM2IyNThhZWNlNzFlM2QyMmJiMTU1Njc2YjcxYWU5MTYzMzc1N2VhYWEwYzVlMTU3M2Y5OTkwMGEzYjE3MWFmZTg3ODFmM2Q5M2Q3MGEyODUwOGI5MDhmM2U4NDNiZGI2NzNhZWZkYzYyYTIwY2Y5ZmQ2OTc5MmRiMWQ3MGFiMGM2NGU3YjU3NzA2ZTRlOTVjZDc2ODJkZWFhZTRmMTA2OGUwMDY3MWExMjllYzYiLCJpbml0aWFsTlAiOiIwMDY0ZTA1YjM4OWNiZDg1OWVmODQyNGYxYzZjNDg3ZjQwMGRhYTdmYjE5NDkwYTIwYWUzMzIyMzQ3MWYzMzg3IiwiZmluYWxTUEQiOiJlNzJhZTUxMzk0NjFmMDgwY2I1ZDczMTA2ZTVkMTUyOTY2ZmVmY2UxNTc5YmE0MTEyMzVlOWE4MWFiNzFlZjEyNDdmNTlkMjU5MzFlZjJkNDVmOGFiNTJlZTEyNDc1OGEyMTM3NTgyMjA4ZGU0MmNkZGJkYTIwNjRjNDQyNDU3MjM2N2Q4YmE4ZGFmM2EwNzY4YjEyM2I0ZjUxZmQ3MjY1NWY1MjFjMTJhZjM0NTFjZTkzMDkzMzViOTUxMjI1NzQyZDVlNDJiNmI4NzlkMDg0YzUwMWY2NGI0MWM3ZDIzODJmN2QyNTY4MjZlNzJlZWFkM2Q5NTlmZmQ4Y2RlODIxZGM3MTlkZTliMWU5MzQ3YTg0YmViNDUzMjE2MTg3YjNkMzcxZjgwOWU5MTZjYjIwYTY3NGRmN2Q0ZDRkOWZmYWE3Yzc0ZDA0NjczODZkN2E4YjA3MjhkOWQzMjE4NjZhODZjZTA2NmU0OTkxMmYwMGNkZTk0NzA2NDc4OTZkNmFjNmYyZWYxMTkyYjEzOTY5MDkzNmNhMDI1MDE3NmFlZTRiM2I2ZjIyNzIxYTlmODgwOGY3YmRlOGYzZWEwYjUwOGU2NGJhYmI4OTE3MzI3ODBmZWVjYWMyMDlmYmU4MTVlN2IxZGVjMWI0MGM0MTExMmMyM2M2ZGJkYmU0OGFlMjk0NmU4MDY5YjU1ZTI0MDNlZjE0YjkxOWE0OTQzYjA3OThkOTg2NzcyOGY4MTFhY2UzZjQyMzgzY2I2MDc5NWI2ODNjY2E2OWVlNWE0MmMxYmY4MmM3MGM3NTY0ZDY5ZDA5YmY0OWI4MTJmNjg0MzFmMzlhZjA2NjdmNDQ0Y2I2OWRlMjFiOGJiZjA1MDUzMGYzNWM3ZmFhMTcwMTBkZjNjZDE5YzA2NWQyNWI5MjM5MzMyYzVkN2JlN2NkMTlhMjQ1NmZlMTQ0OTY0NzRkNmQzYzhhYjZjNmM5NWM1YTA1NDE2NDU0MTc1ZmVjNmRlYjI5Mjk4YTNjMWVmOGQyM2JkMzU3YWVhYzkyMzk5NjBiNThmNGIzODc3ZWM5N2FkNzM0ZDljMTU4MzBlYWY1MDM4MmJlMDQyNWNiZTdjZDRiMWI1ZWMyNmJiZmFkNTJkNzI1MTE1MzVhNmIyM2E4OTIzYjRhZGQxOTZkYWNmODE5ZTY0YWY2Yjg0YzA1YzNjMTc3OTdiMjVjZDc1MmI2MDQ5NTFhZmQyNzA5YjBiZjA4MmI5NDQ0NGQzNzkxZDY5OWM1ZjRkYTg1YzBhZDE5ZGQiLCJmaW5hbE5QIjoiNjlmN2Y1MTVhNTkxZDc5YzhiZDhiNDJjNmM0OGVkMjViOWM2YzZkYWNmYTdhYzlhYmYxODZiYzI0MWQyMmJlZiIsImNoZWNrc3VtIjoiMzQyZmY4MzdmYzk5MDY2ZjdiNzAwNGFkODFlZTg0YjFlMjlhOWU5YjE2ZDkzNmJmN2MyM2Y3Mzg0MzQzOTVjNCJ9LHsicHJvdG9jb2wiOiJzMmtfZm8iLCJuYW1lIjoiY29udHJvbCIsImFkc2lkIjoiUHVibGljLUZpeHR1cmVcbklkZW50aWZpZXIiLCJpbml0aWFsU1BEIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTJkMzM1NGEwZmRlMGVkYWE3YmYzZmYzYzg3ZmJjYjZjYTU0ODNkNTVlZmQ1M2RhOTZhNjc5MTEwYWMwOWE2MGQwNGMyOTQ0ZDBlNGIxMTQxOTkwMDViMjVlNGI2ZDA1MDZiZDBhMzBmZTZjNDc1MDU0NzlhMjIwNzIyMmMyNTA3NTZiZjI3MDU3ZmI2ZTFiYzlkZDE0ZGJmZjliYTkyNTVkYmNjMTg2MThmZDRmN2JkMjEzYjYwOTY5ZTFkNWFkNDc4NjFjYjMxZWEyYTk0ZWYzNjhmODc5MmYzMGNlMDlkNDYxMTM1ZDUxOGNkMTk4MTdlMTQzZTBiZTFlNWY4NmMwMzc3Mzc4NjNkYzg4OWVjOTMzM2U4MTczMTI4N2RhNmY2ODFjN2Q0ZGFmZDA0Mzc1NmVlMjA0YzMxYTFmOWFmOGU3NWI1YmIyNzI4MWM4Y2MwNjFkOWVlOWE3Y2ViZDE0MmI0MmU3YWU1ZGIyNGJiZWZiMDUxNTIxZGVhZmJlODJlNDIxM2Q2ZjFkMTNlZjlhYzk1YzljNjlkZjFjMGMwYmY1MTQ2ODZkMzBmMThhNzY3ODBjN2FhNDdjMmExMzA0NmNkM2Y5ZjAzZjAxYzAzMzc3NmRiMjFjZjExMjEzOGFhZDJhM2FkNDUwOTk5NWI0YzcxNDA3OTIzNDBjNWY3NjllMTYxYzFjNWVhMDhiMjg4ZjM5ZGU2Mjc1YTA0ZWIzYTBlODY4YmEyNzJlY2RlYWVkMGIzOTU0YjU0ZGYxZWUxMzFlNjUyZjhkMjk1NmFkZGMzMDlhOTVkYWE1YWZiOGUzYjczNzFhZWQ3MmY2MjI5ODcxOGRhMDc3MWZiMTE2IiwiaW5pdGlhbE5QIjoiMDZkMjc1MDQ1YzFkNzMzZDIyM2U0MmJjYmUwNDE2NWIzZWRiYTkxMTMxOTZiMzEyNmIzMzA0NjhmODEzMDg0ZCIsImZpbmFsU1BEIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTJkMzM1NGEwZmRlMGVkYWE3YmYzZmYzYzg3ZmJjYjZjYTU0ODNkNTVlZmQ1M2RhOTZhNjc5MTEwYWMwOWE2MGQwNGMyOTQ0ZDBlNGIxMTQxOTkwMDViMjVlNGI2ZDA1MDZiZDBhMzBmZTZjNDc1MDU0NzlhMjIwNzIyMmMyNTA3NTZiZjI3MDU3ZmI2ZTFiYzlkZDE0ZGJmZjliYTkyNTVkYmNjMTg2MThmZDRmN2JkMjEzYjYwOTY5ZTFkNWFkNDc4NjFjYjMxZWEyYTk0ZWYzNjhmODc5MmYzMGNlMDlkNDYxMTM1ZDUxOGNkMTk4MTdlMTQzZTBiZTFlNWY4NmMwMzc3Mzc4NjNkYzg4OWVjOTMzM2U4MTczMTI4N2RhNmY2ODFjN2Q0ZGFmZDA0Mzc1NmVlMjA0YzMxYTFmOWFmOGU3NWI1YmIyNzI4MWM4Y2MwNjFkOWVlOWE3Y2ViZDE0MmI0MmU3YWU1ZGIyNGJiZWZiMDUxNTIxZGVhZmJlODJlNDIxM2Q2ZjFkMTNlZjlhYzk1YzljNjlkZjFjMGMwYmEwZTI3ZmYyOGE5YjAzMzJhYjNkMzY0YjRmZWI3NTA1Y2Y1ODYyOGFkMjU3ZTk4ZTljMTVjYzYyYjM1OGU5NzAxZjI4MDU5ZjFmNTcxY2YxNTgzYjJiMTBlMmVmYmZkNCIsImZpbmFsTlAiOiJkYTIwMTY4OWMzMWRhYWEyZGI5YTY4NmRjMTE0NDFjYTc2NGM4YTQ5OThiMmQ0NTRjOTk5ZmVmNDBjZGE4NDZiIiwiY2hlY2tzdW0iOiI2NTczZTFkMjI5YTMwN2Q1ODU4MmYxOTIxMGE1MmJmOTM1Yzg2ZDY2OWZiY2QyZjcwOWFmY2VkOGZkMzVhYzQ4In0seyJwcm90b2NvbCI6InMya19mbyIsIm5hbWUiOiJjMSIsImFkc2lkIjoiUHVibGljLUZpeHR1cmVcdTAwODVJZGVudGlmaWVyIiwiaW5pdGlhbFNQRCI6ImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZDMzNTRhMGZkZTBlZGFhN2JmM2ZmM2M4N2ZiY2I2Y2E3ZTg1NjU5ZmNkZWM4ZDRjMWM5MTVmY2JjNjZhNGQxZGNkZWFmZDFmMTliNDQyOGIwNTU3NTA5NzkzZmFjMGZmMzYwZWEzODkzNmY2ZTgxYWZkZmFjZWE1ZmIwNmNjNDhjZjYyNjA5OWExZTY0MDdmNTE3MTRhMTNiM2VjNzQ5Njg1Y2IyYWVkZDUzZThhYzU5OTBkODkyNjkyYzQ5ZTQ2MWNmZDBlYjE5MmQ1NzJjYTQ5N2YwMTY3ZjAyZWYyMTgzYzNkMTQ0ODQ0MWE4NzQwNWUwMGI0ZWZlNGE4Zjg0ZWU0YWE4MWFjYzU4YTg5N2RlZTg1ZGE5MGVmNTI5MjNiNTQ1YmNjMzBlZmQwZjNlMTBiOGY0YTA3MGIwY2ZjNjdhNThiNGYwZmZmMDQ1YzViMDM1ZmVjODEwNTJmMjUyMTVhYTA0M2Y3ZTBlNWRjNWE4MDQwZjRmNDQxMTY5NzNkMTA2MjNjZjBmNDljNDczMGE5ZTU3MzZhNWY2NDZkODVmZGUxNGU4Zjk1MmEzMTgwYWI2MWQzYWNlMDQ4Mzc3M2Y2OThhMTQyZDNjMDBkZjg5ZmI5YmEzMjRlZTk3NTA0YmYzYTI3M2I5MmY0ZmRiMTg5MzBhODBiMjk5M2Y0OWEzOGU4YzYxZjliODkzNWMxZjI1MzRiZDQxYzM0MGUyMDcwYTQ1NDFiNTdlYjk3OTI4NjUxY2YyOGMwZWQwMmY4YzljNzM4N2RiOGExODZlNmI3Mjc1ODU0ZmI0YjQ5YWE3MTdmOTAxYThkMGQzODIwYmEzM2MzOWNiOGM2YWE4NSIsImluaXRpYWxOUCI6ImZhZjlmOGMxYTg5OTU5NGI1M2FhZjQyODY1MjVkM2FiYjNhMDhjZjg3MTg3YzUxYjBiNDM1NGU1NmU4M2IyNzEiLCJmaW5hbFNQRCI6ImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZDMzNTRhMGZkZTBlZGFhN2JmM2ZmM2M4N2ZiY2I2Y2E3ZTg1NjU5ZmNkZWM4ZDRjMWM5MTVmY2JjNjZhNGQxZGNkZWFmZDFmMTliNDQyOGIwNTU3NTA5NzkzZmFjMGZmMzYwZWEzODkzNmY2ZTgxYWZkZmFjZWE1ZmIwNmNjNDhjZjYyNjA5OWExZTY0MDdmNTE3MTRhMTNiM2VjNzQ5Njg1Y2IyYWVkZDUzZThhYzU5OTBkODkyNjkyYzQ5ZTQ2MWNmZDBlYjE5MmQ1NzJjYTQ5N2YwMTY3ZjAyZWYyMTgzYzNkMTQ0ODQ0MWE4NzQwNWUwMGI0ZWZlNGE4Zjg0ZWU0YWE4MWFjYzU4YTg5N2RlZTg1ZGE5MGVmNTI5MjNiNTQ1YmNjMzBlZmQwZjNlMTBiOGY0YTA3MGIwY2ZjNjdhNThiNGYwZmZmMDQ1YzViMDM1ZmVjODEwNTJmMjUyMTVhYTA0M2Y3ZTBlNWRjNWE4MDQwZjRmNDQxMTY5NzNkMTA2MjNjZjBmNDljNDczMGE5ZTU3MzZhNWY2NDZkODU2MTZmM2JlNDMyZWI1ZjkzOTFhNGFmNTM2OTk5ODRlNjg3NzJjYzA3N2IyYzgzOGUwOGY0YjdhOTdjN2EzOGVkN2Y0NGZiYjFiYjlkYjJiODA4YmIwNmM0ZjBmZmUwMTAiLCJmaW5hbE5QIjoiZmE0ZTJjM2QzZjdiNGIyOTgzZTBkZGY3MTk5YTgxMGEwYTk0YmQxODFlMGRiOGFiMGQ2ZGJlNTU4YWM0Nzc1MyIsImNoZWNrc3VtIjoiOTJlNTYyN2U3NGM2ODJlMGVhNjRhOWQ4YjJmM2VmZWQ3NjRmM2I2MTk3ODc3NWQ0MzAyZTU3OGI2NDA3YWJiMiJ9LHsicHJvdG9jb2wiOiJzMmtfZm8iLCJuYW1lIjoib3ZlcnNpemVkIiwiYWRzaWQiOiJQdWJsaWMtRml4dHVyZS5BRFMtSUQtQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1BYjktQWI5LUFiOS1YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFgiLCJpbml0aWFsU1BEIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTJkMzM1NGEwZmRlMGVkYWE3YmYzZmYzYzg3ZmJjYjZjYWZkMmM5NjVkMzQ3OTIyOWQ2ZGNiYmRkOTM4YzQzMmQyM2I3ZTc0OGM1ZmJiNmNjMDQxODJiOWY0ZjlhODdhZmY1NjUyNzUyMGY3ZmVjY2NhNjhmNzJhMzc0OTU0M2U0ZmFhMTA1M2RjODQ1YjM3M2QzMmJhZTliNjdlZjlhNGQxNGFlYzBmODg0ZmFiOTk4MzUyYjQxMDk5YzlhMmQ5YmQwNDNjODdkNzk5ZjYxMDU4N2QxMWU4YTg0MzM1YThiM2RkMmIxMzQ3YmUwMWJjZTZlY2NmMjk3OTU0ZDBlMmQ2YTk5ODJkMGZkNzUyZmI3YjYwOGQ4MDZkYWNmMzk2ZjJhMzNmYmQ2NjgxMDA4YTFlYTg4NGZjYzE3MTRhYzRhODU2ZTFmZDg1ZjE2MTU1NzBkNmMzNmFhMjgwNzJiN2ZmMGFkMmMxYzk4MGFjZTQwNWYzZjVjMGU5YTczNGZmZjc4OWQ3ZWExOTJiYjVlYmJmNzZkNWQ0MzM2YTg2ZWI4MGEyNDc1ZmQwMjBlYTQ3NTljM2Y5MDNkMTlhMzVkNzAzZDRkOGU2Nzc3MjIyZmYwYTE1YzUxM2FjZWYxNThiYzg1NTExOGRhNTE3OGZiYWNhMmY4ODhmMmYxYWZiZWFkYTZjMTZkOGEzZjJiM2I4NWRmMDBkNzdjNzg4MTFhMDIwMzVhOTIxMTdkZjg1MzE4M2M2YzFlZGQxMTM0Y2Q0YTBmZDNjMTgxNTRjYzJlNmRmZjMwYWYzMDcxY2IyZGRjMzNjZWVlNDZlMTA5MWZiZDZiMTM5NTgzOGRlMzJlZjM4NTdmYzRlMDMwZmVlMDlmNWE3MGRhNmI1NTFiZjAzZWRiMjk4ODFkZGY0NzFkOTI2ZmY3NWIxYzA1NDRlOWJlNThjOWM3M2YyZDcwNzVhODNhZDRiNmViMDgyM2FmZjZmY2Y4NTFkZWM0ZjlkODJiMjRhM2VkMDk3NjdhZmNkMmY1MjdkYTBlNWZmOWVjMGU5YTM1NTA2YWVlODIwMDMyYWU0MDM1MGQ5NmI4OTQxMjVjMjdmMTUwZjUzNGU4MTY5IiwiaW5pdGlhbE5QIjoiNGMyZTA1MDQ0NTVmZTI5MjNlOGZhNmZhZWVmMDA3MGMyMDc0NDBiZjE1Mzg3ZDI3ZDcwM2Q4OTFmOTM3MmYwYSIsImZpbmFsU1BEIjoiZTcyYWU1MTM5NDYxZjA4MGNiNWQ3MzEwNmU1ZDE1Mjk2NmZlZmNlMTU3OWJhNDExMjM1ZTlhODFhYjcxZWYxMjQ3ZjU5ZDI1OTMxZWYyZDQ1ZjhhYjUyZWUxMjQ3NThhMjEzNzU4MjIwOGRlNDJjZGRiZGEyMDY0YzQ0MjQ1NzIzNjdkOGJhOGRhZjNhMDc2OGIxMjNiNGY1MWZkNzI2NTVmNTIxYzEyYWYzNDUxY2U5MzA5MzM1Yjk1MTIyNTc0MmQ1ZTQyYjZiODc5ZDA4NGM1MDFmNjRiNDFjN2QyMzgyZjdkMjU2ODI2ZTcyZWVhZDNkOTU5ZmZkOGNkZTgyMWRjNzE5ZGU5YjFlOTM0N2E4NGJlYjQ1MzIxNjE4N2IzZDM3MWY4MDllOTE2Y2IyMGE2NzRkZjdkNGQ0ZDlmZmFhN2M3NGQwNDY3Mzg2ZDdhOGIwNzI4ZDlkMzIxODY2YTg2Y2UwNjZlNDk5MTJmMDBjZGU5NDcwNjQ3ODk2ZDZhYzZmMmVmMTE5MmIxMzk2OTA5MzZjYTAyNTAxNzZhZWU0YjNiNmYyMjcyMWE5Zjg4MDhmN2JkZThmM2VhMGI1MDhlNjRiYWJiODkxNzMyNzgwZmVlY2FjMjA5ZmJlODE1ZTdiMWRlYzFiNDBjNDExMTJjMjNjNmRiZGJlNDhhZTJkMzM1NGEwZmRlMGVkYWE3YmYzZmYzYzg3ZmJjYjZjYWZkMmM5NjVkMzQ3OTIyOWQ2ZGNiYmRkOTM4YzQzMmQyM2I3ZTc0OGM1ZmJiNmNjMDQxODJiOWY0ZjlhODdhZmY1NjUyNzUyMGY3ZmVjY2NhNjhmNzJhMzc0OTU0M2U0ZmFhMTA1M2RjODQ1YjM3M2QzMmJhZTliNjdlZjlhNGQxNGFlYzBmODg0ZmFiOTk4MzUyYjQxMDk5YzlhMmQ5YmQwNDNjODdkNzk5ZjYxMDU4N2QxMWU4YTg0MzM1YThiM2RkMmIxMzQ3YmUwMWJjZTZlY2NmMjk3OTU0ZDBlMmQ2YTk5ODJkMGZkNzUyZmI3YjYwOGQ4MDZkYWNmMzk2ZjJhMzNmYmQ2NjgxMDA4YTFlYTg4NGZjYzE3MTRhYzRhODU2ZTFmZDg1ZjE2MTU1NzBkNmMzNmFhMjgwNzJiN2ZmMGFkMmMxYzk4MGFjZTQwNWYzZjVjMGU5YTczNGZmZjc4OWQ3ZWExOTJiYjVlYmJmNzZkNWQ0MzM2YTg2ZWI4MGEyNDc1ZmQwMjBlYTQ3NTljM2Y5MDNkMTlhMzVkNzAzZDRkOGU2Nzc3MjIyZmYwYTE1YzUxM2FjZWYxNThiYzg1NTExOGRhNTE3OGZiYWNhMmY4ODhmMmYxYWZiZWFkYTZjMTZkOGEzZjJiM2I4NWRmMDBkNzdjNzg4MTFhMDIwMzVhOTIxMTdkZjg1MzE4M2M2YzFlZGQxMTM0Y2Q0YTBmZDNjMTgxNTRjYzJlNmRmZjMwYWYzMDcxY2IyZGRjMzg2MzhkYmY3NjRmODkyNTc0NTBjN2FiNmVhMmNhMmIxMmQxZGM4YTllZTViMTljYThiNmVjM2NkZTZjNzRiZDQ0NGI4YWZkOGQ0Y2JlMjZmMTE3YmNiMmJmNTg5N2JhZSIsImZpbmFsTlAiOiJiMTFiMGZjYjZhMzEzY2E1MjBlNzUzY2RkZmRhNTc1NTMzZjg5ZjQwMDJhMTQ3OWMwYzVkMTE2Y2Y1ZmYwZWRjIiwiY2hlY2tzdW0iOiI5ZTIwMzNmZjE5MzI2MDBjY2VkM2VmYWU4YTNiYTUxMmU3MWNmODc5N2E0ZDNkODg3MTY3YTAxYWZlY2M0MWRhIn1dfQo="
    }
    private enum Vectors {
        private struct File: Decodable { let appleDerived: [Vector] }
        static func first() throws -> Vector { try #require(all().first) }
        static func all() throws -> [Vector] { try JSONDecoder().decode(File.self, from: #require(Data(base64Encoded: base64))).appleDerived }
        // Generated from independently executed vectors/reference.py. All
        // passwords/tokens/keys are intentionally public fixtures, not accounts.
        static let base64 = "ew0KICAic2NoZW1hVmVyc2lvbiI6IDEsDQogICJwdWJsaWNGaXh0dXJlc09ubHkiOiB0cnVlLA0KICAicmZjNTA1NCI6IHsNCiAgICAic291cmNlIjogIlJGQzUwNTQgQXBwZW5kaXggQjsgcHVibGlzaGVkIFNIQTEvMTAyNCByZWZlcmVuY2Ugb25seSwgbm90IHByb2R1Y3Rpb24gQXBwbGUgcG9saWN5IiwNCiAgICAiY2hlY2tlZEZpZWxkcyI6IFsNCiAgICAgICJrIiwNCiAgICAgICJ4IiwNCiAgICAgICJ1IiwNCiAgICAgICJBIiwNCiAgICAgICJCIiwNCiAgICAgICJTIg0KICAgIF0sDQogICAgInBhc3NlZCI6IHRydWUNCiAgfSwNCiAgImFwcGxlRGVyaXZlZCI6IFsNCiAgICB7DQogICAgICAicHJvdG9jb2wiOiAiczJrIiwNCiAgICAgICJ1c2VybmFtZSI6ICJmaXh0dXJlQGV4YW1wbGUuaW52YWxpZCIsDQogICAgICAicGFzc3dvcmQiOiAicHVibGljLWZpeHR1cmUtcGFzc3dvcmQiLA0KICAgICAgInNhbHQiOiAiMDAwMTAyMDMwNDA1MDYwNzA4MDkwYTBiMGMwZDBlMGYiLA0KICAgICAgInByaXZhdGVBIjogIjAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjEwMTExMjEzMTQxNTE2MTcxODE5MWExYjFjMWQxZTFmMjAiLA0KICAgICAgInByaXZhdGVCIjogIjIxMjIyMzI0MjUyNjI3MjgyOTJhMmIyYzJkMmUyZjMwMzEzMjMzMzQzNTM2MzczODM5M2EzYjNjM2QzZTNmNDAiLA0KICAgICAgIml0ZXJhdGlvbnMiOiAxMDAwLA0KICAgICAgInBhc3N3b3JkS2V5IjogImIwNTFmMDJmYjAzOThmMmZiMjNkZWRkYjQ0M2JjOTEzMTdkMjFlZDc1MGViZTUxYTE2NzllYzE5NjAxYzQ5N2EiLA0KICAgICAgImdyb3VwTiI6ICJhYzZiZGI0MTMyNGE5YTliZjE2NmRlNWUxMzg5NTgyZmFmNzJiNjY1MTk4N2VlMDdmYzMxOTI5NDNkYjU2MDUwYTM3MzI5Y2JiNGEwOTllZDgxOTNlMDc1Nzc2N2ExM2RkNTIzMTJhYjRiMDMzMTBkY2Q3ZjQ4YTlkYTA0ZmQ1MGU4MDgzOTY5ZWRiNzY3YjBjZjYwOTUxNzlhMTYzYWIzNjYxYTA1ZmJkNWZhYWFlODI5MThhOTk2MmYwYjkzYjg1NWY5Nzk5M2VjOTc1ZWVhYTgwZDc0MGFkYmY0ZmY3NDczNTlkMDQxZDVjMzNlYTcxZDI4MWU0NDZiMTQ3NzNiY2E5N2I0M2EyM2ZiODAxNjc2YmQyMDdhNDM2YzY0ODFmMWQyYjkwNzg3MTc0NjFhNWI5ZDMyZTY4OGY4Nzc0ODU0NDUyM2I1MjRiMGQ1N2Q1ZWE3N2EyNzc1ZDJlY2ZhMDMyY2ZiZGJmNTJmYjM3ODYxNjAyNzkwMDRlNTdhZTZhZjg3NGU3MzAzY2U1MzI5OWNjYzA0MWM3YmMzMDhkODJhNTY5OGYzYThkMGMzODI3MWFlMzVmOGU5ZGJmYmI2OTRiNWM4MDNkODlmN2FlNDM1ZGUyMzZkNTI1ZjU0NzU5YjY1ZTM3MmZjZDY4ZWYyMGZhNzExMWY5ZTRhZmY3MyIsDQogICAgICAibiI6ICJhYzZiZGI0MTMyNGE5YTliZjE2NmRlNWUxMzg5NTgyZmFmNzJiNjY1MTk4N2VlMDdmYzMxOTI5NDNkYjU2MDUwYTM3MzI5Y2JiNGEwOTllZDgxOTNlMDc1Nzc2N2ExM2RkNTIzMTJhYjRiMDMzMTBkY2Q3ZjQ4YTlkYTA0ZmQ1MGU4MDgzOTY5ZWRiNzY3YjBjZjYwOTUxNzlhMTYzYWIzNjYxYTA1ZmJkNWZhYWFlODI5MThhOTk2MmYwYjkzYjg1NWY5Nzk5M2VjOTc1ZWVhYTgwZDc0MGFkYmY0ZmY3NDczNTlkMDQxZDVjMzNlYTcxZDI4MWU0NDZiMTQ3NzNiY2E5N2I0M2EyM2ZiODAxNjc2YmQyMDdhNDM2YzY0ODFmMWQyYjkwNzg3MTc0NjFhNWI5ZDMyZTY4OGY4Nzc0ODU0NDUyM2I1MjRiMGQ1N2Q1ZWE3N2EyNzc1ZDJlY2ZhMDMyY2ZiZGJmNTJmYjM3ODYxNjAyNzkwMDRlNTdhZTZhZjg3NGU3MzAzY2U1MzI5OWNjYzA0MWM3YmMzMDhkODJhNTY5OGYzYThkMGMzODI3MWFlMzVmOGU5ZGJmYmI2OTRiNWM4MDNkODlmN2FlNDM1ZGUyMzZkNTI1ZjU0NzU5YjY1ZTM3MmZjZDY4ZWYyMGZhNzExMWY5ZTRhZmY3MyIsDQogICAgICAiayI6ICI1YjllOGVmMDU5YzZiMzJlYTU5ZmMxZDMyMmQzN2YwNGFhMzBiYWU1YWE5MDAzYjgzMjFlMjFkZGIwNGUzMDAiLA0KICAgICAgIngiOiAiYTM3M2E1OWNiMDkwZjBhZjBkNDcxNWIzYWM5YTllYzI5NTg0NGZkMmFkZmM0Yzk2ODg3ZGU4MjllZjkwYzdiOCIsDQogICAgICAidiI6ICI2MzQxOGM5MGFhNDM0ZTQ0NmY3ODAxYzA1NWM1YWI0NTE0YjkyYjVhYzBkYTc5MmMzZjI4OTMyNGJhMWQwNDMyZmMwMTNlYWUzNGRjNDg4NWU0ZjViZDFjYWVhZjljZmY3ODlhMTQxMTA2ZTIyMDljNGViMGZiYTJhMDQzZDMzODU3M2FmMTRhOTA0ZjI5MjIwMDY2OGJmYmRjMmYxNjM3Zjc4ZDA4NzYzODZkYjRiMGE2YzFkMWZlN2UzYTlkN2M3NDM0YTBkYTM1ZGMyZDBjZGQ0NThhNjhlNWZlOGI1YzMyMmJlYWQ1NTJjNmVmNDM4MzM4N2U4MTE5ZTk0YmIwOWI0YWZjZDlmNDIwMTg0MTNlMzM2NTUxNTI1YWI3OTkzMzQxNzhkNzkwNDlhNTg3MzlhYjJhYmQ4YmNkZDMwZWUyZmQ1MjgyZjdlZTIwYjNkMjYwNWY5YjQyOWQ3OGY0MWYyNThmNDc4YTZlY2RiYTc5ZDA0ZTk2ZTJiMThlZWRmNTgwM2FiYTk4NzhmODgwMDliNjgwODAyNzU3NGU4M2NmZTM4OGZkMmQ0MDQ0NWZmMTM1ZjY4OWNhNTIzYWZkMDk3YThmMGU1ZTg3Mjc1YWFhZDQ1MTE5Njc1NTUzMGY0ZmQ5MTkxYjBmNjNiNGI5YWMyZGZiYjEzNWQxY2JmMyIsDQogICAgICAiQSI6ICI2MzBhY2RmZjVkMzM0NDYyZDkyYTI5ZTBiN2ZhNmUyMDAyMGYzMzMzMjkyZjZkM2E2NDBmMWM3YTc2YWQ5ZDMxNzUzMWM1Nzk3OTk1MmU1NzM2Yzg4ZGIxMThkMDYwZGMwNTM5YTgxMmI5YjBhZjNiNDAwMjM4MGE5ZjI4YWU0YTdjNDVhODk2NTQyZGUwNWZiY2Y3NmE0ZTdlMDczOWI5YTU1ZDVkNmM3YWJhNGYxZTFiNTg3MjlhNzliYzA4NGQ1ZmY1MTNlYWVjMzNjZTk3OGY1YmFkODdlNTc5YjVhOTVmYzc3MzE5OGUyMjY5N2IyZWFkYWI5ZWI5NGY4NGNkY2YxZmU5NGZmMDlmODhkNGNhNDZlOTY4YmJhNDQzZmY3MTE2NzU3MWYxOWZlYjA1Mjg2OWJkMjhkN2RhYmY5NjNiN2ZlMzk5YTFmNzBlN2UwOGQwMGUxYTM3NzhlZDFkZGRjMzMyNWRkMDllMDVkMzFlNzc0ZDFmZDI5NWM0YWJmYmM2MTM0NDYyMzIwMDRkNjdjYjAzZDZhMDM0ZDJjZTZjYTBhNTQ0YTBmZjViNDM0YjRiNDI2N2ZhNmM2ZDcyYWNiYmRhMmVmYzFlZjFkMWZlMzZkMzUzODJiMDg5YWJlNTU2ODYyYWVjMzViMjlkM2QwY2RmMzU5YTljZmVkMyIsDQogICAgICAiQiI6ICI1ZjAxNmI2NmU1ZGFiNTQ4MDEzYTQ2MDdjMDJhYjE1NjlmNThkOTRhYTY3MGJkNjhiY2U5YmZkYjc4MDdjNDQ0ZGFiZmJjMTM4YzVlNWFiOWRlYzVkZjM4YTFjNWU1OTUyYjYwYzMyMDg3ZWU1MDhhNmE0YTE4YzQ5ZDdjNjM4NzQ2ZDcyZGE4OTQyMTA0NTJhMmE1NjYzNTk1MzBjMWRjMTM1Y2NiNGEzNWYxODBhNzQwZjA0MmUxMmZmOGFiYTQzNTU4ZDU2NzgxZGUzZWI3MWI2YjJkMWJkYTc3MjRkMmFjZTZlYTA5YTE0NDIwNmM5ZDU4NWU3Y2ZkNDg0OTg1OWNiOTk5MGRlYmFmNWVhY2E1ZjZkYTIyZTkyN2QxMDVhNTkzOGYxOGExZDc3OTMyNTNlNDZmNDJmMDIxMDkwMTZkNTg2Y2NkOGY5YzYyMDU2NGU3NzIzNjkxMDBmODQzZTM4YjlkMTQxMTZiOWIwY2U3YTYzN2ZjZDM1ZTAyNjFjNTkzNGEyNjYyOGY4NzdkYzhmMjM1NTc1NTI1YmE1NzRhYjhlMmUwNTUwYTlkNTdjNDY3MWM4OTRhZmQxYmI4ZmVlMjRkYjc4MGVhNDQ3OGJjM2M2MjE5NDFlNmQwYzYzY2MxMjVlNzQyNWM4ZmRkYzc2ZWNjYmQ0OTlmYWJkMiIsDQogICAgICAidSI6ICIyNjJlODc0MDNmODgxZjNjNGFkZjI0YTBiZWYxNzk5OTI0YmQ2NDViMzJjYjdhZWU4ZGY1ODQ1N2ZkNmZlOWQzIiwNCiAgICAgICJTIjogIjIwMzE4ZTg5YWVmYjEwNmZhMmQ2OGI0YTgyY2JkNmM4YTFhMWYyOWU1MWUzYTA0OWU0N2VkYjFmYjgzOGE5MjQ4OTFkNDI2MjEyZmY0YjY0NTU1ZmIxYzUwM2M0ZWE3ZDE0MTZkYjEzYjU1MmNlMTc0ZThkOWZiYjdlNzFiY2QxYzlhYTgwNDZmZWVlYTZhMDQ3NzkwNTNmNzA5M2I2MzRmZmRkMTM1NjM5ZDIyMDU1NTIyY2M2MzU0MDlhZDE4MDJlNDgxNDY5M2RiZjdmYjk1NzJlMWZmYzAxNzUxNzlmMjE3MjIxMWQyOWY2YTQyNzgxZjFiZGE2NWU2ZGY3NzJhOGQ5ZTcyYTdmMWFkNmFmYTgxOWVkZDAwNTIzZWI1MTFiMGRlZDM0ZmQ5ODJkMDJiNzljYTk5ODFiZGQ1NGRmNmRjYmJjNTBhZTAxZDVhZmYxMTZkYjYzN2Q4MGVkYzc4N2FiZjEwM2MzYWUxMjBkMWZmZTZjOGZmNmIzNTFlMTU4MTc5YjUxNTA5MThkYWZkZTFjNWJhZTc2NTk4NWRlNGRiODIwZjIxZmRkYWNlZDgyMjZhZGViNzIxNzY5ODRjNTU2MWNiNTU4ODJhMTE4OTFjZjE2MTI2ZTQ2M2ZiZTA2NzBhMjlkYmZhYmZjZDg5ZDU3MDBhZTk5M2U2YWZiIiwNCiAgICAgICJLIjogIjU3Y2Q2NGYxYzIzNTk0ZTM5NDFmNmU2YzQyMWZjNDU1NWI5YWVjNjg0NDNhZjZiNWIyMmNiNWYxZDZiNWVjYTciLA0KICAgICAgIk0xIjogImRkNzZkNTViNTA1NzIxZjQzZjljNmJiYWRiZmE0MWUwYTA1NWQzNzYzZDBhZmUzMGY0YWMyMjg0NzdmZGM3ZmQiLA0KICAgICAgIk0yIjogIjVlNzc3ZmQ0NzBmMWEyYTIzZjM1MzMwNGQ5Y2FhMDIwZTIxMzdjNmJkYzcyNGU1ZGIzY2NiYzhlNTEzNjVjOTUiLA0KICAgICAgInNwZCI6ICIxNmFjYWRiYjljYjhiYTUyNDUyNTY1OGQwNzY5ZDhjMmM0MDhjNmRkZTgwZjA2NzlmNTM1MjQzMjEzN2YwMDczZmUxZjUzYzI5MzM1M2UxZTU4OWRmOWZiYWNhZmQzMzFiMDg3ZDc0ODhmZWYyMjdjN2ZmYWIxMDBjYWRkMTk3MGMzYzJjN2ViY2MwYWQyNmQ3NDE0Mjk5N2I4ZWRiMWFhZmJjOTg5OGQwYjE5MGFiNDA4ZTRjYjExYTI2NDkzZmI4MGRlYjU0ZWMxMjlmOTRlNjBkY2U2ZmUyMTY0N2VkZmMwYzlhOWZjODI2NDRlNGQzNjBmMzQ4YTQ4N2Y5ZjgyYTM0NjExZTJlZDhkNTdhNWUzMjMyNjM0MmE1Njc1ZTAzODMxODI1ZjY3ZWQ1ODkzNWZjNzMxMzQ5YzMxYjI4MGZmZGIzNjkyNjJjNmRjMjdkYzc5MTZkYjkzMmI1MTkxYjFjNDNhMTZjMWUwZjI4NzI1MWI3YjU2MTRhMzRkMTc2YmViYWEzMzM1ZjkzYzExOTRmYjJkMDA4ODlkMzljMzg4NTgyYjQ3NDZjZGQwOGJlMTQyZGM0NWEyZDc1MTViMWVlZDg4MDk4OWNhZTk0ODM4YWU1NjJiNzk3MWM3OGI4MzhlYmRmMTBmYjAxYjVlNTM5YzEwZjI2NGJmODg1MmQzZTVkNmM4MGI0ZDkyNzBmOGYzZDAwZmMwZThjMTk5NGM0ODU3MDkwZGNiMjQwMTM4NDI1NWQ4MzRhZGUyMTcwZDhhNmVjZjExZGY3ZWNlOGM4NjFjMWM4MmFkMDc5ZmI0NDdiNGY5MDBlNmE3ZTIwMmE5NDg5NzM5Y2UyY2Y2MjVmNzRkMzVmMDVjMmYxYzJmOTk2NTc1YTNjOGFiNjVlNjA0YjEzYjY5OWIzOTEyMjM3N2QxMmQ2Mjc1MGZkM2E0OTYzNmE3MjIxZThjZDczZGZkODBjMDc1NjIzZGY5NmM5NTg5MWM3ZDdjN2I1Y2RkMzJhYTZlNTE3MzM1M2Y4ZjExODkyYjQ0ZWU2NmE3YTVhZjcxNzNiZDNhZjFlM2QzYTZhMjI5NzMzY2UwNDk3NTliYmUyZTA0NTA5MDIyOTdhOTBmOTY3NjBhZjRmMmU4YzU4ZjM3ODQ0MzNkMzUyMWYzOWRmMDE1N2Q4MzcxYmQ2NmMyZjA5OWE5NDk5YSIsDQogICAgICAic2MiOiAiNzA3NTYyNmM2OTYzMmQ3MzYzIiwNCiAgICAgICJucCI6ICIwMjI2NTFmNjk4NWRiMmIzNmJkZjdiOGNhZDRkOWZmZDdlMWNiMDkyZTFiYTNmNTllMmM5MTBlN2U2MDA4ZWYzIiwNCiAgICAgICJzayI6ICIwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjEwMTExMjEzMTQxNTE2MTcxODE5MWExYjFjMWQxZTFmIiwNCiAgICAgICJjb29raWUiOiAiNzA3NTYyNmM2OTYzMmQ2ZjcwNjE3MTc1NjUyZDYzNmY2ZjZiNjk2NSIsDQogICAgICAiZHNpZCI6ICIxMjM0NTY3ODkiLA0KICAgICAgImlkbXMiOiAicHVibGljLWZpeHR1cmUtaWRtcyIsDQogICAgICAiY2hlY2tzdW0iOiAiYzZhMzEzZDY3ZjhkZjdmZWE2NTk4NWE5NTE0MWUyM2YxZjU1ZjNhZDE2ODdhOGY3ZTkyYjgxYzVlNjAxNmMwNiIsDQogICAgICAiZW5jcnlwdGVkVG9rZW4iOiAiNTg1OTVhMDAwMTAyMDMwNDA1MDYwNzA4MDkwYTBiMGMwZDBlMGY1YjUzZDgxYjU1YzQzYzRkZWY4Y2IyNDYzYjk5MGU4MjdhODM0OTgxMDJlM2IwMmMyMDU3MjNiMmIzZGI5OTllMmU1MmIxZDY0MjdlZGFmMmMzNmQ3OTE1YjU2ZmI1Mzc3NzAwMjYzM2ZmNjA2MGQxZjVmZmVhNTJhMjBiNjBhYjNjYzQzYWQ0YjAwOGUyYjAxMDE1ZjQ3MjUyMmYxOWZkODhkNzI2OWRjMDBkNjBhZGMzMjAwMGRkZjVkNjdkNjAyOGRmZjc2MzNmNzk2YjYyNWY5NmNjYjQzYjQyMWJkMWEwMDFhMWYzNDcwMTI2MGZlNzZmY2U3NTQ3M2IzYjhkZDU1ZjI5YzZlZjMxYWRiZWQ5ZDYyNWZjY2IwZjk0YzlmMzAyMTFkZGI4NmJjZWY4ODBkOTY1OWIwNjc5ZmQ0ZTAwYWNlYjdjMjBkYmM4NmY5ODAwM2QzMjIwNTRhNDlkYTNkZGJhMzJjZTg3ZDM1YjM5N2Y1ZWE1ZjY1NjViYTEwZjg3MTVhODUzYzdlNmZhNGE1ZTEzODljNGNlYmRhM2M0ZjRjOWFmMjVkNzU1YWIyNmIwZDdlYjgzMGEyNTlmYjQzNjQxMTNhZjIwYTM2NjRlYjc3MDQzOGM5MjRlODM2YzI1YmEyYWNiNmYyYzQyZjQ4MmEzOTVlODU1OWU3ODBmYjk1OTIzODJjYTc2ZDNkYTY1OWIwNWZlN2RjOTM1MjdhYTRkODlmNzc0YTZlNjlhZGZiYTBlNDZjYWQxMjI1Y2Y2MDJhMDY2NWQ0ODZhYzFkN2Y0OGI4ZWVlMGY0MjRlM2E0ZDc0NTM4NjY5MDkwZjIyYWFmODNiY2ZjNTY0NmE2ODkyYTdkMjVkZjc2YjM3MGM2MGE5MDY3MmY1YmFlZDczMzU0N2NiZTQ0ZTI5ZGMyNTBhMTFhZjAwNTdmZTYzMzQyNDdhMDcxZjdmOTE0NTUwZmIwZWZhOWU3N2E2NWFhZTZmNDJlNWE2ZTBkZjMyOWJlYTAyZjYyMWYyMDAwYzY5YmI2MGJhZTJjMTVmMmE5ODMyMzMxMzY2ZmRlYTRjY2UyZTIwMzZkYTVjM2NkMGJjMWMwOTBjY2Y5ZiIsDQogICAgICAidG9rZW4iOiAicHVibGljLWZpeHR1cmUteGNvZGUtdG9rZW4iLA0KICAgICAgImV4cGlyeU1pbGxpc2Vjb25kcyI6IDE3OTI1NDQ0MDAwMDANCiAgICB9LA0KICAgIHsNCiAgICAgICJwcm90b2NvbCI6ICJzMmtfZm8iLA0KICAgICAgInVzZXJuYW1lIjogImZpeHR1cmVAZXhhbXBsZS5pbnZhbGlkIiwNCiAgICAgICJwYXNzd29yZCI6ICJwdWJsaWMtZml4dHVyZS1wYXNzd29yZCIsDQogICAgICAic2FsdCI6ICIwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZiIsDQogICAgICAicHJpdmF0ZUEiOiAiMDEwMjAzMDQwNTA2MDcwODA5MGEwYjBjMGQwZTBmMTAxMTEyMTMxNDE1MTYxNzE4MTkxYTFiMWMxZDFlMWYyMCIsDQogICAgICAicHJpdmF0ZUIiOiAiMjEyMjIzMjQyNTI2MjcyODI5MmEyYjJjMmQyZTJmMzAzMTMyMzMzNDM1MzYzNzM4MzkzYTNiM2MzZDNlM2Y0MCIsDQogICAgICAiaXRlcmF0aW9ucyI6IDEwMDAsDQogICAgICAicGFzc3dvcmRLZXkiOiAiOTAzNTkyNjk3YmUwMzcwYTlmZmY2MDNkYzg1ZDM0NTVmMjI0NWMxOWJkYTY0NTgzM2RhMjkxNDAyZDdmMmVhNyIsDQogICAgICAiZ3JvdXBOIjogImFjNmJkYjQxMzI0YTlhOWJmMTY2ZGU1ZTEzODk1ODJmYWY3MmI2NjUxOTg3ZWUwN2ZjMzE5Mjk0M2RiNTYwNTBhMzczMjljYmI0YTA5OWVkODE5M2UwNzU3NzY3YTEzZGQ1MjMxMmFiNGIwMzMxMGRjZDdmNDhhOWRhMDRmZDUwZTgwODM5NjllZGI3NjdiMGNmNjA5NTE3OWExNjNhYjM2NjFhMDVmYmQ1ZmFhYWU4MjkxOGE5OTYyZjBiOTNiODU1Zjk3OTkzZWM5NzVlZWFhODBkNzQwYWRiZjRmZjc0NzM1OWQwNDFkNWMzM2VhNzFkMjgxZTQ0NmIxNDc3M2JjYTk3YjQzYTIzZmI4MDE2NzZiZDIwN2E0MzZjNjQ4MWYxZDJiOTA3ODcxNzQ2MWE1YjlkMzJlNjg4Zjg3NzQ4NTQ0NTIzYjUyNGIwZDU3ZDVlYTc3YTI3NzVkMmVjZmEwMzJjZmJkYmY1MmZiMzc4NjE2MDI3OTAwNGU1N2FlNmFmODc0ZTczMDNjZTUzMjk5Y2NjMDQxYzdiYzMwOGQ4MmE1Njk4ZjNhOGQwYzM4MjcxYWUzNWY4ZTlkYmZiYjY5NGI1YzgwM2Q4OWY3YWU0MzVkZTIzNmQ1MjVmNTQ3NTliNjVlMzcyZmNkNjhlZjIwZmE3MTExZjllNGFmZjczIiwNCiAgICAgICJuIjogImFjNmJkYjQxMzI0YTlhOWJmMTY2ZGU1ZTEzODk1ODJmYWY3MmI2NjUxOTg3ZWUwN2ZjMzE5Mjk0M2RiNTYwNTBhMzczMjljYmI0YTA5OWVkODE5M2UwNzU3NzY3YTEzZGQ1MjMxMmFiNGIwMzMxMGRjZDdmNDhhOWRhMDRmZDUwZTgwODM5NjllZGI3NjdiMGNmNjA5NTE3OWExNjNhYjM2NjFhMDVmYmQ1ZmFhYWU4MjkxOGE5OTYyZjBiOTNiODU1Zjk3OTkzZWM5NzVlZWFhODBkNzQwYWRiZjRmZjc0NzM1OWQwNDFkNWMzM2VhNzFkMjgxZTQ0NmIxNDc3M2JjYTk3YjQzYTIzZmI4MDE2NzZiZDIwN2E0MzZjNjQ4MWYxZDJiOTA3ODcxNzQ2MWE1YjlkMzJlNjg4Zjg3NzQ4NTQ0NTIzYjUyNGIwZDU3ZDVlYTc3YTI3NzVkMmVjZmEwMzJjZmJkYmY1MmZiMzc4NjE2MDI3OTAwNGU1N2FlNmFmODc0ZTczMDNjZTUzMjk5Y2NjMDQxYzdiYzMwOGQ4MmE1Njk4ZjNhOGQwYzM4MjcxYWUzNWY4ZTlkYmZiYjY5NGI1YzgwM2Q4OWY3YWU0MzVkZTIzNmQ1MjVmNTQ3NTliNjVlMzcyZmNkNjhlZjIwZmE3MTExZjllNGFmZjczIiwNCiAgICAgICJrIjogIjViOWU4ZWYwNTljNmIzMmVhNTlmYzFkMzIyZDM3ZjA0YWEzMGJhZTVhYTkwMDNiODMyMWUyMWRkYjA0ZTMwMCIsDQogICAgICAieCI6ICIyYzk1MWI1NWI4ZjJhMzdiNzFhN2NiZmY3NGJkMmFjODBjOTcyZjM2MTc5YWJkYTdlNjliOTRjMmM0NDkxNWQ4IiwNCiAgICAgICJ2IjogIjI1YWI2ODlkODgyNWY2NjI5OGJmN2RmYjRjYjc3NGMxZTU4ZDk1ODBmMmRjNTdmODMyZTliOGM2NDZhMmZhY2Q0Y2IyMmE1ZGQwZWI3ODMwZDliZjdhMWJjMGIxNThkYTEwNWYzY2E5ZGI5OTc0ODFiMjZlOGViZmMwMDk0NWU0OThkZGQ0ZGI3MDE2MTA0ZThhOTU3OTY2MzNkOGUwMDQyNDYyNGJhOTMyYzQ3ZGNiNjAxYTYyZGYzY2I1Mjk0Y2IyZTA0ZTVmNTQ4ZGQ2ZDkyOWU3ZDk5Yzc3M2ZkNWU3NjFmZTNlOGE3MGNhMGYyOTA4ZjM0ZDIzOTgzOWJlYTg3YWFhYThlMGVhNGQ4YzUyMjAyYzcyZGRiMGVjODg2OGVmOGZhMGRhYzMzYjc3YWI2OWIwOTA2MThhNTY3N2U1NGYzNDI0MmU5MGY4NDM5ZmI4YmU3MmFmYjUyYzI5YWY0OTYwN2RiMjBjZWE4YTcxYzgxZjIwZjIwYTBlNTE2YWQwMDZjYmY4MTg0YjAzNGRmZDdiM2I1MGE4ODc1MTJiNmZiNDk4OGRkOGRkMDY1NzI2ODEzZTRiMzlhNTYzYzAxYjhhNTU3N2QzOTg4NjNhNzlmNDE3NjExNmVkMDRiYjc2YmY1NmU3MGViZjA1MTNlNTc2ZTkyMjg0NDU5YmYyIiwNCiAgICAgICJBIjogIjYzMGFjZGZmNWQzMzQ0NjJkOTJhMjllMGI3ZmE2ZTIwMDIwZjMzMzMyOTJmNmQzYTY0MGYxYzdhNzZhZDlkMzE3NTMxYzU3OTc5OTUyZTU3MzZjODhkYjExOGQwNjBkYzA1MzlhODEyYjliMGFmM2I0MDAyMzgwYTlmMjhhZTRhN2M0NWE4OTY1NDJkZTA1ZmJjZjc2YTRlN2UwNzM5YjlhNTVkNWQ2YzdhYmE0ZjFlMWI1ODcyOWE3OWJjMDg0ZDVmZjUxM2VhZWMzM2NlOTc4ZjViYWQ4N2U1NzliNWE5NWZjNzczMTk4ZTIyNjk3YjJlYWRhYjllYjk0Zjg0Y2RjZjFmZTk0ZmYwOWY4OGQ0Y2E0NmU5NjhiYmE0NDNmZjcxMTY3NTcxZjE5ZmViMDUyODY5YmQyOGQ3ZGFiZjk2M2I3ZmUzOTlhMWY3MGU3ZTA4ZDAwZTFhMzc3OGVkMWRkZGMzMzI1ZGQwOWUwNWQzMWU3NzRkMWZkMjk1YzRhYmZiYzYxMzQ0NjIzMjAwNGQ2N2NiMDNkNmEwMzRkMmNlNmNhMGE1NDRhMGZmNWI0MzRiNGI0MjY3ZmE2YzZkNzJhY2JiZGEyZWZjMWVmMWQxZmUzNmQzNTM4MmIwODlhYmU1NTY4NjJhZWMzNWIyOWQzZDBjZGYzNTlhOWNmZWQzIiwNCiAgICAgICJCIjogIjg3ZmY1ZWIyOWE4NDFiYjU3Mzc4Y2Q5ZDk0MGJjNGE5ZDYyYzIyN2QzNWY5ZGU4YTVlYTk0ZWNhNzhmN2E1Y2YwZjAzMTZmOWY1NjE1ZmE3NDU5ZTA0MDg2ZWQ2YzlhNTgxOGQzYmEwOWYzMzgzZGNmM2QzMzE1MDRhNWIwMTJmOWJhYWYxOGIzOWUyOTcyZmIzMGY0NTI4OTZhMzk0Y2YyMTZlYmMwNWZlNTdiODRkYzM0YTIyNTliNzIyNDdkZDgwMDZiNjFiYTgwMzNkMDBmNzMwMzJjMzVmZGE0MzBiYWZmYTk3YTMzNWUzMzZjN2Q4MzNiOTNlYTJiMjVjOTIzM2I5NjBkNGY2ZmRkYjc2OTg2OWFjODlmZjIwN2Q0YTg1MzYwMTFiMjVhMjgzYzljYTg1OTQzMzEzMjk4YzNjMjU4MGJkYzgyOTYxMjU3NzE4MGI1ZWIyNWExOWM4ZTg0ZTc5MTg3YjY5ZWE0NDVlZWY4Y2FlNDQ0ZWEyNzFlN2I2MmNkMjVmMmExYTY0NDZkZDVkYzY5MDBhNzk5OTcwNDU5ZTAzMjdmMjI1NWE0MzgzOWZlZjc1OWI4MjMwY2UyMmJjY2JjODAzMTNkZWMwN2IyMzY0MjIyODY2NTA3ZDU2ZTg2YTlkNzc1ZDQ5ZjhiYjg2MGIyNzYzMGY0MDBjIiwNCiAgICAgICJ1IjogImY2MzA2Mzg0YzJmMDYwYjI2MWQzNTU3NGZlNzY5NjI4N2JjMTA5MDhmODlmMDJjYTAzMGUxNTc2NzJlN2RkN2QiLA0KICAgICAgIlMiOiAiNjY0NTQ2MTdjMTNhM2QxZDg0Mzk1ZTdjMDk4ZjZmZmZhNWJjOGI1YzE4OGQ3M2JmNDc5ZThiZWMyOTFlOTE2MzA1OTNjZTVkYmU2NTI1MDc4MmM0ZDA4YmFjMGE4MWE4NTc0ZWY1NjBkY2U4NzVlNmUyYWZiM2U4OGIyMTg0NjM0ZWMzNjllNzY5NTY1NWU2MDg4YWFiNDQwZTc5NTliMjMyODNmN2E5YmY3NmNlM2QxNDFhZTdiYjQ5MjA2MTU4MDc0ZGZiNGYxOWEwNjYyZmNlOGEzNDhmOTRhOTE1ZTVjZGQ1MzhkZmEyYzMyZjU0MzJlNTYzZjA2YzUxYWY4N2YyOWM5YTk1ZmMwOGU2ODhiZDE0YTE0OGI4YzRlNGM0MmVmY2ZkYzk3YjdmMDg0ZWYwNzljNzUzMGE1ZDA2N2I1Y2U3MzA3ZDgyNTVmNTVmYmU2MjMxN2UyM2Q0YmM1NDQzZjY1NDI4NTY4NGZlYzMzYTVlZGVkYWVhOTk3NTM0YWM4ZTM4MDhkMjY3ZjUyM2Q0NGRmNjYwNzNjNGUxNWI4MWYwZDE5OTMxNzA0MjZhMTIzZjY3NjkwYzFiMWIwY2FhN2JhM2ZiMWRkNWJhZmJhNmM3M2NmMjQ4OTBkNzdjYTVlZGU1YmUzNGY0MjRiZjc1NTk3MzgzNGM5MGQxODMiLA0KICAgICAgIksiOiAiNjVmNDRjZTg0ZjcxYzQ3MmJkNGRkYTJjNmE4MDhlMDY4ZjY1MTAyYWQ4ZjI1NWIwYTAxZmVmMGZiNjRmNGVmYyIsDQogICAgICAiTTEiOiAiMTU2NzY3MTJjYmI5NmQ0NTViZWNmM2NhMTc1NjU1NmIwMzkyMGNjZGM4MGFlNDAyNWNmM2YzNzcyMjQ4M2JlMiIsDQogICAgICAiTTIiOiAiMDhhY2U3YTA3MThjZjc0NjRmZmMyOGQ4OTQyNDQ1MTdlZjkwZTZhZjFjMDhiYmQyYjIzMTY3MmFiYjc1ODM2ZCIsDQogICAgICAic3BkIjogImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZjFmYzcwZTBhMDM2MDA4OTE4YjJjNDA3ODE1MGIwOTJiNDQ3NWY3NTE1YjI4MjkxNjYzMzkwNThiM2QyOWY0YWQ2NTQwZjUwNWViMTAxOGQ3ZGU1ZjIyYmQyYmZjODk4ZjMyNzU4NWFlYWUzYTFmMGNjZjFlZDFlOWNmOGE4Y2ZjNDQ2OTg4YzQ0YjA1YjFhNDVlOGQwNzI0NzIyYTk5ZTRlMGVjMmQ0NzBhN2RiNjc4YmE2ZWFiZjdkNzQ5YTM5YjI5ZWRjMWQ1NTJjZDlhM2RiMjYzZTM2NDc3MWIxNTQ4MTAwN2E2Zjc0NmRlY2Y1ZDI4NGIzMmVkYzc5YTBhNzU1NDRkYWI5ZTNlMDdkNGIzZjkyNzQ1ZjQ1ZWFlNTllZTczY2NjNTY5MmJlNjFmYTA0NmY0ZWE4MTkxMGY3NjNkMmM2ZGNjOTczYjUzYTRiYmFkNWNlMDA0MDM1MzA5YjJhZmNhYTY0MTA3OTNjZGZmMDdiZDk5ZWQxNzg5MTlmIiwNCiAgICAgICJzYyI6ICI3MDc1NjI2YzY5NjMyZDczNjMiLA0KICAgICAgIm5wIjogIjkzYjIxMDQ5NmQxNjY3ZWUyYWZhNmU5YWNiYTY5MDM0NDE5ZWNhZDc3NWNmNmVlMDczNmM3ZDdmNjRmODljMTciLA0KICAgICAgInNrIjogIjAwMDEwMjAzMDQwNTA2MDcwODA5MGEwYjBjMGQwZTBmMTAxMTEyMTMxNDE1MTYxNzE4MTkxYTFiMWMxZDFlMWYiLA0KICAgICAgImNvb2tpZSI6ICI3MDc1NjI2YzY5NjMyZDZmNzA2MTcxNzU2NTJkNjM2ZjZmNmI2OTY1IiwNCiAgICAgICJkc2lkIjogIjEyMzQ1Njc4OSIsDQogICAgICAiaWRtcyI6ICJwdWJsaWMtZml4dHVyZS1pZG1zIiwNCiAgICAgICJjaGVja3N1bSI6ICJjNmEzMTNkNjdmOGRmN2ZlYTY1OTg1YTk1MTQxZTIzZjFmNTVmM2FkMTY4N2E4ZjdlOTJiODFjNWU2MDE2YzA2IiwNCiAgICAgICJlbmNyeXB0ZWRUb2tlbiI6ICI1ODU5NWEwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjViNTNkODFiNTVjNDNjNGRlZjhjYjI0NjNiOTkwZTgyN2E4MzQ5ODEwMmUzYjAyYzIwNTcyM2IyYjNkYjk5OWUyZTUyYjFkNjQyN2VkYWYyYzM2ZDc5MTViNTZmYjUzNzc3MDAyNjMzZmY2MDYwZDFmNWZmZWE1MmEyMGI2MGFiM2NjNDNhZDRiMDA4ZTJiMDEwMTVmNDcyNTIyZjE5ZmQ4OGQ3MjY5ZGMwMGQ2MGFkYzMyMDAwZGRmNWQ2N2Q2MDI4ZGZmNzYzM2Y3OTZiNjI1Zjk2Y2NiNDNiNDIxYmQxYTAwMWExZjM0NzAxMjYwZmU3NmZjZTc1NDczYjNiOGRkNTVmMjljNmVmMzFhZGJlZDlkNjI1ZmNjYjBmOTRjOWYzMDIxMWRkYjg2YmNlZjg4MGQ5NjU5YjA2NzlmZDRlMDBhY2ViN2MyMGRiYzg2Zjk4MDAzZDMyMjA1NGE0OWRhM2RkYmEzMmNlODdkMzViMzk3ZjVlYTVmNjU2NWJhMTBmODcxNWE4NTNjN2U2ZmE0YTVlMTM4OWM0Y2ViZGEzYzRmNGM5YWYyNWQ3NTVhYjI2YjBkN2ViODMwYTI1OWZiNDM2NDExM2FmMjBhMzY2NGViNzcwNDM4YzkyNGU4MzZjMjViYTJhY2I2ZjJjNDJmNDgyYTM5NWU4NTU5ZTc4MGZiOTU5MjM4MmNhNzZkM2RhNjU5YjA1ZmU3ZGM5MzUyN2FhNGQ4OWY3NzRhNmU2OWFkZmJhMGU0NmNhZDEyMjVjZjYwMmEwNjY1ZDQ4NmFjMWQ3ZjQ4YjhlZWUwZjQyNGUzYTRkNzQ1Mzg2NjkwOTBmMjJhYWY4M2JjZmM1NjQ2YTY4OTJhN2QyNWRmNzZiMzcwYzYwYTkwNjcyZjViYWVkNzMzNTQ3Y2JlNDRlMjlkYzI1MGExMWFmMDA1N2ZlNjMzNDI0N2EwNzFmN2Y5MTQ1NTBmYjBlZmE5ZTc3YTY1YWFlNmY0MmU1YTZlMGRmMzI5YmVhMDJmNjIxZjIwMDBjNjliYjYwYmFlMmMxNWYyYTk4MzIzMzEzNjZmZGVhNGNjZTJlMjAzNmRhNWMzY2QwYmMxYzA5MGNjZjlmIiwNCiAgICAgICJ0b2tlbiI6ICJwdWJsaWMtZml4dHVyZS14Y29kZS10b2tlbiIsDQogICAgICAiZXhwaXJ5TWlsbGlzZWNvbmRzIjogMTc5MjU0NDQwMDAwMA0KICAgIH0NCiAgXSwNCiAgImluZGVwZW5kZW5jZSI6ICJQeXRob24gaGFzaGxpYiBidWlsdGluIHBvdyBwbHVzIGNyeXB0b2dyYXBoeTsgbm8gU3dpZnQgaW1wbGVtZW50YXRpb24gaW1wb3J0ZWQvZXhlY3V0ZWQiLA0KICAiY3J5cHRvZ3JhcGh5VmVyc2lvbiI6ICI0Ny4wLjAiLA0KICAiYWN0dWFsUHl0aG9uUmVmZXJlbmNlUnVucyI6IDQsDQogICJwcmV2aW91c0ZhaWx1cmVzUHJlc2VydmVkIjogdHJ1ZSwNCiAgInByZXZpb3VzUGFzc1JlZ2VuZXJhdGlvblJlYXNvbiI6ICJCaW5kIHRva2VuIGV4cGlyeSB0byB0aGUgZXhpc3Rpbmcgb3JpZ2luYWwgaWRlbnRpdHkgZml4dHVyZSBjbG9jayByYXRoZXIgdGhhbiB5ZWFyMjEwMCIsDQogICJTd2lmdFNES0V4ZWN1dGlvbnMiOiAwLA0KICAiQXBwbGVSZXF1ZXN0cyI6IDANCn0NCg=="
    }
}
