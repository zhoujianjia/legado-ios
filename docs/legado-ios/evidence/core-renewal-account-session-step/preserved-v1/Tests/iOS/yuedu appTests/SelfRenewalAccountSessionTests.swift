import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

#if DEBUG
// These methods belong to the existing serialized peer suite. A separate suite
// would race its one owned URLProtocol peer; there is no second peer registry.
extension SelfRenewalDeveloperAccountClientTests {
    @Test("App session renews its actual published key and reopens the same credential and material namespace")
    func appSessionRefreshesTheActualPublishedKeyAndReopensIt() async throws {
        try await Self.withAccountAppSession { c in
            let connected = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            #expect(connected.personalTeamMatched)
            let published = try await c.session.refreshDeveloperMaterials(machineName: "Owned App Session")
            #expect(published.keyID == c.originalLease.keyID)
            #expect(published.namespaceID == c.fixture.namespace.id)
            #expect(published.generation == c.originalLease.generation + 1)
            #expect(!published.appleAuthorizationEstablished)
            #expect(!published.installedApplicationRenewed)
            let retained = await c.session.developerMaterialObservation()
            #expect(retained == published)
            let facts = await c.peer.facts()
            #expect(facts.validCSRs == 1)
            #expect(facts.profileRequests == 3)
            let raw = try Data(contentsOf: c.root.appendingPathComponent("configuration.json"))
            #expect(!String(decoding: raw, as: UTF8.self).contains(c.fixture.credentials.xcodeToken))
            try await c.session.close()
            let reopened = c.newSession()
            do {
                let status = try await reopened.bootstrap(handoff: c.handoff)
                #expect(status.access == .signing)
                let observation = try await reopened.observeDeveloperAccount()
                #expect(observation.personalTeamMatched)
                let after = await c.peer.facts()
                #expect(after.validCSRs == 1)
                try await reopened.close()
            } catch { do { try await reopened.close() } catch { Issue.record(error) }; throw error }
        }
    }

    @Test("retired prior preparation permits newer material generation only while its actual candidate remains absent")
    func appSessionChecksDurableRetirementBeforeAcceptingNewMaterialGeneration() async throws {
        try await Self.withAccountAppSession(seedUnsubmitted: true) { c in
            _ = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            let retired = await c.session.status()
            #expect(retired?.phase == .retired)
            let refreshed = try await c.session.refreshDeveloperMaterials(machineName: "Owned Retired Session")
            #expect(refreshed.generation > c.originalLease.generation)
            try await c.session.close()
            let reopened = c.newSession()
            let first = try await reopened.bootstrap(handoff: c.handoff)
            #expect(first.access == .signing)
            #expect(first.phase == .retired)
            try await reopened.close()
            let candidate = c.root.appendingPathComponent("SelfRenewalTransactions/candidate.ipa")
            let bytes = Data("owned unexpected candidate; not a verified archive".utf8)
            try bytes.write(to: candidate)
            let refused = c.newSession()
            do {
                _ = try await refused.bootstrap(handoff: c.handoff)
                Issue.record("Retired metadata ignored an actual unexpected candidate")
            } catch {
                let unchanged = try Data(contentsOf: candidate)
                #expect(unchanged == bytes)
                let status = await refused.status()
                #expect(status?.access != .signing)
            }
            try await refused.close()
        }
    }

