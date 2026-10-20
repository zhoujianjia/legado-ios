import CryptoKit
import Darwin
import Foundation
import Security
import Testing
import YueduCoreText
@testable import yuedu_app

@Suite("Actual App renewal bootstrap and explicit public configuration", .serialized)
struct SelfRenewalAppOwnerTests {
    typealias Session = SelfRenewalAppSession
    typealias Journal = SelfRenewalTransactionJournal

    @Test("missing configuration is durably typed and the one journal lock survives repeated bootstrap")
    func persistsUnconfiguredStatusAndReopensTheSameLocalOwner() async throws {
        try await Self.root { root in
            let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
            var session = Session(root: root)
            let first = try await session.bootstrap(handoff: handoff)
            #expect(first.state == .unconfigured && first.phase == nil)
            #expect(!first.automaticRenewalVerified && !first.appleAuthorizationVerified)
            let raw = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
            let second = try await session.bootstrap(handoff: handoff)
            #expect(first == second)
            #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == raw)
            let invalidImport = root.appendingPathComponent("owned-invalid-import.json")
            try Data("{invalid".utf8).write(to: invalidImport)
            do { _ = try await session.configure(from: invalidImport, handoff: handoff); Issue.record("invalid import admitted") }
            catch let error as Session.Failure { #expect(error == .invalidConfiguration) }
            #expect(try Data(contentsOf: root.appendingPathComponent("configuration.json")) == raw)
            do {
                let foreign = try await Journal.open(at: root.appendingPathComponent("SelfRenewalTransactions"))
                try await foreign.close(); Issue.record("second App journal owner admitted")
            } catch let error as Journal.Failure { #expect(error == .ownerAlreadyOpen) }
            try await session.close()
            let pending = root.appendingPathComponent("configuration.pending")
            try Data("owned interrupted configuration".utf8).write(to: pending)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            session = Session(root: root)
            let reopened = try await session.bootstrap(handoff: handoff)
            #expect(reopened == first)
            #expect(!FileManager.default.fileExists(atPath: pending.path))
            try await session.close()
        }
    }

    @Test("unconfigured startup retains an actual prior transaction without retirement, network or replacement")
    func retainsExistingTransactionWhenSigningMaterialsAreMissing() async throws {
        try await Self.root { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let journal = try await Journal.open(at: root.appendingPathComponent("SelfRenewalTransactions"))
            let created = try await journal.create(namespace: UUID(), generation: 1,
                originalSHA256: Data(repeating: 1, count: 32), identitySHA256: Data(repeating: 2, count: 32),
                bundleIdentifier: "owned.fixture.reader", bundleVersion: "1", at: Date())
            try await journal.close()
            let path = root.appendingPathComponent("SelfRenewalTransactions/transaction.json")
            let raw = try Data(contentsOf: path)
            let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
            let session = Session(root: root)
            let status = try await session.bootstrap(handoff: handoff)
            #expect(status.state == .unconfigured && status.phase == .created)
            #expect(try Data(contentsOf: path) == raw)
            do { _ = try await session.recoverExplicitly(handoff: handoff); Issue.record("missing signing material recovered") }
            catch let error as Session.Failure { #expect(error == .notConfigured) }
            #expect(created.record.remoteHistory == .neverStarted)
            try await session.close()
        }
    }

    @Test("corrupt, linked and oversized local configuration stays on disk and never becomes a default identity")
    func rejectsCorruptLinkedAndOversizedConfigurationWithoutReset() async throws {
        try await Self.root { root in
            let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
            let initial = Session(root: root)
            _ = try await initial.bootstrap(handoff: handoff); try await initial.close()
            let file = root.appendingPathComponent("configuration.json")
            for invalid in [Data("{broken".utf8), Data(repeating: 0x41, count: Session.maximumConfigurationBytes + 1)] {
                try invalid.write(to: file, options: .atomic)
                let session = Session(root: root)
                do { _ = try await session.bootstrap(handoff: handoff); Issue.record("invalid local configuration reset") }
                catch { #expect(try Data(contentsOf: file) == invalid) }
                try await session.close()
                let released = try await Journal.open(at: root.appendingPathComponent("SelfRenewalTransactions"))
                try await released.close()
            }
            try FileManager.default.removeItem(at: file)
            let target = root.appendingPathComponent("owned-target.json")
            let raw = Data("owned target unchanged".utf8); try raw.write(to: target)
            guard symlink(target.path, file.path) == 0 else { throw POSIXError(.EIO) }
            let linked = Session(root: root)
            do { _ = try await linked.bootstrap(handoff: handoff); Issue.record("linked configuration followed") }
            catch { #expect(try Data(contentsOf: target) == raw) }
            try await linked.close()
        }
    }

    @Test("certificate syntax is not a signing lease; unavailable Keychain refs never become pairing handles")
    func validatesRealCertificateInputsAndRejectsMissingAuthenticationHandles() async throws {
        let worker = Task.detached(priority: .utility) {
            let issuer = try SelfRenewalSigningOwnedPKIFixture.issuer(at: Date())
            let certificate = try #require(issuer.certificateChainDER.first)
            let device = Session.DeviceConfiguration(identityPersistentReference: Data(UUID().uuidString.utf8),
                deviceCertificateDER: certificate, rootCertificateDER: certificate,
                hostID: UUID().uuidString, systemBUID: UUID().uuidString,
                numericAddress: "127.0.0.1", port: 62078, interfaceIndex: 0)
            let input = Session.Configuration(schema: 1, namespaceID: UUID(),
                codeAnchors: [certificate], profileAnchors: [certificate], device: device)
            let raw = try JSONEncoder().encode(input)
            let decoded = try Session.decodeConfiguration(raw)
            #expect(decoded == input)
            do { _ = try Session.pairing(device); Issue.record("random opaque ref produced a SecIdentity") }
            catch let error as Session.Failure {
                switch error { case .identityUnavailable(let status): #expect(status != errSecSuccess)
                default: Issue.record("unexpected identity failure") }
            }
            for invalid in [Session.Configuration(schema: 2, namespaceID: input.namespaceID, codeAnchors: [certificate], profileAnchors: [certificate], device: nil),
                Session.Configuration(schema: 1, namespaceID: input.namespaceID, codeAnchors: [], profileAnchors: [certificate], device: nil),
                Session.Configuration(schema: 1, namespaceID: input.namespaceID, codeAnchors: [certificate, certificate], profileAnchors: [certificate], device: nil),
                Session.Configuration(schema: 1, namespaceID: input.namespaceID, codeAnchors: [Data([1, 2, 3])], profileAnchors: [certificate], device: nil)] {
                do { _ = try Session.decodeConfiguration(JSONEncoder().encode(invalid)); Issue.record("invalid configuration decoded") }
                catch let error as Session.Failure { #expect(error == .invalidConfiguration) }
            }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    @Test("cancellation and an actual invalid file destination cannot publish a usable bootstrap status")
    func preservesCancelledAndFailedConfigurationWrites() async throws {
        try await Self.root { root in
            let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
            let cancelled = Session(root: root)
            let operation = Task.detached(priority: .utility) {
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try await cancelled.bootstrap(handoff: handoff); Issue.record("cancelled bootstrap admitted") }
                catch is CancellationError { }
            }
            try await operation.value
            #expect(!FileManager.default.fileExists(atPath: root.path))
            try await cancelled.close()
            let parent = root.deletingLastPathComponent()
            guard chmod(parent.path, 0o500) == 0 else { throw POSIXError(.EIO) }
            defer { if chmod(parent.path, 0o700) != 0 { Issue.record("owned parent permissions could not be restored") } }
            let denied = Session(root: root)
            do { _ = try await denied.bootstrap(handoff: handoff); Issue.record("actual unwritable parent admitted bootstrap") }
            catch let error as Session.Failure { #expect(error == .storage) }
            let deniedStatus = await denied.status()
            #expect(deniedStatus == nil)
            guard chmod(parent.path, 0o700) == 0 else { throw POSIXError(.EIO) }
            try await denied.close()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = root.appendingPathComponent("configuration.json")
            // The existing directory is an actual invalid destination, not an
            // injectable writer that returns a false success acknowledgement.
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let failed = Session(root: root)
            do { _ = try await failed.bootstrap(handoff: handoff); Issue.record("directory accepted as configuration") }
            catch { let status = await failed.status(); #expect(status == nil) }
            try await failed.close()
            try FileManager.default.removeItem(at: file)
            let restored = Session(root: root)
            let status = try await restored.bootstrap(handoff: handoff)
            #expect(status.state == .unconfigured)
            try await restored.close()
            #if DEBUG
            let unknownRoot = root.deletingLastPathComponent().appendingPathComponent("ack-loss")
            try FileManager.default.createDirectory(at: unknownRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let owned = unknownRoot.appendingPathComponent("SelfRenewalApp")
            let unknown = Session(root: owned, publicationFault: .loseNextDirectorySyncAcknowledgement)
            do { _ = try await unknown.bootstrap(handoff: handoff); Issue.record("lost configuration ACK reported success") }
            catch let error as Session.Failure { #expect(error == .commitDurabilityUnknown) }
            let beforeReload = await unknown.status()
            #expect(beforeReload == nil)
            let destination = owned.appendingPathComponent("configuration.json")
            let committed = try Data(contentsOf: destination)
            // Prepare a distinct, still valid actual disk document at the
            // uncertain-commit window. A retry must read these bytes under the
            // same lock, rather than blindly republish in-memory defaults.
            var document = try #require(JSONSerialization.jsonObject(with: committed) as? [String: Any])
            document["ownedRecoveryMarker"] = "must survive unchanged local refresh"
            let staged = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try staged.write(to: destination, options: .atomic)
            let recovered = try await unknown.bootstrap(handoff: handoff)
            #expect(recovered.state == .unconfigured)
            #expect(try Data(contentsOf: destination) == staged)
            try await unknown.close()
            #endif
        }
    }

    @Test("App start binds actual owned stores and the same Navigator produces real position acknowledgements")
    func appOwnerBootstrapsItsSharedHandoffWithoutCreatingSigningCredentials() async throws {
        try await Self.root { root in
            let app = root.deletingLastPathComponent().appendingPathComponent("owned-library")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            var book = ReadingBook(title: "Owned App bootstrap", author: "Owned", contentFilename: "owned.txt")
            book.isInBookshelf = true
            try JSONEncoder().encode([book]).write(to: app.appendingPathComponent("books_meta.json"))
            try Data("[]".utf8).write(to: app.appendingPathComponent("books_meta.reading.json"))
            try Data("[]".utf8).write(to: app.appendingPathComponent("book_sources.json"))
            let books = try await BookStore.openForRenewalHandoff(metadataFileURL: app.appendingPathComponent("books_meta.json"), legacyMetadataDefaults: nil)
            let sources = BookSourceStore(directory: app)
            _ = try await sources.normalLoadReceiptForRenewalHandoff()
            let positions = JSONFileReadingPositionStore(baseURL: app.appendingPathComponent("positions"), onSave: { _, _ in })
            let owner = await MainActor.run { SelfRenewalAppOwner(root: root) }
            let identity = await MainActor.run { ObjectIdentifier(owner.handoff) }
            await owner.start(books: books, sources: sources, positions: positions)
            let state = await MainActor.run { owner.status?.state }
            #expect(state == .unconfigured)
            let bookID = book.id.uuidString
            let position = CoreTextReadingPosition(spineIndex: 0, charOffset: 7, translationOffset: 3)
            let navigator = await MainActor.run {
                let appearance = ReaderAppearance(theme: .sepia, fontSize: 18, lineHeightMultiple: 1.4,
                    lineSpacing: 2, paragraphSpacing: 6, letterSpacing: 0, marginH: 24, marginV: 28,
                    footerHeight: 20, writingMode: .horizontal)
                let state = ReaderPresentationState(location: ReaderLocation(position), direction: .ltr,
                    spreadMode: .singlePage, viewportSize: CGSize(width: 320, height: 480), appearance: appearance, pagingStyle: .slide)
                return ReaderNavigator(initialState: state, positionStore: positions, bookId: bookID, renewalHandoff: owner.handoff)
            }
            let receipt = try await owner.handoff.prepareForSubmission()
            #expect(receipt.positions.count == 1 && receipt.positions.first?.position == position)
            #expect(receipt.positions.first?.bookId == bookID)
            let raw = try Data(contentsOf: app.appendingPathComponent("positions/" + bookID + ".json"))
            let positionSHA = Data(SHA256.hash(data: raw))
            #expect(receipt.positions.first?.rawSHA256 == positionSHA)
            _ = await MainActor.run { navigator.currentLocation }
            await owner.becameActive()
            let again = await MainActor.run { ObjectIdentifier(owner.handoff) }
            #expect(identity == again)
            // This test never manufactures a lease or PairingIdentity and never
            // calls an upload/Upgrade route. The App keeps the actor for life.
            try await owner.close()
        }
    }

    nonisolated private static func root(_ action: @escaping @Sendable (URL) async throws -> Void) async throws {
        let worker = Task.detached(priority: .utility) {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent("owned-app-renewal-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do { try await action(parent.appendingPathComponent("SelfRenewalApp", isDirectory: true)); try FileManager.default.removeItem(at: parent) }
            catch { do { try FileManager.default.removeItem(at: parent) } catch { Issue.record(error) }; throw error }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
