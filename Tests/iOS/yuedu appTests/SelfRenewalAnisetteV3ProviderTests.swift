import CryptoKit
import Darwin
import Foundation
import Testing
@testable import yuedu_app

/// Owned protocol state-machine fixtures only. The fixture strings below are
/// not real anisette, Apple authentication, TLS or signing-authority evidence.
@Suite("Explicit anisette v3 registration and shared transport boundaries", .serialized)
struct SelfRenewalAnisetteV3ProviderTests {
    typealias Provider = SelfRenewalAnisetteV3Provider
    private static let identifier = Data((0..<16).map(UInt8.init))
    private static let blob = Data("owned registration fixture".utf8)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("full wire sequence commits before get_headers and a reopened provider reuses the same registration")
    func persistsSuccessBeforeHeadersAndReopensWithoutProvisioning() async throws {
        let storage = Storage(); let peer = Peer(storage: storage)
        let configuration = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: "https://owned-fixture.invalid")!)
        let namespace = UUID()
        let provider = try Provider(configuration: configuration, namespaceID: namespace, transport: peer,
            storage: storage, clock: { Self.now }, randomIdentifier: { Self.identifier })
        let candidate = try await provider.freshAnisette()
        #expect(candidate.machineID == "owned-machine-fixture" && candidate.oneTimePassword == "owned-otp-fixture")
        #expect(candidate.localUserID == SHA256.hash(data: Self.identifier).map { String(format: "%02x", $0) }.joined())
        #expect(candidate.deviceID == "00010203-0405-0607-0809-0a0b0c0d0e0f")
        #expect(candidate.deviceSerialNumber == "0") // upstream protocol marker, not a measured serial
        #expect(try await provider.observeRegistration()?.phase == .provisioned)
        let sent = await peer.socket.sent
        let decoded = try sent.map { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
        #expect(decoded.count == 3)
        #expect(decoded[0] == ["identifier": Self.identifier.base64EncodedString()])
        #expect(decoded[1] == ["spim": Data("owned spim".utf8).base64EncodedString()])
        #expect(Set(decoded[2]!.keys) == Set(["ptm", "tk"]))
        #expect(await peer.headersObservedClosedSocket)
        #expect(await peer.headersObservedCommittedRegistration)
        #expect(await peer.openCount == 1)
        let registration = storage.registration
        let reopened = try Provider(configuration: configuration, namespaceID: namespace, transport: peer,
            storage: storage, clock: { Self.now }, randomIdentifier: { throw FixtureFailure.unexpected })
        _ = try await reopened.freshAnisette()
        #expect(await peer.openCount == 1)
        #expect(storage.registration == registration)
        #expect(storage.account == nil) // no Apple credential record was created
    }

    @Test("interrupted provisioning retains durable unknown and cannot automatically replay or rotate its ID")
    func interruptedProvisioningRequiresExplicitRecovery() async throws {
        let storage = Storage(); let peer = Peer(interrupt: true)
        let configuration = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: "https://owned-fixture.invalid")!)
        let namespace = UUID()
        let provider = try Provider(configuration: configuration, namespaceID: namespace, transport: peer,
            storage: storage, clock: { Self.now }, randomIdentifier: { Self.identifier })
        do { _ = try await provider.freshAnisette(); Issue.record("interrupted fixture accepted") }
        catch FixtureFailure.interrupted { }
        #expect(try await provider.observeRegistration()?.phase == .provisioningOutcomeUnknown)
        let durable = storage.registration
        let count = await peer.requestCount
        let reopened = try Provider(configuration: configuration, namespaceID: namespace, transport: peer,
            storage: storage, randomIdentifier: { throw FixtureFailure.unexpected })
        do { _ = try await reopened.freshAnisette(); Issue.record("unknown provisioning replayed") }
        catch let failure as Provider.Failure { #expect(failure == .provisioningOutcomeUnknown) }
        #expect(await peer.requestCount == count)
        #expect(await peer.openCount == 1)
        #expect(storage.registration == durable)
    }

    @Test("get_headers rejection preserves registration and does not issue another provisioning session")
    func rejectedRegistrationNeverReprovisions() async throws {
        let storage = Storage(); let peer = Peer()
        let configuration = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: "https://owned-fixture.invalid")!)
        let provider = try Provider(configuration: configuration, namespaceID: UUID(), transport: peer,
            storage: storage, clock: { Self.now }, randomIdentifier: { Self.identifier })
        _ = try await provider.freshAnisette()
        let durable = storage.registration
        await peer.rejectHeaders()
        do { _ = try await provider.freshAnisette(); Issue.record("registration rejection ignored") }
        catch let failure as Provider.Failure { #expect(failure == .registrationRejected) }
        #expect(await peer.openCount == 1)
        #expect(storage.registration == durable)
    }

    @Test("a lost secure success save keeps unknown intent and never starts get_headers or a new registration")
    func failedSuccessSaveRetainsUnknownIntent() async throws {
        let storage = Storage(failOnSave: 3); let peer = Peer()
        let configuration = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: "https://owned-fixture.invalid")!)
        let provider = try Provider(configuration: configuration, namespaceID: UUID(), transport: peer,
            storage: storage, clock: { Self.now }, randomIdentifier: { Self.identifier })
        do { _ = try await provider.freshAnisette(); Issue.record("failed registration save accepted") }
        catch let failure as Provider.Failure { #expect(failure == .storage) }
        #expect(try await provider.observeRegistration()?.phase == .provisioningOutcomeUnknown)
        #expect(!(await peer.headersObservedClosedSocket))
        do { _ = try await provider.freshAnisette(); Issue.record("unknown success replayed") }
        catch let failure as Provider.Failure { #expect(failure == .provisioningOutcomeUnknown) }
        #expect(await peer.openCount == 1)
    }

    @Test("explicit reset resumes one pending replacement identity after uncertain readback, then provisions it once")
    func resetsUnknownRegistrationAndReusesTheSameNewIdentity() async throws {
        let storage = Storage(failReadAfterSave: 3); let interrupted = Peer(interrupt: true)
        let configuration = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: "https://owned-fixture.invalid")!)
        let namespace = UUID(), replacement = Data(repeating: 0xa5, count: 16)
        let provider = try Provider(configuration: configuration, namespaceID: namespace, transport: interrupted,
            storage: storage, clock: { Self.now }, randomIdentifier: { Self.identifier })
        do { _ = try await provider.freshAnisette(); Issue.record("interrupted fixture accepted") }
        catch FixtureFailure.interrupted { }
        let requestCount = await interrupted.requestCount
        // Save #3 records resetPending; its readback is deliberately unavailable.
        do {
            _ = try Provider.resetUnknownRegistration(configuration: configuration, namespaceID: namespace,
                storage: storage, randomIdentifier: { replacement })
            Issue.record("unconfirmed reset reported success")
        } catch let failure as Provider.Failure { #expect(failure == .resetCommitUnknown) }
        #expect(try Provider.observeRegistration(configuration: configuration, namespaceID: namespace, storage: storage)?.phase == .resetOutcomeUnknown)
        do { _ = try await provider.freshAnisette(); Issue.record("pending reset automatically provisioned") }
        catch let failure as Provider.Failure { #expect(failure == .resetCommitUnknown) }
        #expect(await interrupted.requestCount == requestCount)
        let wrongEndpoint = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: "https://other-owned-fixture.invalid")!)
        let pending = storage.registration
        do {
            _ = try Provider.resetUnknownRegistration(configuration: wrongEndpoint, namespaceID: namespace,
                storage: storage, randomIdentifier: { throw FixtureFailure.unexpected })
            Issue.record("registration migrated to another endpoint")
        } catch let failure as Provider.Failure { #expect(failure == .registrationBoundToAnotherEndpoint) }
        #expect(storage.registration == pending)
        // The explicit retry reuses resetIdentifier and must not ask for more randomness.
        let reset = try Provider.resetUnknownRegistration(configuration: configuration, namespaceID: namespace,
            storage: storage, randomIdentifier: { throw FixtureFailure.unexpected })
        #expect(reset.phase == .unprovisioned)
        let resetRecord = try JSONSerialization.jsonObject(with: Data(try #require(storage.registration).utf8)) as? [String: Any]
        #expect(resetRecord?["identifier"] as? String == replacement.base64EncodedString())
        #expect(resetRecord?["resetIdentifier"] == nil)
        #expect(await interrupted.requestCount == requestCount) // resetting itself never used a transport
        let nextPeer = Peer(expectedIdentifier: replacement)
        let reopened = try Provider(configuration: configuration, namespaceID: namespace, transport: nextPeer,
            storage: storage, clock: { Self.now }, randomIdentifier: { throw FixtureFailure.unexpected })
        let candidate = try await reopened.freshAnisette()
        #expect(candidate.deviceID == "a5a5a5a5-a5a5-a5a5-a5a5-a5a5a5a5a5a5")
        _ = try await reopened.freshAnisette()
        #expect(await nextPeer.openCount == 1)
        let provisioned = storage.registration
        do {
            _ = try Provider.resetUnknownRegistration(configuration: configuration, namespaceID: namespace,
                storage: storage, randomIdentifier: { throw FixtureFailure.unexpected })
            Issue.record("completed registration erased")
        } catch let failure as Provider.Failure { #expect(failure == .resetNotRequired) }
        #expect(storage.registration == provisioned)
    }

    @Test("reset credential barrier detects a storage owner that fails to apply credential removal")
    func confirmsCredentialRemovalBeforeRegistrationResetCanProceed() throws {
        let namespace = UUID()
        // Structural account-record fixture only; these values never authenticate.
        let value: [String: Any] = ["schema": 1, "namespaceID": namespace.uuidString,
            "identitySHA256": Data(repeating: 7, count: 32).base64EncodedString(),
            "pin": ["dsid": "123", "personID": "owned-person", "email": "owned@example.invalid", "teamID": "OWNEDTEAM"],
            "credentials": ["dsid": "123", "xcodeToken": "owned-token-fixture", "expiresAt": Self.now.addingTimeInterval(300).timeIntervalSinceReferenceDate]]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        let retained = Storage(initialAccount: encoded, dropAccountWrites: true)
        do {
            try SelfRenewalDeveloperAccountClient.signOutStoredCredentials(namespaceID: namespace, storage: retained, requireReadback: true)
            Issue.record("unconfirmed credential removal accepted")
        } catch let failure as SelfRenewalDeveloperAccountClient.Failure { #expect(failure == .storage) }
        #expect(retained.account == encoded && retained.registration == nil)
        let confirmed = Storage(initialAccount: encoded)
        try SelfRenewalDeveloperAccountClient.signOutStoredCredentials(namespaceID: namespace, storage: confirmed, requireReadback: true)
        let record = try JSONSerialization.jsonObject(with: Data(try #require(confirmed.account).utf8)) as? [String: Any]
        #expect(record?["credentials"] == nil && confirmed.registration == nil)
    }

    @Test("endpoint selection is local, schema-1 compatible, and excludes private registration state")
    func endpointSelectionIsLocalAndBackwardCompatible() async throws {
        try await Task.detached {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { do { try FileManager.default.removeItem(at: parent) } catch { Issue.record("fixture cleanup failed") } }
            let root = parent.appendingPathComponent("SelfRenewalApp", isDirectory: true)
            let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
            var session = SelfRenewalAppSession(root: root)
            _ = try await session.bootstrap(handoff: handoff)
            #expect(!(await session.developerServicesAreConfigured()))
            // The existing document omits the optional provider field.
            let before = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
            #expect(!(String(decoding: before, as: UTF8.self).contains("anisetteProvider")))
            let configuration = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: "https://owned-fixture.invalid")!)
            try await session.configureAnisetteProvider(configuration)
            #expect(await session.developerServicesAreConfigured())
            let saved = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
            let publicText = String(decoding: saved, as: UTF8.self)
            #expect(!publicText.contains("adiPB") && !publicText.contains("identifier") && !publicText.contains("otp"))
            try await session.close()
            session = SelfRenewalAppSession(root: root)
            _ = try await session.bootstrap(handoff: handoff)
            #expect(await session.configuredAnisetteProvider() == configuration)
            #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == saved)
            try await session.close()
        }.value
    }

    @Test("actual shared URLSession constructs only provider fields and account surface refuses a provider URL")
    func realTransportSeparatesProviderAndAppleRequests() async throws {
        let transport = SelfRenewalDeveloperURLSessionTransport(protocolClasses: [OwnedProtocol.self])
        let configuration = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: "https://owned-fixture.invalid")!)
        _ = try await transport.sendAnisette(.headers(configuration, identifier: Self.identifier, adiPB: Self.blob))
        let request = try #require(OwnedProtocol.last)
        #expect(request.httpMethod == "POST" && request.url == configuration.url("/v3/get_headers"))
        let data = try #require(request.httpBody)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(body == ["identifier": Self.identifier.base64EncodedString(), "adi_pb": Self.blob.base64EncodedString()])
        for header in ["Authorization", "Cookie", "X-Apple-GS-Token", "X-Apple-Identity-Token", "security-code", "X-Apple-I-MD", "X-Apple-I-MD-M"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        do { _ = try await transport.send(request); Issue.record("account transport accepted provider endpoint") }
        catch let failure as SelfRenewalDeveloperAccountTransportFailure { #expect(failure == .wrongEndpoint) }
        for url in ["http://owned-fixture.invalid", "https://user:secret@owned-fixture.invalid", "https://owned-fixture.invalid/?x=1", "https://gsa.apple.com"] {
            do { _ = try SelfRenewalAnisetteV3Configuration(endpoint: URL(string: url)!); Issue.record("unsafe endpoint accepted") }
            catch let failure as Provider.Failure { #expect(failure == .invalidConfiguration) }
        }
    }

    private enum FixtureFailure: Error { case interrupted, unexpected }
    private final class Storage: SelfRenewalDeveloperSessionStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var storedAccount: String?
        private var storedRegistration: String?
        private var saveCount = 0
        private let failOnSave: Int?
        private let failReadAfterSave: Int?
        private var failedRead = false
        private let dropAccountWrites: Bool
        init(failOnSave: Int? = nil, failReadAfterSave: Int? = nil, initialAccount: String? = nil,
            dropAccountWrites: Bool = false) {
            self.failOnSave = failOnSave; self.failReadAfterSave = failReadAfterSave
            self.storedAccount = initialAccount; self.dropAccountWrites = dropAccountWrites
        }
        var account: String? { lock.withLock { storedAccount } }
        var registration: String? { lock.withLock { storedRegistration } }
        func load(namespace: UUID) throws -> String? { account }
        func save(namespace: UUID, value: String) throws { lock.withLock { if !dropAccountWrites { storedAccount = value } } }
        func loadAnisetteRegistration(namespace: UUID) throws -> String? {
            try lock.withLock {
                if saveCount == failReadAfterSave && !failedRead {
                    failedRead = true; throw Provider.Failure.storage
                }
                return storedRegistration
            }
        }
        func saveAnisetteRegistration(namespace: UUID, value: String) throws {
            try lock.withLock {
                saveCount += 1
                if saveCount == failOnSave { throw Provider.Failure.storage }
                storedRegistration = value
            }
        }
    }
    private actor Socket: SelfRenewalAnisetteProvisioningSocket {
        let interrupt: Bool
        var step = 0; var sent: [Data] = []; var closed = false
        init(interrupt: Bool) { self.interrupt = interrupt }
        func receive() async throws -> Data {
            defer { step += 1 }
            if interrupt && step == 1 { throw FixtureFailure.interrupted }
            let messages: [[String: String]] = [
                ["result": "GiveIdentifier"], ["result": "GiveStartProvisioningData"],
                ["result": "GiveEndProvisioningData", "cpim": Data("owned cpim".utf8).base64EncodedString()],
                ["result": "ProvisioningSuccess", "adi_pb": SelfRenewalAnisetteV3ProviderTests.blob.base64EncodedString()]]
            guard step < messages.count else { throw FixtureFailure.unexpected }
            return try JSONSerialization.data(withJSONObject: messages[step])
        }
        func send(_ data: Data) async throws { sent.append(data) }
        func close() async { closed = true }
    }
    private actor Peer: SelfRenewalDeveloperAccountTransport {
        let socket: Socket
        var openCount = 0; var requestCount = 0; var headersObservedClosedSocket = false
        var headersObservedCommittedRegistration = false
        let storage: Storage?
        let expectedIdentifier: Data
        private var rejected = false
        init(interrupt: Bool = false, storage: Storage? = nil, expectedIdentifier: Data = SelfRenewalAnisetteV3ProviderTests.identifier) {
            socket = Socket(interrupt: interrupt); self.storage = storage; self.expectedIdentifier = expectedIdentifier
        }
        func rejectHeaders() { rejected = true }
        func send(_ request: URLRequest) async throws -> SelfRenewalDeveloperAccountResponse { throw FixtureFailure.unexpected }
        func openAnisetteProvisioning(_ configuration: SelfRenewalAnisetteV3Configuration) async throws -> any SelfRenewalAnisetteProvisioningSocket {
            openCount += 1; return socket
        }
        func sendAnisette(_ input: SelfRenewalAnisetteRequest) async throws -> SelfRenewalDeveloperAccountResponse {
            requestCount += 1
            let body: Data
            switch input {
            case .clientInfo:
                body = try JSONSerialization.data(withJSONObject: ["client_info": "owned-client-fixture", "user_agent": "owned-user-agent-fixture"])
            case .appleLookup:
                body = try Self.plist(["urls": ["midStartProvisioning": "https://gsa.apple.com/grandslam/MidService/startMachineProvisioning",
                    "midFinishProvisioning": "https://gsa.apple.com/grandslam/MidService/finishMachineProvisioning"]])
            case .appleStart:
                body = try Self.plist(["Response": ["spim": Data("owned spim".utf8).base64EncodedString()]])
            case .appleFinish:
                body = try Self.plist(["Response": ["ptm": Data("owned ptm".utf8).base64EncodedString(), "tk": Data("owned tk".utf8).base64EncodedString()]])
            case .headers(_, let identifier, let blob):
                guard identifier == expectedIdentifier, blob == SelfRenewalAnisetteV3ProviderTests.blob else { throw FixtureFailure.unexpected }
                headersObservedClosedSocket = await socket.closed
                if let encoded = storage?.registration {
                    let registration = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
                    headersObservedCommittedRegistration = registration?["phase"] as? String == "provisioned"
                }
                body = try JSONSerialization.data(withJSONObject: rejected ? ["result": "GetHeadersError", "message": "owned rejection fixture"] :
                    ["result": "Headers", "X-Apple-I-MD-M": "owned-machine-fixture", "X-Apple-I-MD": "owned-otp-fixture", "X-Apple-I-MD-RINFO": "17106176"])
            }
            return SelfRenewalDeveloperAccountResponse(statusCode: 200, body: body)
        }
        private static func plist(_ value: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
    }
    private final class OwnedProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var stored: URLRequest?
        static var last: URLRequest? { lock.withLock { stored } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.withLock { Self.stored = request }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { }
    }
}
