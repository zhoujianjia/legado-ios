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
