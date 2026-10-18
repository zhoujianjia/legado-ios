import CryptoKit
import Foundation

/// A local distribution's optional source pack. All I/O is performed by the
/// store's existing load queue; constructing this descriptor only forms URLs.
enum BuiltInBookSourceBootstrap {
    struct Package: Sendable {
        let resourceURL: URL
        let manifestURL: URL

        static func bundled(
            in bundle: Bundle = .main,
            isLocalExperience: Bool = ReaderExperienceConfiguration.isLocalExperience
        ) -> Package? {
            guard isLocalExperience, let resources = bundle.resourceURL else { return nil }
            return Package(
                resourceURL: resources.appendingPathComponent("BuiltInBookSources.json"),
                manifestURL: resources.appendingPathComponent("BuiltInBookSources.manifest.json")
            )
        }
    }

    struct Manifest: Codable, Sendable {
        let schemaVersion: Int
        let version: String
        let sha256: String
    }

    /// Pending is a recovery journal, never an assertion that import succeeded.
    /// Its target digest lets a relaunch finish the marker without adding back a
    /// source the user may have deleted after the library was already committed.
    struct Journal: Codable, Sendable {
        enum State: String, Codable, Sendable { case pending, complete }
        let schemaVersion: Int
        let version: String
        let sha256: String
        let previousLibraryDigest: String
        let targetLibraryDigest: String
        var state: State
    }

    enum BootstrapError: Error {
        case invalidManifest
        case packageHashMismatch
        case emptyPackage
        case invalidJournal
        case interruptedImportConflictsWithLocalEdits
    }

    static func apply(
        _ package: Package,
        to existing: [BookSource],
        libraryURL: URL,
        pins: [UUID: SourcePinRecord],
        writeLibrary: ([BookSource], URL) throws -> Void = BookSourceStore.writeLibrary
    ) throws -> [BookSource] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // The pack is optional. Its absence must not change an upstream build.
        do {
            _ = try FileManager.default.attributesOfItem(atPath: package.resourceURL.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return existing
        }
        return try SourcePerfTrace.span(
            "bookSources.bootstrap", "main=\(Thread.isMainThread) sources=\(existing.count)"
        ) {
            let manifestData = try Data(contentsOf: package.manifestURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.schemaVersion == 1, !manifest.version.isEmpty,
                  isDigest(manifest.sha256) else { throw BootstrapError.invalidManifest }
            let markerURL = journalURL(for: manifest, libraryURL: libraryURL)
            if var journal = try readJournal(at: markerURL) {
                guard journal.schemaVersion == 1, journal.version == manifest.version,
                      journal.sha256 == manifest.sha256,
                      isDigest(journal.previousLibraryDigest), isDigest(journal.targetLibraryDigest)
                else { throw BootstrapError.invalidJournal }
                if journal.state == .complete { return existing }
                let digest = try libraryDigest(existing)
                if digest == journal.targetLibraryDigest {
                    // The atomic library replacement finished before interruption.
                    journal.state = .complete
                    try writeJournal(journal, to: markerURL)
                    return existing
                }
                guard digest == journal.previousLibraryDigest else {
                    // A user edit/deletion must win over ambiguous crash recovery.
                    throw BootstrapError.interruptedImportConflictsWithLocalEdits
                }
            }

            let data = try SourcePerfTrace.span(
                "bookSources.bootstrap.read", "main=\(Thread.isMainThread) file=\(package.resourceURL.lastPathComponent)"
            ) { try Data(contentsOf: package.resourceURL) }
            let incoming: [BookSource] = try SourcePerfTrace.span(
                "bookSources.bootstrap.decode", "main=\(Thread.isMainThread) bytes=\(data.count)"
            ) {
                guard digest(data) == manifest.sha256 else { throw BootstrapError.packageHashMismatch }
                let decoded = try JSONDecoder().decode([BookSource].self, from: data)
                guard !decoded.isEmpty else { throw BootstrapError.emptyPackage }
                return BookSourceStore.dedupedByURL(decoded)
            }
            let merged: [BookSource] = SourcePerfTrace.span(
                "bookSources.bootstrap.merge",
                "main=\(Thread.isMainThread) sources=\(existing.count) incoming=\(incoming.count)"
            ) {
                let existingURLs = Set(existing.lazy.map(\.bookSourceUrl).filter { !$0.isEmpty })
                let additions = incoming.filter { $0.bookSourceUrl.isEmpty || !existingURLs.contains($0.bookSourceUrl) }
                guard !additions.isEmpty else { return existing }
                var result = existing
                // Preserve the existing store's pinned-tail insertion convention.
                let insertion = result.firstIndex { pins[$0.id]?.position == .bottom } ?? result.count
                result.insert(contentsOf: additions, at: insertion)
                return result
            }
            var journal = Journal(
                schemaVersion: 1, version: manifest.version, sha256: manifest.sha256,
                previousLibraryDigest: try libraryDigest(existing),
                targetLibraryDigest: try libraryDigest(merged), state: .pending
            )
            try FileManager.default.createDirectory(
                at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Persist recovery intent before replacing any user data. Completion
            // is recorded only after a successful write (or an unchanged library).
            try writeJournal(journal, to: markerURL)
            if merged.count != existing.count {
                try SourcePerfTrace.span(
                    "bookSources.bootstrap.persist", "main=\(Thread.isMainThread) sources=\(merged.count)"
                ) { try writeLibrary(merged, libraryURL) }
            }
            journal.state = .complete
            try writeJournal(journal, to: markerURL)
            return merged
        }
    }

    static func journalURL(for manifest: Manifest, libraryURL: URL) -> URL {
        libraryURL.deletingLastPathComponent()
            .appendingPathComponent("book_source_bootstrap.\(manifest.sha256).json")
    }

    /// Deterministic, bounded-memory identity for recovery. Sorting each source's
    /// keys avoids JSONEncoder's key-order variation without encoding a whole
    /// 50,000-source library into another giant Data allocation.
    static func libraryDigest(_ sources: [BookSource]) throws -> String {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return try SourcePerfTrace.span(
            "bookSources.bootstrap.digest", "main=\(Thread.isMainThread) sources=\(sources.count)"
        ) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            var hash = SHA256()
            hash.update(data: Data("[".utf8))
            for (index, source) in sources.enumerated() {
                try autoreleasepool {
                    if index > 0 { hash.update(data: Data(",".utf8)) }
                    hash.update(data: try encoder.encode(source))
                }
            }
            hash.update(data: Data("]".utf8))
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func readJournal(at url: URL) throws -> Journal? {
        do {
            return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private static func writeJournal(_ journal: Journal, to url: URL) throws {
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url, options: .atomic)
    }
}
