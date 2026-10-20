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
    }

    private enum Mode: Sendable { case normal, wrongTeam, secondary, holdInit, badM2, badNP, badTag, missingSerial, storageFailure }
    private enum FixtureFailure: Error { case invalid }
    private actor Peer {
        let vector: Vector; let team: String
        private var mode: Mode = .normal, validated = false
        private var history: [String] = []
        enum Event: Sendable, Equatable { case initArrived, finished }
        private var event: Event?; private var waiters: [CheckedContinuation<Event, Never>] = []
        init(vector: Vector, team: String) { self.vector = vector; self.team = team }
        func set(_ mode: Mode) { self.mode = mode }
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
                return try Self.plist(["Response": ["Status": status, "M2": mode == .badM2 ? Data(repeating: 0, count: 32) : vector.bytes(vector.M2),
                    "spd": vector.bytes(vector.spd), "sc": vector.bytes(vector.sc), "np": mode == .badNP ? Data(repeating: 0, count: 32) : vector.bytes(vector.np)]])
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
        let vault: Vault; let namespace: Vault.Namespace; let vector: Vector; let peer: Peer
        let storage = Storage(); let transport = SelfRenewalDeveloperURLSessionTransport(protocolClasses: [PeerProtocol.self])
        init(directory: URL, material: SelfRenewalApplicationMaterialVerifier.Materials, vault: Vault, namespace: Vault.Namespace, vector: Vector) {
            self.directory = directory; self.material = material; self.vault = vault; self.namespace = namespace; self.vector = vector
            peer = Peer(vector: vector, team: material.bundles[0].slices[0].teamIdentifier)
        }
        func authentication(serial: Bool = true) async throws -> Auth {
            let date = date
            let anisette: @Sendable () async throws -> Client.Anisette = {
                var value = Client.Anisette(machineID: "owned-machine", oneTimePassword: "owned-fresh-otp", localUserID: "owned-user", routingInfo: 1,
                    deviceID: "owned-device", clientInfo: "Owned controlled peer", issuedAt: date, locale: "en_US", timeZone: "UTC")
                if serial { value.deviceSerialNumber = "owned-public-serial" }; return value
            }
            let client = try await Client.open(vault: vault, namespace: namespace, identity: material, issuerChainDER: [], transport: transport,
                storage: storage, freshAnisette: anisette, clock: { date })
            let vector = vector
            return Auth(account: client, transport: transport, freshAnisette: anisette, clock: { date }, random: { try vector.bytes(vector.privateA) })
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
        static func make() async throws -> Fixture {
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
                let vault = Vault(codeAnchors: [SelfRenewalCMSFixture.rootCertificate], profileAnchors: [SelfRenewalCMSFixture.rootCertificate], clock: { date }); cleanupVault = vault
                let namespace = try await vault.create(identity: material); cleanupNamespace = namespace
                let value = Fixture(directory: directory, material: material, vault: vault, namespace: namespace, vector: try Vectors.first())
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
        let worker = Task.detached(operation: action)
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    nonisolated private static func fixture(_ action: @escaping @Sendable (Fixture) async throws -> Void) async throws {
        try await Self.offMain { let value = try await Fixture.make(); do { try await action(value); try await value.cleanup() } catch { do { try await value.cleanup() } catch { Issue.record(error) }; throw error } }
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
    private enum Vectors {
        private struct File: Decodable { let appleDerived: [Vector] }
        static func first() throws -> Vector { try #require(all().first) }
        static func all() throws -> [Vector] { try JSONDecoder().decode(File.self, from: #require(Data(base64Encoded: base64))).appleDerived }
        // Generated from independently executed vectors/reference.py. All
        // passwords/tokens/keys are intentionally public fixtures, not accounts.
        static let base64 = "ew0KICAic2NoZW1hVmVyc2lvbiI6IDEsDQogICJwdWJsaWNGaXh0dXJlc09ubHkiOiB0cnVlLA0KICAicmZjNTA1NCI6IHsNCiAgICAic291cmNlIjogIlJGQzUwNTQgQXBwZW5kaXggQjsgcHVibGlzaGVkIFNIQTEvMTAyNCByZWZlcmVuY2Ugb25seSwgbm90IHByb2R1Y3Rpb24gQXBwbGUgcG9saWN5IiwNCiAgICAiY2hlY2tlZEZpZWxkcyI6IFsNCiAgICAgICJrIiwNCiAgICAgICJ4IiwNCiAgICAgICJ1IiwNCiAgICAgICJBIiwNCiAgICAgICJCIiwNCiAgICAgICJTIg0KICAgIF0sDQogICAgInBhc3NlZCI6IHRydWUNCiAgfSwNCiAgImFwcGxlRGVyaXZlZCI6IFsNCiAgICB7DQogICAgICAicHJvdG9jb2wiOiAiczJrIiwNCiAgICAgICJ1c2VybmFtZSI6ICJmaXh0dXJlQGV4YW1wbGUuaW52YWxpZCIsDQogICAgICAicGFzc3dvcmQiOiAicHVibGljLWZpeHR1cmUtcGFzc3dvcmQiLA0KICAgICAgInNhbHQiOiAiMDAwMTAyMDMwNDA1MDYwNzA4MDkwYTBiMGMwZDBlMGYiLA0KICAgICAgInByaXZhdGVBIjogIjAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjEwMTExMjEzMTQxNTE2MTcxODE5MWExYjFjMWQxZTFmMjAiLA0KICAgICAgInByaXZhdGVCIjogIjIxMjIyMzI0MjUyNjI3MjgyOTJhMmIyYzJkMmUyZjMwMzEzMjMzMzQzNTM2MzczODM5M2EzYjNjM2QzZTNmNDAiLA0KICAgICAgIml0ZXJhdGlvbnMiOiAxMDAwLA0KICAgICAgInBhc3N3b3JkS2V5IjogImIwNTFmMDJmYjAzOThmMmZiMjNkZWRkYjQ0M2JjOTEzMTdkMjFlZDc1MGViZTUxYTE2NzllYzE5NjAxYzQ5N2EiLA0KICAgICAgImdyb3VwTiI6ICJhYzZiZGI0MTMyNGE5YTliZjE2NmRlNWUxMzg5NTgyZmFmNzJiNjY1MTk4N2VlMDdmYzMxOTI5NDNkYjU2MDUwYTM3MzI5Y2JiNGEwOTllZDgxOTNlMDc1Nzc2N2ExM2RkNTIzMTJhYjRiMDMzMTBkY2Q3ZjQ4YTlkYTA0ZmQ1MGU4MDgzOTY5ZWRiNzY3YjBjZjYwOTUxNzlhMTYzYWIzNjYxYTA1ZmJkNWZhYWFlODI5MThhOTk2MmYwYjkzYjg1NWY5Nzk5M2VjOTc1ZWVhYTgwZDc0MGFkYmY0ZmY3NDczNTlkMDQxZDVjMzNlYTcxZDI4MWU0NDZiMTQ3NzNiY2E5N2I0M2EyM2ZiODAxNjc2YmQyMDdhNDM2YzY0ODFmMWQyYjkwNzg3MTc0NjFhNWI5ZDMyZTY4OGY4Nzc0ODU0NDUyM2I1MjRiMGQ1N2Q1ZWE3N2EyNzc1ZDJlY2ZhMDMyY2ZiZGJmNTJmYjM3ODYxNjAyNzkwMDRlNTdhZTZhZjg3NGU3MzAzY2U1MzI5OWNjYzA0MWM3YmMzMDhkODJhNTY5OGYzYThkMGMzODI3MWFlMzVmOGU5ZGJmYmI2OTRiNWM4MDNkODlmN2FlNDM1ZGUyMzZkNTI1ZjU0NzU5YjY1ZTM3MmZjZDY4ZWYyMGZhNzExMWY5ZTRhZmY3MyIsDQogICAgICAibiI6ICJhYzZiZGI0MTMyNGE5YTliZjE2NmRlNWUxMzg5NTgyZmFmNzJiNjY1MTk4N2VlMDdmYzMxOTI5NDNkYjU2MDUwYTM3MzI5Y2JiNGEwOTllZDgxOTNlMDc1Nzc2N2ExM2RkNTIzMTJhYjRiMDMzMTBkY2Q3ZjQ4YTlkYTA0ZmQ1MGU4MDgzOTY5ZWRiNzY3YjBjZjYwOTUxNzlhMTYzYWIzNjYxYTA1ZmJkNWZhYWFlODI5MThhOTk2MmYwYjkzYjg1NWY5Nzk5M2VjOTc1ZWVhYTgwZDc0MGFkYmY0ZmY3NDczNTlkMDQxZDVjMzNlYTcxZDI4MWU0NDZiMTQ3NzNiY2E5N2I0M2EyM2ZiODAxNjc2YmQyMDdhNDM2YzY0ODFmMWQyYjkwNzg3MTc0NjFhNWI5ZDMyZTY4OGY4Nzc0ODU0NDUyM2I1MjRiMGQ1N2Q1ZWE3N2EyNzc1ZDJlY2ZhMDMyY2ZiZGJmNTJmYjM3ODYxNjAyNzkwMDRlNTdhZTZhZjg3NGU3MzAzY2U1MzI5OWNjYzA0MWM3YmMzMDhkODJhNTY5OGYzYThkMGMzODI3MWFlMzVmOGU5ZGJmYmI2OTRiNWM4MDNkODlmN2FlNDM1ZGUyMzZkNTI1ZjU0NzU5YjY1ZTM3MmZjZDY4ZWYyMGZhNzExMWY5ZTRhZmY3MyIsDQogICAgICAiayI6ICI1YjllOGVmMDU5YzZiMzJlYTU5ZmMxZDMyMmQzN2YwNGFhMzBiYWU1YWE5MDAzYjgzMjFlMjFkZGIwNGUzMDAiLA0KICAgICAgIngiOiAiYTM3M2E1OWNiMDkwZjBhZjBkNDcxNWIzYWM5YTllYzI5NTg0NGZkMmFkZmM0Yzk2ODg3ZGU4MjllZjkwYzdiOCIsDQogICAgICAidiI6ICI2MzQxOGM5MGFhNDM0ZTQ0NmY3ODAxYzA1NWM1YWI0NTE0YjkyYjVhYzBkYTc5MmMzZjI4OTMyNGJhMWQwNDMyZmMwMTNlYWUzNGRjNDg4NWU0ZjViZDFjYWVhZjljZmY3ODlhMTQxMTA2ZTIyMDljNGViMGZiYTJhMDQzZDMzODU3M2FmMTRhOTA0ZjI5MjIwMDY2OGJmYmRjMmYxNjM3Zjc4ZDA4NzYzODZkYjRiMGE2YzFkMWZlN2UzYTlkN2M3NDM0YTBkYTM1ZGMyZDBjZGQ0NThhNjhlNWZlOGI1YzMyMmJlYWQ1NTJjNmVmNDM4MzM4N2U4MTE5ZTk0YmIwOWI0YWZjZDlmNDIwMTg0MTNlMzM2NTUxNTI1YWI3OTkzMzQxNzhkNzkwNDlhNTg3MzlhYjJhYmQ4YmNkZDMwZWUyZmQ1MjgyZjdlZTIwYjNkMjYwNWY5YjQyOWQ3OGY0MWYyNThmNDc4YTZlY2RiYTc5ZDA0ZTk2ZTJiMThlZWRmNTgwM2FiYTk4NzhmODgwMDliNjgwODAyNzU3NGU4M2NmZTM4OGZkMmQ0MDQ0NWZmMTM1ZjY4OWNhNTIzYWZkMDk3YThmMGU1ZTg3Mjc1YWFhZDQ1MTE5Njc1NTUzMGY0ZmQ5MTkxYjBmNjNiNGI5YWMyZGZiYjEzNWQxY2JmMyIsDQogICAgICAiQSI6ICI2MzBhY2RmZjVkMzM0NDYyZDkyYTI5ZTBiN2ZhNmUyMDAyMGYzMzMzMjkyZjZkM2E2NDBmMWM3YTc2YWQ5ZDMxNzUzMWM1Nzk3OTk1MmU1NzM2Yzg4ZGIxMThkMDYwZGMwNTM5YTgxMmI5YjBhZjNiNDAwMjM4MGE5ZjI4YWU0YTdjNDVhODk2NTQyZGUwNWZiY2Y3NmE0ZTdlMDczOWI5YTU1ZDVkNmM3YWJhNGYxZTFiNTg3MjlhNzliYzA4NGQ1ZmY1MTNlYWVjMzNjZTk3OGY1YmFkODdlNTc5YjVhOTVmYzc3MzE5OGUyMjY5N2IyZWFkYWI5ZWI5NGY4NGNkY2YxZmU5NGZmMDlmODhkNGNhNDZlOTY4YmJhNDQzZmY3MTE2NzU3MWYxOWZlYjA1Mjg2OWJkMjhkN2RhYmY5NjNiN2ZlMzk5YTFmNzBlN2UwOGQwMGUxYTM3NzhlZDFkZGRjMzMyNWRkMDllMDVkMzFlNzc0ZDFmZDI5NWM0YWJmYmM2MTM0NDYyMzIwMDRkNjdjYjAzZDZhMDM0ZDJjZTZjYTBhNTQ0YTBmZjViNDM0YjRiNDI2N2ZhNmM2ZDcyYWNiYmRhMmVmYzFlZjFkMWZlMzZkMzUzODJiMDg5YWJlNTU2ODYyYWVjMzViMjlkM2QwY2RmMzU5YTljZmVkMyIsDQogICAgICAiQiI6ICI1ZjAxNmI2NmU1ZGFiNTQ4MDEzYTQ2MDdjMDJhYjE1NjlmNThkOTRhYTY3MGJkNjhiY2U5YmZkYjc4MDdjNDQ0ZGFiZmJjMTM4YzVlNWFiOWRlYzVkZjM4YTFjNWU1OTUyYjYwYzMyMDg3ZWU1MDhhNmE0YTE4YzQ5ZDdjNjM4NzQ2ZDcyZGE4OTQyMTA0NTJhMmE1NjYzNTk1MzBjMWRjMTM1Y2NiNGEzNWYxODBhNzQwZjA0MmUxMmZmOGFiYTQzNTU4ZDU2NzgxZGUzZWI3MWI2YjJkMWJkYTc3MjRkMmFjZTZlYTA5YTE0NDIwNmM5ZDU4NWU3Y2ZkNDg0OTg1OWNiOTk5MGRlYmFmNWVhY2E1ZjZkYTIyZTkyN2QxMDVhNTkzOGYxOGExZDc3OTMyNTNlNDZmNDJmMDIxMDkwMTZkNTg2Y2NkOGY5YzYyMDU2NGU3NzIzNjkxMDBmODQzZTM4YjlkMTQxMTZiOWIwY2U3YTYzN2ZjZDM1ZTAyNjFjNTkzNGEyNjYyOGY4NzdkYzhmMjM1NTc1NTI1YmE1NzRhYjhlMmUwNTUwYTlkNTdjNDY3MWM4OTRhZmQxYmI4ZmVlMjRkYjc4MGVhNDQ3OGJjM2M2MjE5NDFlNmQwYzYzY2MxMjVlNzQyNWM4ZmRkYzc2ZWNjYmQ0OTlmYWJkMiIsDQogICAgICAidSI6ICIyNjJlODc0MDNmODgxZjNjNGFkZjI0YTBiZWYxNzk5OTI0YmQ2NDViMzJjYjdhZWU4ZGY1ODQ1N2ZkNmZlOWQzIiwNCiAgICAgICJTIjogIjIwMzE4ZTg5YWVmYjEwNmZhMmQ2OGI0YTgyY2JkNmM4YTFhMWYyOWU1MWUzYTA0OWU0N2VkYjFmYjgzOGE5MjQ4OTFkNDI2MjEyZmY0YjY0NTU1ZmIxYzUwM2M0ZWE3ZDE0MTZkYjEzYjU1MmNlMTc0ZThkOWZiYjdlNzFiY2QxYzlhYTgwNDZmZWVlYTZhMDQ3NzkwNTNmNzA5M2I2MzRmZmRkMTM1NjM5ZDIyMDU1NTIyY2M2MzU0MDlhZDE4MDJlNDgxNDY5M2RiZjdmYjk1NzJlMWZmYzAxNzUxNzlmMjE3MjIxMWQyOWY2YTQyNzgxZjFiZGE2NWU2ZGY3NzJhOGQ5ZTcyYTdmMWFkNmFmYTgxOWVkZDAwNTIzZWI1MTFiMGRlZDM0ZmQ5ODJkMDJiNzljYTk5ODFiZGQ1NGRmNmRjYmJjNTBhZTAxZDVhZmYxMTZkYjYzN2Q4MGVkYzc4N2FiZjEwM2MzYWUxMjBkMWZmZTZjOGZmNmIzNTFlMTU4MTc5YjUxNTA5MThkYWZkZTFjNWJhZTc2NTk4NWRlNGRiODIwZjIxZmRkYWNlZDgyMjZhZGViNzIxNzY5ODRjNTU2MWNiNTU4ODJhMTE4OTFjZjE2MTI2ZTQ2M2ZiZTA2NzBhMjlkYmZhYmZjZDg5ZDU3MDBhZTk5M2U2YWZiIiwNCiAgICAgICJLIjogIjU3Y2Q2NGYxYzIzNTk0ZTM5NDFmNmU2YzQyMWZjNDU1NWI5YWVjNjg0NDNhZjZiNWIyMmNiNWYxZDZiNWVjYTciLA0KICAgICAgIk0xIjogImRkNzZkNTViNTA1NzIxZjQzZjljNmJiYWRiZmE0MWUwYTA1NWQzNzYzZDBhZmUzMGY0YWMyMjg0NzdmZGM3ZmQiLA0KICAgICAgIk0yIjogIjVlNzc3ZmQ0NzBmMWEyYTIzZjM1MzMwNGQ5Y2FhMDIwZTIxMzdjNmJkYzcyNGU1ZGIzY2NiYzhlNTEzNjVjOTUiLA0KICAgICAgInNwZCI6ICIxNmFjYWRiYjljYjhiYTUyNDUyNTY1OGQwNzY5ZDhjMmM0MDhjNmRkZTgwZjA2NzlmNTM1MjQzMjEzN2YwMDczZmUxZjUzYzI5MzM1M2UxZTU4OWRmOWZiYWNhZmQzMzFiMDg3ZDc0ODhmZWYyMjdjN2ZmYWIxMDBjYWRkMTk3MGMzYzJjN2ViY2MwYWQyNmQ3NDE0Mjk5N2I4ZWRiMWFhZmJjOTg5OGQwYjE5MGFiNDA4ZTRjYjExYTI2NDkzZmI4MGRlYjU0ZWMxMjlmOTRlNjBkY2U2ZmUyMTY0N2VkZmMwYzlhOWZjODI2NDRlNGQzNjBmMzQ4YTQ4N2Y5ZjgyYTM0NjExZTJlZDhkNTdhNWUzMjMyNjM0MmE1Njc1ZTAzODMxODI1ZjY3ZWQ1ODkzNWZjNzMxMzQ5YzMxYjI4MGZmZGIzNjkyNjJjNmRjMjdkYzc5MTZkYjkzMmI1MTkxYjFjNDNhMTZjMWUwZjI4NzI1MWI3YjU2MTRhMzRkMTc2YmViYWEzMzM1ZjkzYzExOTRmYjJkMDA4ODlkMzljMzg4NTgyYjQ3NDZjZGQwOGJlMTQyZGM0NWEyZDc1MTViMWVlZDg4MDk4OWNhZTk0ODM4YWU1NjJiNzk3MWM3OGI4MzhlYmRmMTBmYjAxYjVlNTM5YzEwZjI2NGJmODg1MmQzZTVkNmM4MGI0ZDkyNzBmOGYzZDAwZmMwZThjMTk5NGM0ODU3MDkwZGNiMjQwMTM4NDI1NWQ4MzRhZGUyMTcwZDhhNmVjZjExZGY3ZWNlOGM4NjFjMWM4MmFkMDc5ZmI0NDdiNGY5MDBlNmE3ZTIwMmE5NDg5NzM5Y2UyY2Y2MjVmNzRkMzVmMDVjMmYxYzJmOTk2NTc1YTNjOGFiNjVlNjA0YjEzYjY5OWIzOTEyMjM3N2QxMmQ2Mjc1MGZkM2E0OTYzNmE3MjIxZThjZDczZGZkODBjMDc1NjIzZGY5NmM5NTg5MWM3ZDdjN2I1Y2RkMzJhYTZlNTE3MzM1M2Y4ZjExODkyYjQ0ZWU2NmE3YTVhZjcxNzNiZDNhZjFlM2QzYTZhMjI5NzMzY2UwNDk3NTliYmUyZTA0NTA5MDIyOTdhOTBmOTY3NjBhZjRmMmU4YzU4ZjM3ODQ0MzNkMzUyMWYzOWRmMDE1N2Q4MzcxYmQ2NmMyZjA5OWE5NDk5YSIsDQogICAgICAic2MiOiAiNzA3NTYyNmM2OTYzMmQ3MzYzIiwNCiAgICAgICJucCI6ICIwMjI2NTFmNjk4NWRiMmIzNmJkZjdiOGNhZDRkOWZmZDdlMWNiMDkyZTFiYTNmNTllMmM5MTBlN2U2MDA4ZWYzIiwNCiAgICAgICJzayI6ICIwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjEwMTExMjEzMTQxNTE2MTcxODE5MWExYjFjMWQxZTFmIiwNCiAgICAgICJjb29raWUiOiAiNzA3NTYyNmM2OTYzMmQ2ZjcwNjE3MTc1NjUyZDYzNmY2ZjZiNjk2NSIsDQogICAgICAiZHNpZCI6ICIxMjM0NTY3ODkiLA0KICAgICAgImlkbXMiOiAicHVibGljLWZpeHR1cmUtaWRtcyIsDQogICAgICAiY2hlY2tzdW0iOiAiYzZhMzEzZDY3ZjhkZjdmZWE2NTk4NWE5NTE0MWUyM2YxZjU1ZjNhZDE2ODdhOGY3ZTkyYjgxYzVlNjAxNmMwNiIsDQogICAgICAiZW5jcnlwdGVkVG9rZW4iOiAiNTg1OTVhMDAwMTAyMDMwNDA1MDYwNzA4MDkwYTBiMGMwZDBlMGY1YjUzZDgxYjU1YzQzYzRkZWY4Y2IyNDYzYjk5MGU4MjdhODM0OTgxMDJlM2IwMmMyMDU3MjNiMmIzZGI5OTllMmU1MmIxZDY0MjdlZGFmMmMzNmQ3OTE1YjU2ZmI1Mzc3NzAwMjYzM2ZmNjA2MGQxZjVmZmVhNTJhMjBiNjBhYjNjYzQzYWQ0YjAwOGUyYjAxMDE1ZjQ3MjUyMmYxOWZkODhkNzI2OWRjMDBkNjBhZGMzMjAwMGRkZjVkNjdkNjAyOGRmZjc2MzNmNzk2YjYyNWY5NmNjYjQzYjQyMWJkMWEwMDFhMWYzNDcwMTI2MGZlNzZmY2U3NTQ3M2IzYjhkZDU1ZjI5YzZlZjMxYWRiZWQ5ZDYyNWZjY2IwZjk0YzlmMzAyMTFkZGI4NmJjZWY4ODBkOTY1OWIwNjc5ZmQ0ZTAwYWNlYjdjMjBkYmM4NmY5ODAwM2QzMjIwNTRhNDlkYTNkZGJhMzJjZTg3ZDM1YjM5N2Y1ZWE1ZjY1NjViYTEwZjg3MTVhODUzYzdlNmZhNGE1ZTEzODljNGNlYmRhM2M0ZjRjOWFmMjVkNzU1YWIyNmIwZDdlYjgzMGEyNTlmYjQzNjQxMTNhZjIwYTM2NjRlYjc3MDQzOGM5MjRlODM2YzI1YmEyYWNiNmYyYzQyZjQ4MmEzOTVlODU1OWU3ODBmYjk1OTIzODJjYTc2ZDNkYTY1OWIwNWZlN2RjOTM1MjdhYTRkODlmNzc0YTZlNjlhZGZiYTBlNDZjYWQxMjI1Y2Y2MDJhMDY2NWQ0ODZhYzFkN2Y0OGI4ZWVlMGY0MjRlM2E0ZDc0NTM4NjY5MDkwZjIyYWFmODNiY2ZjNTY0NmE2ODkyYTdkMjVkZjc2YjM3MGM2MGE5MDY3MmY1YmFlZDczMzU0N2NiZTQ0ZTI5ZGMyNTBhMTFhZjAwNTdmZTYzMzQyNDdhMDcxZjdmOTE0NTUwZmIwZWZhOWU3N2E2NWFhZTZmNDJlNWE2ZTBkZjMyOWJlYTAyZjYyMWYyMDAwYzY5YmI2MGJhZTJjMTVmMmE5ODMyMzMxMzY2ZmRlYTRjY2UyZTIwMzZkYTVjM2NkMGJjMWMwOTBjY2Y5ZiIsDQogICAgICAidG9rZW4iOiAicHVibGljLWZpeHR1cmUteGNvZGUtdG9rZW4iLA0KICAgICAgImV4cGlyeU1pbGxpc2Vjb25kcyI6IDE3OTI1NDQ0MDAwMDANCiAgICB9LA0KICAgIHsNCiAgICAgICJwcm90b2NvbCI6ICJzMmtfZm8iLA0KICAgICAgInVzZXJuYW1lIjogImZpeHR1cmVAZXhhbXBsZS5pbnZhbGlkIiwNCiAgICAgICJwYXNzd29yZCI6ICJwdWJsaWMtZml4dHVyZS1wYXNzd29yZCIsDQogICAgICAic2FsdCI6ICIwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZiIsDQogICAgICAicHJpdmF0ZUEiOiAiMDEwMjAzMDQwNTA2MDcwODA5MGEwYjBjMGQwZTBmMTAxMTEyMTMxNDE1MTYxNzE4MTkxYTFiMWMxZDFlMWYyMCIsDQogICAgICAicHJpdmF0ZUIiOiAiMjEyMjIzMjQyNTI2MjcyODI5MmEyYjJjMmQyZTJmMzAzMTMyMzMzNDM1MzYzNzM4MzkzYTNiM2MzZDNlM2Y0MCIsDQogICAgICAiaXRlcmF0aW9ucyI6IDEwMDAsDQogICAgICAicGFzc3dvcmRLZXkiOiAiOTAzNTkyNjk3YmUwMzcwYTlmZmY2MDNkYzg1ZDM0NTVmMjI0NWMxOWJkYTY0NTgzM2RhMjkxNDAyZDdmMmVhNyIsDQogICAgICAiZ3JvdXBOIjogImFjNmJkYjQxMzI0YTlhOWJmMTY2ZGU1ZTEzODk1ODJmYWY3MmI2NjUxOTg3ZWUwN2ZjMzE5Mjk0M2RiNTYwNTBhMzczMjljYmI0YTA5OWVkODE5M2UwNzU3NzY3YTEzZGQ1MjMxMmFiNGIwMzMxMGRjZDdmNDhhOWRhMDRmZDUwZTgwODM5NjllZGI3NjdiMGNmNjA5NTE3OWExNjNhYjM2NjFhMDVmYmQ1ZmFhYWU4MjkxOGE5OTYyZjBiOTNiODU1Zjk3OTkzZWM5NzVlZWFhODBkNzQwYWRiZjRmZjc0NzM1OWQwNDFkNWMzM2VhNzFkMjgxZTQ0NmIxNDc3M2JjYTk3YjQzYTIzZmI4MDE2NzZiZDIwN2E0MzZjNjQ4MWYxZDJiOTA3ODcxNzQ2MWE1YjlkMzJlNjg4Zjg3NzQ4NTQ0NTIzYjUyNGIwZDU3ZDVlYTc3YTI3NzVkMmVjZmEwMzJjZmJkYmY1MmZiMzc4NjE2MDI3OTAwNGU1N2FlNmFmODc0ZTczMDNjZTUzMjk5Y2NjMDQxYzdiYzMwOGQ4MmE1Njk4ZjNhOGQwYzM4MjcxYWUzNWY4ZTlkYmZiYjY5NGI1YzgwM2Q4OWY3YWU0MzVkZTIzNmQ1MjVmNTQ3NTliNjVlMzcyZmNkNjhlZjIwZmE3MTExZjllNGFmZjczIiwNCiAgICAgICJuIjogImFjNmJkYjQxMzI0YTlhOWJmMTY2ZGU1ZTEzODk1ODJmYWY3MmI2NjUxOTg3ZWUwN2ZjMzE5Mjk0M2RiNTYwNTBhMzczMjljYmI0YTA5OWVkODE5M2UwNzU3NzY3YTEzZGQ1MjMxMmFiNGIwMzMxMGRjZDdmNDhhOWRhMDRmZDUwZTgwODM5NjllZGI3NjdiMGNmNjA5NTE3OWExNjNhYjM2NjFhMDVmYmQ1ZmFhYWU4MjkxOGE5OTYyZjBiOTNiODU1Zjk3OTkzZWM5NzVlZWFhODBkNzQwYWRiZjRmZjc0NzM1OWQwNDFkNWMzM2VhNzFkMjgxZTQ0NmIxNDc3M2JjYTk3YjQzYTIzZmI4MDE2NzZiZDIwN2E0MzZjNjQ4MWYxZDJiOTA3ODcxNzQ2MWE1YjlkMzJlNjg4Zjg3NzQ4NTQ0NTIzYjUyNGIwZDU3ZDVlYTc3YTI3NzVkMmVjZmEwMzJjZmJkYmY1MmZiMzc4NjE2MDI3OTAwNGU1N2FlNmFmODc0ZTczMDNjZTUzMjk5Y2NjMDQxYzdiYzMwOGQ4MmE1Njk4ZjNhOGQwYzM4MjcxYWUzNWY4ZTlkYmZiYjY5NGI1YzgwM2Q4OWY3YWU0MzVkZTIzNmQ1MjVmNTQ3NTliNjVlMzcyZmNkNjhlZjIwZmE3MTExZjllNGFmZjczIiwNCiAgICAgICJrIjogIjViOWU4ZWYwNTljNmIzMmVhNTlmYzFkMzIyZDM3ZjA0YWEzMGJhZTVhYTkwMDNiODMyMWUyMWRkYjA0ZTMwMCIsDQogICAgICAieCI6ICIyYzk1MWI1NWI4ZjJhMzdiNzFhN2NiZmY3NGJkMmFjODBjOTcyZjM2MTc5YWJkYTdlNjliOTRjMmM0NDkxNWQ4IiwNCiAgICAgICJ2IjogIjI1YWI2ODlkODgyNWY2NjI5OGJmN2RmYjRjYjc3NGMxZTU4ZDk1ODBmMmRjNTdmODMyZTliOGM2NDZhMmZhY2Q0Y2IyMmE1ZGQwZWI3ODMwZDliZjdhMWJjMGIxNThkYTEwNWYzY2E5ZGI5OTc0ODFiMjZlOGViZmMwMDk0NWU0OThkZGQ0ZGI3MDE2MTA0ZThhOTU3OTY2MzNkOGUwMDQyNDYyNGJhOTMyYzQ3ZGNiNjAxYTYyZGYzY2I1Mjk0Y2IyZTA0ZTVmNTQ4ZGQ2ZDkyOWU3ZDk5Yzc3M2ZkNWU3NjFmZTNlOGE3MGNhMGYyOTA4ZjM0ZDIzOTgzOWJlYTg3YWFhYThlMGVhNGQ4YzUyMjAyYzcyZGRiMGVjODg2OGVmOGZhMGRhYzMzYjc3YWI2OWIwOTA2MThhNTY3N2U1NGYzNDI0MmU5MGY4NDM5ZmI4YmU3MmFmYjUyYzI5YWY0OTYwN2RiMjBjZWE4YTcxYzgxZjIwZjIwYTBlNTE2YWQwMDZjYmY4MTg0YjAzNGRmZDdiM2I1MGE4ODc1MTJiNmZiNDk4OGRkOGRkMDY1NzI2ODEzZTRiMzlhNTYzYzAxYjhhNTU3N2QzOTg4NjNhNzlmNDE3NjExNmVkMDRiYjc2YmY1NmU3MGViZjA1MTNlNTc2ZTkyMjg0NDU5YmYyIiwNCiAgICAgICJBIjogIjYzMGFjZGZmNWQzMzQ0NjJkOTJhMjllMGI3ZmE2ZTIwMDIwZjMzMzMyOTJmNmQzYTY0MGYxYzdhNzZhZDlkMzE3NTMxYzU3OTc5OTUyZTU3MzZjODhkYjExOGQwNjBkYzA1MzlhODEyYjliMGFmM2I0MDAyMzgwYTlmMjhhZTRhN2M0NWE4OTY1NDJkZTA1ZmJjZjc2YTRlN2UwNzM5YjlhNTVkNWQ2YzdhYmE0ZjFlMWI1ODcyOWE3OWJjMDg0ZDVmZjUxM2VhZWMzM2NlOTc4ZjViYWQ4N2U1NzliNWE5NWZjNzczMTk4ZTIyNjk3YjJlYWRhYjllYjk0Zjg0Y2RjZjFmZTk0ZmYwOWY4OGQ0Y2E0NmU5NjhiYmE0NDNmZjcxMTY3NTcxZjE5ZmViMDUyODY5YmQyOGQ3ZGFiZjk2M2I3ZmUzOTlhMWY3MGU3ZTA4ZDAwZTFhMzc3OGVkMWRkZGMzMzI1ZGQwOWUwNWQzMWU3NzRkMWZkMjk1YzRhYmZiYzYxMzQ0NjIzMjAwNGQ2N2NiMDNkNmEwMzRkMmNlNmNhMGE1NDRhMGZmNWI0MzRiNGI0MjY3ZmE2YzZkNzJhY2JiZGEyZWZjMWVmMWQxZmUzNmQzNTM4MmIwODlhYmU1NTY4NjJhZWMzNWIyOWQzZDBjZGYzNTlhOWNmZWQzIiwNCiAgICAgICJCIjogIjg3ZmY1ZWIyOWE4NDFiYjU3Mzc4Y2Q5ZDk0MGJjNGE5ZDYyYzIyN2QzNWY5ZGU4YTVlYTk0ZWNhNzhmN2E1Y2YwZjAzMTZmOWY1NjE1ZmE3NDU5ZTA0MDg2ZWQ2YzlhNTgxOGQzYmEwOWYzMzgzZGNmM2QzMzE1MDRhNWIwMTJmOWJhYWYxOGIzOWUyOTcyZmIzMGY0NTI4OTZhMzk0Y2YyMTZlYmMwNWZlNTdiODRkYzM0YTIyNTliNzIyNDdkZDgwMDZiNjFiYTgwMzNkMDBmNzMwMzJjMzVmZGE0MzBiYWZmYTk3YTMzNWUzMzZjN2Q4MzNiOTNlYTJiMjVjOTIzM2I5NjBkNGY2ZmRkYjc2OTg2OWFjODlmZjIwN2Q0YTg1MzYwMTFiMjVhMjgzYzljYTg1OTQzMzEzMjk4YzNjMjU4MGJkYzgyOTYxMjU3NzE4MGI1ZWIyNWExOWM4ZTg0ZTc5MTg3YjY5ZWE0NDVlZWY4Y2FlNDQ0ZWEyNzFlN2I2MmNkMjVmMmExYTY0NDZkZDVkYzY5MDBhNzk5OTcwNDU5ZTAzMjdmMjI1NWE0MzgzOWZlZjc1OWI4MjMwY2UyMmJjY2JjODAzMTNkZWMwN2IyMzY0MjIyODY2NTA3ZDU2ZTg2YTlkNzc1ZDQ5ZjhiYjg2MGIyNzYzMGY0MDBjIiwNCiAgICAgICJ1IjogImY2MzA2Mzg0YzJmMDYwYjI2MWQzNTU3NGZlNzY5NjI4N2JjMTA5MDhmODlmMDJjYTAzMGUxNTc2NzJlN2RkN2QiLA0KICAgICAgIlMiOiAiNjY0NTQ2MTdjMTNhM2QxZDg0Mzk1ZTdjMDk4ZjZmZmZhNWJjOGI1YzE4OGQ3M2JmNDc5ZThiZWMyOTFlOTE2MzA1OTNjZTVkYmU2NTI1MDc4MmM0ZDA4YmFjMGE4MWE4NTc0ZWY1NjBkY2U4NzVlNmUyYWZiM2U4OGIyMTg0NjM0ZWMzNjllNzY5NTY1NWU2MDg4YWFiNDQwZTc5NTliMjMyODNmN2E5YmY3NmNlM2QxNDFhZTdiYjQ5MjA2MTU4MDc0ZGZiNGYxOWEwNjYyZmNlOGEzNDhmOTRhOTE1ZTVjZGQ1MzhkZmEyYzMyZjU0MzJlNTYzZjA2YzUxYWY4N2YyOWM5YTk1ZmMwOGU2ODhiZDE0YTE0OGI4YzRlNGM0MmVmY2ZkYzk3YjdmMDg0ZWYwNzljNzUzMGE1ZDA2N2I1Y2U3MzA3ZDgyNTVmNTVmYmU2MjMxN2UyM2Q0YmM1NDQzZjY1NDI4NTY4NGZlYzMzYTVlZGVkYWVhOTk3NTM0YWM4ZTM4MDhkMjY3ZjUyM2Q0NGRmNjYwNzNjNGUxNWI4MWYwZDE5OTMxNzA0MjZhMTIzZjY3NjkwYzFiMWIwY2FhN2JhM2ZiMWRkNWJhZmJhNmM3M2NmMjQ4OTBkNzdjYTVlZGU1YmUzNGY0MjRiZjc1NTk3MzgzNGM5MGQxODMiLA0KICAgICAgIksiOiAiNjVmNDRjZTg0ZjcxYzQ3MmJkNGRkYTJjNmE4MDhlMDY4ZjY1MTAyYWQ4ZjI1NWIwYTAxZmVmMGZiNjRmNGVmYyIsDQogICAgICAiTTEiOiAiMTU2NzY3MTJjYmI5NmQ0NTViZWNmM2NhMTc1NjU1NmIwMzkyMGNjZGM4MGFlNDAyNWNmM2YzNzcyMjQ4M2JlMiIsDQogICAgICAiTTIiOiAiMDhhY2U3YTA3MThjZjc0NjRmZmMyOGQ4OTQyNDQ1MTdlZjkwZTZhZjFjMDhiYmQyYjIzMTY3MmFiYjc1ODM2ZCIsDQogICAgICAic3BkIjogImU3MmFlNTEzOTQ2MWYwODBjYjVkNzMxMDZlNWQxNTI5NjZmZWZjZTE1NzliYTQxMTIzNWU5YTgxYWI3MWVmMTI0N2Y1OWQyNTkzMWVmMmQ0NWY4YWI1MmVlMTI0NzU4YTIxMzc1ODIyMDhkZTQyY2RkYmRhMjA2NGM0NDI0NTcyMzY3ZDhiYThkYWYzYTA3NjhiMTIzYjRmNTFmZDcyNjU1ZjUyMWMxMmFmMzQ1MWNlOTMwOTMzNWI5NTEyMjU3NDJkNWU0MmI2Yjg3OWQwODRjNTAxZjY0YjQxYzdkMjM4MmY3ZDI1NjgyNmU3MmVlYWQzZDk1OWZmZDhjZGU4MjFkYzcxOWRlOWIxZTkzNDdhODRiZWI0NTMyMTYxODdiM2QzNzFmODA5ZTkxNmNiMjBhNjc0ZGY3ZDRkNGQ5ZmZhYTdjNzRkMDQ2NzM4NmQ3YThiMDcyOGQ5ZDMyMTg2NmE4NmNlMDY2ZTQ5OTEyZjAwY2RlOTQ3MDY0Nzg5NmQ2YWM2ZjJlZjExOTJiMTM5NjkwOTM2Y2EwMjUwMTc2YWVlNGIzYjZmMjI3MjFhOWY4ODA4ZjdiZGU4ZjNlYTBiNTA4ZTY0YmFiYjg5MTczMjc4MGZlZWNhYzIwOWZiZTgxNWU3YjFkZWMxYjQwYzQxMTEyYzIzYzZkYmRiZTQ4YWUyZjFmYzcwZTBhMDM2MDA4OTE4YjJjNDA3ODE1MGIwOTJiNDQ3NWY3NTE1YjI4MjkxNjYzMzkwNThiM2QyOWY0YWQ2NTQwZjUwNWViMTAxOGQ3ZGU1ZjIyYmQyYmZjODk4ZjMyNzU4NWFlYWUzYTFmMGNjZjFlZDFlOWNmOGE4Y2ZjNDQ2OTg4YzQ0YjA1YjFhNDVlOGQwNzI0NzIyYTk5ZTRlMGVjMmQ0NzBhN2RiNjc4YmE2ZWFiZjdkNzQ5YTM5YjI5ZWRjMWQ1NTJjZDlhM2RiMjYzZTM2NDc3MWIxNTQ4MTAwN2E2Zjc0NmRlY2Y1ZDI4NGIzMmVkYzc5YTBhNzU1NDRkYWI5ZTNlMDdkNGIzZjkyNzQ1ZjQ1ZWFlNTllZTczY2NjNTY5MmJlNjFmYTA0NmY0ZWE4MTkxMGY3NjNkMmM2ZGNjOTczYjUzYTRiYmFkNWNlMDA0MDM1MzA5YjJhZmNhYTY0MTA3OTNjZGZmMDdiZDk5ZWQxNzg5MTlmIiwNCiAgICAgICJzYyI6ICI3MDc1NjI2YzY5NjMyZDczNjMiLA0KICAgICAgIm5wIjogIjkzYjIxMDQ5NmQxNjY3ZWUyYWZhNmU5YWNiYTY5MDM0NDE5ZWNhZDc3NWNmNmVlMDczNmM3ZDdmNjRmODljMTciLA0KICAgICAgInNrIjogIjAwMDEwMjAzMDQwNTA2MDcwODA5MGEwYjBjMGQwZTBmMTAxMTEyMTMxNDE1MTYxNzE4MTkxYTFiMWMxZDFlMWYiLA0KICAgICAgImNvb2tpZSI6ICI3MDc1NjI2YzY5NjMyZDZmNzA2MTcxNzU2NTJkNjM2ZjZmNmI2OTY1IiwNCiAgICAgICJkc2lkIjogIjEyMzQ1Njc4OSIsDQogICAgICAiaWRtcyI6ICJwdWJsaWMtZml4dHVyZS1pZG1zIiwNCiAgICAgICJjaGVja3N1bSI6ICJjNmEzMTNkNjdmOGRmN2ZlYTY1OTg1YTk1MTQxZTIzZjFmNTVmM2FkMTY4N2E4ZjdlOTJiODFjNWU2MDE2YzA2IiwNCiAgICAgICJlbmNyeXB0ZWRUb2tlbiI6ICI1ODU5NWEwMDAxMDIwMzA0MDUwNjA3MDgwOTBhMGIwYzBkMGUwZjViNTNkODFiNTVjNDNjNGRlZjhjYjI0NjNiOTkwZTgyN2E4MzQ5ODEwMmUzYjAyYzIwNTcyM2IyYjNkYjk5OWUyZTUyYjFkNjQyN2VkYWYyYzM2ZDc5MTViNTZmYjUzNzc3MDAyNjMzZmY2MDYwZDFmNWZmZWE1MmEyMGI2MGFiM2NjNDNhZDRiMDA4ZTJiMDEwMTVmNDcyNTIyZjE5ZmQ4OGQ3MjY5ZGMwMGQ2MGFkYzMyMDAwZGRmNWQ2N2Q2MDI4ZGZmNzYzM2Y3OTZiNjI1Zjk2Y2NiNDNiNDIxYmQxYTAwMWExZjM0NzAxMjYwZmU3NmZjZTc1NDczYjNiOGRkNTVmMjljNmVmMzFhZGJlZDlkNjI1ZmNjYjBmOTRjOWYzMDIxMWRkYjg2YmNlZjg4MGQ5NjU5YjA2NzlmZDRlMDBhY2ViN2MyMGRiYzg2Zjk4MDAzZDMyMjA1NGE0OWRhM2RkYmEzMmNlODdkMzViMzk3ZjVlYTVmNjU2NWJhMTBmODcxNWE4NTNjN2U2ZmE0YTVlMTM4OWM0Y2ViZGEzYzRmNGM5YWYyNWQ3NTVhYjI2YjBkN2ViODMwYTI1OWZiNDM2NDExM2FmMjBhMzY2NGViNzcwNDM4YzkyNGU4MzZjMjViYTJhY2I2ZjJjNDJmNDgyYTM5NWU4NTU5ZTc4MGZiOTU5MjM4MmNhNzZkM2RhNjU5YjA1ZmU3ZGM5MzUyN2FhNGQ4OWY3NzRhNmU2OWFkZmJhMGU0NmNhZDEyMjVjZjYwMmEwNjY1ZDQ4NmFjMWQ3ZjQ4YjhlZWUwZjQyNGUzYTRkNzQ1Mzg2NjkwOTBmMjJhYWY4M2JjZmM1NjQ2YTY4OTJhN2QyNWRmNzZiMzcwYzYwYTkwNjcyZjViYWVkNzMzNTQ3Y2JlNDRlMjlkYzI1MGExMWFmMDA1N2ZlNjMzNDI0N2EwNzFmN2Y5MTQ1NTBmYjBlZmE5ZTc3YTY1YWFlNmY0MmU1YTZlMGRmMzI5YmVhMDJmNjIxZjIwMDBjNjliYjYwYmFlMmMxNWYyYTk4MzIzMzEzNjZmZGVhNGNjZTJlMjAzNmRhNWMzY2QwYmMxYzA5MGNjZjlmIiwNCiAgICAgICJ0b2tlbiI6ICJwdWJsaWMtZml4dHVyZS14Y29kZS10b2tlbiIsDQogICAgICAiZXhwaXJ5TWlsbGlzZWNvbmRzIjogMTc5MjU0NDQwMDAwMA0KICAgIH0NCiAgXSwNCiAgImluZGVwZW5kZW5jZSI6ICJQeXRob24gaGFzaGxpYiBidWlsdGluIHBvdyBwbHVzIGNyeXB0b2dyYXBoeTsgbm8gU3dpZnQgaW1wbGVtZW50YXRpb24gaW1wb3J0ZWQvZXhlY3V0ZWQiLA0KICAiY3J5cHRvZ3JhcGh5VmVyc2lvbiI6ICI0Ny4wLjAiLA0KICAiYWN0dWFsUHl0aG9uUmVmZXJlbmNlUnVucyI6IDQsDQogICJwcmV2aW91c0ZhaWx1cmVzUHJlc2VydmVkIjogdHJ1ZSwNCiAgInByZXZpb3VzUGFzc1JlZ2VuZXJhdGlvblJlYXNvbiI6ICJCaW5kIHRva2VuIGV4cGlyeSB0byB0aGUgZXhpc3Rpbmcgb3JpZ2luYWwgaWRlbnRpdHkgZml4dHVyZSBjbG9jayByYXRoZXIgdGhhbiB5ZWFyMjEwMCIsDQogICJTd2lmdFNES0V4ZWN1dGlvbnMiOiAwLA0KICAiQXBwbGVSZXF1ZXN0cyI6IDANCn0NCg=="
    }
}