    @Test("unopened expired App session can erase its stored credentials and write failure never enables reuse")
    func appSessionErasesCredentialsAfterExpiryAndRetainsFailedWriteFacts() async throws {
        try await Self.withAccountAppSession { c in
            _ = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            try await c.session.close()
            let expired = c.newSession(at: c.fixture.date.addingTimeInterval(366 * 86_400))
            let before = await c.peer.facts()
            c.fixture.storage.failSave(afterSuccessfulSaves: 0)
            do { try await expired.signOutDeveloperAccount(); Issue.record("Failed credential write became logout acknowledgement") }
            catch let failure as Client.Failure { #expect(failure == .storage) }
            do { _ = try await expired.observeDeveloperAccount(); Issue.record("Failed erasure allowed credential reuse") }
            catch let failure as Client.Failure { #expect(failure == .signedOut) }
            try await expired.signOutDeveloperAccount()
            let encoded = try #require(try c.fixture.storage.load(namespace: c.fixture.namespace.id))
            #expect(!encoded.contains(c.fixture.credentials.xcodeToken))
            let after = await c.peer.facts()
            #expect(before.paths == after.paths)
            #expect(after.validCSRs == 0)
            try await expired.close()
        }
    }

    @Test("one App operation owns the actual held CSR and cancellation preserves pending intent without a second issue")
    func appSessionSerializesHeldEnrollmentAndPreservesCancelledRemoteIntent() async throws {
        try await Self.withAccountAppSession { c in
            _ = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            await c.peer.set(.holdCSR)
            let operation = Task {
                do {
                    let result = try await c.session.refreshDeveloperMaterials(machineName: "Owned Held Session")
                    await c.peer.refreshFinished(); return result
                } catch { await c.peer.refreshFinished(); throw error }
            }
            let event = await withTaskCancellationHandler {
                await c.peer.waitForCSROrRefreshCompletion()
            } onCancel: { operation.cancel() }
            if event == .refreshFinished {
                _ = try await operation.value
                Issue.record("Refresh finished before the actual CSR reached its peer")
                return
            }
            do { try await c.session.signOutDeveloperAccount(); Issue.record("Concurrent logout bypassed the App operation owner") }
            catch let error as SelfRenewalAppSession.Failure { #expect(error == .busy) }
            operation.cancel()
            do { _ = try await operation.value; Issue.record("Cancelled CSR was acknowledged as publication") }
            catch let error as Client.EnrollmentFailure {
                #expect(error.underlying is CancellationError)
                #expect(error.remoteCertificateMayHaveBeenIssued)
            }
            try await c.session.signOutDeveloperAccount()
            _ = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            let before = await c.peer.facts()
            do {
                _ = try await c.session.refreshDeveloperMaterials(machineName: "Owned No Duplicate")
                Issue.record("Unknown CSR issue was repeated")
            } catch let error as Client.Failure { #expect(error == .reconciliationRequired) }
            let after = await c.peer.facts()
            #expect(after.paths == before.paths)
            #expect(after.validCSRs == 1)
        }
    }

    private struct AccountAppContext: @unchecked Sendable {
        let fixture: Fixture
        let peer: Peer
        let root: URL
        let session: SelfRenewalAppSession
        let services: SelfRenewalAppSession.DeveloperServices
        let originalLease: Vault.Lease
        let handoff: SelfRenewalUserDataHandoff
        func newSession(at date: Date? = nil) -> SelfRenewalAppSession {
            let now = date ?? fixture.date
            return SelfRenewalAppSession(root: root,
                currentApplicationRoot: fixture.directory.appendingPathComponent("Owned.app"),
                developerServices: services, clock: { now })
        }
    }
    nonisolated private static func withAccountAppSession(seedUnsubmitted: Bool = false,
        _ action: @escaping @Sendable (AccountAppContext) async throws -> Void) async throws {
        try await Self.fixture { f in
            let root = f.directory.appendingPathComponent("AccountSession")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let original = try await f.vault.lease(in: f.namespace)
            let peer = Peer(material: f.material, issuer: f.issuer, key: original.keyMaterial, date: f.date)
            PeerProtocol.install(peer)
            let date = f.date
            let services = SelfRenewalAppSession.DeveloperServices(
                transport: SelfRenewalDeveloperURLSessionTransport(protocolClasses: [PeerProtocol.self]), storage: f.storage,
                freshAnisette: { Client.Anisette(machineID: "owned-machine", oneTimePassword: "owned-fresh-otp",
                    localUserID: "owned-local-user", routingInfo: 1, deviceID: "owned-device-id", clientInfo: "Owned controlled peer",
                    issuedAt: date, locale: "en_US", timeZone: "UTC") })
            if seedUnsubmitted {
                let journal = try await SelfRenewalTransactionJournal.open(at: root.appendingPathComponent("SelfRenewalTransactions"))
                let identifier = try #require(f.material.bundles.first?.bundleIdentifier)
                _ = try await journal.create(namespace: f.namespace.id, generation: original.generation,
                    originalSHA256: Data(SHA256.hash(data: Data("owned preparation intent".utf8))),
                    identitySHA256: Data(SHA256.hash(data: Data(identifier.utf8))), bundleIdentifier: identifier,
                    bundleVersion: "1", at: date)
                try await journal.close()
            }
            let session = SelfRenewalAppSession(root: root,
                currentApplicationRoot: f.directory.appendingPathComponent("Owned.app"), developerServices: services, clock: { date })
            let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
            do {
                _ = try await session.bootstrap(handoff: handoff)
                let anchors = [SelfRenewalCMSFixture.rootCertificate] + f.issuer.certificateChainDER
                let configuration = SelfRenewalAppSession.Configuration(schema: 1, namespaceID: f.namespace.id,
                    codeAnchors: anchors, profileAnchors: anchors, device: nil)
                let input = f.directory.appendingPathComponent("account-session-configuration.json")
                try JSONEncoder().encode(configuration).write(to: input)
                _ = try await session.configure(from: input, handoff: handoff)
                try await action(AccountAppContext(fixture: f, peer: peer, root: root, session: session,
                    services: services, originalLease: original, handoff: handoff))
                try await session.close()
                _ = try await f.vault.resume(namespaceID: f.namespace.id, identity: f.material)
            } catch {
                do { try await session.close() } catch { Issue.record(error) }
                do { _ = try await f.vault.resume(namespaceID: f.namespace.id, identity: f.material) } catch { Issue.record(error) }
                throw error
            }
        }
    }
}
#endif
