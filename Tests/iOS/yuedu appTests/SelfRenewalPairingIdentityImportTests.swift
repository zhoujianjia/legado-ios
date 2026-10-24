import CryptoKit
import Foundation
import Security
import Testing
@testable import yuedu_app

#if DEBUG
@Suite("Explicit synthetic P12 import through the actual App Keychain owner", .serialized)
struct SelfRenewalPairingIdentityImportTests {
    typealias Import = SelfRenewalPairingIdentityImport
    typealias Inputs = SelfRenewalPairingOwnedPKCS12Fixture
    typealias Session = SelfRenewalAppSession
    typealias Execution = SelfRenewalAppExecutionTests
    typealias Package = SelfRenewalControlledPackageSignerTests

    @Test("Security imports real synthetic P12, proves possession and reuses the exact persistent identity")
    func realIdentityReadBackAndBoundedRejections() async throws {
        try await Task.detached {
            try await Self.withInputs { files in
                let namespaceDate = Date(timeIntervalSince1970: 1_792_540_800)
                let imported = try Import.importIdentity(pkcs12: files.hostA, password: Inputs.password,
                    publicConfiguration: files.publicA, at: namespaceDate)
                #expect(try Session.pairing(imported).hostCertificateDER == Inputs.hostACertificate)
                let retry = try Import.importIdentity(pkcs12: files.hostA, password: Inputs.password,
                    publicConfiguration: files.publicA, at: namespaceDate)
                #expect(retry.identityPersistentReference == imported.identityPersistentReference)
                do {
                    _ = try Import.importIdentity(pkcs12: files.hostA, password: "deliberately-wrong-test-password",
                        publicConfiguration: files.publicA, at: namespaceDate)
                    Issue.record("Wrong password imported an identity")
                } catch let failure as Import.Failure {
                    guard case .invalidPKCS12 = failure else { throw failure }
                }
                do {
                    _ = try Import.importIdentity(pkcs12: files.hostB, password: Inputs.password,
                        publicConfiguration: files.publicA, at: namespaceDate)
                    Issue.record("A different valid P12 replaced the public HostCertificate")
                } catch let failure as Import.Failure { #expect(failure == .hostCertificateMismatch) }
                let malformed = files.directory.appendingPathComponent("malformed-test-only.p12")
                try Data([0x30, 0x02, 0x01]).write(to: malformed)
                do {
                    _ = try Import.importIdentity(pkcs12: malformed, password: Inputs.password,
                        publicConfiguration: files.publicA, at: namespaceDate)
                    Issue.record("Malformed PKCS12 imported an identity")
                } catch let failure as Import.Failure {
                    guard case .invalidPKCS12 = failure else { throw failure }
                }
                var unsafe = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: files.publicA)) as? [String: Any])
                unsafe["HostPrivateKey"] = "synthetic-field-that-must-be-rejected"
                do {
                    _ = try Import.decodePublicConfiguration(JSONSerialization.data(withJSONObject: unsafe))
                    Issue.record("Private/unknown public configuration field was ignored")
                } catch let failure as Import.Failure { #expect(failure == .invalidPublicConfiguration) }
                #expect(try Session.pairing(imported).hostCertificateDER == Inputs.hostACertificate)
            }
        }.value
    }

    @Test("One Session publishes the imported selector, reopens it, preserves old binding on failure and refuses an active journal")
    func sameSessionReopenFailureAndActiveTransaction() async throws {
        try await Package.fixture { fixture in
            try await Self.withInputs { files in
                let application = try await Execution.application(fixture)
                let owners = try await Execution.library(in: fixture.directory, at: fixture.date)
                let root = fixture.directory.appendingPathComponent("SelfRenewalApp")
                let session = Session(root: root, currentApplicationRoot: application, clock: { fixture.date })
                do {
                    _ = try await session.configure(from: Execution.configuration(fixture, device: nil), handoff: owners.handoff)
                    let libraryBefore = try Self.libraryBytes(fixture.directory)
                    let imported = try await session.importPairingIdentity(pkcs12: files.hostA, password: Inputs.password,
                        publicConfiguration: files.publicA, handoff: owners.handoff)
                    #expect(imported.access == .signing)
                    #expect(!imported.automaticRenewalVerified && !imported.coldLaunchVerified && !imported.appleAuthorizationVerified)
                    let configured = try Self.configuration(root)
                    let original = try #require(configured.device)
                    #expect(configured.namespaceID == fixture.namespace.id)
                    #expect(try Session.pairing(original).hostCertificateDER == Inputs.hostACertificate)
                    let beforeFailure = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
                    do {
                        _ = try await session.importPairingIdentity(pkcs12: files.hostB, password: Inputs.password,
                            publicConfiguration: files.publicA, handoff: owners.handoff)
                        Issue.record("Mismatched host identity changed the Session")
                    } catch let failure as Import.Failure { #expect(failure == .hostCertificateMismatch) }
                    #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == beforeFailure)
                    #expect(try Session.pairing(original).hostCertificateDER == Inputs.hostACertificate)
                    #expect(try Self.libraryBytes(fixture.directory) == libraryBefore)
                    try await session.close()
                    let reopened = Session(root: root, currentApplicationRoot: application, clock: { fixture.date })
                    do {
                        let status = try await reopened.bootstrap(handoff: owners.handoff)
                        #expect(status.access == .signing)
                        let reopenedDevice = try #require(Self.configuration(root).device)
                        #expect(reopenedDevice.identityPersistentReference == original.identityPersistentReference)
                        _ = try await reopened.prepareRenewal(from: fixture.input)
                        let journal = root.appendingPathComponent("SelfRenewalTransactions/transaction.json")
                        let journalBefore = try Data(contentsOf: journal)
                        // Invalid, nonexistent inputs prove transaction refusal
                        // happens before file/P12 import, with no permission work.
                        let absent = files.directory.appendingPathComponent("never-created")
                        do {
                            _ = try await reopened.importPairingIdentity(pkcs12: absent, password: "",
                                publicConfiguration: absent, handoff: owners.handoff)
                            Issue.record("Active candidate allowed a pairing replacement")
                        } catch let failure as Session.Failure { #expect(failure == .configurationInUse) }
                        #expect(try Data(contentsOf: journal) == journalBefore)
                        #expect(try #require(Self.configuration(root).device) == original)
                        #expect(try Self.libraryBytes(fixture.directory) == libraryBefore)
                        try await reopened.close()
                    } catch { do { try await reopened.close() } catch { Issue.record(error) }; throw error }
                } catch { do { try await session.close() } catch { Issue.record(error) }; throw error }
            }
        }
    }

    @Test("A lost real directory-sync ACK reloads the same imported item without deleting the previous identity")
    func lostAcknowledgementRetainsBothRealIdentitiesAndRetrySelector() async throws {
        try await Package.fixture { fixture in
            try await Self.withInputs { files in
                let application = try await Execution.application(fixture)
                let owners = try await Execution.library(in: fixture.directory, at: fixture.date)
                let root = fixture.directory.appendingPathComponent("SelfRenewalApp")
                let initial = Session(root: root, currentApplicationRoot: application, clock: { fixture.date })
                let original: Session.DeviceConfiguration
                do {
                    _ = try await initial.configure(from: Execution.configuration(fixture, device: nil), handoff: owners.handoff)
                    _ = try await initial.importPairingIdentity(pkcs12: files.hostA, password: Inputs.password,
                        publicConfiguration: files.publicA, handoff: owners.handoff)
                    original = try #require(Self.configuration(root).device)
                    try await initial.close()
                } catch { do { try await initial.close() } catch { Issue.record(error) }; throw error }
                let interrupted = Session(root: root, currentApplicationRoot: application,
                    publicationFault: .loseNextDirectorySyncAcknowledgement, clock: { fixture.date })
                do {
                    do {
                        _ = try await interrupted.importPairingIdentity(pkcs12: files.hostB, password: Inputs.password,
                            publicConfiguration: files.publicB, handoff: owners.handoff)
                        Issue.record("Lost configuration ACK was returned as success")
                    } catch let failure as Session.Failure { #expect(failure == .commitDurabilityUnknown) }
                    let committed = try #require(Self.configuration(root).device)
                    #expect(try Session.pairing(committed).hostCertificateDER == Inputs.hostBCertificate)
                    #expect(try Session.pairing(original).hostCertificateDER == Inputs.hostACertificate)
                    let retried = try await interrupted.importPairingIdentity(pkcs12: files.hostB, password: Inputs.password,
                        publicConfiguration: files.publicB, handoff: owners.handoff)
                    #expect(retried.access == .signing)
                    #expect(try #require(Self.configuration(root).device).identityPersistentReference == committed.identityPersistentReference)
                    // Cancelled entry is drained before its task returns and
                    // cannot change the committed selector or underlying keys.
                    let before = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
                    let cancelled = Task {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return try await interrupted.importPairingIdentity(pkcs12: files.hostA, password: Inputs.password,
                            publicConfiguration: files.publicA, handoff: owners.handoff)
                    }
                    do { _ = try await cancelled.value; Issue.record("Cancelled import changed configuration") }
                    catch is CancellationError { }
                    #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == before)
                    #expect(try Session.pairing(original).hostCertificateDER == Inputs.hostACertificate)
                    try await interrupted.close()
                } catch { do { try await interrupted.close() } catch { Issue.record(error) }; throw error }
            }
        }
    }

    @Test("First pairing binds the actual ready candidate without changing its bytes, material generation or Anisette owner")
    func firstBindingPreservesReadyCandidateNamespaceMaterialsAndAnisette() async throws {
        let observation = FirstBindingFacts()
        try await Package.fixture { f in
            try await Self.withInputs { files in
                let application = try await Execution.application(f)
                let root = f.directory.appendingPathComponent("SelfRenewalApp")
                let probe = FirstBindingRemoteProbe(namespace: f.namespace.id)
                let services = Session.DeveloperServices(transport: probe, storage: probe,
                    freshAnisette: { try probe.freshAnisette() })
                let owner = await MainActor.run {
                    SelfRenewalAppOwner(root: root, currentApplicationRoot: application,
                        developerServices: services, clock: { f.date })
                }
                let owners = try await Execution.library(in: f.directory, at: f.date, handoff: owner.handoff)
                do {
                    let endpoint = try #require(URL(string: "https://owned-anisette.invalid"))
                    let providerConfigured = await owner.configureAnisetteProvider(endpoint: endpoint)
                    await owner.importConfiguration(try Execution.configuration(f, device: nil))
                    await owner.prepareRenewal(from: f.input)
                    // Create a real immutable predecessor commitment before
                    // capturing the current candidate that import must retain.
                    await owner.prepareRenewal(from: f.input)
                    let beforeRecord = try Self.recordBytes(root)
                    let record = try JSONDecoder().decode(Session.Journal.Record.self, from: beforeRecord)
                    let beforeCandidate = try Data(contentsOf: Self.candidateURL(root))
                    let beforeConfiguration = try Self.configuration(root)
                    let beforeAnisette = try Self.anisetteBytes(root)
                    let beforeMaterial = await owner.developerMaterial
                    let admission = await owner.pairingIdentityImportAvailable
                    let imported = await owner.importPairingIdentity(pkcs12: files.hostA, password: Inputs.password,
                        publicConfiguration: files.publicA)
                    let afterConfiguration = try Self.configuration(root)
                    let status = await owner.status
                    let afterMaterial = await owner.developerMaterial
                    let afterAdmission = await owner.pairingIdentityImportAvailable
                    let remoteLoginUnverified = await owner.developerSession == nil
                    let afterProvider = await owner.anisetteProvider
                    let paired = try #require(afterConfiguration.device)
                    let recordUnchanged = try Self.recordBytes(root) == beforeRecord
                    let candidateUnchanged = try Data(contentsOf: Self.candidateURL(root)) == beforeCandidate
                    let pairingMatches = try Session.pairing(paired).hostCertificateDER == Inputs.hostACertificate
                    let anisetteUnchanged = try Self.anisetteBytes(root) == beforeAnisette
                    let checks = [
                        "prepared": record.phase == .candidateReady && record.remoteHistory == .neverStarted
                            && record.previousRetirement != nil,
                        "admitted": admission && imported && !afterAdmission,
                        "record": recordUnchanged,
                        "candidate": candidateUnchanged
                            && Data(SHA256.hash(data: beforeCandidate)) == record.candidate?.sha256,
                        "configuration": beforeConfiguration.device == nil
                            && afterConfiguration.namespaceID == beforeConfiguration.namespaceID
                            && afterConfiguration.codeAnchors == beforeConfiguration.codeAnchors
                            && afterConfiguration.profileAnchors == beforeConfiguration.profileAnchors,
                        "pairing": pairingMatches,
                        "material": beforeMaterial != nil && beforeMaterial == afterMaterial
                            && record.materialGeneration == afterMaterial?.generation,
                        "status": status?.phase == .candidateReady && status?.access == .signing
                            && remoteLoginUnverified,
                        "anisette": providerConfigured && afterProvider?.endpoint == endpoint
                            && beforeAnisette != nil && anisetteUnchanged,
                        "offline": probe.remoteCalls == 0 && probe.storageWrites == 0]
                    try await owner.close()
                    withExtendedLifetime(owners) {}
                    await observation.store(checks)
                } catch { do { try await owner.close() } catch { Issue.record(error) }; throw error }
            }
        }
        let checks = try #require(await observation.checks)
        #expect(checks.count == 10)
        #expect(checks.filter { !$0.value }.isEmpty)
    }

    @Test("Unknown remote history and every non-ready phase refuse first binding before nonexistent P12 inputs")
    func firstBindingRejectsUnknownOrRemoteFactsBeforeP12Import() async throws {
        let observation = FirstBindingFacts()
        try await Package.fixture { f in
            try await Self.withInputs { files in
                let application = try await Execution.application(f)
                let owners = try await Execution.library(in: f.directory, at: f.date)
                let root = f.directory.appendingPathComponent("SelfRenewalApp")
                let session = Session(root: root, currentApplicationRoot: application, clock: { f.date })
                do {
                    _ = try await session.configure(from: Execution.configuration(f, device: nil), handoff: owners.handoff)
                    _ = try await session.prepareRenewal(from: f.input)
                    let original = try Self.recordBytes(root)
                    let record = try JSONDecoder().decode(Session.Journal.Record.self, from: original)
                    var rejected = 0
                    let phases: [Session.Journal.Phase] = [.created, .signing, .uploadIntent, .upgradeIntent,
                        .receiptObserved, .installationUnknown, .lookupObserved, .attentionRequired, .retirementPending, .retired]
                    for phase in phases {
                        var changed = record; changed.phase = phase
                        if !Session.permitsFirstPairingBinding(changed, namespaceID: f.namespace.id) { rejected += 1 }
                    }
                    let histories: [Session.Journal.RemoteHistory?] = [nil, .started]
                    for history in histories {
                        var changed = record; changed.remoteHistory = history
                        if !Session.permitsFirstPairingBinding(changed, namespaceID: f.namespace.id) { rejected += 1 }
                    }
                    var noCandidate = record; noCandidate.candidate = nil
                    var hasSubmission = record
                    hasSubmission.submission = .init(remotePackagePath: "PublicStaging/reader-renewal-00000000-0000-0000-0000-000000000000.ipa",
                        deviceCertificateSHA256: Data(repeating: 1, count: 32))
                    var hasLookup = record; hasLookup.lookupReportedSameVersion = false
                    let refusedFacts = !Session.permitsFirstPairingBinding(noCandidate, namespaceID: f.namespace.id)
                        && !Session.permitsFirstPairingBinding(hasSubmission, namespaceID: f.namespace.id)
                        && !Session.permitsFirstPairingBinding(hasLookup, namespaceID: f.namespace.id)
                        && !Session.permitsFirstPairingBinding(record, namespaceID: UUID())
                    var legacy = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
                    legacy.removeValue(forKey: "remoteHistory")
                    let legacyBytes = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
                    let recordURL = Self.recordURL(root)
                    try legacyBytes.write(to: recordURL, options: .atomic)
                    let candidateBefore = try Data(contentsOf: Self.candidateURL(root))
                    let absent = files.directory.appendingPathComponent("never-created")
                    var deniedBeforeInput = false
                    do {
                        _ = try await session.importPairingIdentity(pkcs12: absent, password: "",
                            publicConfiguration: absent, handoff: owners.handoff)
                    } catch let error as Session.Failure { deniedBeforeInput = error == .configurationInUse }
                    let displayAvailable = try await session.pairingIdentityImportIsAvailable()
                    let recordUnchanged = try Data(contentsOf: recordURL) == legacyBytes
                    let candidateUnchanged = try Data(contentsOf: Self.candidateURL(root)) == candidateBefore
                    let checks = ["phaseAndHistory": rejected == 12, "otherFacts": refusedFacts,
                        "beforeInput": deniedBeforeInput, "display": !displayAvailable,
                        "unchanged": recordUnchanged && candidateUnchanged]
                    try original.write(to: recordURL, options: .atomic)
                    try await session.close()
                    await observation.store(checks)
                } catch { do { try await session.close() } catch { Issue.record(error) }; throw error }
            }
        }
        let checks = try #require(await observation.checks)
        #expect(checks.count == 5)
        #expect(checks.filter { !$0.value }.isEmpty)
    }

    @Test("First binding verifies actual candidate bytes and propagates cancellation without importing or changing configuration")
    func firstBindingChecksActualCandidateAndCancellationBeforeP12Import() async throws {
        let observation = FirstBindingFacts()
        try await Package.fixture { f in
            try await Self.withInputs { files in
                let application = try await Execution.application(f)
                let owners = try await Execution.library(in: f.directory, at: f.date)
                let root = f.directory.appendingPathComponent("SelfRenewalApp")
                let session = Session(root: root, currentApplicationRoot: application, clock: { f.date })
                do {
                    _ = try await session.configure(from: Execution.configuration(f, device: nil), handoff: owners.handoff)
                    _ = try await session.prepareRenewal(from: f.input)
                    let before = try Self.recordBytes(root)
                    let configurationBefore = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
                    let candidate = Self.candidateURL(root)
                    let raw = try Data(contentsOf: candidate)
                    let absent = files.directory.appendingPathComponent("never-created")
                    let cancelled = Task {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return try await session.importPairingIdentity(pkcs12: absent, password: "",
                            publicConfiguration: absent, handoff: owners.handoff)
                    }
                    var cancellationPreserved = false
                    do { _ = try await cancelled.value } catch is CancellationError { cancellationPreserved = true }
                    var broken = raw; broken[0] ^= 0xff
                    try broken.write(to: candidate)
                    var candidateRejectedBeforeInput = false
                    do {
                        _ = try await session.importPairingIdentity(pkcs12: absent, password: "",
                            publicConfiguration: absent, handoff: owners.handoff)
                    } catch {
                        // P12/password validation is after the actual full IPA proof.
                        candidateRejectedBeforeInput = error is SelfRenewalIPAArchiveValidator.Failure
                    }
                    try raw.write(to: candidate)
                    var pairingRejected = false
                    do {
                        _ = try await session.importPairingIdentity(pkcs12: files.hostB, password: Inputs.password,
                            publicConfiguration: files.publicA, handoff: owners.handoff)
                    } catch let error as Import.Failure { pairingRejected = error == .hostCertificateMismatch }
                    let recordUnchanged = try Self.recordBytes(root) == before
                    let configurationUnchanged = try Data(contentsOf: root.appendingPathComponent("configuration.json")) == configurationBefore
                    let noDevice = try Self.configuration(root).device == nil
                    let checks = ["cancelled": cancellationPreserved, "actualBytes": candidateRejectedBeforeInput,
                        "record": recordUnchanged, "configuration": configurationUnchanged, "noDevice": noDevice,
                        "wrongHost": pairingRejected]
                    try await session.close()
                    await observation.store(checks)
                } catch { do { try await session.close() } catch { Issue.record(error) }; throw error }
            }
        }
        let checks = try #require(await observation.checks)
        #expect(checks.count == 6)
        #expect(checks.filter { !$0.value }.isEmpty)
    }

    @Test("Lost first-binding publication acknowledgement retains the actual identity and exact unsubmitted candidate")
    func firstBindingLostAcknowledgementKeepsCandidateAndActualIdentity() async throws {
        let observation = FirstBindingFacts()
        try await Package.fixture { f in
            try await Self.withInputs { files in
                let application = try await Execution.application(f)
                let owners = try await Execution.library(in: f.directory, at: f.date)
                let root = f.directory.appendingPathComponent("SelfRenewalApp")
                let initial = Session(root: root, currentApplicationRoot: application, clock: { f.date })
                _ = try await initial.configure(from: Execution.configuration(f, device: nil), handoff: owners.handoff)
                _ = try await initial.prepareRenewal(from: f.input)
                let record = try Self.recordBytes(root)
                let candidate = try Data(contentsOf: Self.candidateURL(root))
                try await initial.close()
                let interrupted = Session(root: root, currentApplicationRoot: application,
                    publicationFault: .loseNextDirectorySyncAcknowledgement, clock: { f.date })
                do {
                    var ackUnknown = false
                    do {
                        _ = try await interrupted.importPairingIdentity(pkcs12: files.hostA, password: Inputs.password,
                            publicConfiguration: files.publicA, handoff: owners.handoff)
                    } catch let error as Session.Failure { ackUnknown = error == .commitDurabilityUnknown }
                    let bound = try #require(Self.configuration(root).device)
                    let sameIdentity = try Session.pairing(bound).hostCertificateDER == Inputs.hostACertificate
                    let recordUnchanged = try Self.recordBytes(root) == record
                    let candidateUnchanged = try Data(contentsOf: Self.candidateURL(root)) == candidate
                    try await interrupted.close()
                    let reopened = Session(root: root, currentApplicationRoot: application, clock: { f.date })
                    do {
                        let status = try await reopened.bootstrap(handoff: owners.handoff)
                        let absent = files.directory.appendingPathComponent("never-created")
                        var replacementRejected = false
                        do {
                            _ = try await reopened.importPairingIdentity(pkcs12: absent, password: "",
                                publicConfiguration: absent, handoff: owners.handoff)
                        } catch let error as Session.Failure { replacementRejected = error == .configurationInUse }
                        let displayAvailable = try await reopened.pairingIdentityImportIsAvailable()
                        let recordStillUnchanged = try Self.recordBytes(root) == record
                        let checks = ["unknownAck": ackUnknown, "identity": sameIdentity,
                            "candidate": recordUnchanged && candidateUnchanged && recordStillUnchanged,
                            "reopened": status.phase == .candidateReady && status.access == .signing,
                            "replacement": replacementRejected && !displayAvailable]
                        try await reopened.close()
                        await observation.store(checks)
                    } catch { do { try await reopened.close() } catch { Issue.record(error) }; throw error }
                } catch { do { try await interrupted.close() } catch { Issue.record(error) }; throw error }
            }
        }
        let checks = try #require(await observation.checks)
        #expect(checks.count == 5)
        #expect(checks.filter { !$0.value }.isEmpty)
    }

    private actor FirstBindingFacts {
        var checks: [String: Bool]?
        func store(_ value: [String: Bool]) { checks = value }
    }
    /// Opaque stored bytes are preserved, never claimed as an authenticated
    /// registration/session. Every remote/account/provider hook fails closed.
    private final class FirstBindingRemoteProbe: SelfRenewalDeveloperAccountTransport, SelfRenewalDeveloperSessionStorage, @unchecked Sendable {
        let namespace: UUID
        private let lock = NSLock()
        private var calls = 0, writes = 0
        private let credentials = "SYNTHETIC-ACCOUNT-RECORD"
        private let registration = "SYNTHETIC-ANIsETTE-RECORD"
        init(namespace: UUID) { self.namespace = namespace }
        var remoteCalls: Int { lock.withLock { calls } }
        var storageWrites: Int { lock.withLock { writes } }
        private func attempted() { lock.withLock { calls += 1 } }
        func send(_ request: URLRequest) async throws -> SelfRenewalDeveloperAccountResponse {
            attempted(); throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        func sendAnisette(_ request: SelfRenewalAnisetteRequest) async throws -> SelfRenewalDeveloperAccountResponse {
            attempted(); throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        func openAnisetteProvisioning(_ configuration: SelfRenewalAnisetteV3Configuration) async throws -> any SelfRenewalAnisetteProvisioningSocket {
            attempted(); throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        func freshAnisette() throws -> SelfRenewalDeveloperAccountClient.Anisette {
            attempted(); throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        func load(namespace: UUID) throws -> String? { namespace == self.namespace ? credentials : nil }
        func loadAnisetteRegistration(namespace: UUID) throws -> String? { namespace == self.namespace ? registration : nil }
        func save(namespace: UUID, value: String) throws {
            lock.withLock { writes += 1 }; throw SelfRenewalDeveloperAccountClient.Failure.storage
        }
        func saveAnisetteRegistration(namespace: UUID, value: String) throws {
            lock.withLock { writes += 1 }; throw SelfRenewalAnisetteV3Provider.Failure.storage
        }
    }
    nonisolated private static func recordURL(_ root: URL) -> URL {
        root.appendingPathComponent("SelfRenewalTransactions/transaction.json")
    }
    nonisolated private static func recordBytes(_ root: URL) throws -> Data { try Data(contentsOf: recordURL(root)) }
    nonisolated private static func anisetteBytes(_ root: URL) throws -> Data? {
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("configuration.json"))) as? [String: Any])
        guard let provider = document["anisetteProvider"] else { return nil }
        return try JSONSerialization.data(withJSONObject: provider, options: [.sortedKeys])
    }
    nonisolated private static func candidateURL(_ root: URL) -> URL {
        root.appendingPathComponent("SelfRenewalTransactions/candidate.ipa")
    }

    private struct Files: Sendable {
        let directory: URL
        let hostA: URL, hostB: URL
        let publicA: URL, publicB: URL
    }
    nonisolated private static func withInputs(_ action: @escaping @Sendable (Files) async throws -> Void) async throws {
        precondition(!Thread.isMainThread)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-pairing-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let files = Files(directory: directory, hostA: directory.appendingPathComponent("synthetic-host-a.p12"),
            hostB: directory.appendingPathComponent("synthetic-host-b.p12"),
            publicA: directory.appendingPathComponent("public-a.json"), publicB: directory.appendingPathComponent("public-b.json"))
        do {
            try cleanupSyntheticIdentities()
            try Inputs.hostAPKCS12.write(to: files.hostA)
            try Inputs.hostBPKCS12.write(to: files.hostB)
            for (url, certificate) in [(files.publicA, Inputs.hostACertificate), (files.publicB, Inputs.hostBCertificate)] {
                let facts = Import.PublicConfiguration(schema: 1, hostCertificateDER: certificate,
                    deviceCertificateDER: Inputs.deviceCertificate, rootCertificateDER: Inputs.rootCertificate,
                    hostID: "SYNTHETIC-TEST-ONLY-HOST-ID", systemBUID: "SYNTHETIC-TEST-ONLY-SYSTEM-BUID",
                    numericAddress: "127.0.0.1", port: 62078, interfaceIndex: 0)
                try JSONEncoder().encode(facts).write(to: url)
            }
            try await action(files)
            try cleanupSyntheticIdentities()
            try FileManager.default.removeItem(at: directory)
        } catch {
            let original = error
            do { try cleanupSyntheticIdentities(); try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
            throw original
        }
    }
    nonisolated private static func cleanupSyntheticIdentities() throws {
        // Only these two known synthetic certificate labels may be removed.
        // Production importer has no delete/update path whatsoever.
        for certificate in [Inputs.hostACertificate, Inputs.hostBCertificate] {
            let digest = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
            let status = SecItemDelete([kSecClass as String: kSecClassIdentity,
                kSecAttrLabel as String: "com.yuedu-reader.self-renewal.pairing.\(digest)"] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Import.Failure.keychain(status) }
        }
    }
    nonisolated private static func configuration(_ root: URL) throws -> Session.Configuration {
        let raw = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return try JSONDecoder().decode(Session.Configuration.self,
            from: JSONSerialization.data(withJSONObject: try #require(object["configuration"])))
    }
    nonisolated private static func libraryBytes(_ directory: URL) throws -> [String: Data] {
        let library = directory.appendingPathComponent("library")
        let files = try FileManager.default.subpathsOfDirectory(atPath: library.path)
        var result: [String: Data] = [:]
        for name in files {
            let url = library.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { result[name] = try Data(contentsOf: url) }
        }
        return result
    }
}
#endif
