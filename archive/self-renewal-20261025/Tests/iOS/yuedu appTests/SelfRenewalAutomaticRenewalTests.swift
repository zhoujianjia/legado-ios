import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

#if DEBUG
@Suite("Opt-in automatic renewal through actual current bundle and the existing session", .serialized)
struct SelfRenewalAutomaticRenewalTests {
    typealias App = SelfRenewalAppExecutionTests
    typealias Package = SelfRenewalControlledPackageSignerTests
    typealias Session = SelfRenewalAppSession
    typealias Peer = SelfRenewalAuthenticatedInstallationFixture
    typealias Unpacker = SelfRenewalIPAUnpacker

    @Test("actual current Bundle becomes a reverified bounded IPA and changed signed bytes cannot enter callback")
    func capturesActualCurrentBundleAndRejectsChangedSignedResources() async throws {
        try await Package.fixture { f in
            let application = try await Self.currentApplication(f)
            let anchors = [f.oldAnchor] + f.issuer.certificateChainDER
            let actual = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: application,
                codeAnchors: anchors, profileAnchors: anchors, at: f.date)
            let capture = try await Unpacker.withCurrentApplicationArchive(application: application,
                codeAnchors: anchors, profileAnchors: anchors, at: f.date) { ipa in
                let verified = try await Unpacker.verify(ipa: ipa, codeAnchors: anchors, profileAnchors: anchors, at: f.date)
                #expect(verified.application == actual)
                #expect(verified.archiveSHA256 != Data(SHA256.hash(data: f.originalBytes)))
                #expect(verified.entryCount <= SelfRenewalIPAArchiveValidator.Limits.entries)
                return ipa
            }
            #expect(!FileManager.default.fileExists(atPath: capture.path))
            let info = application.appendingPathComponent("Info.plist")
            var value = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
            value["CFBundleIdentifier"] = "owned.invalid.current.bundle"
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: info)
            do {
                _ = try await Unpacker.withCurrentApplicationArchive(application: application,
                    codeAnchors: anchors, profileAnchors: anchors, at: f.date) { _ in
                    Issue.record("Changed current bundle entered automatic preparation")
                }
                Issue.record("Changed current bundle became an IPA")
            } catch { #expect(!(error is CancellationError)) }
        }
    }

    @Test("opt-in and clock/throttle survive the same Document reopen without creating a transaction")
    func persistsOptInThrottleAndClockRollbackWithoutRemoteWork() async throws {
        try await Package.fixture { f in
            let application = try await Self.currentApplication(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let owners = try await App.library(in: f.directory, at: f.date)
            let handoff = await owners.handoff
            let clock = Clock(f.date)
            let session = Session(root: root, currentApplicationRoot: application, clock: { clock.value })
            do {
                _ = try await session.bootstrap(handoff: handoff)
                let off = await session.automaticRenewalObservation()
                #expect(!off.isEnabled && off.outcome == .disabled)
                _ = try await session.configure(from: App.configuration(f, device: nil), handoff: handoff)
                _ = try await session.setAutomaticRenewalEnabled(true)
                let first = try await session.runAutomaticRenewal(handoff: handoff)
                #expect(first.outcome == .configurationRequired && first.lastAttemptAt == nil)
                let path = root.appendingPathComponent("configuration.json")
                let before = try Data(contentsOf: path)
                _ = try await session.setAutomaticRenewalEnabled(true)
                _ = try await session.runAutomaticRenewal(handoff: handoff)
                #expect(try Data(contentsOf: path) == before)
                clock.set(f.date.addingTimeInterval(-1))
                let rollback = try await session.runAutomaticRenewal(handoff: handoff)
                #expect(rollback.outcome == .clockChanged && rollback.nextEligibleAt == clock.value.addingTimeInterval(3_600))
                try await session.close()
                let reopened = Session(root: root, currentApplicationRoot: application, clock: { f.date })
                _ = try await reopened.bootstrap(handoff: handoff)
                let preserved = await reopened.automaticRenewalObservation()
                #expect(preserved == rollback && preserved.isEnabled)
                let disabled = try await reopened.setAutomaticRenewalEnabled(false)
                #expect(!disabled.isEnabled && disabled.outcome == .disabled && disabled.nextEligibleAt == nil)
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SelfRenewalTransactions/transaction.json").path))
                try await reopened.close()
            } catch {
                do { try await session.close() } catch { Issue.record(error) }
                throw error
            }
        }
    }

    @Test("one due trigger captures current Bundle, really signs, persists and sends exact candidate with all three owners")
    func performsFullActualAutomaticRenewalAndNeverRepostsAReceipt() async throws {
        try await Package.fixture { f in
            let application = try await Self.currentApplication(f)
            try await Self.extendPublishedProfiles(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let owner = await MainActor.run { SelfRenewalAppOwner(root: root, currentApplicationRoot: application, clock: { f.date }) }
            let owners = try await App.library(in: f.directory, at: f.date, handoff: owner.handoff)
            let foreground = await MainActor.run {
                owner.noteScenePhase(.inactive)
                return owner.noteScenePhase(.active)
            }
            await owner.start(books: owners.books, sources: owners.sources, positions: owners.positions,
                foregroundGeneration: foreground)
            // The fixture peer validates the exact real persisted candidate at
            // AFC Close; the test independently verifies that ZIP afterwards.
            let current = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: application,
                codeAnchors: [f.oldAnchor] + f.issuer.certificateChainDER,
                profileAnchors: [f.oldAnchor] + f.issuer.certificateChainDER, at: f.date)
            let metadata = try #require(current.resources.executableMaterials.inventory.components.first { $0.relativePath == "." }?.metadata)
            do {
                try await Peer.withPeer(bytes: Data([1]), bundle: metadata.bundleIdentifier, version: metadata.build, at: f.date,
                    expectedUploadedArchive: {
                        try App.candidate(root, record: App.record(root))
                    }) { peer in
                    await owner.importConfiguration(try App.configuration(f, device: App.device(peer)))
                    await owner.setAutomaticRenewalEnabled(true)
                    let observed = await MainActor.run { (owner.automaticRenewal, owner.status, owner.problem, owner.isWorking) }
                    #expect(observed.0?.outcome == .receiptObserved && observed.0?.lastAttemptAt == f.date)
                    #expect(observed.1?.phase == .receiptObserved && observed.2 == nil && !observed.3)
                    #expect(observed.0?.automaticRenewalVerified == false && observed.1?.coldLaunchVerified == false)
                    let record = try App.record(root)
                    #expect(record.originalArchiveSHA256 != Data(SHA256.hash(data: f.originalBytes)))
                    #expect(record.userDataHandoff?.capturedAt == f.date)
                    #expect(record.userDataHandoff?.files.map(\.role) == ["shelf", "reading", "sources"])
                    #expect(record.userDataHandoff?.positions.first?.position == App.position)
                    let candidate = try App.candidate(root, record: record)
                    #expect(peer.observed.snapshot.uploaded == candidate && peer.observed.snapshot.upgradeRequests == 1)
                    let independent = f.directory.appendingPathComponent("automatic-independent.ipa")
                    try candidate.write(to: independent)
                    let verified = try await Unpacker.verify(ipa: independent, codeAnchors: f.issuer.certificateChainDER,
                        profileAnchors: f.issuer.certificateChainDER, at: f.date)
                    #expect(verified.application.profiles.profiles.allSatisfy { $0.summary.expiresAt == f.date.addingTimeInterval(7_200) })
                    _ = await owner.runAutomaticRenewalNow()
                    #expect(peer.observed.snapshot.upgradeRequests == 1)
                }
                try await owner.close()
            } catch { do { try await owner.close() } catch { Issue.record(error) }; throw error }
        }
    }

    @Test("automatic ready resume preserves rejected candidates and requires current App expiry advancement before transport")
    func resumedReadyCandidateRequiresExpiryAdvanceAndReadableCurrentApplication() async throws {
        let cases: [(expiresAfter: TimeInterval, corruptCurrent: Bool, submits: Bool)] = [
            (3_600, false, false), (1_800, false, false),
            (7_200, true, false), (7_200, false, true),
        ]
        for testCase in cases {
            try await Package.fixture { f in
                // Capture the original currently running fixture before the
                // publication changes. The real current profiles last one hour.
                let application = try await Self.currentApplication(f)
                try await Self.extendPublishedProfiles(f, expiresAfter: testCase.expiresAfter)
                let root = f.directory.appendingPathComponent("SelfRenewalApp")
                let owners = try await App.library(in: f.directory, at: f.date)
                let handoff = await owners.handoff
                let session = Session(root: root, currentApplicationRoot: application, clock: { f.date })
                do {
                    _ = try await session.bootstrap(handoff: handoff)
                    _ = try await session.configure(from: App.configuration(f, device: nil), handoff: handoff)
                    // Manual preparation deliberately keeps its original API:
                    // even shorter still-valid profiles can become ready.
                    let prepared = try await session.prepareRenewal(from: f.input)
                    #expect(prepared.phase == .candidateReady)
                    let ready = try App.record(root)
                    let candidate = try App.candidate(root, record: ready)
                    let recordPath = root.appendingPathComponent("SelfRenewalTransactions/transaction.json")
                    let initialRecord = try Data(contentsOf: recordPath)
                    let mode: Peer.Mode = testCase.submits ? .normal : .unusedInput
                    try await Peer.withPeer(mode, bytes: candidate, bundle: ready.bundleIdentifier,
                        version: ready.bundleVersion, at: f.date) { peer in
                        _ = try await session.configure(from: App.configuration(f, device: App.device(peer)), handoff: handoff)
                        _ = try await session.setAutomaticRenewalEnabled(true)
                        if testCase.corruptCurrent {
                            // Admission must use a fresh actual App read; an old
                            // connected validity bound must not authorize upload.
                            try Data("unreadable-current-profile".utf8).write(to:
                                application.appendingPathComponent("embedded.mobileprovision"))
                        }
                        if testCase.submits {
                            let result = try await session.runAutomaticRenewal(handoff: handoff)
                            #expect(result.outcome == .receiptObserved && !result.automaticRenewalVerified)
                            #expect(peer.observed.snapshot.uploaded == candidate)
                            #expect(peer.observed.snapshot.upgradeRequests == 1)
                            #expect(try App.record(root).phase == .receiptObserved)
                        } else {
                            do {
                                _ = try await session.runAutomaticRenewal(handoff: handoff)
                                Issue.record("Automatic ready resume accepted absent expiry advancement or unreadable current material")
                            } catch { #expect(!(error is CancellationError)) }
                            let result = await session.automaticRenewalObservation()
                            #expect(result.outcome == .failed && !result.automaticRenewalVerified)
                            #expect(peer.observed.snapshot.authenticatedChannels == 0)
                            #expect(peer.observed.snapshot.openedFileHandles == 0)
                            #expect(peer.observed.snapshot.uploaded.isEmpty && peer.observed.snapshot.upgradeRequests == 0)
                            #expect(try Data(contentsOf: recordPath) == initialRecord)
                            #expect(try App.candidate(root, record: App.record(root)) == candidate)
                            let preserved = try App.record(root)
                            #expect(preserved.phase == .candidateReady && preserved.submission == nil)
                            #expect(preserved.remoteHistory == .neverStarted && preserved.materialGeneration == ready.materialGeneration)
                        }
                    }
                    try await session.close()
                } catch { do { try await session.close() } catch { Issue.record(error) }; throw error }
            }
        }
    }

    @Test("caller expiration cancels the actual automatic TLS task and awaits durable candidate recovery")
    func cancellationDrainsActualAutomaticTransportAndPersistsInterruption() async throws {
        try await Package.fixture { f in
            let application = try await Self.currentApplication(f)
            try await Self.extendPublishedProfiles(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let owners = try await App.library(in: f.directory, at: f.date)
            let handoff = await owners.handoff
            let session = Session(root: root, currentApplicationRoot: application, clock: { f.date })
            do {
                _ = try await session.bootstrap(handoff: handoff)
                try await Peer.withPeer(.stallSession, bytes: Data([1]), at: f.date) { peer in
                    _ = try await session.configure(from: App.configuration(f, device: App.device(peer)), handoff: handoff)
                    _ = try await session.setAutomaticRenewalEnabled(true)
                    let operation = Task { try await session.runAutomaticRenewal(handoff: handoff) }
                    var signal = peer.sessionRequestReceived.makeAsyncIterator()
                    #expect(await signal.next() != nil)
                    operation.cancel()
                    do { _ = try await operation.value; Issue.record("Expired automatic TLS task reported success") }
                    catch { }
                    let observed = await session.automaticRenewalObservation()
                    #expect(observed.outcome == .interrupted && observed.nextEligibleAt != nil)
                    let record = try App.record(root)
                    #expect(record.phase == .candidateReady && record.submission == nil && record.remoteHistory == .neverStarted)
                    #expect(peer.observed.snapshot.upgradeRequests == 0 && peer.observed.snapshot.uploaded.isEmpty)
                    let before = try App.candidate(root, record: record)
                    _ = try await session.runAutomaticRenewal(handoff: handoff)
                    #expect(try App.candidate(root, record: App.record(root)) == before)
                }
                try await session.close()
            } catch { do { try await session.close() } catch { Issue.record(error) }; throw error }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var stored: Date
        init(_ date: Date) { stored = date }
        var value: Date { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ date: Date) { lock.lock(); stored = date; lock.unlock() }
    }
    private nonisolated static func currentApplication(_ f: Package.Fixture) async throws -> URL {
        let signed = try await f.sign()
        let ipa = f.directory.appendingPathComponent("current-signed.ipa")
        try await signed.archive.data(maximumBytes: 1_048_576).write(to: ipa)
        let destination = f.directory.appendingPathComponent("Current.app")
        try await Unpacker.withOwnedApplication(ipa: ipa, codeAnchors: f.issuer.certificateChainDER,
            profileAnchors: f.issuer.certificateChainDER, at: f.date) { scope in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for fact in scope.original.resources.executableMaterials.inventory.files {
                let file = destination.appendingPathComponent(fact.relativePath)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await scope.read(fact.relativePath, maximumBytes: 1_048_576).write(to: file)
            }
        }
        return destination
    }
    private nonisolated static func extendPublishedProfiles(_ f: Package.Fixture,
        expiresAfter: TimeInterval = 7_200) async throws {
        let leaf = try #require(f.lease.keyMaterial.certificateChainDER.first)
        let profiles = try f.lease.profiles.map { profile in
            let path = profile.file.relativePath
            let component = path == "embedded.mobileprovision" ? "." : String(path.dropLast("/embedded.mobileprovision".count))
            return SelfRenewalSigningMaterialVault.ProfileInput(componentRelativePath: component,
                bytes: try SelfRenewalSigningOwnedPKIFixture.profile(from: profile, developerCertificate: leaf,
                    issuer: f.issuer, at: f.date) { $0["ExpirationDate"] = .date(f.date.addingTimeInterval(expiresAfter)) })
        }
        _ = try await f.vault.publish(in: f.namespace, keyID: f.lease.keyID, expectedGeneration: f.lease.generation,
            certificateChainDER: f.lease.keyMaterial.certificateChainDER, profiles: profiles)
    }
}
#endif
