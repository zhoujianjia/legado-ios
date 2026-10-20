import Foundation
import Testing
@testable import yuedu_app

@Suite("Actual supported signed materials and process-scoped observation", .serialized)
struct SelfRenewalInstalledMaterialObserverTests {
    typealias Observer = SelfRenewalInstalledMaterialObserver
    typealias Package = SelfRenewalControlledPackageSignerTests
    typealias Unpacker = SelfRenewalIPAUnpacker
    typealias Journal = SelfRenewalTransactionJournal
    typealias Coordinator = SelfRenewalControlledRenewalCoordinator
    typealias Peer = SelfRenewalAuthenticatedInstallationFixture

    @Test("separate real extraction of the renewed three-bundle package has the same signed projection")
    func matchesActualCodeDirectoriesCertificatesProfilesAndOrderedGroups() async throws {
        try await Self.withCandidate { fixture, candidate, input in
            let result = try await Unpacker.withOwnedApplication(ipa: input, codeAnchors: fixture.issuer.certificateChainDER,
                profileAnchors: fixture.issuer.certificateChainDER, at: fixture.date) { scope in
                try Observer.compareVerifiedMaterial(scope.original, expected: candidate)
            }
            #expect(result.candidateArchiveSHA256 == candidate.archiveSHA256)
            #expect(result.candidateArchiveBytes == candidate.archiveBytes)
            #expect(result.authenticatedMaterialSHA256.count == 32)
            #expect(result.codeFiles == 3 && result.profiles == 3)
            let again = try Observer.compareVerifiedMaterial(candidate.application, expected: candidate)
            #expect(again.authenticatedMaterialSHA256 == result.authenticatedMaterialSHA256)
        }
    }

    @Test("old fully verified signature is not the new package even with identical version and business IDs")
    func rejectsOldSignedMaterialWithTheSameReportedIdentityAndVersion() async throws {
        try await Self.withCandidate { fixture, candidate, _ in
            let old = try await Unpacker.verify(ipa: fixture.input, codeAnchors: [fixture.oldAnchor],
                profileAnchors: [fixture.oldAnchor], at: fixture.date)
            #expect(old.application.bundles.map(\.bundleIdentifier) == candidate.application.bundles.map(\.bundleIdentifier))
            #expect(old.application.bundles.map(\.slices) != candidate.application.bundles.map(\.slices))
            do { _ = try Observer.compareVerifiedMaterial(old.application, expected: candidate)
                Issue.record("Same bundle/version Lookup identity replaced actual renewed signing material")
            } catch Observer.Failure.codeChanged {}
        }
    }

    @Test("actual current host Bundle cannot be replaced by an arbitrary fixture URL or Complete receipt")
    func unavailableCurrentProcessDoesNotAdvanceOrEraseThePendingTransaction() async throws {
        try await Package.fixture { fixture in
            let journal = try await Journal.open(at: fixture.directory.appendingPathComponent("SelfRenewalTransactions"))
            do {
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await coordinator.prepare(ipa: fixture.input, lease: fixture.lease,
                    originalCodeAnchors: [fixture.oldAnchor], originalProfileAnchors: [fixture.oldAnchor])
                let input = try await journal.candidateURL(ready)
                let bytes = try Data(contentsOf: input)
                try await Peer.withPeer(bytes: bytes, bundle: ready.record.bundleIdentifier,
                    version: ready.record.bundleVersion, at: fixture.date) { peer in
                    let transport = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    let before = transport.snapshot
                    do { _ = try await coordinator.observeCurrentProcess()
                        Issue.record("Unrelated actual XCTest host accepted as the renewed synthetic package")
                    } catch is Observer.Unavailable {}
                    let after = try await journal.load()
                    #expect(after?.record == before.record)
                    #expect(after?.record.installedMaterial == nil)
                    #expect(after?.record.observedDifferentProcess == nil)
                    #expect(after?.record.renewalVerified == false)
                }
                try await coordinator.close()
            } catch { do { try await journal.close() } catch { Issue.record(error) }; throw error }
        }
    }

    @Test("foreground or owner reopen in the same process does not fabricate a cold-launch event")
    func preservesOneActualProcessIdentityWithoutObservingAnUnsubmittedCandidate() async throws {
        try await Package.fixture { fixture in
            let root = fixture.directory.appendingPathComponent("SelfRenewalTransactions")
            let journal = try await Journal.open(at: root)
            do {
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let absent = try await coordinator.observeCurrentProcess()
                #expect(absent == nil)
                let ready = try await coordinator.prepare(ipa: fixture.input, lease: fixture.lease,
                    originalCodeAnchors: [fixture.oldAnchor], originalProfileAnchors: [fixture.oldAnchor])
                let active = try await coordinator.observeCurrentProcess()
                #expect(active?.record == ready.record)
                #expect(ready.record.preparationProcessID == Observer.ProcessIdentity.current.id)
                #expect(active?.record.installedMaterial == nil && active?.record.observedDifferentProcess == nil)
                try await coordinator.close()
                let reopened = try await Journal.open(at: root)
                do {
                    let restored = try await reopened.load()
                    #expect(restored?.record.preparationProcessID == Observer.ProcessIdentity.current.id)
                    #expect(restored?.record.observedDifferentProcess == nil && restored?.record.renewalVerified == false)
                    try await reopened.close()
                } catch { try await reopened.close(); throw error }
            } catch { do { try await journal.close() } catch { Issue.record(error) }; throw error }
        }
    }

    nonisolated private static func withCandidate(_ action: @escaping @Sendable (Package.Fixture, Unpacker.Materials, URL) async throws -> Void) async throws {
        try await Package.fixture { fixture in
            let signed = try await fixture.sign()
            let raw = try await signed.archive.data(maximumBytes: 1_048_576)
            let input = fixture.directory.appendingPathComponent("observed-candidate.ipa")
            try raw.write(to: input, options: .withoutOverwriting)
            let candidate = try await Unpacker.verify(ipa: input, codeAnchors: fixture.issuer.certificateChainDER,
                profileAnchors: fixture.issuer.certificateChainDER, at: fixture.date)
            try await action(fixture, candidate, input)
        }
    }
}
