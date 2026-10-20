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
        try await Self.fixture { f in
            let auth = try await f.authentication()
            guard case .connected(let observation) = try await auth.signIn(appleID: f.vector.username, password: f.vector.password) else { Issue.record("Expected connected account"); return }
            #expect(observation.personalTeamMatched && !observation.appleSigningAuthorityEstablished && !observation.replacementAuthorized)
            #expect(await f.peer.paths() == ["init", "complete", "apptokens", "viewDeveloper.action", "listTeams.action"])
            let stored = try f.storage.load(namespace: f.namespace.id)
            #expect(stored?.contains(f.vector.token) == true)
            for secret in [f.vector.password, f.vector.idms, "owned-fresh-otp"] { #expect(stored?.contains(secret) == false) }
        }
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

    private enum Mode: Sendable { case normal, wrongTeam, secondary, holdInit, badM2, badNP, badTag, missingSerial, storageFailure }
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
        private var history: [String] = []
        enum Event: Sendable, Equatable { case initArrived, finished }
        private var event: Event?; private var waiters: [CheckedContinuation<Event, Never>] = []
        init(vector: Vector, team: String) { self.vector = vector; self.team = team }
        func set(_ mode: Mode) { self.mode = mode }
        func configure(_ scenario: SignedScenario) throws {
            signedVector = try #require(SignedVectors.all().first { $0.protocol == vector.protocol && $0.name == scenario.payload })
            signedScenario = scenario
        }
        func paths() -> [String] { history }
        func firstEvent() async -> Event { if let event { return event }; return await withCheckedContinuation { waiters.append($0) } }
        func finished() { observe(.finished) }
        private func observe(_ value: Event) {
            guard event == nil else { return }; event = value
            let values = waiters; waiters.removeAll(); values.forEach { $0.resume(returning: value) }
        }
        func handle(_ request: URLRequest) async throws -> Data {
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
                return try Self.plist(["Response": ["Status": status, "M2": mode == .badM2 ? Data(repeating: 0, count: 32) : vector.bytes(vector.M2),
                    "spd": vector.bytes(signed?.spd ?? vector.spd), "sc": vector.bytes(vector.sc),
                    "np": mode == .badNP ? Data(repeating: 0, count: 32) : vector.bytes(signed?.np ?? vector.np)]])
            case "apptokens":
                #expect(inner["checksum"] as? Data == (try vector.bytes(vector.checksum)))
                #expect(inner["u"] as? String == vector.dsid && inner["t"] as? String == vector.idms)
                var token = try vector.bytes(vector.encryptedToken); if mode == .badTag { token[token.count - 1] ^= 1 }
                return try Self.envelope(["et": token])
            default: throw FixtureFailure.invalid
            }
        }
        private static func envelope(_ value: [String: Any]) throws -> Data { var value = value; value["Status"] = ["ec": 0]; return try plist(["Response": value]) }
        private static func plist(_ value: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
        private static func body(_ request: URLRequest) throws -> [String: Any] {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); guard count > 0, data.count + count <= 65_536 else { throw FixtureFailure.invalid }; data.append(contentsOf: buffer.prefix(count)) }
            }
            return try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
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
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/x-xml-plist", "Content-Length": String(body.count)])!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
                } catch { client?.urlProtocol(self, didFailWithError: URLError(error is CancellationError ? .cancelled : .badServerResponse)) }
            }
            operationLock.lock(); let wasStopped = stopped; if !wasStopped { operation = started }; operationLock.unlock(); if wasStopped { started.cancel() }
        }
        override func stopLoading() { operationLock.lock(); stopped = true; let value = operation; operation = nil; operationLock.unlock(); value?.cancel() }
    }
    private final class Storage: @unchecked Sendable, SelfRenewalDeveloperSessionStorage {
        private let base = SelfRenewalDeveloperKeychainSessionStorage()
        private let lock = NSLock(); private var shouldFail = false
        var fail: Bool { get { lock.lock(); defer { lock.unlock() }; return shouldFail } set { lock.lock(); defer { lock.unlock() }; shouldFail = newValue } }
        func load(namespace: UUID) throws -> String? { try base.load(namespace: namespace) }
        func save(namespace: UUID, value: String) throws { guard !fail else { throw Client.Failure.storage }; try base.save(namespace: namespace, value: value) }
        func cleanup(_ namespace: UUID) throws { guard KeychainHelper.delete(account: namespace.uuidString, service: "com.yuedu.selfRenewal.developerSession.v1", synchronizable: false) else { throw Client.Failure.storage } }
    }
    private final class Fixture: @unchecked Sendable {
        let directory: URL; let material: SelfRenewalApplicationMaterialVerifier.Materials
        let date = Date(timeIntervalSince1970: 1_792_540_800)
        let vault: Vault; let namespace: Vault.Namespace; let vector: Vector; let peer: Peer; let anchors: [Data]
        let storage = Storage(); let transport = SelfRenewalDeveloperURLSessionTransport(protocolClasses: [PeerProtocol.self])
        init(directory: URL, material: SelfRenewalApplicationMaterialVerifier.Materials, vault: Vault, namespace: Vault.Namespace, vector: Vector, anchors: [Data]) {
            self.directory = directory; self.material = material; self.vault = vault; self.namespace = namespace; self.vector = vector; self.anchors = anchors
            peer = Peer(vector: vector, team: material.bundles[0].slices[0].teamIdentifier)
        }
        private func anisette(serial: Bool = true) -> @Sendable () async throws -> Client.Anisette {
            let date = date
            return {
                var value = Client.Anisette(machineID: "owned-machine", oneTimePassword: "owned-fresh-otp", localUserID: "owned-user", routingInfo: 1,
                    deviceID: "owned-device", clientInfo: "Owned controlled peer", issuedAt: date, locale: "en_US", timeZone: "UTC")
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
        static func make(seedPublishedLease: Bool = false) async throws -> Fixture {
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
                let value = Fixture(directory: directory, material: material, vault: vault, namespace: namespace, vector: try Vectors.first(), anchors: anchors)
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
        let dsid: String, idms: String, token: String
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
    private enum Vectors {
        private struct File: Decodable { let appleDerived: [Vector] }
        static func first() throws -> Vector { try #require(all().first) }
        static func all() throws -> [Vector] { try JSONDecoder().decode(File.self, from: #require(Data(base64Encoded: base64))).appleDerived }
        // Generated from independently executed vectors/reference.py. All
        // passwords/tokens/keys are intentionally public fixtures, not accounts.
        static let base64 = "ew0KICAic2NoZW1hVmVyc2lvbiI6IDEsDQogICJwdWJsaWNGaXh0dXJlc09ubHkiOiB0cnVlLA0KICAicmZjNTA1NCI6IHsNCiAgICAic291cmNlIjogIlJGQzUwNTQgQXBwZW5kaXggQjsgcHVibGlzaGVkIFNIQTEvMTAyNCByZWZlcmVuY2Ugb25seSwgbm90IHByb2R1Y3Rpb24gQXBwbGUgcG9saWN5IiwNCiAgICAiY2hlY2tlZEZpZWxkcyI6IFsNCiAgICAgICJrIiwNCiAgICAgICJ4IiwNCiAgICAgICJ1IiwNCiAgICAgICJBIiwNCiAgICAgICJCIiwNCiAgICAgICJTIg0KICAgIF0sDQogICAgInBhc3NlZCI6IHRydWUNCiAgfSwNCiAgImFwcGxlRGVyaXZlZCI6IFsNCiAgICB7DQogICAgICAicHJvdG9jb2wiOiAiczJrIiwNCiAgICAgICJ1c2VybmFtZSI6ICJmaXh0dXJlQGV4YW1wbGUuaW52YWxpZCIsDQogICAgICAicGFzc3dvcmQiOiAicHVibGljLWZpeHR1cmUtcGFzc3dvcmQiLA0KICAgICAgInNhbHQiOiAiMDAwMTAyMDMwNDA1MDYwNzA4MDkwYTBiMGMwZDBlMGYiLA0KICAgICAgInByaXZhdGVBIjogIjAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjEwMTExMjEzMTQxNTE2MTcxODE5MWExYjFjMWQxZTFmMjAiLA0KICAgICAgInByaXZhdGVCIjogIjIxMjIyMzI0MjUyNjI3MjgyOTJhMmIyYzJkMmUyZjMwMzEzMjMzMzQzNTM2MzczODM5M2EzYjNjM2QzZTNmNDAiLA0KICAgICAgIml0ZXJhdGlvbnMiOiAxMDAwLA0KICAgICAgInBhc3N3b3JkS2V5IjogImIwNTFmMDJmYjAzOThmMmZiMjNkZWRkYjQ0M2JjOTEzMTdkMjFlZDc1MGViZTUxYTE2NzllYzE5NjAxYzQ5N2EiLA0KICAgICAgImdyb3VwTiI6ICJhYzZiZGI0MTMyNGE5YTliZjE2NmRlNWUxMzg5NTgyZmFmNzJiNjY1MTk4N2VlMDdmYzMxOTI5NDNkYjU2MDUwYTM3MzI5Y2JiNGEwOTllZDgxOTNlMDc1Nzc2N2ExM2RkNTIzMTJhYjRiMDMzMTBkY2Q3ZjQ4YTlkYTA0ZmQ1MGU4MDgzOTY5ZWRiNzY3YjBjZjYwOTUxNzlhMTYzYWIzNjYxYTA1ZmJkNWZhYWFlODI5MThhOTk2MmYwYjkzYjg1NWY5Nzk5M2VjOTc1ZWVhYTgwZDc0MGFkYmY0ZmY3NDczNTlkMDQxZDVjMzNlYTcxZDI4MWU0NDZiMTQ3NzNiY2E5N2I0M2EyM2ZiODAxNjc2YmQyMDdhNDM2YzY0ODFmMWQyYjkwNzg3MTc0NjFhNWI5ZDMyZTY4OGY4Nzc0ODU0NDUyM2I1MjRiMGQ1N2Q1ZWE3N2EyNzc1ZDJlY2ZhMDMyY2ZiZGJmNTJmYjM3ODYxNjAyNzkwMDRlNTdhZTZhZjg3NGU3MzAzY2U1MzI5OWNjYzA0MWM3YmMzMDhkODJhNTY5OGYzYThkMGMzODI3MWFlMzVmOGU5ZGJmYmI2OTRiNWM4MDNkODlmN2FlNDM1ZGUyMzZkNTI1ZjU0NzU5YjY1ZTM3MmZjZDY4ZWYyMGZhNzExMWY5ZTRhZmY3MyIsDQogICAgICAibiI6ICJhYzZiZGI0MTMyNGE5YTliZjE2NmRlNWUxMzg5NTgyZmFmNzJiNjY1MTk4N2VlMDdmYzMxOTI5NDNkYjU2MDUwYTM3MzI5Y2JiNGEwOTllZDgxOTNlMDc1Nzc2N2ExM2RkNTIzMTJhYjRiMDMzMTBkY2Q3ZjQ4YTlkYTA0ZmQ1MGU4MDgzOTY5ZWRiNzY3YjBjZjYwOTUxNzlhMTYzYWIzNjYxYTA1ZmJkNWZhYWFlODI5MThhOTk2MmYwYjkzYjg1NWY5Nzk5M2VjOTc1ZWVhYTgwZDc0MGFkYmY0ZmY3NDczNTlkMDQxZDVjMzNlYTcxZDI4MWU0NDZiMTQ3NzNiY2E5N2I0M2EyM2ZiODAxNjc2YmQyMDdhNDM2YzY0ODFmMWQyYjkwNzg3MTc0NjFhNWI5ZDMyZTY4OGY4Nzc0ODU0NDUyM2I1MjRiMGQ1N2Q1ZWE3N2EyNzc1ZDJlY2ZhMDMyY2ZiZGJmNTJmYjM3ODYxNjAyNzkwMDRlNTdhZTZhZjg3NGU3MzAzY2U1MzI5OWNjYzA0MWM3YmMzMDhkODJhNTY5OGYzYThkMGMzODI3MWFlMzVmOGU5ZGJmYmI2OTRiNWM4MDNkODlmN2FlNDM1ZGUyMzZkNTI1ZjU0NzU5YjY1ZTM3MmZjZDY4ZWYyMGZhNzExMWY5ZTRhZmY3MyIsDQogICAgICAiayI6ICI1YjllOGVmMDU5YzZiMzJlYTU5ZmMxZDMyMmQzN2YwNGFhMzBiYWU1YWE5MDAzYjgzMjFlMjFkZGIwNGUzMDAiLA0KICAgICAgIngiOiAiYTM3M2E1OWNiMDkwZjBhZjBkNDcxNWIzYWM5YTllYzI5NTg0NGZkMmFkZmM0Yzk2ODg3ZGU4MjllZjkwYzdiOCIsDQogICAgICAidiI6ICI2MzQxOGM5MGFhNDM0ZTQ0NmY3ODAxYzA1NWM1YWI0NTE0YjkyYjVhYzBkYTc5MmMzZjI4OTMyNGJhMWQwNDMyZmMwMTNlYWUzNGRjNDg4NWU0ZjViZDFjYWVhZjljZmY3ODlhMTQxMTA2ZTIyMDljNGViMGZiYTJhMDQzZDMzODU3M2FmMTRhOTA0ZjI5MjIwMDY2OGJmYmRjMmYxNjM3Zjc4ZDA4NzYzODZkYjRiMGE2YzFkMWZlN2UzYTlkN2M3NDM0YTBkYTM1ZGMyZDBjZGQ0NThhNjhlNWZlOGI1YzMyMmJlYWQ1NTJjNmVmNDM4MzM4N2U4MTE5ZTk0YmIwOWI0YWZjZDlmNDIwMTg0MTNlMzM2NTUxNTI1YWI3OTkzMzQxNzhkNzkwNDlhNTg3MzlhYjJhYmQ4YmNkZDMwZWUyZmQ1MjgyZjdlZTIwYjNkMjYwNWY5YjQyOWQ3OGY0MWYyNThmNDc4YTZlY2RiYTc5ZDA0ZTk2ZTJiMThlZWRmNTgwM2FiYTk4NzhmODgwMDliNjgwODAyNzU3NGU4M2NmZTM4OGZkMmQ0MDQ0NWZmMTM1ZjY4OWNhNTIzYWZkMDk3YThmMGU1ZTg3Mjc1YWFhZDQ1MTE5Njc1NTUzMGY0ZmQ5MTkxYjBmNjNiNGI5YWMyZGZiYjEzNWQxY2JmMyIsDQogICAgICAiQSI6ICI2MzBhY2RmZjVkMzM0NDYyZDkyYTI5ZTBiN2ZhNmUyMDAyMGYzMzMzMjkyZjZkM2E2NDBmMWM3YTc2YWQ5ZDMxNzUzMWM1Nzk3OTk1MmU1NzM2Yzg4ZGIxMThkMDYwZGMwNTM5YTgxMmI5YjBhZjNiNDAwMjM4MGE5ZjI4YWU0YTdjNDVhODk2NTQyZGUwNWZiY2Y3NmE0ZTdlMDczOWI5YTU1ZDVkNmM3YWJhNGYxZTFiNTg3MjlhNzliYzA4NGQ1ZmY1MTNlYWVjMzNjZTk3OGY1YmFkODdlNTc5YjVhOTVmYzc3MzE5OGUyMjY5N2IyZWFkYWI5ZWI5NGY4NGNkY2YxZmU5NGZmMDlmODhkNGNhNDZlOTY4YmJhNDQzZmY3MTE2NzU3MWYxOWZlYjA1Mjg2OWJkMjhkN2RhYmY5NjNiN2ZlMzk5YTFmNzBlN2UwOGQwMGUxYTM3NzhlZDFkZGRjMzMyNWRkMDllMDVkMzFlNzc0ZDFmZDI5NWM0YWJmYmM2MTM0NDYyMzIwMDRkNjdjYjAzZDZhMDM0ZDJjZTZjYTBhNTQ0YTBmZjViNDM0YjRiNDI2N2ZhNmM2ZDcyYWNiYmRhMmVmYzFlZjFkMWZlMzZkMzUzODJiMDg5YWJlNTU2ODYyYWVjMzViMjlkM2QwY2RmMzU5YTljZmVkMyIsDQogICAgICAiQiI6ICI1ZjAxNmI2NmU1ZGFiNTQ4MDEzYTQ2MDdjMDJhYjE1NjlmNThkOTRhYTY3MGJkNjhiY2U5YmZkYjc4MDdjNDQ0ZGFiZmJjMTM4YzVlNWFiOWRlYzVkZjM4YTFjNWU1OTUyYjYwYzMyMDg3ZWU1MDhhNmE0YTE4YzQ5ZDdjNjM4NzQ2ZDcyZGE4OTQyMTA0NTJhMmE1NjYzNTk1MzBjMWRjMTM1Y2NiNGEzNWYxODBhNzQwZjA0MmUxMmZmOGFiYTQzNTU4ZDU2NzgxZGUzZWI3MWI2YjJkMWJkYTc3MjRkMmFjZTZlYTA5YTE0NDIwNmM5ZDU4NWU3Y2ZkNDg0OTg1OWNiOTk5MGRlYmFmNWVhY2E1ZjZkYTIyZTkyN2QxMDVhNTkzOGYxOGExZDc3OTMyNTNlNDZmNDJmMDIxMDkwMTZkNTg2Y2NkOGY5YzYyMDU2NGU3NzIzNjkxMDBmODQzZTM4YjlkMTQxMTZiOWIwY2U3YTYzN2ZjZDM1ZTAyNjFjNTkzNGEyNjYyOGY4NzdkYzhmMjM1NTc1NTI1YmE1NzRhYjhlMmUwNTUwYTlkNTdjNDY3MWM4OTRhZmQxYmI4ZmVlMjRkYjc4MGVhNDQ3OGJjM2M2MjE5NDFlNmQwYzYzY2MxMjVlNzQyNWM4ZmRkYzc2ZWNjYmQ0OTlmYWJkMiIsDQogICAgICAidSI6ICIyNjJlODc0MDNmODgxZjNjNGFkZjI0YTBiZWYxNzk5OTI0YmQ2NDViMzJjYjdhZWU4ZGY1ODQ1N2ZkNmZlOWQzIiwNCiAgICAgICJTIjogIjIwMzE4ZTg5YWVmYjEwNmZhMmQ2OGI0YTgyY2JkNmM4YTFhMWYyOWU1MWUzYTA0OWU0N2VkYjFmYjgzOGE5MjQ4OTFkNDI2MjEyZmY0YjY0NTU1ZmIxYzUwM2M0ZWE3ZDE0MTZkYjEzYjU1MmNlMTc0ZThkOWZiYjdlNzFiY2QxYzlhYTgwNDZmZWVlYTZhMDQ3NzkwNTNmNzA5M2I2MzRmZmRkMTM1NjM5ZDIyMDU1NTIyY2M2MzU0MDlhZDE4MDJlNDgxNDY5M2RiZjdmYjk1NzJlMWZmYzAxNzUxNzlmMjE3MjIxMWQyOWY2YTQyNzgxZjFiZGE2NWU2ZGY3NzJhOGQ5ZTcyYTdmMWFkNmFmYTgxOWVkZDAwNTIzZWI1MTFiMGRlZDM0ZmQ5ODJkMDJiNzljYTk5ODFiZGQ1NGRmNmRjYmJjNTBhZTAxZDVhZmYxMTZkYjYzN2Q4MGVkYzc4N2FiZjEwM2MzYWUxMjBkMWZmZTZjOGZmNmIzNTFlMTU4MTc5YjUxNTA5MThkYWZkZTFjNWJhZTc2NTk4NWRlNGRiODIwZjIxZmRkYWNlZDgyMjZhZGViNzIxNzY5ODRjNTU2MWNiNTU4ODJhMTE4OTFjZjE2MTI2ZTQ2M2ZiZTA2NzBhMjlkYmZhYmZjZDg5ZDU3MDBhZTk5M2U2YWZiIiwNCiAgICAgICJLIjogIjU3Y2Q2NGYxYzIzNTk0ZTM5NDFmNmU2YzQyMWZjNDU1NWI5YWVjNjg0NDNhZjZiNWIyMmNiNWYxZDZiNWVjYTciLA0KICAgICAgIk0xIjogImRkNzZkNTViNTA1NzIxZjQzZjljNmJiYWRiZmE0MWUwYTA1NWQzNzYzZDBhZmUzMGY0YWMyMjg0NzdmZGM3ZmQiLA0KICAgICAgIk0yIjogIjVlNzc3ZmQ0NzBmMWEyYTIzZjM1MzMwNGQ5Y2FhMDIwZTIxMzdjNmJkYzcyNGU1ZGIzY2NiYzhlNTEzNjVjOTUiLA0KICAgICAgInNwZCI6ICIxNmFjYWRiYjljYjhiYTUyNDUyNTY1OGQwNzY5ZDhjMmM0MDhjNmRkZTgwZjA2NzlmNTM1MjQzMjEzN2YwMDczZmUxZjUzYzI5MzM1M2UxZTU4OWRmOWZiYWNhZmQzMzFiMDg3ZDc0ODhmZWYyMjdjN2ZmYWIxMDBjYWRkMTk3MGMzYzJjN2ViY2MwYWQyNmQ3NDE0Mjk5N2I4ZWRiMWFhZmJjOTg5OGQwYjE5MGFiNDA4ZTRjYjExYTI2NDkzZmI4MGRlYjU0ZWMxMjlmOTRlNjBkY2U2ZmUyMTY0N2VkZmMwYzlhOWZjODI2NDRlNGQzNjBmMzQ4YTQ4N2Y5ZjgyYTM0NjExZTJlZDhkNTdhNWUzMjMyNjM0MmE1Njc1ZTAzODMxODI1ZjY3ZWQ1ODkzNWZjNzMxMzQ5YzMxYjI4MGZmZGIzNjkyNjJjNmRjMjdkYzc5MTZkYjkzMmI1MTkxYjFjNDNhMTZjMWUwZjI4NzI1MWI3YjU2MTRhMzRkMTc2YmViYWEzMzM1ZjkzYzExOTRmYjJkMDA4ODlkMzljMzg4NTgyYjQ3NDZjZGQwOGJlMTQyZGM0NWEyZDc1MTViMWVlZDg4MDk4OWNhZTk0ODM4YWU1NjJiNzk3MWM3OGI4MzhlYmRmMTBmYjAxYjVlNTM5YzEwZjI2NGJmODg1MmQzZTVkNmM4MGI0ZDkyNzBmOGYzZDAwZmMwZThjMTk5NGM0ODU3MDkwZGNiMjQwMTM4NDI1NWQ4MzRhZGUyMTcwZDhhNmVjZjExZGY3ZWNlOGM4NjFjMWM4MmFkMDc5ZmI0NDdiNGY5MDBlNmE3ZTIwMmE5NDg5NzM5Y2UyY2Y2MjVmNzRkMzVmMDVjMmYxYzJmOTk2NTc1YTNjOGFiNjVlNjA0YjEzYjY5OWIzOTEyMjM3N2QxMmQ2Mjc1MGZkM2E0OTYzNmE3MjIxZThjZDczZGZkODBjMDc1NjIzZGY5NmM5NTg5MWM3ZDdjN2I1Y2RkMzJhYTZlNTE3MzM1M2Y4ZjExODkyYjQ0ZWU2NmE3YTVhZjcxNzNiZDNhZjFlM2QzYTZhMjI5NzMzY2UwNDk3NTliYmUyZTA0NTA5MDIyOTdhOTBmOTY3NjBhZjRmMmU4YzU4ZjM3ODQ0MzNkMzUyMWYzOWRmMDE1N2Q4MzcxYmQ2NmMyZjA5OWE5NDk5YSIsDQogICAgICAic2MiOiAiNzA3NTYyNmM2OTYzMmQ3MzYzIiwNCiAgICAgICJucCI6ICIwMjI2NTFmNjk4NWRiMmIzNmJkZjdiOGNhZDRkOWZmZDdlMWNiMDkyZTFiYTNmNTllMmM5MTBlN2U2MDA4ZWYzIiwNCiAgICAgICJzayI6ICIwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjEwMTExMjEzMTQxNTE2MTcxODE5MWExYjFjMWQxZTFmIiwNCiAgICAgICJjb29raWUiOiAiNzA3NTYyNmM2OTYzMmQ2ZjcwNjE3MTc1NjUyZDYzNmY2ZjZiNjk2NSIsDQogICAgICAiZHNpZCI6ICIxMjM0NTY3ODkiLA0KICAgICAgImlkbXMiOiAicHVibGljLWZpeHR1cmUtaWRtcyIsDQogICAgICAiY2hlY2tzdW0iOiAiYzZhMzEzZDY3ZjhkZjdmZWE2NTk4NWE5NTE0MWUyM2YxZjU1ZjNhZDE2ODdhOGY3ZTkyYjgxYzVlNjAxNmMwNiIsDQogICAgICAiZW5jcnlwdGVkVG9rZW4iOiAiNTg1OTVhMDAwMTAyMDMwNDA1MDYwNzA4MDkwYTBiMGMwZDBlMGY1YjUzZDgxYjU1YzQzYzRkZWY4Y2IyNDYzYjk5MGU4MjdhODM0OTgxMDJlM2IwMmMyMDU3MjNiMmIzZGI5OTllMmU1MmIxZDY0MjdlZGFmMmMzNmQ3OTE1YjU2ZmI1Mzc3NzAwMjYzM2ZmNjA2MGQxZjVmZmVhNTJhMjBiNjBhYjNjYzQzYWQ0YjAwOGUyYjAxMDE1ZjQ3MjUyMmYxOWZkODhkNzI2OWRjMDBkNjBhZGMzMjAwMGRkZjVkNjdkNjAyOGRmZjc2MzNmNzk2YjYyNWY5NmNjYjQzYjQyMWJkMWEwMDFhMWYzNDcwMTI2MGZlNzZmY2U3NTQ3M2IzYjhkZDU1ZjI5YzZlZjMxYWRiZWQ5ZDYyNWZjY2IwZjk0YzlmMzAyMTFkZGI4NmJjZWY4ODBkOTY1OWIwNjc5ZmQ0ZTAwYWNlYjdjMjBkYmM4NmY5ODAwM2QzMjIwNTRhNDlkYTNkZGJhMzJjZTg3ZDM1YjM5N2Y1ZWE1ZjY1NjViYTEwZjg3MTVhODUzYzdlNmZhNGE1ZTEzODljNGNlYmRhM2M0ZjRjOWFmMjVkNzU1YWIyNmIwZDdlYjgzMGEyNTlmYjQzNjQxMTNhZjIwYTM2NjRlYjc3MDQzOGM5MjRlODM2YzI1YmEyYWNiNmYyYzQyZjQ4MmEzOTVlODU1OWU3ODBmYjk1OTIzODJjYTc2ZDNkYTY1OWIwNWZlN2RjOTM1MjdhYTRkODlmNzc0YTZlNjlhZGZiYTBlNDZjYWQxMjI1Y2Y2MDJhMDY2NWQ0ODZhYzFkN2Y0OGI4ZWVlMGY0MjRlM2E0ZDc0NTM4NjY5MDkwZjIyYWFmODNiY2ZjNTY0NmE2ODkyYTdkMjVkZjc2YjM3MGM2MGE5MDY3MmY1YmFlZDczMzU0N2NiZTQ0ZTI5ZGMyNTBhMTFhZjAwNTdmZTYzMzQyNDdhMDcxZjdmOTE0NTUwZmIwZWZhOWU3N2E2NWFhZTZmNDJlNWE2ZTBkZjMyOWJlYTAyZjYyMWYyMDAwYzY5YmI2MGJhZTJjMTVmMmE5ODMyMzMxMzY2ZmRlYTRjY2UyZTIwMzZkYTVjM2NkMGJjMWMwOTBjY2Y5ZiIsDQogICAgICAidG9rZW4iOiAicHVibGljLWZpeHR1cmUteGNvZGUtdG9rZW4iLA0KICAgICAgImV4cGlyeU1pbGxpc2Vjb25kcyI6IDE3OTI1NDQ0MDAwMDANCiAgICB9LA0KICAgIHsNCiAgICAgICJwcm90b2NvbCI6ICJzMmtfZm8iLA0KICAgICAgInVzZXJuYW1lIjogImZpeHR1cmVAZXhhbXBsZS5pbnZhbGlkIiwNCiAgICAgICJwYXNzd29yZCI6ICJwdWJsaWMtZml4dHVyZS1wYXNzd29yZCIsDQogICAgICAic2FsdCI6ICIwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZiIsDQogICAgICAicHJpdmF0ZUEiOiAiMDEwMjAzMDQwNTA2MDcwODA5MGEwYjBjMGQwZTBmMTAxMTEyMTMxNDE1MTYxNzE4MTkxYTFiMWMxZDFlMWYyMCIsDQogICAgICAicHJpdmF0ZUIiOiAiMjEyMjIzMjQyNTI2MjcyODI5MmEyYjJjMmQyZTJmMzAzMTMyMzMzNDM1MzYzNzM4MzkzYTNiM2MzZDNlM2Y0MCIsDQogICAgICAiaXRlcmF0aW9ucyI6IDEwMDAsDQogICAgICAicGFzc3dvcmRLZXkiOiAiOTAzNTkyNjk3YmUwMzcwYTlmZmY2MDNkYzg1ZDM0NTVmMjI0NWMxOWJkYTY0NTgzM2RhMjkxNDAyZDdmMmVhNyIsDQogICAgICAiZ3JvdXBOIjogImFjNmJkYjQxMzI0YTlhOWJmMTY2ZGU1ZTEzODk1ODJmYWY3MmI2NjUxOTg3ZWUwN2ZjMzE5Mjk0M2RiNTYwNTBhMzczMjljYmI0YTA5OWVkODE5M2UwNzU3NzY3YTEzZGQ1MjMxMmFiNGIwMzMxMGRjZDdmNDhhOWRhMDRmZDUwZTgwODM5NjllZGI3NjdiMGNmNjA5NTE3OWExNjNhYjM2NjFhMDVmYmQ1ZmFhYWU4MjkxOGE5OTYyZjBiOTNiODU1Zjk3OTkzZWM5NzVlZWFhODBkNzQwYWRiZjRmZjc0NzM1OWQwNDFkNWMzM2VhNzFkMjgxZTQ0NmIxNDc3M2JjYTk3YjQzYTIzZmI4MDE2NzZiZDIwN2E0MzZjNjQ4MWYxZDJiOTA3ODcxNzQ2MWE1YjlkMzJlNjg4Zjg3NzQ4NTQ0NTIzYjUyNGIwZDU3ZDVlYTc3YTI3NzVkMmVjZmEwMzJjZmJkYmY1MmZiMzc4NjE2MDI3OTAwNGU1N2FlNmFmODc0ZTczMDNjZTUzMjk5Y2NjMDQxYzdiYzMwOGQ4MmE1Njk4ZjNhOGQwYzM4MjcxYWUzNWY4ZTlkYmZiYjY5NGI1YzgwM2Q4OWY3YWU0MzVkZTIzNmQ1MjVmNTQ3NTliNjVlMzcyZmNkNjhlZjIwZmE3MTExZjllNGFmZjczIiwNCiAgICAgICJuIjogImFjNmJkYjQxMzI0YTlhOWJmMTY2ZGU1ZTEzODk1ODJmYWY3MmI2NjUxOTg3ZWUwN2ZjMzE5Mjk0M2RiNTYwNTBhMzczMjljYmI0YTA5OWVkODE5M2UwNzU3NzY3YTEzZGQ1MjMxMmFiNGIwMzMxMGRjZDdmNDhhOWRhMDRmZDUwZTgwODM5NjllZGI3NjdiMGNmNjA5NTE3OWExNjNhYjM2NjFhMDVmYmQ1ZmFhYWU4MjkxOGE5OTYyZjBiOTNiODU1Zjk3OTkzZWM5NzVlZWFhODBkNzQwYWRiZjRmZjc0NzM1OWQwNDFkNWMzM2VhNzFkMjgxZTQ0NmIxNDc3M2JjYTk3YjQzYTIzZmI4MDE2NzZiZDIwN2E0MzZjNjQ4MWYxZDJiOTA3ODcxNzQ2MWE1YjlkMzJlNjg4Zjg3NzQ4NTQ0NTIzYjUyNGIwZDU3ZDVlYTc3YTI3NzVkMmVjZmEwMzJjZmJkYmY1MmZiMzc4NjE2MDI3OTAwNGU1N2FlNmFmODc0ZTczMDNjZTUzMjk5Y2NjMDQxYzdiYzMwOGQ4MmE1Njk4ZjNhOGQwYzM4MjcxYWUzNWY4ZTlkYmZiYjY5NGI1YzgwM2Q4OWY3YWU0MzVkZTIzNmQ1MjVmNTQ3NTliNjVlMzcyZmNkNjhlZjIwZmE3MTExZjllNGFmZjczIiwNCiAgICAgICJrIjogIjViOWU4ZWYwNTljNmIzMmVhNTlmYzFkMzIyZDM3ZjA0YWEzMGJhZTVhYTkwMDNiODMyMWUyMWRkYjA0ZTMwMCIsDQogICAgICAieCI6ICIyYzk1MWI1NWI4ZjJhMzdiNzFhN2NiZmY3NGJkMmFjODBjOTcyZjM2MTc5YWJkYTdlNjliOTRjMmM0NDkxNWQ4IiwNCiAgICAgICJ2IjogIjI1YWI2ODlkODgyNWY2NjI5OGJmN2RmYjRjYjc3NGMxZTU4ZDk1ODBmMmRjNTdmODMyZTliOGM2NDZhMmZhY2Q0Y2IyMmE1ZGQwZWI3ODMwZDliZjdhMWJjMGIxNThkYTEwNWYzY2E5ZGI5OTc0ODFiMjZlOGViZmMwMDk0NWU0OThkZGQ0ZGI3MDE2MTA0ZThhOTU3OTY2MzNkOGUwMDQyNDYyNGJhOTMyYzQ3ZGNiNjAxYTYyZGYzY2I1Mjk0Y2IyZTA0ZTVmNTQ4ZGQ2ZDkyOWU3ZDk5Yzc3M2ZkNWU3NjFmZTNlOGE3MGNhMGYyOTA4ZjM0ZDIzOTgzOWJlYTg3YWFhYThlMGVhNGQ4YzUyMjAyYzcyZGRiMGVjODg2OGVmOGZhMGRhYzMzYjc3YWI2OWIwOTA2MThhNTY3N2U1NGYzNDI0MmU5MGY4NDM5ZmI4YmU3MmFmYjUyYzI5YWY0OTYwN2RiMjBjZWE4YTcxYzgxZjIwZjIwYTBlNTE2YWQwMDZjYmY4MTg0YjAzNGRmZDdiM2I1MGE4ODc1MTJiNmZiNDk4OGRkOGRkMDY1NzI2ODEzZTRiMzlhNTYzYzAxYjhhNTU3N2QzOTg4NjNhNzlmNDE3NjExNmVkMDRiYjc2YmY1NmU3MGViZjA1MTNlNTc2ZTkyMjg0NDU5YmYyIiwNCiAgICAgICJBIjogIjYzMGFjZGZmNWQzMzQ0NjJkOTJhMjllMGI3ZmE2ZTIwMDIwZjMzMzMyOTJmNmQzYTY0MGYxYzdhNzZhZDlkMzE3NTMxYzU3OTc5OTUyZTU3MzZjODhkYjExOGQwNjBkYzA1MzlhODEyYjliMGFmM2I0MDAyMzgwYTlmMjhhZTRhN2M0NWE4OTY1NDJkZTA1ZmJjZjc2YTRlN2UwNzM5YjlhNTVkNWQ2YzdhYmE0ZjFlMWI1ODcyOWE3OWJjMDg0ZDVmZjUxM2VhZWMzM2NlOTc4ZjViYWQ4N2U1NzliNWE5NWZjNzczMTk4ZTIyNjk3YjJlYWRhYjllYjk0Zjg0Y2RjZjFmZTk0ZmYwOWY4OGQ0Y2E0NmU5NjhiYmE0NDNmZjcxMTY3NTcxZjE5ZmViMDUyODY5YmQyOGQ3ZGFiZjk2M2I3ZmUzOTlhMWY3MGU3ZTA4ZDAwZTFhMzc3OGVkMWRkZGMzMzI1ZGQwOWUwNWQzMWU3NzRkMWZkMjk1YzRhYmZiYzYxMzQ0NjIzMjAwNGQ2N2NiMDNkNmEwMzRkMmNlNmNhMGE1NDRhMGZmNWI0MzRiNGI0MjY3ZmE2YzZkNzJhY2JiZGEyZWZjMWVmMWQxZmUzNmQzNTM4MmIwODlhYmU1NTY4NjJhZWMzNWIyOWQzZDBjZGYzNTlhOWNmZWQzIiwNCiAgICAgICJCIjogIjg3ZmY1ZWIyOWE4NDFiYjU3Mzc4Y2Q5ZDk0MGJjNGE5ZDYyYzIyN2QzNWY5ZGU4YTVlYTk0ZWNhNzhmN2E1Y2YwZjAzMTZmOWY1NjE1ZmE3NDU5ZTA0MDg2ZWQ2YzlhNTgxOGQzYmEwOWYzMzgzZGNmM2QzMzE1MDRhNWIwMTJmOWJhYWYxOGIzOWUyOTcyZmIzMGY0NTI4OTZhMzk0Y2YyMTZlYmMwNWZlNTdiODRkYzM0YTIyNTliNzIyNDdkZDgwMDZiNjFiYTgwMzNkMDBmNzMwMzJjMzVmZGE0MzBiYWZmYTk3YTMzNWUzMzZjN2Q4MzNiOTNlYTJiMjVjOTIzM2I5NjBkNGY2ZmRkYjc2OTg2OWFjODlmZjIwN2Q0YTg1MzYwMTFiMjVhMjgzYzljYTg1OTQzMzEzMjk4YzNjMjU4MGJkYzgyOTYxMjU3NzE4MGI1ZWIyNWExOWM4ZTg0ZTc5MTg3YjY5ZWE0NDVlZWY4Y2FlNDQ0ZWEyNzFlN2I2MmNkMjVmMmExYTY0NDZkZDVkYzY5MDBhNzk5OTcwNDU5ZTAzMjdmMjI1NWE0MzgzOWZlZjc1OWI4MjMwY2UyMmJjY2JjODAzMTNkZWMwN2IyMzY0MjIyODY2NTA3ZDU2ZTg2YTlkNzc1ZDQ5ZjhiYjg2MGIyNzYzMGY0MDBjIiwNCiAgICAgICJ1IjogImY2MzA2Mzg0YzJmMDYwYjI2MWQzNTU3NGZlNzY5NjI4N2JjMTA5MDhmODlmMDJjYTAzMGUxNTc2NzJlN2RkN2QiLA0KICAgICAgIlMiOiAiNjY0NTQ2MTdjMTNhM2QxZDg0Mzk1ZTdjMDk4ZjZmZmZhNWJjOGI1YzE4OGQ3M2JmNDc5ZThiZWMyOTFlOTE2MzA1OTNjZTVkYmU2NTI1MDc4MmM0ZDA4YmFjMGE4MWE4NTc0ZWY1NjBkY2U4NzVlNmUyYWZiM2U4OGIyMTg0NjM0ZWMzNjllNzY5NTY1NWU2MDg4YWFiNDQwZTc5NTliMjMyODNmN2E5YmY3NmNlM2QxNDFhZTdiYjQ5MjA2MTU4MDc0ZGZiNGYxOWEwNjYyZmNlOGEzNDhmOTRhOTE1ZTVjZGQ1MzhkZmEyYzMyZjU0MzJlNTYzZjA2YzUxYWY4N2YyOWM5YTk1ZmMwOGU2ODhiZDE0YTE0OGI4YzRlNGM0MmVmY2ZkYzk3YjdmMDg0ZWYwNzljNzUzMGE1ZDA2N2I1Y2U3MzA3ZDgyNTVmNTVmYmU2MjMxN2UyM2Q0YmM1NDQzZjY1NDI4NTY4NGZlYzMzYTVlZGVkYWVhOTk3NTM0YWM4ZTM4MDhkMjY3ZjUyM2Q0NGRmNjYwNzNjNGUxNWI4MWYwZDE5OTMxNzA0MjZhMTIzZjY3NjkwYzFiMWIwY2FhN2JhM2ZiMWRkNWJhZmJhNmM3M2NmMjQ4OTBkNzdjYTVlZGU1YmUzNGY0MjRiZjc1NTk3MzgzNGM5MGQxODMiLA0KICAgICAgIksiOiAiNjVmNDRjZTg0ZjcxYzQ3MmJkNGRkYTJjNmE4MDhlMDY4ZjY1MTAyYWQ4ZjI1NWIwYTAxZmVmMGZiNjRmNGVmYyIsDQogICAgICAiTTEiOiAiMTU2NzY3MTJjYmI5NmQ0NTViZWNmM2NhMTc1NjU1NmIwMzkyMGNjZGM4MGFlNDAyNWNmM2YzNzcyMjQ4M2JlMiIsDQogICAgICAiTTIiOiAiMDhhY2U3YTA3MThjZjc0NjRmZmMyOGQ4OTQyNDQ1MTdlZjkwZTZhZjFjMDhiYmQyYjIzMTY3MmFiYjc1ODM2ZCIsDQogICAgICAic3BkIjogImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZjFmYzcwZTBhMDM2MDA4OTE4YjJjNDA3ODE1MGIwOTJiNDQ3NWY3NTE1YjI4MjkxNjYzMzkwNThiM2QyOWY0YWQ2NTQwZjUwNWViMTAxOGQ3ZGU1ZjIyYmQyYmZjODk4ZjMyNzU4NWFlYWUzYTFmMGNjZjFlZDFlOWNmOGE4Y2ZjNDQ2OTg4YzQ0YjA1YjFhNDVlOGQwNzI0NzIyYTk5ZTRlMGVjMmQ0NzBhN2RiNjc4YmE2ZWFiZjdkNzQ5YTM5YjI5ZWRjMWQ1NTJjZDlhM2RiMjYzZTM2NDc3MWIxNTQ4MTAwN2E2Zjc0NmRlY2Y1ZDI4NGIzMmVkYzc5YTBhNzU1NDRkYWI5ZTNlMDdkNGIzZjkyNzQ1ZjQ1ZWFlNTllZTczY2NjNTY5MmJlNjFmYTA0NmY0ZWE4MTkxMGY3NjNkMmM2ZGNjOTczYjUzYTRiYmFkNWNlMDA0MDM1MzA5YjJhZmNhYTY0MTA3OTNjZGZmMDdiZDk5ZWQxNzg5MTlmIiwNCiAgICAgICJzYyI6ICI3MDc1NjI2YzY5NjMyZDczNjMiLA0KICAgICAgIm5wIjogIjkzYjIxMDQ5NmQxNjY3ZWUyYWZhNmU5YWNiYTY5MDM0NDE5ZWNhZDc3NWNmNmVlMDczNmM3ZDdmNjRmODljMTciLA0KICAgICAgInNrIjogIjAwMDEwMjAzMDQwNTA2MDcwODA5MGEwYjBjMGQwZTBmMTAxMTEyMTMxNDE1MTYxNzE4MTkxYTFiMWMxZDFlMWYiLA0KICAgICAgImNvb2tpZSI6ICI3MDc1NjI2YzY5NjMyZDZmNzA2MTcxNzU2NTJkNjM2ZjZmNmI2OTY1IiwNCiAgICAgICJkc2lkIjogIjEyMzQ1Njc4OSIsDQogICAgICAiaWRtcyI6ICJwdWJsaWMtZml4dHVyZS1pZG1zIiwNCiAgICAgICJjaGVja3N1bSI6ICJjNmEzMTNkNjdmOGRmN2ZlYTY1OTg1YTk1MTQxZTIzZjFmNTVmM2FkMTY4N2E4ZjdlOTJiODFjNWU2MDE2YzA2IiwNCiAgICAgICJlbmNyeXB0ZWRUb2tlbiI6ICI1ODU5NWEwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjViNTNkODFiNTVjNDNjNGRlZjhjYjI0NjNiOTkwZTgyN2E4MzQ5ODEwMmUzYjAyYzIwNTcyM2IyYjNkYjk5OWUyZTUyYjFkNjQyN2VkYWYyYzM2ZDc5MTViNTZmYjUzNzc3MDAyNjMzZmY2MDYwZDFmNWZmZWE1MmEyMGI2MGFiM2NjNDNhZDRiMDA4ZTJiMDEwMTVmNDcyNTIyZjE5ZmQ4OGQ3MjY5ZGMwMGQ2MGFkYzMyMDAwZGRmNWQ2N2Q2MDI4ZGZmNzYzM2Y3OTZiNjI1Zjk2Y2NiNDNiNDIxYmQxYTAwMWExZjM0NzAxMjYwZmU3NmZjZTc1NDczYjNiOGRkNTVmMjljNmVmMzFhZGJlZDlkNjI1ZmNjYjBmOTRjOWYzMDIxMWRkYjg2YmNlZjg4MGQ5NjU5YjA2NzlmZDRlMDBhY2ViN2MyMGRiYzg2Zjk4MDAzZDMyMjA1NGE0OWRhM2RkYmEzMmNlODdkMzViMzk3ZjVlYTVmNjU2NWJhMTBmODcxNWE4NTNjN2U2ZmE0YTVlMTM4OWM0Y2ViZGEzYzRmNGM5YWYyNWQ3NTVhYjI2YjBkN2ViODMwYTI1OWZiNDM2NDExM2FmMjBhMzY2NGViNzcwNDM4YzkyNGU4MzZjMjViYTJhY2I2ZjJjNDJmNDgyYTM5NWU4NTU5ZTc4MGZiOTU5MjM4MmNhNzZkM2RhNjU5YjA1ZmU3ZGM5MzUyN2FhNGQ4OWY3NzRhNmU2OWFkZmJhMGU0NmNhZDEyMjVjZjYwMmEwNjY1ZDQ4NmFjMWQ3ZjQ4YjhlZWUwZjQyNGUzYTRkNzQ1Mzg2NjkwOTBmMjJhYWY4M2JjZmM1NjQ2YTY4OTJhN2QyNWRmNzZiMzcwYzYwYTkwNjcyZjViYWVkNzMzNTQ3Y2JlNDRlMjlkYzI1MGExMWFmMDA1N2ZlNjMzNDI0N2EwNzFmN2Y5MTQ1NTBmYjBlZmE5ZTc3YTY1YWFlNmY0MmU1YTZlMGRmMzI5YmVhMDJmNjIxZjIwMDBjNjliYjYwYmFlMmMxNWYyYTk4MzIzMzEzNjZmZGVhNGNjZTJlMjAzNmRhNWMzY2QwYmMxYzA5MGNjZjlmIiwNCiAgICAgICJ0b2tlbiI6ICJwdWJsaWMtZml4dHVyZS14Y29kZS10b2tlbiIsDQogICAgICAiZXhwaXJ5TWlsbGlzZWNvbmRzIjogMTc5MjU0NDQwMDAwMA0KICAgIH0NCiAgXSwNCiAgImluZGVwZW5kZW5jZSI6ICJQeXRob24gaGFzaGxpYiBidWlsdGluIHBvdyBwbHVzIGNyeXB0b2dyYXBoeTsgbm8gU3dpZnQgaW1wbGVtZW50YXRpb24gaW1wb3J0ZWQvZXhlY3V0ZWQiLA0KICAiY3J5cHRvZ3JhcGh5VmVyc2lvbiI6ICI0Ny4wLjAiLA0KICAiYWN0dWFsUHl0aG9uUmVmZXJlbmNlUnVucyI6IDQsDQogICJwcmV2aW91c0ZhaWx1cmVzUHJlc2VydmVkIjogdHJ1ZSwNCiAgInByZXZpb3VzUGFzc1JlZ2VuZXJhdGlvblJlYXNvbiI6ICJCaW5kIHRva2VuIGV4cGlyeSB0byB0aGUgZXhpc3Rpbmcgb3JpZ2luYWwgaWRlbnRpdHkgZml4dHVyZSBjbG9jayByYXRoZXIgdGhhbiB5ZWFyMjEwMCIsDQogICJTd2lmdFNES0V4ZWN1dGlvbnMiOiAwLA0KICAiQXBwbGVSZXF1ZXN0cyI6IDANCn0NCg=="
    }
}
