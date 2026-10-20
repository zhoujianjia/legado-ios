import Foundation
import LegadoRuntime
import os

/// Queue-owned variable projection for explicitly granted App records. It stores no file
/// and owns no queue. Every ordinary metadata write consults this bounded projection so
/// an older queued whole-record snapshot cannot undo an accepted runtime variable commit.
final class OriginalRuntimeBookMetadataOwner: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let book: BookStore.RuntimeBookSnapshot
        let revision: UInt64
    }
    struct BookmarkIdentity: Sendable, Equatable, Codable {
        let id: UUID
        let contentFilename: String
        let source: String
        init(_ record: ReadingBook) { id = record.id; contentFilename = record.contentFilename; source = record.source }
    }
    struct BookmarkProof: Sendable, Equatable {
        let identity: BookmarkIdentity
        let bookmarks: [Bookmark]
        let lease: UUID
        let revision: UInt64
    }
    private struct Entry {
        var snapshot: Snapshot
        var pendingPublication = false
    }
    private let queue: DispatchQueue
    private var entries: [UUID: Entry] = [:]
    private var recency: [UUID] = []
    private var revision: UInt64 = 0
    private var bookmarkEntries: [UUID: BookmarkProof] = [:]
    private let bookmarkVersions = OSAllocatedUnfairLock<[UUID: UInt64]>(initialState: [:])
    /// Only a revision proof, bounded with entries; UI never reads the queue-owned maps.
    private let publicationVersions = OSAllocatedUnfairLock<[UUID: UInt64]>(initialState: [:])

    init(persistenceQueue: DispatchQueue) { queue = persistenceQueue }

    var isEmpty: Bool { dispatchPrecondition(condition: .onQueue(queue)); return entries.isEmpty && bookmarkEntries.isEmpty }

    func beginBookmarks(identity: BookmarkIdentity, bookmarks: [Bookmark], lease: UUID,
                        recovering: Bool = false, migrated: [Bookmark]) throws -> BookmarkProof {
        dispatchPrecondition(condition: .onQueue(queue))
        if recovering {
            guard let old = bookmarkEntries[identity.id], old.lease == lease, old.identity == identity,
                  old.bookmarks == migrated, bookmarks == migrated else {
                throw TXTLocationMigration.Failure.missingSourceIdentity
            }
            return old
        }
        guard bookmarkEntries[identity.id] == nil, bookmarkEntries.count < 256 else {
            throw LegadoRuntimeError(code: "STATE_LIMIT", message: "A bookmark migration is pending or the owner is full")
        }
        let proof = try bookmarkProof(identity: identity, bookmarks: bookmarks, lease: lease)
        bookmarkEntries[identity.id] = proof
        bookmarkVersions.withLock { $0[identity.id] = proof.revision }
        return proof
    }

    func bookmarkCandidate(_ expected: BookmarkProof, bookmarks: [Bookmark]) throws -> BookmarkProof {
        dispatchPrecondition(condition: .onQueue(queue))
        guard bookmarkEntries[expected.identity.id] == expected else {
            throw TXTLocationMigration.Failure.missingSourceIdentity
        }
        return try bookmarkProof(identity: expected.identity, bookmarks: bookmarks, lease: expected.lease)
    }

    func acceptBookmarks(_ proof: BookmarkProof) {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(bookmarkEntries[proof.identity.id]?.lease == proof.lease)
        bookmarkEntries[proof.identity.id] = proof
        bookmarkVersions.withLock { $0[proof.identity.id] = proof.revision }
    }

    func noteBookmarkChange(identity: BookmarkIdentity, previous: [Bookmark], bookmarks: [Bookmark]?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let old = bookmarkEntries[identity.id] else { return }
        guard old.identity == identity, let bookmarks else { releaseBookmarks(id: identity.id, lease: old.lease); return }
        guard previous != bookmarks else { return }
        guard old.bookmarks != bookmarks else { return }
        let next = try bookmarkProof(identity: identity, bookmarks: bookmarks, lease: old.lease)
        acceptBookmarks(next)
    }

    func permitsBookmarkPublication(_ proof: BookmarkProof) -> Bool {
        bookmarkVersions.withLock { $0[proof.identity.id] == proof.revision }
    }

    func releaseBookmarks(id: UUID, lease: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard bookmarkEntries[id]?.lease == lease else { return }
        bookmarkEntries.removeValue(forKey: id)
        bookmarkVersions.withLock { $0.removeValue(forKey: id) }
    }

    private func bookmarkProof(identity: BookmarkIdentity, bookmarks: [Bookmark], lease: UUID) throws -> BookmarkProof {
        guard revision < UInt64.max else { throw LegadoRuntimeError(code: "STATE_LIMIT", message: "App metadata revision exhausted") }
        revision += 1
        return .init(identity: identity, bookmarks: bookmarks, lease: lease, revision: revision)
    }

    func register(_ book: BookStore.RuntimeBookSnapshot) throws -> Snapshot {
        dispatchPrecondition(condition: .onQueue(queue))
        if let entry = entries[book.id], sameIdentity(entry.snapshot.book, book) {
            touch(book.id)
            return entry.snapshot
        }
        if entries[book.id] == nil, entries.count >= 256 {
            guard let old = recency.first(where: { entries[$0]?.pendingPublication == false }) else {
                throw LegadoRuntimeError(code: "STATE_LIMIT", message: "All App book owners await their accepted publication")
            }
            entries.removeValue(forKey: old); recency.removeAll { $0 == old }
            publicationVersions.withLock { $0.removeValue(forKey: old) }
        }
        let snapshot = try next(book)
        entries[book.id] = .init(snapshot: snapshot)
        publicationVersions.withLock { $0[book.id] = snapshot.revision }
        touch(book.id)
        return snapshot
    }

    /// previous/current are actual UI record values, captured at the sole record write
    /// point. A progress-only change does not replace a newer queue-owned variable map.
    func noteAppChange(previous: BookStore.RuntimeBookSnapshot, current: BookStore.RuntimeBookSnapshot?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let old = entries[previous.id] else { return }
        guard let current, sameIdentity(previous, current), sameIdentity(old.snapshot.book, current) else {
            entries.removeValue(forKey: previous.id); recency.removeAll { $0 == previous.id }
            publicationVersions.withLock { $0.removeValue(forKey: previous.id) }; return
        }
        // TOC/title/progress metadata does not advance a variables-key revision. It must
        // neither shadow an accepted variable map nor revoke that map's UI publication.
        guard previous.variables != current.variables else { return }
        let desired = current
        do { entries[current.id] = .init(snapshot: try next(desired)) }
        catch {
            // A runtime revision limit cannot make ordinary App edits persist an older
            // overlay. Retire this proof; the App record remains the normal writer input.
            entries.removeValue(forKey: current.id); recency.removeAll { $0 == current.id }
            publicationVersions.withLock { $0.removeValue(forKey: current.id) }
            throw error
        }
        publicationVersions.withLock { $0[current.id] = entries[current.id]!.snapshot.revision }
        touch(current.id)
    }

    func matches(_ expected: Snapshot) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return entries[expected.book.id]?.snapshot == expected
    }

    func candidate(_ expected: Snapshot, variables: [String: String]?) throws -> Snapshot? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard matches(expected) else { return nil }
        return try next(Self.replacingVariables(in: expected.book, with: variables))
    }

    /// No fallible operation follows the atomic file replacement before acknowledgement.
    func accepted(_ expected: Snapshot, candidate: Snapshot) {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(matches(expected))
        entries[expected.book.id] = .init(snapshot: candidate, pendingPublication: true)
        publicationVersions.withLock { $0[expected.book.id] = candidate.revision }
        touch(expected.book.id)
    }

    /// Enqueued after the one UI publication. Thus every whole-record snapshot captured
    /// before publication has already passed the overlay before this entry is evictable.
    func publicationFinished(_ accepted: Snapshot) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard entries[accepted.book.id]?.snapshot == accepted else { return }
        entries[accepted.book.id]?.pendingPublication = false
    }

    func permitsPublication(_ accepted: Snapshot) -> Bool {
        publicationVersions.withLock { $0[accepted.book.id] == accepted.revision }
    }

    func applying(to records: [ReadingBook]) -> [ReadingBook] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !entries.isEmpty || !bookmarkEntries.isEmpty else { return records }
        var result = records
        for index in result.indices {
            if let bookmarks = bookmarkEntries[result[index].id], BookmarkIdentity(result[index]) == bookmarks.identity {
                result[index].bookmarks = bookmarks.bookmarks
            }
            guard let desired = entries[result[index].id]?.snapshot.book,
                  result[index].isOnline, result[index].bookSourceId == desired.sourceID,
                  (result[index].bookInfoURL ?? result[index].source) == desired.bookURL else { continue }
            result[index].runtimeVariables = desired.variables
        }
        return result
    }

    private func next(_ book: BookStore.RuntimeBookSnapshot) throws -> Snapshot {
        guard revision < UInt64.max else { throw LegadoRuntimeError(code: "STATE_LIMIT", message: "App book owner revision exhausted") }
        revision += 1
        return .init(book: book, revision: revision)
    }
    private func touch(_ id: UUID) { recency.removeAll { $0 == id }; recency.append(id) }
    private func sameIdentity(_ a: BookStore.RuntimeBookSnapshot, _ b: BookStore.RuntimeBookSnapshot) -> Bool {
        a.id == b.id && a.isOnline && b.isOnline && a.sourceID == b.sourceID && a.bookURL == b.bookURL
    }
    static func replacingVariables(in book: BookStore.RuntimeBookSnapshot, with variables: [String: String]?) -> BookStore.RuntimeBookSnapshot {
        .init(id: book.id, sourceID: book.sourceID, isOnline: book.isOnline, bookURL: book.bookURL,
            tocURL: book.tocURL, variables: variables)
    }
}
