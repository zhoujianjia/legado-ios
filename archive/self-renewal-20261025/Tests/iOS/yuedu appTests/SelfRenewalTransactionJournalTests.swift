import CryptoKit
import Darwin
import Foundation
import Testing
@testable import yuedu_app

@Suite("Single durable renewal journal owner", .serialized)
struct SelfRenewalTransactionJournalTests {
    typealias Journal = SelfRenewalTransactionJournal

    @Test("actual flock excludes a second owner and reopening retains the exact checkpoint")
    func excludesSecondOwnerAndReopensDurableCheckpoint() async throws {
        try await Self.fixture { parent in
            let root = parent.appendingPathComponent("SelfRenewalTransactions")
            let journal = try await Journal.open(at: root)
            do {
                let created = try await Self.create(journal)
                let signing = try await journal.beginSigning(created, at: created.record.createdAt)
                do { _ = try await Journal.open(at: root); Issue.record("Two durable journal owners opened") }
                catch Journal.Failure.ownerAlreadyOpen {}
                try await journal.close()
                let reopened = try await Journal.open(at: root)
                do {
                    let loaded = try await reopened.load()
                    let snapshot = try #require(loaded)
                    #expect(snapshot.record == signing.record)
                    do { _ = try await reopened.beginSigning(created, at: created.record.createdAt)
                        Issue.record("A previous owner snapshot was accepted after reopen")
                    } catch Journal.Failure.staleSnapshot {}
                    try await reopened.close()
                } catch { try await reopened.close(); throw error }
            } catch { try await journal.close(); throw error }
        }
    }

    @Test("strict phase validation rejects a ready candidate carrying old upload authority")
    func rejectsContradictoryDurablePhaseInsteadOfResubmitting() async throws {
        try await Self.fixture { parent in
            let root = parent.appendingPathComponent("SelfRenewalTransactions")
            let journal = try await Journal.open(at: root)
            let created = try await Self.create(journal)
            try await journal.close()
            var contradictory = created.record
            contradictory.phase = .candidateReady
            contradictory.candidate = .init(byteCount: 1, sha256: Data(repeating: 0x11, count: 32))
            contradictory.submission = .init(remotePackagePath: "PublicStaging/reader-renewal-" + UUID().uuidString.lowercased() + ".ipa",
                deviceCertificateSHA256: Data(repeating: 0x22, count: 32))
            try JSONEncoder().encode(contradictory).write(to: root.appendingPathComponent("transaction.json"))
            let reopened = try await Journal.open(at: root)
            do {
                do { _ = try await reopened.load(); Issue.record("Contradictory ready/upload authority was accepted") }
                catch Journal.Failure.malformedRecord {}
                try await reopened.close()
            } catch { try await reopened.close(); throw error }
        }
    }

    @Test("candidate hashing cancellation and stale CAS preserve the previous durable record")
    func rejectsFailedCandidateWithoutAcknowledgingOrReplacingState() async throws {
        try await Self.fixture { parent in
            let journal = try await Journal.open(at: parent.appendingPathComponent("SelfRenewalTransactions"))
            do {
                let created = try await Self.create(journal)
                let signing = try await journal.beginSigning(created, at: created.record.createdAt)
                let bytes = Data(repeating: 0x35, count: 131_073)
                let wrong = Journal.ArchiveInput(byteCount: bytes.count, sha256: Data(repeating: 0, count: 32),
                    read: { offset, count in bytes.subdata(in: offset..<(offset + count)) })
                do { _ = try await journal.storeCandidate(signing, archive: wrong, at: signing.record.updatedAt)
                    Issue.record("Incorrect candidate digest was published")
                } catch Journal.Failure.invalidCandidate {}
                let afterFailure = try await journal.load()
                #expect(afterFailure?.record == signing.record)
                let valid = Journal.ArchiveInput(byteCount: bytes.count, sha256: Data(SHA256.hash(data: bytes)), read: wrong.read)
                let cancelled = Task.detached {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await journal.storeCandidate(signing, archive: valid, at: signing.record.updatedAt)
                }
                do { _ = try await cancelled.value; Issue.record("Cancelled candidate was published") }
                catch is CancellationError {}
                let afterCancel = try await journal.load()
                #expect(afterCancel?.record == signing.record)
                let ready = try await journal.storeCandidate(signing, archive: valid, at: signing.record.updatedAt)
                let head = try await journal.readCandidate(ready, at: 0, count: 65_536)
                #expect(head == Data(bytes.prefix(65_536)))
                do { _ = try await journal.storeCandidate(signing, archive: valid, at: signing.record.updatedAt)
                    Issue.record("Stale signing snapshot replaced a committed candidate")
                } catch Journal.Failure.staleSnapshot {}
                let final = try await journal.load()
                #expect(final?.record == ready.record && final?.record.renewalVerified == false)
                try await journal.close()
            } catch { try await journal.close(); throw error }
        }
    }

    @Test("reopen reclaims only strict owned crash temporaries and preserves the checkpoint")
    func reclaimsAbandonedOwnedTemporaryAfterProcessInterruption() async throws {
        try await Self.fixture { parent in
            let root = parent.appendingPathComponent("SelfRenewalTransactions")
            let journal = try await Journal.open(at: root)
            let created = try await Self.create(journal)
            try await journal.close()
            let orphan = root.appendingPathComponent(".candidate-" + UUID().uuidString.lowercased() + ".tmp")
            try Data(repeating: 0x7f, count: 4096).write(to: orphan, options: .withoutOverwriting)
            guard chmod(orphan.path, 0o600) == 0 else { throw Journal.Failure.storageIO }
            let reopened = try await Journal.open(at: root)
            do {
                let loaded = try await reopened.load()
                #expect(loaded?.record == created.record)
                #expect(!FileManager.default.fileExists(atPath: orphan.path))
                try await reopened.close()
            } catch { try await reopened.close(); throw error }
            let unrelated = root.appendingPathComponent("unrelated-user-file")
            let unrelatedBytes = Data("do not remove".utf8)
            try unrelatedBytes.write(to: unrelated, options: .withoutOverwriting)
            do { _ = try await Journal.open(at: root); Issue.record("Unrecognized owner directory entry was ignored") }
            catch Journal.Failure.invalidDirectory {}
            let remaining = try Data(contentsOf: unrelated)
            #expect(remaining == unrelatedBytes)
        }
    }

    nonisolated private static func create(_ journal: Journal) async throws -> Journal.Snapshot {
        try await journal.create(namespace: UUID(), generation: 1,
            originalSHA256: Data(repeating: 0x31, count: 32), identitySHA256: Data(repeating: 0x41, count: 32),
            bundleIdentifier: "owned.reader", bundleVersion: "42", at: Date(timeIntervalSince1970: 1_792_540_800))
    }
    nonisolated private static func fixture(_ action: @escaping @Sendable (URL) async throws -> Void) async throws {
        try await Task.detached {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent("owned-renewal-journal-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            do { try await action(parent); try FileManager.default.removeItem(at: parent) }
            catch { do { try FileManager.default.removeItem(at: parent) } catch { Issue.record(error) }; throw error }
        }.value
    }
}
