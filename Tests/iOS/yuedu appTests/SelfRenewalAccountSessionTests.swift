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
            let live = try await c.session.bootstrap(handoff: c.handoff)
            #expect(live.access == .signing)
            #expect(live.phase == .retired)
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

    @Test("reopened App session recovers one lost CSR ACK through its same namespace key and preserves owned data bytes")
    func appSessionReconcilesLostCSRAcknowledgementWithoutAnotherIssue() async throws {
        try await Self.withAccountAppSession { c in
            _ = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            let bookID = UUID()
            let userData = Data(("{\"bookID\":\"" + bookID.uuidString + "\",\"spineIndex\":7,\"charOffset\":113}").utf8)
            let userDataURL = c.root.appendingPathComponent("owned-user-data-sentinel.json")
            try userData.write(to: userDataURL)
            let configurationURL = c.root.appendingPathComponent("configuration.json")
            let originalConfiguration = try JSONDecoder().decode(AccountStoredConfiguration.self,
                from: Data(contentsOf: configurationURL)).configuration
            await c.peer.set(.lostCSRACK)
            do {
                _ = try await c.session.refreshDeveloperMaterials(machineName: "Owned lost ACK App session")
                Issue.record("Lost CSR acknowledgement was called a publication")
            } catch let failure as Client.EnrollmentFailure {
                #expect(failure.remoteCertificateMayHaveBeenIssued && !failure.remoteProfilesMayHaveBeenRefreshed)
            }
            let failed = await c.session.developerMaterialObservation()
            #expect(failed == nil)
            let pendingBytes = try #require(try c.fixture.storage.load(namespace: c.fixture.namespace.id))
            #expect(pendingBytes.contains("certificateRequestIntent"))
            try await c.session.close()
            await c.peer.set(.normal)
            let reopened = c.newSession()
            do {
                let status = try await reopened.bootstrap(handoff: c.handoff)
                #expect(status.access == .signing)
                // No account client has been opened in this reopened Session.
                // Its erase-only fallback can fail with credentials still on
                // disk; that must not undo the Session's local logout denial.
                c.fixture.storage.failSave(afterSuccessfulSaves: 0)
                do { try await reopened.signOutDeveloperAccount(); Issue.record("Failed credential erasure was acknowledged") }
                catch let failure as Client.Failure { #expect(failure == .storage) }
                let beforeDenied = await c.peer.facts()
                do { _ = try await reopened.reconcileDeveloperMaterials(); Issue.record("Failed logout reenabled pending material requests") }
                catch let failure as Client.Failure { #expect(failure == .signedOut) }
                let afterDenied = await c.peer.facts()
                #expect(beforeDenied.paths == afterDenied.paths)
                let stillStored = try #require(try c.fixture.storage.load(namespace: c.fixture.namespace.id))
                #expect(stillStored.contains(c.fixture.credentials.xcodeToken) && stillStored.contains("certificateRequestIntent"))
                // Only a new explicit live account connection lifts denial.
                _ = try await reopened.connectDeveloperAccount(c.fixture.credentials)
                let published = try await reopened.reconcileDeveloperMaterials()
                #expect(published.namespaceID == c.fixture.namespace.id && published.keyID == c.originalLease.keyID)
                #expect(published.generation == c.originalLease.generation + 1)
                #expect(!published.appleAuthorizationEstablished && !published.installedApplicationRenewed)
                let retained = await reopened.developerMaterialObservation()
                #expect(retained == published)
                let namespace = try await c.fixture.vault.resume(namespaceID: c.fixture.namespace.id, identity: c.fixture.material)
                let lease = try await c.fixture.vault.lease(in: namespace)
                try await c.fixture.vault.validate(lease, for: c.fixture.material)
                let before = await c.peer.facts()
                do { _ = try await reopened.reconcileDeveloperMaterials(); Issue.record("Empty intent issued another material operation") }
                catch let failure as Client.Failure { #expect(failure == .reconciliationRequired) }
                let after = await c.peer.facts()
                #expect(before.paths == after.paths && after.validCSRs == 1 && after.profileRequests == 3)
                let raw = try #require(try c.fixture.storage.load(namespace: c.fixture.namespace.id))
                let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
                let record = try #require(object as? [String: Any])
                #expect(record["pending"] == nil)
                let currentConfiguration = try JSONDecoder().decode(AccountStoredConfiguration.self,
                    from: Data(contentsOf: configurationURL)).configuration
                #expect(currentConfiguration.namespaceID == originalConfiguration.namespaceID)
                #expect(currentConfiguration.codeAnchors == originalConfiguration.codeAnchors)
                #expect(currentConfiguration.profileAnchors == originalConfiguration.profileAnchors)
                let afterData = try Data(contentsOf: userDataURL)
                #expect(afterData == userData)
                // A fixture sentinel and identity equality do not certify all
                // App data, a cold process, installation or Apple authorization.
                try await reopened.close()
            } catch { do { try await reopened.close() } catch { Issue.record(error) }; throw error }
        }
    }

    @Test("expired installed and published profiles permit only same-manifest account enrollment, never signing access")
    func appSessionEnrollsAfterRealInstalledAndPublishedProfileExpiry() async throws {
        try await Self.withAccountAppSession(seedUnsubmitted: true, nearOriginalProfileExpiry: true) { c in
            _ = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            let configurationURL = c.root.appendingPathComponent("configuration.json")
            let beforeConfiguration = try JSONDecoder().decode(AccountStoredConfiguration.self,
                from: Data(contentsOf: configurationURL)).configuration
            let markerURL = c.root.appendingPathComponent("owned-enrollment-user-data.json")
            let marker = Data("{\"bookID\":\"owned\",\"spineIndex\":9,\"charOffset\":73}".utf8)
            try marker.write(to: markerURL)
            try await c.session.close()
            let now = c.fixture.date.addingTimeInterval(7201)
            let anchors = [SelfRenewalCMSFixture.rootCertificate] + c.fixture.issuer.certificateChainDER
            let expiredVault = Vault(codeAnchors: anchors, profileAnchors: anchors, clock: { now })
            let namespace = try await expiredVault.resume(namespaceID: c.fixture.namespace.id, identity: c.fixture.material)
            do { _ = try await expiredVault.lease(in: namespace); Issue.record("Expired published profile produced a current signing lease") }
            catch let failure as SelfRenewalProvisioningProfileVerifier.Failure { #expect(failure == .profileExpired) }
            let application = c.fixture.directory.appendingPathComponent("Owned.app")
            do {
                _ = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: application,
                    codeAnchors: anchors, profileAnchors: anchors, at: now)
                Issue.record("Expired actual installed profile became current Materials")
            } catch let failure as SelfRenewalProvisioningProfileVerifier.Failure { #expect(failure == .profileExpired) }
            await c.peer.issueNewMaterial(at: now)
            let reopened = c.newSession(at: now)
            do {
                let fresh = Client.Credentials(dsid: c.fixture.credentials.dsid, xcodeToken: c.fixture.credentials.xcodeToken,
                    expiresAt: now.addingTimeInterval(3600))
                // No successful bootstrap/current lease is a prerequisite for
                // this explicit account path. The real peer checks the same pin.
                let account = try await reopened.connectDeveloperAccount(fresh)
                #expect(account.personalTeamMatched)
                let published = try await reopened.refreshDeveloperMaterials(machineName: "Owned expiry enrollment")
                #expect(published.namespaceID == c.fixture.namespace.id && published.keyID == c.originalLease.keyID)
                #expect(published.generation == c.originalLease.generation + 1)
                #expect(published.profileExpiresAt.map { $0 > now } == true)
                #expect(!published.appleAuthorizationEstablished && !published.installedApplicationRenewed)
                let currentNamespace = try await expiredVault.resume(namespaceID: namespace.id, identity: c.fixture.material)
                let currentLease = try await expiredVault.lease(in: currentNamespace)
                try await expiredVault.validate(currentLease, for: c.fixture.material)
                #expect(currentLease.verifiedAt == now && currentLease.keyID == c.originalLease.keyID)
                do { _ = try await reopened.bootstrap(handoff: c.handoff); Issue.record("New publication reauthorized the still-expired installed Bundle") }
                catch let failure as SelfRenewalAppSession.Unavailable { #expect(failure.problem == .signingMaterials) }
                let status = await reopened.status()
                #expect(status?.access != .signing)
                let afterConfiguration = try JSONDecoder().decode(AccountStoredConfiguration.self,
                    from: Data(contentsOf: configurationURL)).configuration
                #expect(beforeConfiguration == afterConfiguration)
                let afterMarker = try Data(contentsOf: markerURL)
                #expect(afterMarker == marker)
                let facts = await c.peer.facts()
                #expect(facts.validCSRs == 1 && facts.profileRequests == 3)
                try await reopened.close()
                let again = c.newSession(at: now)
                do {
                    let observation = try await again.observeDeveloperAccount()
                    #expect(observation.personalTeamMatched)
                    let after = await c.peer.facts()
                    #expect(after.validCSRs == 1)
                    try await again.close()
                } catch { do { try await again.close() } catch { Issue.record(error) }; throw error }
            } catch { do { try await reopened.close() } catch { Issue.record(error) }; throw error }
        }
    }

    @Test("expired App reopens its exact unknown CSR intent without a second issue and failed logout remains denied")
    func appSessionReconcilesExpiredEnrollmentAndRetainsLogoutDenial() async throws {
        try await Self.withAccountAppSession(nearOriginalProfileExpiry: true) { c in
            _ = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            try await c.session.close()
            let now = c.fixture.date.addingTimeInterval(7201)
            await c.peer.issueNewMaterial(at: now)
            await c.peer.set(.lostCSRACK)
            let fresh = Client.Credentials(dsid: c.fixture.credentials.dsid, xcodeToken: c.fixture.credentials.xcodeToken,
                expiresAt: now.addingTimeInterval(3600))
            let interrupted = c.newSession(at: now)
            do {
                _ = try await interrupted.connectDeveloperAccount(fresh)
                do { _ = try await interrupted.refreshDeveloperMaterials(machineName: "Owned expired lost ACK"); Issue.record("Lost ACK became a publication") }
                catch let failure as Client.EnrollmentFailure { #expect(failure.remoteCertificateMayHaveBeenIssued) }
                try await interrupted.close()
            } catch { do { try await interrupted.close() } catch { Issue.record(error) }; throw error }
            await c.peer.set(.normal)
            let reopened = c.newSession(at: now)
            do {
                c.fixture.storage.failSave(afterSuccessfulSaves: 0)
                do { try await reopened.signOutDeveloperAccount(); Issue.record("Failed logout write was acknowledged") }
                catch let failure as Client.Failure { #expect(failure == .storage) }
                let deniedBefore = await c.peer.facts()
                do { _ = try await reopened.reconcileDeveloperMaterials(); Issue.record("Expiry enrollment bypassed local logout denial") }
                catch let failure as Client.Failure { #expect(failure == .signedOut) }
                let deniedAfter = await c.peer.facts()
                #expect(deniedBefore.paths == deniedAfter.paths)
                _ = try await reopened.connectDeveloperAccount(fresh)
                let published = try await reopened.reconcileDeveloperMaterials()
                #expect(published.keyID == c.originalLease.keyID && published.namespaceID == c.fixture.namespace.id)
                #expect(published.generation == c.originalLease.generation + 1)
                let facts = await c.peer.facts()
                #expect(facts.validCSRs == 1 && facts.profileRequests == 3)
                let retained = try #require(try c.fixture.storage.load(namespace: c.fixture.namespace.id))
                #expect(!retained.contains("certificateRequestIntent") && !retained.contains("certificateObserved"))
                let status = await reopened.status()
                #expect(status?.access != .signing)
                try await reopened.close()
            } catch { do { try await reopened.close() } catch { Issue.record(error) }; throw error }
        }
    }

    @Test("expired account entry refuses actual changed Bundle routing and an unknown configured namespace without HTTP")
    func appSessionEnrollmentRejectsChangedBundleAndMissingManifest() async throws {
        try await Self.withAccountAppSession(nearOriginalProfileExpiry: true) { c in
            try await c.session.close()
            let now = c.fixture.date.addingTimeInterval(7201)
            let infoURL = c.fixture.directory.appendingPathComponent("Owned.app/Info.plist")
            let originalInfo = try Data(contentsOf: infoURL)
            var info = try #require(PropertyListSerialization.propertyList(from: originalInfo, format: nil) as? [String: Any])
            info["CFBundleIdentifier"] = "invalid.changed.enrollment"
            let changed = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            try changed.write(to: infoURL)
            let before = await c.peer.facts()
            let refused = c.newSession(at: now)
            do {
                do { _ = try await refused.connectDeveloperAccount(c.fixture.credentials); Issue.record("Changed Bundle obtained an account owner") }
                catch let failure as Vault.Failure { #expect(failure == .identityChanged) }
                try await refused.close()
            } catch { do { try await refused.close() } catch { Issue.record(error) }; throw error }
            try originalInfo.write(to: infoURL)
            let configurationURL = c.root.appendingPathComponent("configuration.json")
            let raw = try Data(contentsOf: configurationURL)
            var document = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            var configuration = try #require(document["configuration"] as? [String: Any])
            configuration["namespaceID"] = UUID().uuidString
            document["configuration"] = configuration
            let unknown = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try unknown.write(to: configurationURL)
            let missing = c.newSession(at: now)
            do {
                do { _ = try await missing.connectDeveloperAccount(c.fixture.credentials); Issue.record("Caller UUID invented an enrollment namespace") }
                catch let failure as Vault.Failure { #expect(failure == .namespaceUnavailable) }
                try await missing.close()
            } catch { do { try await missing.close() } catch { Issue.record(error) }; throw error }
            let after = await c.peer.facts()
            #expect(before.paths == after.paths && after.validCSRs == 0)
        }
    }

    private enum EnrollmentFixtureStop: Error { case beforeRemoteCreation }

    @Test("expired enrollment cannot change generation after an actual authenticated upload intent")
    func appSessionExpiredEnrollmentRetainsRealUploadIntentBarrier() async throws {
        try await Self.withAccountAppSession(nearOriginalProfileExpiry: true) { c in
            _ = try await c.session.connectDeveloperAccount(c.fixture.credentials)
            try await c.session.close()
            let now = c.fixture.date.addingTimeInterval(7201)
            let journalRoot = c.root.appendingPathComponent("SelfRenewalTransactions")
            let journal = try await SelfRenewalTransactionJournal.open(at: journalRoot)
            // Only opaque transport bytes are needed to reach the authenticated
            // before-FileOpen hook. This fixture never asserts a signed IPA.
            let candidate = Data("owned enrollment transport-boundary bytes".utf8)
            let bundle = try #require(c.fixture.material.bundles.first { $0.componentRelativePath == "." })
            do {
                let created = try await journal.create(namespace: c.fixture.namespace.id, generation: c.originalLease.generation,
                    originalSHA256: Data(SHA256.hash(data: candidate)), identitySHA256: Data(SHA256.hash(data: Data(bundle.bundleIdentifier.utf8))),
                    bundleIdentifier: bundle.bundleIdentifier, bundleVersion: "1", at: c.fixture.date)
                let signing = try await journal.beginSigning(created, at: c.fixture.date)
                let archive = SelfRenewalTransactionJournal.ArchiveInput(byteCount: candidate.count,
                    sha256: Data(SHA256.hash(data: candidate)), read: { offset, count in candidate.subdata(in: offset..<offset + count) })
                let ready = try await journal.storeCandidate(signing, archive: archive, at: c.fixture.date)
                try await SelfRenewalAuthenticatedInstallationFixture.withPeer(.unusedInput, bytes: candidate,
                    bundle: bundle.bundleIdentifier, version: "1", at: now) { peer in
                    do {
                        _ = try await peer.upgrade(beforeCreation: { intent in
                            _ = try await journal.noteUploadIntent(ready, intent: intent, at: now)
                            throw EnrollmentFixtureStop.beforeRemoteCreation
                        })
                        Issue.record("Owned boundary stop returned an install receipt")
                    } catch let failure as SelfRenewalAuthenticatedInstallationClient.OperationFailure {
                        #expect(failure.underlying is EnrollmentFixtureStop)
                        #expect(!failure.upgradeMayHaveExecuted)
                    }
                    let observed = peer.observed.snapshot
                    #expect(observed.openedFileHandles == 0 && observed.upgradeRequests == 0)
                }
                let checkpoint = try await journal.load()
                let loaded = try #require(checkpoint)
                #expect(loaded.record.phase == .uploadIntent && loaded.record.remoteHistory == .started)
                try await journal.close()
            } catch { do { try await journal.close() } catch { Issue.record(error) }; throw error }
            let transactionURL = journalRoot.appendingPathComponent("transaction.json")
            let beforeTransaction = try Data(contentsOf: transactionURL)
            let beforeCandidate = try Data(contentsOf: journalRoot.appendingPathComponent("candidate.ipa"))
            let reopened = c.newSession(at: now)
            do {
                let fresh = Client.Credentials(dsid: c.fixture.credentials.dsid, xcodeToken: c.fixture.credentials.xcodeToken,
                    expiresAt: now.addingTimeInterval(3600))
                _ = try await reopened.connectDeveloperAccount(fresh)
                let before = await c.peer.facts()
                do { _ = try await reopened.refreshDeveloperMaterials(machineName: "Owned blocked expiry enrollment"); Issue.record("Upload intent allowed material generation change") }
                catch let failure as SelfRenewalTransactionJournal.Failure { #expect(failure == .activeTransaction) }
                let after = await c.peer.facts()
                #expect(before.paths == after.paths && after.validCSRs == 0 && after.profileRequests == 0)
                let afterTransaction = try Data(contentsOf: transactionURL)
                let afterCandidate = try Data(contentsOf: journalRoot.appendingPathComponent("candidate.ipa"))
                #expect(beforeTransaction == afterTransaction && beforeCandidate == afterCandidate)
                try await reopened.close()
            } catch { do { try await reopened.close() } catch { Issue.record(error) }; throw error }
        }
    }

    private struct AccountStoredConfiguration: Decodable {
        let configuration: SelfRenewalAppSession.Configuration
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
            let reopenedServices = SelfRenewalAppSession.DeveloperServices(transport: services.transport, storage: services.storage,
                freshAnisette: { Client.Anisette(machineID: "owned-machine", oneTimePassword: "owned-fresh-otp",
                    localUserID: "owned-local-user", routingInfo: 1, deviceID: "owned-device-id", clientInfo: "Owned controlled peer",
                    issuedAt: now, locale: "en_US", timeZone: "UTC") })
            return SelfRenewalAppSession(root: root,
                currentApplicationRoot: fixture.directory.appendingPathComponent("Owned.app"),
                developerServices: reopenedServices, clock: { now })
        }
    }
    nonisolated private static func withAccountAppSession(seedUnsubmitted: Bool = false, nearOriginalProfileExpiry: Bool = false,
        _ action: @escaping @Sendable (AccountAppContext) async throws -> Void) async throws {
        try await Self.fixture(nearOriginalProfileExpiry: nearOriginalProfileExpiry) { f in
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
            } catch {
                do { try await session.close() } catch { Issue.record(error) }
                throw error
            }
        }
    }
}
#endif
