import Foundation
import LegadoRuntime

/// A proof borrowed from an existing ChapterFetchManager job. Imported JSON cannot create
/// it. The manager invalidates this same ticket when that generation is cancelled/replaced.
final class OriginalRuntimeChapterGeneration: @unchecked Sendable {
    let bookID: UUID
    let chapterID: UUID
    let index: Int
    let url: String
    let token: UUID
    private let cancellation = OriginalRuntimeCommitCancellation()

    init(bookID: UUID, chapter: OnlineChapterRef, token: UUID) {
        self.bookID = bookID; self.chapterID = chapter.id
        self.index = chapter.index; self.url = chapter.url; self.token = token
    }
    func revoke() { cancellation.cancel() }
    func check(deadline: Date) throws { try cancellation.check(deadline: deadline) }
}

struct LegadoEntityStateKey: Sendable {
    let wire: String
    let chapterURL: String?
    /// nil is the complete short-variable JSON map; non-nil is one large variable.
    let largeVariable: String?
}

struct LegadoEntityStateSnapshot: Sendable {
    let book: BookStore.RuntimeBookSnapshot
    let chapter: BookChapterStore.RuntimeVariablesSnapshot?
    let state: LegadoOwnedStateSnapshot
}

/// Uses an explicitly supplied App store and its existing UUIDs. This adapter reads the
/// owned book record and durably commits chapter variables to that store's chapter file.
/// Shelf/reading metadata writes and cross-owner transactions remain typed unsupported.
final class AppLegadoBookStateOwner: @unchecked Sendable {
    let bookID: UUID
    let sourceID: UUID
    let bookURL: String
    let chapter: OnlineChapterRef?
    private let store: BookStore
    private let generation: OriginalRuntimeChapterGeneration?
    private let lifetime = OriginalRuntimeCommitCancellation()

    init(store: BookStore, bookID: UUID, sourceID: UUID, bookURL: String,
         chapter: OnlineChapterRef?, generation: OriginalRuntimeChapterGeneration?) throws {
        guard store.originalRuntimeBookSnapshot(id: bookID, sourceID: sourceID, bookURL: bookURL) != nil else {
            throw Self.failure("An existing App book UUID, source and URL must be explicitly granted")
        }
        if let chapter {
            guard let generation, generation.bookID == bookID, generation.chapterID == chapter.id,
                  generation.index == chapter.index, generation.url == chapter.url else {
                throw Self.failure("Chapter state requires its existing fetch generation and identity")
            }
        } else if generation != nil { throw Self.failure("A generation without its chapter is not a valid grant") }
        self.store = store; self.bookID = bookID; self.sourceID = sourceID
        self.bookURL = bookURL; self.chapter = chapter; self.generation = generation
    }

    func revoke() { lifetime.cancel() }

    func validate(deadline: Date) throws {
        _ = try currentBook(deadline: deadline)
        if chapter != nil { try generation?.check(deadline: deadline) }
    }

    func parse(_ wires: [String], sourceURL: String) throws -> [LegadoEntityStateKey] {
        var result: [LegadoEntityStateKey] = []
        for wire in wires {
            guard wire.utf8.count <= 16_384,
                  let parts = try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String],
                  parts.first == sourceURL, parts.count == 5 || parts.count == 6,
                  parts[1] == "variables" || parts[1] == "big-variable",
                  (parts[1] == "variables" ? parts.count == 5 : parts.count == 6),
                  parts[3] == bookURL else { throw Self.failure("State key does not match its granted App book") }
            let chapterURL: String?
            if parts[2] == "book", parts[4].isEmpty { chapterURL = nil }
            else if parts[2] == "chapter", let chapter, parts[4] == chapter.url { chapterURL = chapter.url }
            else { throw Self.failure("State key does not match its granted App chapter") }
            result.append(.init(wire: wire, chapterURL: chapterURL, largeVariable: parts.count == 6 ? parts[5] : nil))
        }
        guard let first = result.first, result.allSatisfy({ $0.chapterURL == first.chapterURL }) else {
            throw Self.failure("Book and chapter owners cannot be changed in one transaction")
        }
        return result
    }

    func read(keys: [LegadoEntityStateKey], deadline: Date) async throws -> LegadoEntityStateSnapshot {
        let book = try currentBook(deadline: deadline)
        let ownedChapter: BookChapterStore.RuntimeVariablesSnapshot?
        let variables: [String: String]?
        if keys[0].chapterURL != nil {
            guard let chapter, let found = try await store.originalRuntimeChapterSnapshot(bookID: bookID,
                index: chapter.index, url: chapter.url), found.chapterID == chapter.id else {
                throw Self.failure("The granted App chapter has changed or been removed")
            }
            try generation?.check(deadline: deadline)
            ownedChapter = found; variables = found.variables
        } else { ownedChapter = nil; variables = book.variables }
        guard try currentBook(deadline: deadline) == book else { throw Self.failure("The granted App book changed during its snapshot") }
        var values: [String: Data] = [:]
        for key in keys {
            if let name = key.largeVariable {
                if let value = variables?[name], value.utf16.count >= 10_000 { values[key.wire] = Data(value.utf8) }
            } else if let variables {
                values[key.wire] = try JSONSerialization.data(withJSONObject: variables.filter { $0.value.utf16.count < 10_000 }, options: [.sortedKeys])
            }
        }
        return .init(book: book, chapter: ownedChapter,
            state: .init(revision: UInt64(ownedChapter?.revision ?? 0), values: values))
    }

    func commit(snapshot: LegadoEntityStateSnapshot, keys: [LegadoEntityStateKey], changes: [String: Data?],
                deadline: Date, cancellation: OriginalRuntimeCommitCancellation) async throws -> Bool {
        guard let expected = snapshot.chapter else {
            throw Self.failure("Durable App book-variable writes require the shelf metadata owner transaction")
        }
        guard try currentBook(deadline: deadline) == snapshot.book else { return false }
        var small = expected.variables?.filter { $0.value.utf16.count < 10_000 } ?? [:]
        var large = expected.variables?.filter { $0.value.utf16.count >= 10_000 } ?? [:]
        var deletedSmall = false
        for key in keys {
            guard let change = changes[key.wire] else { continue }
            if let name = key.largeVariable {
                if let change {
                    guard let value = String(data: change, encoding: .utf8), value.utf16.count >= 10_000 else {
                        throw Self.failure("A large entity variable must preserve the original UTF-16 threshold")
                    }
                    large[name] = value
                } else { large.removeValue(forKey: name) }
            } else if let change {
                let parsed = try JSONDecoder().decode([String: String].self, from: change)
                guard parsed.values.allSatisfy({ $0.utf16.count < 10_000 }) else {
                    throw Self.failure("Large entity variables must be committed with their original companion key")
                }
                small = parsed
            } else { small = [:]; deletedSmall = true }
        }
        guard Set(small.keys).isDisjoint(with: large.keys) else { throw Self.failure("Entity variable companions disagree") }
        let variables: [String: String]? = deletedSmall && large.isEmpty ? nil : small.merging(large) { first, _ in first }
        return try await store.compareOriginalRuntimeChapter(expected: expected, variables: variables,
            deadline: deadline, cancellation: cancellation) { [self] in
                guard try currentBook(deadline: deadline) == snapshot.book else {
                    throw Self.failure("The granted App book changed before its chapter write")
                }
                try generation?.check(deadline: deadline)
            }
    }

    private func currentBook(deadline: Date) throws -> BookStore.RuntimeBookSnapshot {
        try lifetime.check(deadline: deadline)
        guard let value = store.originalRuntimeBookSnapshot(id: bookID, sourceID: sourceID, bookURL: bookURL) else {
            throw Self.failure("The granted App book was removed or changed source")
        }
        return value
    }
    private static func failure(_ message: String) -> LegadoRuntimeError {
        .init(code: "UNSUPPORTED_CAPABILITY", message: message)
    }
}
