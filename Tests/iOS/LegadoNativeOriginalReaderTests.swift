import CoreFoundation
import CryptoKit
import Foundation
import LegadoRuntime
@preconcurrency import Network
import WebKit
import XCTest
@testable import yuedu_app

/// The existing native-reader target must link the real ordinary JAR and Zero VM.
/// All service/executor/Host/client/cache implementations below are production defaults.
/// The loopback peer supplies bytes only; it is never a runtime transport substitute.
final class LegadoNativeOriginalReaderTests: XCTestCase {
    /// Platform information only: this does not execute Android or enable a
    /// product result encoder. Unsupported WK values remain recorded failures
    /// of information transport, even when this observation test completes.
    func testNativeOriginalWebJSNativeResultBridgeCharacterizesAndroidConversionInformation() async throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("Native-result bridge characterization requires the supported iOS 17+ WK host")
        }
        executionTimeAllowance = 90
        let probe = await MainActor.run { OriginalNativeResultBridgeCharacterization() }
        var records: [OriginalNativeResultBridgeCharacterization.Record] = []
        let vectors = OriginalNativeResultBridgeCharacterization.vectors
        do {
            let loaded = expectation(description: "Owned native-result document loaded")
            try await probe.load(finished: loaded)
            await fulfillment(of: [loaded], timeout: 10)
            try await probe.requireLoaded()
            for (index, vector) in vectors.enumerated() {
                // One direct native Program execution. There is no eval,
                // function wrapper, stringify, or preliminary value traversal.
                let program = try await probe.evaluate(vector.program, label: vector.id)
                // These trusted primitive observations happen only AFTER the
                // actual native callback, never before a getter/toJSON runs.
                let page = try await probe.evaluate(vector.pageObservation, label: vector.id + ".page")
                XCTAssertNil(page.errorDomain, "The owned page observation must remain callable: \(vector.id)")
                XCTAssertTrue(page.nativeString?.hasPrefix("\(index + 1)|") == true,
                    "The original Program must execute exactly once: \(vector.id)")
                if let expected = vector.expectedPageObservation {
                    XCTAssertEqual(page.nativeString, expected, "Owned page facts changed: \(vector.id)")
                }
                if vector.requiresOrdinaryNativeDictionary {
                    XCTAssertNil(program.errorDomain, "Ordinary object control failed: \(vector.id)")
                    XCTAssertEqual(program.nodes.first?.kind, "dictionary")
                }
                records.append(.init(id: vector.id, sourceDerivedAndroidExpectation: vector.androidExpectation,
                    native: program, pageAfterNativeCallback: page))
            }
            let lifecycle = await probe.close()
            XCTAssertEqual(records.count, 14)
            XCTAssertEqual(lifecycle.createdViews, 1)
            XCTAssertEqual(lifecycle.evaluationsIssued, 28)
            XCTAssertEqual(lifecycle.evaluationsCompleted, lifecycle.evaluationsIssued)
            XCTAssertEqual(lifecycle.evaluationsInFlight, 0)
            let report = OriginalNativeResultBridgeCharacterization.Report(records: records,
                lifecycle: lifecycle, infrastructureFailure: nil)
            let reportData = try await OriginalNativeResultBridgeCharacterization.encodeReport(report)
            print("YUEDU_WK_NATIVE_RESULT_BRIDGE_JSON " + String(decoding: reportData, as: UTF8.self))
            let attachment = XCTAttachment(data: reportData, uniformTypeIdentifier: "public.json")
            attachment.name = "WK-native-result-bridge-observations.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            let lifecycle = await probe.close()
            let report = OriginalNativeResultBridgeCharacterization.Report(records: records,
                lifecycle: lifecycle, infrastructureFailure: String(describing: error))
            let reportData = try await OriginalNativeResultBridgeCharacterization.encodeReport(report)
            print("YUEDU_WK_NATIVE_RESULT_BRIDGE_JSON " + String(decoding: reportData, as: UTF8.self))
            let attachment = XCTAttachment(data: reportData, uniformTypeIdentifier: "public.json")
            attachment.name = "WK-native-result-bridge-partial-observations.json"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw error
        }
    }

    /// Test-only WK characterization. This does not grant support to the product
    /// object-result path, and deliberately never calls the JVM/source service.
    func testNativeOriginalOrderedWebJSCharacterizesCSPAndOriginalJSONInSamePageWorld() async throws {
        executionTimeAllowance = 90
        let probe = await MainActor.run { OriginalOrderedWebJSCharacterization() }
        do {
            // Reuse one actual WKWebView; a new document resets its JavaScript
            // globals. The two pages differ only in CSP unsafe-eval permission.
            for allowsEval in [true, false] {
                let loaded = expectation(description: "Owned ordered-result CSP document loaded")
                try await probe.load(allowsEval: allowsEval, finished: loaded)
                await fulfillment(of: [loaded], timeout: 10)
                try await probe.requireLoaded()

                let overrides = try await probe.string("[window.eval('ignored'),JSON.stringify({b:2,a:1})].join('|')")
                XCTAssertEqual(overrides, "page-eval|page-json")
                let captured = try await probe.captureStatus()
                XCTAssertEqual(captured, "function|function|false|false")

                // This is native Program evaluation, not page eval. Preserve a
                // real global var and a global lexical binding across calls.
                let nativeObject = try await probe.dictionary("var orderedNativeVar=40; let orderedNativeLexical=2; ({b:2,a:1})")
                XCTAssertEqual(nativeObject, ["b": 2, "a": 1])
                let strictNative = try await probe.string("'use strict'; var orderedNativeStrict=9; 'strict-native-ready'")
                XCTAssertEqual(strictNative, "strict-native-ready")

                let vectors: [(expression: String, expectedJSON: String)] = [
                    ("({b:2,a:1})", #"{"b":2,"a":1}"#),
                    ("[{b:2,a:1},{d:4,c:3}]", #"[{"b":2,"a":1},{"d":4,"c":3}]"#),
                    ("({z:{b:2,a:1},a:[3,2,1]})", #"{"z":{"b":2,"a":1},"a":[3,2,1]}"#),
                    ("(()=>{const o={};o.z=1;o['10']=10;o['2']=2;o.a=3;return o;})()", #"{"2":2,"10":10,"z":1,"a":3}"#),
                    (#"({'\u00e9':1,'e\u0301':2})"#, "{\"\u{00e9}\":1,\"e\u{0301}\":2}"),
                    ("({b:orderedNativeVar,a:orderedNativeLexical,s:orderedNativeStrict})", #"{"b":40,"a":2,"s":9}"#),
                    ("(window.orderedEffects=(window.orderedEffects||0)+1,({b:2,a:1}))", #"{"b":2,"a":1}"#),
                    ("({b:undefined,a:[undefined,NaN,Infinity]})", #"{"a":[null,null,null]}"#)
                ]
                for vector in vectors {
                    let actual = try await probe.encodeExpression(vector.expression)
                    // String equality canonically equates Unicode sequences;
                    // compare the actual JSON bytes, including distinct keys.
                    XCTAssertEqual(Data(actual.utf8), Data(vector.expectedJSON.utf8))
                }
                let effectCount = try await probe.encodeExpression("window.orderedEffects")
                XCTAssertEqual(effectCount, "1")

                // Capturing eval before the CSP meta element is not a CSP
                // bypass. This contrast must be established by actual WebKit.
                let indirect = try await probe.capturedEval("var orderedEvalVar=7; let orderedEvalLexical=8; ({b:orderedEvalVar,a:orderedEvalLexical})")
                let expected = allowsEval ? #"{"ok":true,"value":{"b":7,"a":8}}"# : #"{"ok":false,"name":"EvalError"}"#
                XCTAssertEqual(Data(indirect.utf8), Data(expected.utf8))
                let scope = try await probe.encodeExpression("[typeof orderedEvalVar,typeof orderedEvalLexical]")
                XCTAssertEqual(scope, allowsEval ? #"["number","undefined"]"# : #"["undefined","undefined"]"#)
                let indirectStrict = try await probe.capturedEval("'use strict'; var orderedEvalStrict=9; ({b:2,a:1})")
                XCTAssertEqual(indirectStrict, allowsEval ? #"{"ok":true,"value":{"b":2,"a":1}}"# : #"{"ok":false,"name":"EvalError"}"#)
                let strictScope = try await probe.encodeExpression("typeof orderedEvalStrict")
                XCTAssertEqual(strictScope, #""undefined""#)
            }
            await probe.close()
        } catch {
            await probe.close()
            throw error
        }
    }

    func testNativeOriginalGeneralWebJSUsesPreviewBatchAndBookCallbackOwners() async throws {
        executionTimeAllowance = 240
        try await withFixture { fixture in
            var preview = fixture.source
            preview.searchUrl = "@js:if(java.webView('<html><body>native</body></html>',null,\"'basic-ready'\")!=='basic-ready')throw new Error('basic WebJS failed');'"
                + fixture.baseURL + "/search?key=native-original&page=2'"
            // An unsaved source has cache-only rule interfaces. This exercises
            // the actual @webjs parser and the same JVM/native page lease.
            preview.ruleSearch.name = "tag.a@text@webjs:if(typeof cache!=='object')throw new Error('missing original cache');document.body.textContent"
            let first = try await fixture.service.originalSearch(query: "native-original", page: 2, source: preview)
            XCTAssertEqual(first.map(\.name), ["Original JNI"])
            var urlMode = fixture.source
            urlMode.searchUrl = fixture.baseURL + "/search?key=native-original&page=2,{\"webView\":true,\"webJs\":\"document.documentElement.outerHTML\"}"
            let loaded = try await fixture.service.originalSearch(query: "native-original", page: 2, source: urlMode)
            XCTAssertEqual(loaded.map(\.name), ["Original JNI"])

            let owned = try await self.ownedBatchBook(fixture)
            var authored = fixture.source
            let existingBatch = try XCTUnwrap(authored.ruleContent.contentBatch)
            authored.ruleContent.contentBatch = "if(java.webView('<html>batch</html>',null,\"'batch-ready'\")!=='batch-ready')throw new Error('batch WebJS failed');\n"
                + existingBatch
            authored.eventListener = true
            authored.ruleContent.callBackJs = "if(java.webView('<html>callback</html>',null,\"'callback-ready'\")!=='callback-ready')throw new Error('callback WebJS failed');book.putVariable('nativeGeneralCallback','accepted')"
            let source = authored
            let fetcher = BookSourceFetcher(mainJSService: fixture.service)
            let webViewFetcher = await MainActor.run { WebViewFetcher.shared }
            let manager = ChapterFetchManager(bookSourceFetcher: fetcher, webViewFetcher: webViewFetcher,
                sourceResolver: { id in id == source.id ? source : nil })
            let result = try await manager.fetchOriginalContentBatch(bookID: owned.book.id, sourceID: source.id,
                book: owned.dto, chapterIndexes: [0, 1, 2], store: owned.store, timeout: 90, cache: fixture.cache)
            XCTAssertEqual(result.missingChapters.map(\.index), [2])
            let currentValue = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
            let current = try XCTUnwrap(currentValue)
            let positions = JSONFileReadingPositionStore(baseURL: fixture.root.appendingPathComponent("general-positions"), onSave: { _, _ in })
            let callback = await MainActor.run { SourceCallBackService.notify(.addBookShelf, book: current,
                positionStore: positions, store: owned.store, fetcher: fetcher, source: source) }
            let pending = try XCTUnwrap(callback)
            let terminal = await pending.value
            XCTAssertFalse(terminal.failed, terminal.errorCode ?? "")
            let after = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
            XCTAssertEqual(after?.runtimeVariables?["nativeGeneralCallback"], "accepted")
            XCTAssertTrue(terminal.completedEffects.contains("bookVariablesCommitted"))
            // The public producer still owns the actual chapter/cache commit;
            // headless success itself has no grant to create these files.
            let saved = try await BookStore.chapterCachePersistence {
                fixture.cache.loadChapterPackageSync(bookId: owned.book.id, chapterIndex: 0,
                    expectedSourceURL: owned.chapters[0].url, expectedTOCTitle: owned.chapters[0].title)
            }
            XCTAssertTrue(saved?.content.contains("INDEX_0") == true)
        }
    }

    func testNativeOriginalColdProducerPersistsPublicReaderBeforeProcessExit() async throws {
        executionTimeAllowance = 180
        let cold = try await coldContext()
        let peer = try NativeOriginalLoopbackServer(runID: cold.control.runID, emitCookie: false)
        let ready = expectation(description: "Cold producer loopback ready")
        peer.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        var fixture: Fixture?
        var ownedID: UUID?
        var prepared: ColdProducerReceipt?
        var problem: Error?
        do {
            let base = try peer.readyBaseURL()
            var source = Self.source(base: base, runID: cold.control.runID, tocRedirect: true)
            source.enabledCookieJar = false
            let data = cold.root.appendingPathComponent("data", isDirectory: true)
            try await Task.detached { try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false) }.value
            let contexts = data.appendingPathComponent("contexts", isDirectory: true)
            let body = data.appendingPathComponent("preview-body", isDirectory: true)
            let f = Fixture(runID: cold.control.runID, prefix: "/" + cold.control.runID,
                cookieName: "native_" + cold.control.runID.replacingOccurrences(of: "-", with: ""),
                baseURL: base, root: data, contextDirectory: contexts,
                metadata: data.appendingPathComponent("books_meta.json"), cacheDirectory: body,
                cache: .init(rootDirectory: body), peer: peer, source: source,
                service: .init(contextDirectory: contexts, operationTimeout: 45))
            fixture = f
            let fetcher = BookSourceFetcher(mainJSService: f.service)
            let foundBooks = try await fetcher.search(query: "native-original", in: source, page: 2)
            let found = try XCTUnwrap(foundBooks.first)
            let detail = try await fetcher.fetchBookInfoPackage(url: found.bookUrl, source: source,
                runtimeVariables: found.runtimeVariables, knownBook: found)
            let toc = try await fetcher.fetchTOCPackage(tocUrl: detail.tocUrl, source: source,
                runtimeVariables: detail.runtimeVariables, forceRefresh: true)
            try Self.coldRequire(toc.chapters.count == 2, "Cold producer needs two real TOC chapters")
            let adoption = await OriginalBookAdoption.prepare(toc.runtimeVariables, chapters: toc.chapters)
            let owned = try await ownedBook(f, title: detail.name, url: found.bookUrl,
                tocURL: toc.tocURL, chapters: adoption.chapters, variables: adoption.variables)
            let cacheAbsent = await Task.detached {
                !FileManager.default.fileExists(atPath: StorageLocations.onlineCache.appendingPathComponent(owned.book.id.uuidString).path)
            }.value
            try Self.coldRequire(cacheAbsent, "Cold producer refuses a preexisting global cache UUID")
            ownedID = owned.book.id
            try await Task.detached { try cold.write(ColdClaim(control: cold.control, bookID: owned.book.id), name: "claim.json") }.value
            _ = try await fetcher.transferOriginalPreview(source: source, runtimeVariables: toc.runtimeVariables,
                to: owned.store, bookID: owned.book.id)
            let reader = await manager(f)
            let first = try await reader.fetchChapter(book: owned.book, chapterIndex: 0,
                priority: .immediate, store: owned.store)
            let second = try await reader.fetchChapter(book: owned.book, chapterIndex: 1,
                priority: .immediate, store: owned.store)
            try Self.coldRequire(first.content.contains("first&page") && first.content.contains("last page")
                && second.content.contains("second chapter"), "Cold producer did not parse real paginated bodies")
            let position = CoreTextReadingPosition(spineIndex: 1, charOffset: 7)
            let positions = JSONFileReadingPositionStore(baseURL: data.appendingPathComponent("positions", isDirectory: true), onSave: { _, _ in })
            let positionReceipt = try await positions.saveChecked(position, for: owned.book.id.uuidString)
            await BookStore.queuedWritesLanded()
            let currentValue = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
            let current = try XCTUnwrap(currentValue)
            let chapters = try XCTUnwrap(current.onlineChapters)
            try Self.coldRequire(chapters.count == 2 && chapters.map(\.index) == [0, 1] && chapters.map(\.cachedFilename) == ["0.txt", "1.txt"]
                && chapters.first?.runtimeVariables?["nativeParsed"] == "yes"
                && current.runtimeVariables?["nativeBig"] == String(repeating: "L", count: 10_000), "Producer ownership/variables were not persisted")
            var fingerprints: [[String: String]] = []
            for chapter in chapters {
                let snapshot = try await BookSourceFetcher.chapterCacheRepository.originalBatchSnapshot(
                    bookID: current.id, index: chapter.index, sourceURL: chapter.url, tocTitle: chapter.title, validateGrant: {})
                try Self.coldRequire(snapshot.package != nil && snapshot.fingerprints.count == 5
                    && !snapshot.fingerprints.values.contains("missing"), "Cold producer lacks committed cache artifacts")
                fingerprints.append(snapshot.fingerprints)
            }
            let persistedSource = source
            try await Task.detached { try cold.write(persistedSource, name: "data/source.json") }.value
            let files = try await Task.detached { try cold.fileFacts(bookID: current.id) }.value
            let expectedTargets = ["/search?key=native-original&page=2", "/book", "/toc-rewritten", "/toc2", "/c1", "/c1p2", "/c2"].map { f.prefix + $0 }
            try Self.coldRequire(peer.snapshot.requests.map(\.target) == expectedTargets, "Cold producer bypassed the public search/detail/paginated reader chain")
            prepared = ColdProducerReceipt(control: cold.control, producerPID: ProcessInfo.processInfo.processIdentifier,
                bookID: current.id, sourceID: source.id, chapterIDs: chapters.map(\.id),
                chapterVariables: chapters.map { $0.runtimeVariables ?? [:] }, bookVariables: current.runtimeVariables ?? [:],
                bodySHA256: [Self.coldHash(Data(first.content.utf8)), Self.coldHash(Data(second.content.utf8))],
                cacheFingerprints: fingerprints, files: files, position: position,
                positionSHA256: Self.coldHex(positionReceipt.rawSHA256), requestTargets: peer.snapshot.requests.map(\.target),
                peerStopped: false, activeConnections: -1, hostAccepted: false)
        } catch { problem = error }
        if let fixture {
            do { try await fixture.service.closeSessions() } catch { if problem == nil { problem = error } }
        }
        let stopped = expectation(description: "Cold producer owns no live TCP listener or connection")
        peer.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
        let snapshot = peer.snapshot
        if problem == nil {
            do {
                try Self.coldRequire(snapshot.listenerCancelled && snapshot.activeConnections == 0 && snapshot.errors.isEmpty,
                    "Cold producer TCP peer failed to drain")
                var receipt = try XCTUnwrap(prepared)
                receipt.peerStopped = true; receipt.activeConnections = 0
                let completedReceipt = receipt
                // Pending only. CI commits producer.json after this exact host's
                // original summary/tests exports prove one passed qualified case.
                try await Task.detached { try cold.write(completedReceipt, name: "producer-pending.json") }.value
            } catch { problem = error }
        }
        if let problem {
            if let ownedID {
                do { try await BookSourceFetcher.shared.clearAllChapterCacheAwait(bookId: ownedID) }
                catch { attach(["coldCacheCleanupFailed": true], name: "ColdProducer-cleanup") }
            }
            do { try await Task.detached { try cold.removeDataOnly() }.value }
            catch { attach(["coldDataCleanupFailed": true], name: "ColdProducer-cleanup") }
            throw problem
        }
    }

    func testNativeOriginalColdConsumerRestoresOwnedReaderWithoutNetwork() async throws {
        executionTimeAllowance = 120
        let cold = try await coldContext()
        var ownedID: UUID?
        var openedService: LegadoMainJSSourceService?
        var problem: Error?
        do {
            let claim: ColdClaim = try await Task.detached { try cold.read(ColdClaim.self, name: "claim.json") }.value
            try Self.coldRequire(claim.control == cold.control, "Cold claim belongs to another run")
            let receipt: ColdProducerReceipt = try await Task.detached { try cold.read(ColdProducerReceipt.self, name: "producer.json") }.value
            try Self.coldRequire(receipt.control == cold.control && receipt.bookID == claim.bookID
                && receipt.hostAccepted && receipt.peerStopped && receipt.activeConnections == 0
                && receipt.producerPID > 0 && receipt.producerPID != ProcessInfo.processInfo.processIdentifier,
                "Cold consumer needs a committed different-process producer")
            ownedID = claim.bookID
            let before = try await Task.detached { try cold.fileFacts(bookID: claim.bookID) }.value
            try Self.coldRequire(before == receipt.files, "Producer metadata/position/source bytes changed before cold load")
            let source: BookSource = try await Task.detached { try cold.read(BookSource.self, name: "data/source.json") }.value
            try Self.coldRequire(source.id == receipt.sourceID && URL(string: source.bookSourceUrl)?.host == "127.0.0.1",
                "Cold source is not the owned loopback definition")
            let metadata = cold.root.appendingPathComponent("data/books_meta.json")
            let store = await Task.detached { BookStore(metadataFileURL: metadata, legacyMetadataDefaults: nil) }.value
            let bookValue = await MainActor.run { store.readingBook(id: claim.bookID) }
            let book = try XCTUnwrap(bookValue)
            let chapters = try XCTUnwrap(book.onlineChapters)
            try Self.coldRequire(book.id == receipt.bookID && book.bookSourceId == source.id && !book.isInBookshelf
                && chapters.map(\.index) == [0, 1]
                && chapters.map(\.id) == receipt.chapterIDs && chapters.map(\.cachedFilename) == ["0.txt", "1.txt"]
                && chapters.map({ $0.runtimeVariables ?? [:] }) == receipt.chapterVariables
                && book.runtimeVariables == receipt.bookVariables, "Cold BookStore lost owned identities/variables")
            let positions = JSONFileReadingPositionStore(baseURL: cold.root.appendingPathComponent("data/positions", isDirectory: true), onSave: { _, _ in })
            let loaded = try await positions.loadChecked(for: book.id.uuidString)
            let position = try XCTUnwrap(loaded)
            try Self.coldRequire(position.operation == .existingFileRead && position.bookId == book.id.uuidString
                && position.position == receipt.position && Self.coldHex(position.rawSHA256) == receipt.positionSHA256,
                "Cold reading position was not read from the producer's real file")
            let probe = ColdSourceResolutionProbe()
            let service = LegadoMainJSSourceService(contextDirectory: cold.root.appendingPathComponent("data/contexts"), operationTimeout: 20)
            openedService = service
            let fetcher = BookSourceFetcher(mainJSService: service)
            let webViewFetcher = await MainActor.run { WebViewFetcher.shared }
            let reader = ChapterFetchManager(bookSourceFetcher: fetcher, webViewFetcher: webViewFetcher,
                sourceResolver: { _ in probe.record(); return source })
            var bodyHashes: [String] = []
            for chapter in chapters {
                let beforeCache = try await BookSourceFetcher.chapterCacheRepository.originalBatchSnapshot(
                    bookID: book.id, index: chapter.index, sourceURL: chapter.url, tocTitle: chapter.title, validateGrant: {})
                try Self.coldRequire(beforeCache.fingerprints == receipt.cacheFingerprints[chapter.index], "Cold cache bytes changed")
                let package = try await reader.fetchChapter(book: book, chapterIndex: chapter.index, priority: .immediate, store: store)
                bodyHashes.append(Self.coldHash(Data(package.content.utf8)))
                let afterCache = try await BookSourceFetcher.chapterCacheRepository.originalBatchSnapshot(
                    bookID: book.id, index: chapter.index, sourceURL: chapter.url, tocTitle: chapter.title, validateGrant: {})
                try Self.coldRequire(afterCache.fingerprints == beforeCache.fingerprints, "Cold reader rewrote cached data")
            }
            let after = try await Task.detached { try cold.fileFacts(bookID: book.id) }.value
            try Self.coldRequire(bodyHashes == receipt.bodySHA256 && probe.count == 0 && before == after,
                "Cold public reader did not return immutable offline cache before source resolution")
            let result = ColdConsumerReceipt(control: cold.control, producerPID: receipt.producerPID,
                consumerPID: ProcessInfo.processInfo.processIdentifier, bookID: book.id, sourceResolutions: probe.count,
                bodySHA256: bodyHashes, fileHashesUnchanged: true, hostAccepted: false)
            try await Task.detached { try cold.write(result, name: "consumer-pending.json") }.value
        } catch { problem = error }
        if let openedService {
            do { try await openedService.closeSessions() }
            catch { if problem == nil { problem = error } }
        }
        // The only global cache subtree admitted here is the freshly claimed
        // book UUID. Never enumerate/erase the default shelf or other books.
        if let ownedID {
            do { try await BookSourceFetcher.shared.clearAllChapterCacheAwait(bookId: ownedID) }
            catch { if problem == nil { problem = error } }
        }
        do { try await Task.detached { try cold.removeDataOnly() }.value }
        catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    private func coldContext() async throws -> ColdContext {
        do {
            let value = try await Task.detached { try ColdContext.load() }.value
            let diagnostics = await Task.detached { LegadoRuntime.diagnose() }.value
            try Self.coldRequire(diagnostics.available, "Cold process needs the ordinary native runtime")
            return value
        } catch {
            #if LEGADO_REQUIRE_NATIVE_MAINJS
            throw error
            #else
            throw XCTSkip("Cold process fixture requires its explicit CI descriptor and ordinary runtime")
            #endif
        }
    }
    private static func coldRequire(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NativeOriginalReaderError.failed(message) }
    }
    private static func coldHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func coldHash(_ data: Data) -> String { coldHex(Data(SHA256.hash(data: data))) }
    private struct ColdControl: Codable, Equatable, Sendable {
        let schemaVersion: Int; let runID: String; let nonce: String; let sourceCommit: String; let container: String
    }
    private struct ColdClaim: Codable, Sendable { let control: ColdControl; let bookID: UUID }
    private struct ColdProducerReceipt: Codable, Sendable {
        let control: ColdControl; let producerPID: Int32; let bookID: UUID; let sourceID: UUID
        let chapterIDs: [UUID]; let chapterVariables: [[String: String]]; let bookVariables: [String: String]
        let bodySHA256: [String]; let cacheFingerprints: [[String: String]]; let files: [String: String]
        let position: CoreTextReadingPosition; let positionSHA256: String; let requestTargets: [String]
        var peerStopped: Bool; var activeConnections: Int; var hostAccepted: Bool
    }
    private struct ColdConsumerReceipt: Codable, Sendable {
        let control: ColdControl; let producerPID: Int32; let consumerPID: Int32; let bookID: UUID
        let sourceResolutions: Int; let bodySHA256: [String]; let fileHashesUnchanged: Bool; let hostAccepted: Bool
    }
    private struct ColdContext: Sendable {
        let control: ColdControl; let root: URL
        static func load() throws -> Self {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let base = support.appendingPathComponent("YueduNativeColdProcess", isDirectory: true)
            let controlData = try bytes(base.appendingPathComponent("control.json"))
            let control = try JSONDecoder().decode(ColdControl.self, from: controlData)
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().path
            let stamp = Bundle.main.object(forInfoDictionaryKey: "YueduExperienceSourceCommit") as? String
            let local = Bundle.main.object(forInfoDictionaryKey: "YueduLocalExperience") as? Bool
            try LegadoNativeOriginalReaderTests.coldRequire(control.schemaVersion == 1
                && UUID(uuidString: control.runID)?.uuidString.lowercased() == control.runID, "Invalid cold namespace")
            try LegadoNativeOriginalReaderTests.coldRequire(control.nonce.count == 64 && control.nonce.allSatisfy({ $0.isHexDigit }), "Invalid cold nonce")
            try LegadoNativeOriginalReaderTests.coldRequire(control.sourceCommit.count == 40 && control.sourceCommit.allSatisfy({ $0.isHexDigit })
                && control.sourceCommit == stamp && local == true && control.container == home,
                "Cold descriptor differs from this source-stamped owned data container")
            let root = base.appendingPathComponent(control.runID, isDirectory: true)
            for directory in [base, root] {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                try LegadoNativeOriginalReaderTests.coldRequire((attributes[.type] as? FileAttributeType) == .typeDirectory,
                    "Cold namespace must be an actual directory")
            }
            try LegadoNativeOriginalReaderTests.coldRequire(root.resolvingSymlinksInPath().deletingLastPathComponent().path == base.resolvingSymlinksInPath().path,
                "Cold namespace escaped its owned parent")
            return .init(control: control, root: root)
        }
        static func bytes(_ url: URL) throws -> Data {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try LegadoNativeOriginalReaderTests.coldRequire((attributes[.type] as? FileAttributeType) == .typeRegular
                && ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16_777_216,
                "Cold evidence must be a bounded regular file")
            return try Data(contentsOf: url)
        }
        func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
            try JSONDecoder().decode(type, from: Self.bytes(root.appendingPathComponent(name)))
        }
        func write<T: Encodable>(_ value: T, name: String) throws {
            let destination = root.appendingPathComponent(name)
            try LegadoNativeOriginalReaderTests.coldRequire(!FileManager.default.fileExists(atPath: destination.path), "Refusing stale cold receipt overwrite")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: destination, options: .withoutOverwriting)
        }
        func fileFacts(bookID: UUID) throws -> [String: String] {
            let names = ["books_meta.reading.json", "books_meta.chapters/" + bookID.uuidString + ".json",
                "positions/" + bookID.uuidString + ".json", "source.json"]
            var result: [String: String] = [:]
            for name in names { result[name] = LegadoNativeOriginalReaderTests.coldHash(try Self.bytes(root.appendingPathComponent("data/" + name))) }
            return result
        }
        func removeDataOnly() throws {
            let data = root.appendingPathComponent("data", isDirectory: true)
            if FileManager.default.fileExists(atPath: data.path) { try FileManager.default.removeItem(at: data) }
        }
    }
    private final class ColdSourceResolutionProbe: @unchecked Sendable {
        private let lock = NSLock(); private var calls = 0
        func record() { lock.withLock { calls += 1 } }
        var count: Int { lock.withLock { calls } }
    }

    func testNativeOriginalWebBookPreviewTransferAndReopen() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            let books = try await fixture.service.originalSearch(query: "native-original", page: 2, source: fixture.source)
            let found = try XCTUnwrap(books.first)
            XCTAssertEqual(books.count, 1)
            XCTAssertEqual(found.name, "Original JNI")
            let detail = try await fixture.service.originalDetails(url: found.bookUrl, source: fixture.source,
                runtimeVariables: found.runtimeVariables, knownBook: found)
            XCTAssertEqual(detail.name, "Original JNI Updated")
            let toc = try await fixture.service.originalTOC(url: detail.tocUrl, source: fixture.source,
                runtimeVariables: detail.runtimeVariables, runPreUpdateJS: true)
            XCTAssertEqual(toc.chapters.count, 2)
            XCTAssertEqual(toc.chapters.map(\.index), [0, 1])
            XCTAssertEqual(toc.chapters.map(\.url), [fixture.prefix + "/c1", fixture.prefix + "/c2"])
            let originalIDs = toc.chapters.map(\.id)
            let firstChapter = try XCTUnwrap(toc.chapters.first)
            let secondChapter = try XCTUnwrap(toc.chapters.dropFirst().first)
            let first = try await fixture.service.originalContent(ref: firstChapter, source: fixture.source)
            XCTAssertTrue(first.contains("first&page"))
            XCTAssertTrue(first.contains("last page"))
            XCTAssertFalse(first.contains("REMOVE"))
            XCTAssertFalse(fixture.peer.snapshot.requests.contains { $0.target == fixture.prefix + "/c2" })
            // A new actual service reads the same preview file, not a shelf UUID
            // invented for a search result or an injected in-memory executor.
            let reopened = LegadoMainJSSourceService(contextDirectory: fixture.contextDirectory, operationTimeout: 45)
            let second = try await reopened.originalContent(ref: secondChapter, source: fixture.source)
            XCTAssertTrue(second.contains("second chapter"))
            // Project this same file after content callbacks. Refetching the TOC
            // would rerun original index/title metadata merging and lose state.
            let transferTOC = try await reopened.originalPreviewSnapshot(source: fixture.source,
                runtimeVariables: toc.runtimeVariables)
            XCTAssertEqual(transferTOC.chapters.map(\.id), originalIDs)
            let owned = try await self.ownedBook(fixture, title: detail.name, url: found.bookUrl,
                tocURL: detail.tocUrl, chapters: transferTOC.chapters, variables: transferTOC.runtimeVariables)
            let transferred = try await reopened.transferOriginalPreview(source: fixture.source,
                runtimeVariables: transferTOC.runtimeVariables, to: owned.store, bookID: owned.book.id)
            XCTAssertEqual(transferred.bookID, owned.book.id)
            let actualChapters = try await owned.store.originalRuntimeChapters(bookID: owned.book.id)
            XCTAssertEqual(actualChapters.map(\.id), originalIDs)
            XCTAssertEqual(actualChapters.first?.runtimeVariables?["nativeParsed"], "yes")
            let restarted = await Task.detached {
                BookStore(metadataFileURL: fixture.metadata, legacyMetadataDefaults: nil)
            }.value
            let actualBook = await MainActor.run { restarted.readingBook(id: owned.book.id) }
            XCTAssertEqual(actualBook?.id, owned.book.id)
            XCTAssertEqual(actualBook?.isInBookshelf, false)
            XCTAssertEqual(actualBook?.runtimeVariables?["nativeInfo"], "ready")
            XCTAssertEqual(actualBook?.runtimeVariables?["nativeToc"], "ready")
            XCTAssertEqual(actualBook?.runtimeVariables?["nativeBig"], String(repeating: "L", count: 10_000))
            let requests = fixture.peer.snapshot.requests
            XCTAssertEqual(requests.map(\.target), [fixture.prefix + "/search?key=native-original&page=2",
                fixture.prefix + "/book", fixture.prefix + "/toc", fixture.prefix + "/toc2",
                fixture.prefix + "/c1", fixture.prefix + "/c1p2", fixture.prefix + "/c2"])
            XCTAssertTrue(requests.allSatisfy { $0.fixtureHeader == fixture.runID && $0.method == "GET" })
            XCTAssertTrue(requests.dropFirst().allSatisfy { $0.cookie.contains(fixture.cookieName + "=wire") })
            try await reopened.closeSessions()
        }
    }

    func testNativeOriginalPublicConsumersUseOwnedReaderAndOfflineReopen() async throws {
        executionTimeAllowance = 180
        try await withFixture(tocRedirect: true) { fixture in
            try await self.withPublicOwnedBook(fixture) { fetcher, owned in
                let manager = await self.manager(fixture)
                let first = try await manager.fetchChapter(book: owned.book, chapterIndex: 0,
                    priority: .immediate, store: owned.store)
                XCTAssertTrue(first.content.contains("first&page"))
                XCTAssertTrue(first.content.contains("last page"))
                let second = try await manager.fetchChapter(book: owned.book, chapterIndex: 1,
                    priority: .prefetch, store: owned.store)
                XCTAssertTrue(second.content.contains("second chapter"))
                let requests = fixture.peer.snapshot.requests
                XCTAssertEqual(requests.map(\.target), [fixture.prefix + "/search?key=native-original&page=2",
                    fixture.prefix + "/book", fixture.prefix + "/toc-rewritten", fixture.prefix + "/toc2",
                    fixture.prefix + "/c1", fixture.prefix + "/c1p2", fixture.prefix + "/c2"])
                let originalFileFacts = try await self.publicMetadataFileFacts(fixture, bookID: owned.book.id)
                let refreshed = try await owned.store.refreshOnlineBookMetadata(bookId: owned.book.id,
                    bookSourceFetcher: LiveBookSourceFetcher(bookSourceFetcher: fetcher),
                    sourceResolver: { _ in fixture.source })
                await BookStore.queuedWritesLanded()
                XCTAssertEqual(refreshed.tocURL, fixture.baseURL + "/toc-rewritten")
                XCTAssertEqual(refreshed.onlineChapters?.map(\.id), owned.chapters.map(\.id))
                XCTAssertEqual(refreshed.onlineChapters?.first?.runtimeVariables?["nativeParsed"], "yes")
                let unchangedFileFacts = try await self.publicMetadataFileFacts(fixture, bookID: owned.book.id)
                XCTAssertEqual(unchangedFileFacts, originalFileFacts,
                    "An unchanged original TOC refresh must preserve metadata bytes and inode, including chapter variables")
                let sameSourceID = await owned.store.originalStoredOnlineBookID(sourceID: fixture.source.id, bookURL: owned.dto.bookURL)
                XCTAssertEqual(sameSourceID, owned.book.id)
                let detailReopen = try await owned.store.refreshOnlineBookMetadata(bookId: owned.book.id,
                    forceInfoRefresh: true, bookSourceFetcher: LiveBookSourceFetcher(bookSourceFetcher: fetcher),
                    sourceResolver: { _ in fixture.source })
                XCTAssertEqual(detailReopen.onlineChapters?.map(\.id), owned.chapters.map(\.id))
                XCTAssertEqual(detailReopen.onlineChapters?.map(\.cachedFilename), ["0.txt", "1.txt"])
                XCTAssertEqual(detailReopen.onlineChapters?.first?.runtimeVariables?["nativeParsed"], "yes")
                let afterRefreshRequests = fixture.peer.snapshot.requests
                XCTAssertEqual(afterRefreshRequests.dropFirst(requests.count).map(\.target),
                    [fixture.prefix + "/toc-rewritten", fixture.prefix + "/toc2",
                     fixture.prefix + "/book", fixture.prefix + "/toc-rewritten", fixture.prefix + "/toc2"])
                let restarted = await Task.detached {
                    BookStore(metadataFileURL: fixture.metadata, legacyMetadataDefaults: nil)
                }.value
                let restoredValue = await MainActor.run { restarted.readingBook(id: owned.book.id) }
                let restored = try XCTUnwrap(restoredValue)
                XCTAssertEqual(restored.id, owned.book.id)
                XCTAssertFalse(restored.isInBookshelf)
                XCTAssertEqual(restored.onlineChapters?.map(\.id), owned.chapters.map(\.id))
                XCTAssertEqual(restored.onlineChapters?.map(\.cachedFilename), ["0.txt", "1.txt"])
                XCTAssertEqual(restored.onlineChapters?.first?.runtimeVariables?["nativeParsed"], "yes")
                XCTAssertEqual(restored.runtimeVariables?["nativeBig"], String(repeating: "L", count: 10_000))
                // Close the real TCP listener before asking the same public reader
                // for the reopened book. Cache-only success cannot use a live peer.
                let stopped = self.expectation(description: "Public original peer is unavailable for offline reopen")
                fixture.peer.stop { stopped.fulfill() }
                await self.fulfillment(of: [stopped], timeout: 10)
                let offline = await self.manager(fixture)
                let savedFirst = try await offline.fetchChapter(book: restored, chapterIndex: 0,
                    priority: .immediate, store: restarted)
                let savedSecond = try await offline.fetchChapter(book: restored, chapterIndex: 1,
                    priority: .immediate, store: restarted)
                XCTAssertEqual(savedFirst.content, first.content); XCTAssertEqual(savedSecond.content, second.content)
                XCTAssertEqual(fixture.peer.snapshot.requests.count, afterRefreshRequests.count)
                let finishedGrant = await manager.originalRuntimeGeneration(bookID: owned.book.id, chapter: owned.chapters[0])
                XCTAssertNil(finishedGrant)
                XCTAssertTrue(fetcher.isChapterCached(bookId: owned.book.id, chapterIndex: 0))
            }
        }
    }

    func testNativeOriginalPublicReaderCancellationDrainsWithoutCache() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            try await self.withPublicOwnedBook(fixture) { fetcher, owned in
                let manager = await self.manager(fixture)
                let entered = self.expectation(description: "Public original chapter HTTP entered its held response")
                let closed = self.expectation(description: "Public original cancellation drains the actual TCP client")
                fixture.peer.armHeldBody(target: fixture.prefix + "/c1", headersSent: { entered.fulfill() },
                    peerClosed: { closed.fulfill() })
                let pending = Task { try await manager.fetchChapter(book: owned.book, chapterIndex: 0,
                    priority: .immediate, store: owned.store) }
                await self.fulfillment(of: [entered], timeout: 30)
                pending.cancel()
                let terminal = await pending.result
                await self.fulfillment(of: [closed], timeout: 20)
                switch terminal {
                case .success: XCTFail("A cancelled public Reader cannot publish a successful chapter")
                case .failure(let error):
                    if let typed = error as? LegadoRuntimeError { XCTAssertEqual(typed.code, "CANCELLED") }
                    else { XCTAssertTrue(error is CancellationError, "Actual error: \(error)") }
                }
                XCTAssertFalse(fetcher.isChapterCached(bookId: owned.book.id, chapterIndex: 0))
                let grant = await manager.originalRuntimeGeneration(bookID: owned.book.id, chapter: owned.chapters[0])
                XCTAssertNil(grant)
                XCTAssertTrue(fixture.peer.snapshot.heldPeerClosed)
            }
        }
    }

    func testNativeOriginalExplorePauseUsesEveryOpenedSourceAndRealCacheOwner() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            var first = fixture.source, second = fixture.source
            first.id = UUID(); second.id = UUID()
            first.bookSourceUrl += "/explore-first-" + fixture.runID
            second.bookSourceUrl += "/explore-second-" + fixture.runID
            let firstSource = first, secondSource = second
            let sources = [firstSource.id: firstSource, secondSource.id: secondSource]
            var operationError: Error?
            do {
                let firstOpened = try await fixture.service.openOriginalExploreContext(source: firstSource)
                let secondOpened = try await fixture.service.openOriginalExploreContext(source: secondSource)
                XCTAssertEqual(firstOpened.infoMap, [:]); XCTAssertEqual(secondOpened.infoMap, [:])
                let firstPending = try await fixture.service.evaluateOriginalExploreContext(
                    script: "infoMap.put('genre','first'); infoMap.save(); 'first-ready'", source: firstSource)
                let secondPending = try await fixture.service.evaluateOriginalExploreContext(
                    script: "infoMap.put('genre','second'); infoMap.save(); 'second-ready'", source: secondSource)
                XCTAssertTrue(firstPending.needSave); XCTAssertTrue(secondPending.needSave)
                XCTAssertEqual(firstPending.infoMap?["genre"], "first")
                XCTAssertEqual(secondPending.infoMap?["genre"], "second")
                let before = try await Task.detached {
                    try [firstSource, secondSource].map { source in
                        try LegadoCacheBridge.runtimeSnapshot(sourceId: source.bookSourceUrl, key: "infoMap_" + source.bookSourceUrl)
                    }
                }.value
                XCTAssertTrue(before.allSatisfy { $0.values.isEmpty })
                let requestedURL = fixture.baseURL + "/search?key=native-original&page=2"
                let script = "@js:if(String(infoMap.get('genre'))!=='first')throw new Error('wrong original context');'" + requestedURL + "'"
                let explored = try await fixture.service.originalExplore(url: script, page: 2, source: firstSource)
                XCTAssertEqual(explored.map(\.name), ["Original JNI"])
                XCTAssertEqual(explored.first?.sourceId, firstSource.id)
                let pause = try await fixture.service.savePendingOriginalExploreContexts(sourceResolver: { sources[$0] })
                XCTAssertEqual(Set(pause.acknowledgedSourceIDs), Set([firstSource.id, secondSource.id]))
                XCTAssertTrue(pause.failures.isEmpty)
                let stored = try await Task.detached {
                    try [firstSource, secondSource].map { source -> (UInt64, String?) in
                        let current = try LegadoCacheBridge.runtimeSnapshot(sourceId: source.bookSourceUrl, key: "infoMap_" + source.bookSourceUrl)
                        let text = try current.values["value"].map { try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: $0).text() }
                        return (current.revision, text)
                    }
                }.value
                let firstText = try XCTUnwrap(stored[0].1), secondText = try XCTUnwrap(stored[1].1)
                XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(firstText.utf8)), ["genre": "first"])
                XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(secondText.utf8)), ["genre": "second"])
                // Neither per-operation session close nor leaving a category removes
                // the original process map. A clean second pause must write nothing.
                _ = try await fixture.service.savePendingOriginalExploreContexts(sourceResolver: { sources[$0] })
                let clean = try await Task.detached {
                    try [firstSource, secondSource].map { source in
                        try LegadoCacheBridge.runtimeSnapshot(sourceId: source.bookSourceUrl, key: "infoMap_" + source.bookSourceUrl).revision
                    }
                }.value
                XCTAssertEqual(clean, stored.map { $0.0 })
                XCTAssertEqual(fixture.peer.snapshot.requests.map(\.target), [fixture.prefix + "/search?key=native-original&page=2"])
            } catch { operationError = error }
            // These are two run-unique controlled cache keys, never user source data.
            await Task.detached {
                for source in [firstSource, secondSource] {
                    LegadoCacheBridge(sourceId: source.bookSourceUrl).delete("infoMap_" + source.bookSourceUrl)
                }
            }.value
            if let operationError { throw operationError }
        }
    }

    func testNativeOriginalCachedExplorePageOpensAndSavesOnLeave() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            var edited = fixture.source
            edited.bookSourceUrl += "/page-lifecycle-" + fixture.runID
            edited.enabledExplore = true
            edited.exploreUrl = "Cached::https://native-page.invalid/category"
            let source = edited
            let requestURL = fixture.baseURL + "/search?key=native-original&page=2"
            let script = "@js:if(infoMap==null)throw new Error('cached page omitted original map');infoMap.put('page','left');infoMap.save();'" + requestURL + "'"
            let raw = ModernParserBridge.DiscoverItem(title: "Cached", url: script)
            let key = DiscoverKindsCache.key(sourceUrl: source.bookSourceUrl, exploreUrl: source.exploreUrl, variableJSON: nil)
            let fetcher = BookSourceFetcher(mainJSService: fixture.service)
            var operationError: Error?
            do {
                let model = await MainActor.run { () -> DiscoverViewModel in
                    DiscoverKindsCache.shared.store([raw], forKey: key)
                    return DiscoverViewModel(source: source, fetcher: fetcher, sourceResolver: { $0 == source.id ? source : nil })
                }
                let load = await MainActor.run { model.reload() }
                await load?.value
                let categories = await MainActor.run { model.rawItems }
                XCTAssertEqual(categories.map(\.title), ["Cached"])
                let books = try await fetcher.discoverBooks(from: raw, page: 2, in: source)
                XCTAssertEqual(books.map(\.name), ["Original JNI"])
                let before = try await Task.detached {
                    try LegadoCacheBridge.runtimeSnapshot(sourceId: source.bookSourceUrl, key: "infoMap_" + source.bookSourceUrl)
                }.value
                XCTAssertTrue(before.values.isEmpty)
                let pause = await MainActor.run { model.pageDisappeared() }
                await pause?.value
                let saved = try await Task.detached { () -> (UInt64, String?) in
                    let snapshot = try LegadoCacheBridge.runtimeSnapshot(sourceId: source.bookSourceUrl, key: "infoMap_" + source.bookSourceUrl)
                    let text = try snapshot.values["value"].map { try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: $0).text() }
                    return (snapshot.revision, text)
                }.value
                let text = try XCTUnwrap(saved.1)
                XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(text.utf8)), ["page": "left"])
                let repeated = await MainActor.run { model.pageDisappeared() }
                await repeated?.value
                let clean = try await Task.detached {
                    try LegadoCacheBridge.runtimeSnapshot(sourceId: source.bookSourceUrl, key: "infoMap_" + source.bookSourceUrl).revision
                }.value
                XCTAssertEqual(clean, saved.0)
                XCTAssertEqual(fixture.peer.snapshot.requests.map(\.target), [fixture.prefix + "/search?key=native-original&page=2"])
            } catch { operationError = error }
            // Delete only this fixture's run-unique original map and category key.
            try await Task.detached {
                LegadoCacheBridge(sourceId: source.bookSourceUrl).delete("infoMap_" + source.bookSourceUrl)
                let categoryFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("DiscoverKindsCache", isDirectory: true).appendingPathComponent(key + ".json")
                if FileManager.default.fileExists(atPath: categoryFile.path) { try FileManager.default.removeItem(at: categoryFile) }
            }.value
            if let operationError { throw operationError }
        }
    }

    func testNativeOriginalBatchUsesRealGrantsArtifactsAndMissingIdentities() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            let owned = try await self.ownedBatchBook(fixture)
            let manager = await self.manager(fixture)
            let result = try await manager.fetchOriginalContentBatch(bookID: owned.book.id, sourceID: fixture.source.id,
                book: owned.dto, chapterIndexes: [0, 1, 2], store: owned.store, timeout: 60, cache: fixture.cache)
            XCTAssertEqual(result.missingChapters.map(\.index), [2])
            XCTAssertEqual(result.missingChapters.first?.url, owned.chapters[2].url)
            XCTAssertEqual(result.missingChapters.first?.bookURL, owned.dto.bookURL)
            let freshCache = ChapterCacheRepository(rootDirectory: fixture.cacheDirectory)
            let saved = try await BookStore.chapterCachePersistence {
                let one = try XCTUnwrap(freshCache.loadChapterPackageSync(bookId: owned.book.id, chapterIndex: 0,
                    expectedSourceURL: owned.chapters[0].url, expectedTOCTitle: owned.chapters[0].title))
                let two = try XCTUnwrap(freshCache.loadChapterPackageSync(bookId: owned.book.id, chapterIndex: 1,
                    expectedSourceURL: owned.chapters[1].url, expectedTOCTitle: owned.chapters[1].title))
                let normalized = try XCTUnwrap(freshCache.loadNormalizedChapterHTMLSync(bookId: owned.book.id,
                    chapterIndex: 1, expectedSourceURL: owned.chapters[1].url, expectedTOCTitle: owned.chapters[1].title))
                let raw = try String(contentsOf: fixture.cacheDirectory.appendingPathComponent(owned.book.id.uuidString)
                    .appendingPathComponent("1.raw.html"), encoding: .utf8)
                return (one, two, raw, normalized,
                    freshCache.loadChapterPackageSync(bookId: owned.book.id, chapterIndex: 2))
            }
            XCTAssertEqual(saved.0.content, "\u{3000}\u{3000}Batch wire content INDEX_0")
            XCTAssertEqual(saved.1.content, "\u{3000}\u{3000}<usehtml><p>Batch wire content INDEX_1</p><img src='media.png'></usehtml>")
            XCTAssertEqual(saved.2, saved.1.content)
            XCTAssertTrue(saved.3.contains(fixture.baseURL + "/media.png"))
            XCTAssertFalse(saved.3.contains("<usehtml"))
            XCTAssertNil(saved.4)
            XCTAssertEqual(owned.chapters[0].url, owned.chapters[1].url)
            XCTAssertNotEqual(owned.chapters[0].id, owned.chapters[1].id)
            let restarted = await Task.detached {
                BookStore(metadataFileURL: fixture.metadata, legacyMetadataDefaults: nil)
            }.value
            let chapters = try await restarted.originalRuntimeChapters(bookID: owned.book.id)
            XCTAssertEqual(chapters.map(\.id), owned.chapters.map(\.id))
            XCTAssertEqual(chapters.map(\.cachedFilename), ["0.txt", "1.txt", nil])
            let actualBook = await MainActor.run { restarted.readingBook(id: owned.book.id) }
            XCTAssertEqual(actualBook?.runtimeVariables?["nativeHost"], "accepted")
            XCTAssertEqual(actualBook?.runtimeVariables?["nativeSetter"], "final")
            for chapter in owned.chapters {
                let generation = await manager.originalRuntimeGeneration(bookID: owned.book.id, chapter: chapter)
                XCTAssertNil(generation)
            }
            XCTAssertEqual(fixture.peer.snapshot.requests.map(\.target), [fixture.prefix + "/duplicate", fixture.prefix + "/duplicate"])
        }
    }

    func testNativeOriginalBatchCancellationDrainsAndPreservesSavedPrefix() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            let owned = try await self.ownedBatchBook(fixture, distinctURLs: true)
            let manager = await self.manager(fixture)
            let headers = self.expectation(description: "Native original second HTTP response is held after its first byte")
            let peerClosed = self.expectation(description: "Cancelled original native client closes its held TCP socket")
            fixture.peer.armHeldBody(target: fixture.prefix + "/held", headersSent: { headers.fulfill() },
                peerClosed: { peerClosed.fulfill() })
            let pending = Task {
                try await manager.fetchOriginalContentBatch(bookID: owned.book.id, sourceID: fixture.source.id,
                    book: owned.dto, chapterIndexes: [0, 1, 2], store: owned.store, timeout: 60, cache: fixture.cache)
            }
            await self.fulfillment(of: [headers], timeout: 30)
            // The original loop cannot issue chapter two's HTTP request before
            // chapter one's actual Host cacheContent save has returned.
            let issued = fixture.peer.snapshot.heldHeadersSent
            pending.cancel()
            let terminal = await pending.result
            XCTAssertTrue(issued)
            await self.fulfillment(of: [peerClosed], timeout: 20)
            if case .success = terminal { XCTFail("Cancelled native batch cannot return a successful missing list") }
            if case .failure(let error) = terminal {
                let failure = try XCTUnwrap(error as? OriginalContentBatchFailure)
                let execution = try XCTUnwrap(failure.executionError)
                let typed = try XCTUnwrap(execution as? LegadoRuntimeError)
                XCTAssertEqual(typed.code, "CANCELLED", "Actual JNI cancellation must remain cancellation")
                XCTAssertTrue(typed.completedEffects?.contains("chapterContentCommitted") == true,
                    "JNI cancellation must retain the actual first Host save acknowledgement")
                self.attach(["verifiedSavedIndexes": failure.verifiedSavedIndexes,
                    "publicationFailed": failure.publicationError != nil], name: "OriginalNative-cancel-returned-facts")
            }
            let cache = ChapterCacheRepository(rootDirectory: fixture.cacheDirectory)
            let saved = try await BookStore.chapterCachePersistence {
                (cache.loadChapterPackageSync(bookId: owned.book.id, chapterIndex: 0,
                    expectedSourceURL: owned.chapters[0].url, expectedTOCTitle: owned.chapters[0].title),
                 cache.loadChapterPackageSync(bookId: owned.book.id, chapterIndex: 1))
            }
            XCTAssertEqual(saved.0?.content, "\u{3000}\u{3000}Batch wire content INDEX_0")
            XCTAssertNil(saved.1)
            for chapter in owned.chapters {
                let generation = await manager.originalRuntimeGeneration(bookID: owned.book.id, chapter: chapter)
                XCTAssertNil(generation)
            }
            XCTAssertTrue(fixture.peer.snapshot.heldPeerClosed)
            XCTAssertEqual(fixture.peer.snapshot.requests.count, 2)
        }
    }

    func testNativeOriginalBookNotificationsUseActualStateAndKeepCacheIdentity() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            try await self.withPublicOwnedBook(fixture) { fetcher, owned in
                var authored = fixture.source
                authored.eventListener = true
                authored.ruleContent.callBackJs = """
                if(String(java.getKey())!==String(source.getKey()) || String(sourceApi.getKey())!==String(baseUrl))throw new Error('wrong notification java');
                if(event==='saveRead' && String(result)!=='1234567890123')throw new Error('lost save time');
                if(event==='saveRead' && String(book.durChapterTime)!==String(result))throw new Error('different save time');
                if(event!=='saveRead' && Number(book.durChapterTime)!==946684800000)throw new Error('notification replaced actual read history');
                if(Number(book.durChapterPos)!==31)throw new Error('lost actual character position');
                if(Number(book.order)!==0 || Number(book.type)!==8)throw new Error('wrong actual book fields');
                if(event!=='saveRead' && result!==null)throw new Error('result must stay null');
                var events=String(book.getVariable('nativeCallbackEvents'));
                book.putVariable('nativeCallbackEvents',events+(events?'|':'')+event);
                book.putVariable('nativeCallbackBig','N'.repeat(10000));
                if(chapter!==null) {
                    if(Number(book.durChapterIndex)!==Number(chapter.index))throw new Error('wrong actual index');
                    chapter.putVariable('nativeCallbackEvent',event);
                    chapter.putVariable('nativeCallbackBig','C'.repeat(10000));
                }
                java.ajax('\(fixture.baseURL)/duplicate');
                // Notification returns are ignored, including objects Java cannot serialize.
                source;
                """
                let source = authored
                let chapter = try XCTUnwrap(owned.chapters.first)
                let existing = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
                var historical = try XCTUnwrap(existing)
                historical.lastOpenedDate = Date(timeIntervalSince1970: 946684800)
                let callbackBook = historical
                await MainActor.run { owned.store.saveReadingBook(callbackBook) }
                await BookStore.queuedWritesLanded()
                let positionOwner = JSONFileReadingPositionStore(
                    baseURL: fixture.root.appendingPathComponent("positions", isDirectory: true), onSave: { _, _ in })
                let actualPosition = CoreTextReadingPosition(spineIndex: chapter.index, charOffset: 31)
                let positionBefore = try await positionOwner.saveChecked(actualPosition, for: owned.book.id.uuidString)
                let identity = owned.chapters.map(\.id)
                let requestsBefore = fixture.peer.snapshot.requests.count
                for event in [SourceCallBackEvent.startRead, .saveRead, .endRead, .addBookShelf] {
                    let task = await MainActor.run {
                        SourceCallBackService.notify(event, book: callbackBook,
                            chapter: event == .addBookShelf ? nil : SourceCallBackService.chapterSnapshot(chapter),
                            chapterID: event == .addBookShelf ? nil : chapter.id,
                            result: event == .saveRead ? "1234567890123" : nil,
                            positionStore: positionOwner,
                            eventTimeMilliseconds: event == .saveRead ? 1234567890123 : nil,
                            store: owned.store, fetcher: fetcher, source: source)
                    }
                    let pending = try XCTUnwrap(task)
                    let outcome = await pending.value
                    XCTAssertFalse(outcome.failed, "\(event.rawValue): \(outcome.errorCode ?? "")")
                    XCTAssertFalse(outcome.handled)
                    XCTAssertNil(outcome.value)
                    XCTAssertTrue(outcome.completedEffects.contains("bookVariablesCommitted"))
                }
                let current = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
                XCTAssertEqual(current?.id, owned.book.id)
                XCTAssertEqual(current?.runtimeVariables?["nativeCallbackEvents"], "startRead|saveRead|endRead|addBookShelf")
                XCTAssertEqual(current?.runtimeVariables?["nativeCallbackBig"], String(repeating: "N", count: 10000))
                let chapters = try await owned.store.originalRuntimeChapters(bookID: owned.book.id)
                XCTAssertEqual(chapters.map(\.id), identity)
                XCTAssertEqual(chapters.map(\.cachedFilename), owned.chapters.map(\.cachedFilename))
                XCTAssertEqual(chapters.first?.runtimeVariables?["nativeCallbackEvent"], "endRead")
                XCTAssertEqual(chapters.first?.runtimeVariables?["nativeCallbackBig"], String(repeating: "C", count: 10000))
                XCTAssertEqual(fixture.peer.snapshot.requests.dropFirst(requestsBefore).map(\.target),
                    Array(repeating: fixture.prefix + "/duplicate", count: 4))
                let cached = try await BookStore.chapterCachePersistence {
                    fetcher.loadChapterPackageSync(bookId: owned.book.id, chapterIndex: chapter.index)
                }
                XCTAssertNil(cached, "A notification has no body save authority")
                let positionAfter = try await positionOwner.loadChecked(for: owned.book.id.uuidString)
                XCTAssertEqual(positionAfter?.position, actualPosition)
                XCTAssertEqual(positionAfter?.rawSHA256, positionBefore.rawSHA256)

                let stale = await MainActor.run { SourceCallBackService.notify(.startRead, book: owned.book,
                    chapter: SourceCallBackService.chapterSnapshot(chapter), chapterID: UUID(),
                    positionStore: positionOwner,
                    store: owned.store, fetcher: fetcher, source: source) }
                let staleTask = try XCTUnwrap(stale)
                let staleOutcome = await staleTask.value
                XCTAssertTrue(staleOutcome.failed); XCTAssertEqual(staleOutcome.errorCode, "STATE_CONFLICT")
                XCTAssertEqual(fixture.peer.snapshot.requests.count, requestsBefore + 4)

                var unsupportedBody = owned.book
                unsupportedBody.contentPipelineKind = .audio
                let nativeBody = unsupportedBody
                let bodyTask = await MainActor.run { SourceCallBackService.notify(.startRead, book: nativeBody,
                    store: owned.store, fetcher: fetcher, source: source) }
                let bodyPending = try XCTUnwrap(bodyTask)
                let bodyOutcome = await bodyPending.value
                XCTAssertTrue(bodyOutcome.failed); XCTAssertEqual(bodyOutcome.errorCode, "UNSUPPORTED_CAPABILITY")
                var mainJS = source
                mainJS.mainJs = "function search(){return []}"
                let unsupportedSource = mainJS
                let sourceTask = await MainActor.run { SourceCallBackService.notify(.startRead, book: owned.book,
                    store: owned.store, fetcher: fetcher, source: unsupportedSource) }
                let sourcePending = try XCTUnwrap(sourceTask)
                let sourceOutcome = await sourcePending.value
                XCTAssertTrue(sourceOutcome.failed); XCTAssertEqual(sourceOutcome.errorCode, "UNSUPPORTED_CAPABILITY")
                XCTAssertEqual(fixture.peer.snapshot.requests.count, requestsBefore + 4)

                var failing = source
                failing.ruleContent.callBackJs = "book.putVariable('nativeCallbackBeforeError','kept');throw new Error('authored notification failure');book.putVariable('nativeCallbackLate','bad')"
                let failingSource = failing
                let task = await MainActor.run { SourceCallBackService.notify(.endRead, book: callbackBook,
                    positionStore: positionOwner,
                    store: owned.store, fetcher: fetcher, source: failingSource) }
                let pending = try XCTUnwrap(task)
                let outcome = await pending.value
                XCTAssertTrue(outcome.failed); XCTAssertEqual(outcome.errorCode, "SCRIPT_ERROR")
                XCTAssertTrue(outcome.completedEffects.contains("bookVariablesCommitted"))
                let fallsBack = await MainActor.run { SourceCallBackService.shouldFallBack(outcome) }
                XCTAssertFalse(fallsBack)
                let after = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
                XCTAssertEqual(after?.runtimeVariables?["nativeCallbackBeforeError"], "kept")
                XCTAssertNil(after?.runtimeVariables?["nativeCallbackLate"])

                var unread = try XCTUnwrap(after)
                unread.lastOpenedDate = nil
                unread.addedDate = Date(timeIntervalSince1970: 915148800)
                let unreadBook = unread
                await MainActor.run { owned.store.saveReadingBook(unreadBook) }
                await BookStore.queuedWritesLanded()
                var verifiesAddedDate = source
                verifiesAddedDate.ruleContent.callBackJs = "if(Number(book.durChapterTime)!==915148800000)throw new Error('lost actual construction date');book.putVariable('nativeCallbackAddedTime',String(book.durChapterTime))"
                let unreadSource = verifiesAddedDate
                let unreadTask = await MainActor.run { SourceCallBackService.notify(.addBookShelf, book: unreadBook,
                    positionStore: positionOwner, store: owned.store, fetcher: fetcher, source: unreadSource) }
                let unreadPending = try XCTUnwrap(unreadTask)
                let unreadOutcome = await unreadPending.value
                XCTAssertFalse(unreadOutcome.failed, unreadOutcome.errorCode ?? "")
                let unreadAfter = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
                XCTAssertEqual(unreadAfter?.runtimeVariables?["nativeCallbackAddedTime"], "915148800000")
            }
        }
    }

    func testNativeOriginalBookNotificationCancellationDrains() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            try await self.withPublicOwnedBook(fixture) { fetcher, owned in
                var authored = fixture.source
                authored.eventListener = true
                authored.ruleContent.callBackJs = "book.putVariable('nativeCallbackBeforeCancel','kept');java.ajax('\(fixture.baseURL)/held');book.putVariable('nativeCallbackAfterCancel','bad')"
                let source = authored
                let positionOwner = JSONFileReadingPositionStore(
                    baseURL: fixture.root.appendingPathComponent("positions", isDirectory: true), onSave: { _, _ in })
                _ = try await positionOwner.saveChecked(.init(spineIndex: 0, charOffset: 31), for: owned.book.id.uuidString)
                let headers = self.expectation(description: "Actual callback HTTP is held")
                let closed = self.expectation(description: "Cancelled callback closes actual TCP socket")
                fixture.peer.armHeldBody(target: fixture.prefix + "/held", headersSent: { headers.fulfill() },
                    peerClosed: { closed.fulfill() })
                let task = await MainActor.run { SourceCallBackService.notify(.saveRead, book: owned.book,
                    chapter: owned.chapters.first.map(SourceCallBackService.chapterSnapshot),
                    chapterID: owned.chapters.first?.id, result: "1234567890123",
                    positionStore: positionOwner, eventTimeMilliseconds: 1234567890123,
                    store: owned.store, fetcher: fetcher, source: source) }
                let pending = try XCTUnwrap(task)
                await self.fulfillment(of: [headers], timeout: 30)
                pending.cancel()
                let terminal = await pending.value
                await self.fulfillment(of: [closed], timeout: 20)
                XCTAssertTrue(terminal.failed); XCTAssertEqual(terminal.errorCode, "CANCELLED")
                XCTAssertTrue(terminal.completedEffects.contains("bookVariablesCommitted"))
                let current = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
                XCTAssertEqual(current?.runtimeVariables?["nativeCallbackBeforeCancel"], "kept")
                XCTAssertNil(current?.runtimeVariables?["nativeCallbackAfterCancel"])
                XCTAssertTrue(fixture.peer.snapshot.heldPeerClosed)
                XCTAssertEqual(fixture.peer.snapshot.requests.filter { $0.target == fixture.prefix + "/held" }.count, 1)
            }
        }
    }

    func testNativeOriginalShelfRefreshUsesNullEntitiesAndSameSourceOwners() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            // Search receives the fixture Cookie through the real JVM transport
            // and App Cookie owner. No actual BookStore UUID is allocated here.
            _ = try await fixture.service.originalSearch(query: "native-original", page: 2, source: fixture.source)
            var authored = fixture.source
            authored.eventListener = true
            authored.ruleContent.callBackJs = """
            if(book!==null || chapter!==null || result!==null)throw new Error('source event has fake entities');
            if(String(java.getKey())!==String(source.getKey()) || String(sourceApi.getKey())!==String(baseUrl))throw new Error('wrong source java');
            if(typeof infoMap!=='undefined')throw new Error('source event invented an exploration context');
            if(String(cookie.getCookie('\(fixture.baseURL)')).indexOf('\(fixture.cookieName)=wire')<0)throw new Error('lost actual Cookie owner');
            var prior=String(source.get('nativeShelfEvents'));
            if(event==='endShelfRefresh' && prior!=='startShelfRefresh')throw new Error('source state lost across real sessions');
            source.put('nativeShelfEvents',prior+(prior?'|':'')+String(event));
            source.put('nativeShelfLarge','S'.repeat(10000));
            if(String(source.get('nativeShelfLarge')).length!==10000)throw new Error('lost source cache owner');
            java.ajax('\(fixture.baseURL)/duplicate');
            ({toString:function(){throw new Error('notification result must be ignored');}});
            """
            let source = authored
            let fetcher = BookSourceFetcher(mainJSService: fixture.service)
            var referenced = ReadingBook(title: "Refresh source reference", source: fixture.baseURL + "/book", contentFilename: "")
            referenced.isOnline = true; referenced.bookSourceId = source.id
            let actualRefreshSnapshot = [referenced, referenced]
            let before = fixture.peer.snapshot.requests.count
            for event in [SourceCallBackEvent.startShelfRefresh, .endShelfRefresh] {
                let pending = await MainActor.run { SourceCallBackService.notifyShelfRefresh(event,
                    books: actualRefreshSnapshot, fetcher: fetcher, sourceResolver: { id in id == source.id ? source : nil }) }
                let deliveries = await pending.value
                XCTAssertEqual(deliveries.count, 1, "Repeated books must emit once per listening source")
                let delivery = try XCTUnwrap(deliveries.first)
                XCTAssertEqual(delivery.sourceID, source.id); XCTAssertTrue(delivery.executed)
                XCTAssertFalse(delivery.outcome.failed, delivery.outcome.errorCode ?? "")
                XCTAssertFalse(delivery.outcome.handled); XCTAssertNil(delivery.outcome.value)
                XCTAssertTrue(delivery.outcome.completedEffects.contains("sourceStateCommitted"))
            }
            let requests = Array(fixture.peer.snapshot.requests.dropFirst(before))
            XCTAssertEqual(requests.map(\.target), Array(repeating: fixture.prefix + "/duplicate", count: 2))
            XCTAssertTrue(requests.allSatisfy { $0.cookie.contains(fixture.cookieName + "=wire") })
            let missingBookOwner = await Task.detached { !FileManager.default.fileExists(atPath: fixture.metadata.path) }.value
            XCTAssertTrue(missingBookOwner, "Source notifications cannot manufacture a BookStore record")
            var notListening = source
            notListening.eventListener = false
            let silentSource = notListening
            let silent = await MainActor.run { SourceCallBackService.notifyShelfRefresh(.endShelfRefresh,
                books: actualRefreshSnapshot, fetcher: fetcher,
                sourceResolver: { id in id == silentSource.id ? silentSource : nil }) }
            let suppressed = await silent.value
            XCTAssertTrue(suppressed.isEmpty)
            XCTAssertEqual(fixture.peer.snapshot.requests.count, before + 2)
        }
    }

    func testNativeOriginalShelfRefreshCancellationDrainsWithoutBookAuthority() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            var authored = fixture.source
            authored.eventListener = true
            authored.ruleContent.callBackJs = "if(book!==null||chapter!==null||result!==null)throw new Error('fake source entities');source.put('nativeShelfBeforeCancel','kept');java.ajax('\(fixture.baseURL)/held');source.put('nativeShelfAfterCancel','bad')"
            let source = authored
            let fetcher = BookSourceFetcher(mainJSService: fixture.service)
            var referenced = ReadingBook(title: "Source cancellation reference", source: fixture.baseURL + "/book", contentFilename: "")
            referenced.isOnline = true; referenced.bookSourceId = source.id
            let refreshSnapshot = [referenced]
            let headers = self.expectation(description: "Actual source notification HTTP is held")
            let closed = self.expectation(description: "Cancelled source notification closes the actual TCP socket")
            fixture.peer.armHeldBody(target: fixture.prefix + "/held", headersSent: { headers.fulfill() },
                peerClosed: { closed.fulfill() })
            let pending = await MainActor.run { SourceCallBackService.notifyShelfRefresh(.startShelfRefresh,
                books: refreshSnapshot, fetcher: fetcher, sourceResolver: { id in id == source.id ? source : nil }) }
            await self.fulfillment(of: [headers], timeout: 30)
            pending.cancel()
            let deliveries = await pending.value
            await self.fulfillment(of: [closed], timeout: 20)
            XCTAssertEqual(deliveries.count, 1)
            let terminal = try XCTUnwrap(deliveries.first)
            XCTAssertTrue(terminal.outcome.failed); XCTAssertEqual(terminal.outcome.errorCode, "CANCELLED")
            XCTAssertTrue(terminal.outcome.completedEffects.contains("sourceStateCommitted"))
            XCTAssertTrue(fixture.peer.snapshot.heldPeerClosed)
            var verifies = source
            verifies.ruleContent.callBackJs = "if(String(source.get('nativeShelfBeforeCancel'))!=='kept'||String(source.get('nativeShelfAfterCancel'))!=='')throw new Error('cancelled source state was not drained');source.put('nativeShelfCancelVerified','yes')"
            let verifySource = verifies
            let check = await MainActor.run { SourceCallBackService.notifyShelfRefresh(.endShelfRefresh,
                books: refreshSnapshot, fetcher: fetcher, sourceResolver: { id in id == verifySource.id ? verifySource : nil }) }
            let verified = await check.value
            XCTAssertEqual(verified.count, 1); XCTAssertFalse(verified.first?.outcome.failed ?? true)
            let noBookOwner = await Task.detached { !FileManager.default.fileExists(atPath: fixture.metadata.path) }.value
            XCTAssertTrue(noBookOwner)
            XCTAssertEqual(fixture.peer.snapshot.requests.filter { $0.target == fixture.prefix + "/held" }.count, 1)
        }
    }

    func testNativeOriginalPreUpdateRefreshKeepsPublicBookIdentityAndProgressWithNewURLContext() async throws {
        executionTimeAllowance = 180
        try await withFixture { fixture in
            try await self.withPublicOwnedBook(fixture) { fetcher, owned in
                // Populate the real old-URL chapter owner and durable body before
                // preUpdate moves the book; an unread book has no stale variables.
                let originalReader = await self.manager(fixture)
                let originalContent = try await originalReader.fetchChapter(book: owned.book, chapterIndex: 0,
                    priority: .immediate, store: owned.store)
                XCTAssertTrue(originalContent.content.contains("first&page"))
                XCTAssertTrue(originalContent.content.contains("last page"))
                let originalChapters = try await owned.store.originalRuntimeChapters(bookID: owned.book.id)
                XCTAssertEqual(originalChapters.first?.runtimeVariables?["nativeParsed"], "yes")
                XCTAssertEqual(originalChapters.first?.cachedFilename, "0.txt")
                let savedPosition = 0.375
                await MainActor.run { owned.store.updatePosition(bookId: owned.book.id, position: savedPosition, forceSave: true) }
                await BookStore.queuedWritesLanded()
                let beforeValue = await MainActor.run { owned.store.readingBook(id: owned.book.id) }
                let before = try XCTUnwrap(beforeValue)
                XCTAssertEqual(before.currentPosition, savedPosition)
                XCTAssertEqual(before.runtimeVariables?["nativeBig"], String(repeating: "L", count: 10_000))
                var authored = fixture.source
                authored.searchUrl = fixture.baseURL + "/refresh-search?key={{key}}&page={{page}}"
                authored.ruleBookInfo.initScript = """
                @js:if(String(book.bookUrl).indexOf('/moved-book')>=0){
                  if(String(java.get('nativeBig')).length===10000)throw new Error('old URL big variable migrated');
                  book.putVariable('nativeMovedInfo','accepted');
                  java.put('nativeRenewedBig','R'.repeat(10000));
                }else{throw new Error('preUpdate fetched old book info');}result
                """
                authored.ruleToc.preUpdateJs = """
                if(String(book.bookUrl).indexOf('/moved-book')<0){java.reGetBook();java.refreshTocUrl();}
                book.putVariable('nativePreUpdate','completed');
                """
                authored.ruleContent.title = """
                @js:if(String(java.get('nativeBig')).length===10000)throw new Error('old book variables reached moved content');
                if(String(java.get('nativeRenewedBig')).length!==10000)throw new Error('lost moved book variables');
                if(String(chapter.getVariable('nativeParsed'))==='yes')throw new Error('old chapter variables reached moved content');
                chapter.putVariable('nativeMovedParsed','yes');String(chapter.title)+'!'
                """
                let source = authored
                let requestsBefore = fixture.peer.snapshot.requests.count
                let refreshed = try await owned.store.refreshOnlineBookMetadata(bookId: owned.book.id,
                    bookSourceFetcher: LiveBookSourceFetcher(bookSourceFetcher: fetcher), sourceResolver: { _ in source })
                await BookStore.queuedWritesLanded()
                let newURL = fixture.baseURL + "/moved-book"
                XCTAssertEqual(refreshed.id, owned.book.id)
                XCTAssertEqual(refreshed.currentPosition, savedPosition)
                XCTAssertEqual(refreshed.addedDate, before.addedDate)
                XCTAssertEqual(refreshed.title, before.title, "reGetBook getInfo(false) must not rename the existing book")
                XCTAssertEqual(refreshed.bookInfoURL, newURL)
                XCTAssertEqual(refreshed.tocURL, fixture.baseURL + "/moved-toc")
                XCTAssertEqual(refreshed.runtimeVariables?["nativePreUpdate"], "completed")
                XCTAssertEqual(refreshed.runtimeVariables?["nativeMovedInfo"], "accepted")
                XCTAssertEqual(refreshed.runtimeVariables?["nativeRenewedBig"], String(repeating: "R", count: 10_000))
                XCTAssertNil(refreshed.runtimeVariables?["nativeBig"])
                XCTAssertEqual(refreshed.onlineChapters?.map(\.url), [fixture.baseURL + "/moved-c1", fixture.baseURL + "/moved-c2"])
                XCTAssertEqual(refreshed.onlineChapters?.map(\.id), originalChapters.map(\.id))
                XCTAssertTrue(refreshed.onlineChapters?.allSatisfy { $0.cachedFilename == nil } == true)
                XCTAssertTrue(refreshed.onlineChapters?.allSatisfy { ($0.runtimeVariables ?? [:]).isEmpty } == true,
                    "Changed chapter URLs must reach preview transfer with only their new variable compartment")
                let webViewFetcher = await MainActor.run { WebViewFetcher.shared }
                let movedReader = ChapterFetchManager(bookSourceFetcher: fetcher,
                    webViewFetcher: webViewFetcher, sourceResolver: { _ in source })
                let movedContent = try await movedReader.fetchChapter(book: refreshed, chapterIndex: 0,
                    priority: .immediate, store: owned.store)
                XCTAssertTrue(movedContent.content.contains("moved first chapter"))
                let movedChapters = try await owned.store.originalRuntimeChapters(bookID: owned.book.id)
                XCTAssertEqual(movedChapters.map(\.id), originalChapters.map(\.id))
                XCTAssertEqual(movedChapters.first?.runtimeVariables?["nativeMovedParsed"], "yes")
                XCTAssertNil(movedChapters.first?.runtimeVariables?["nativeParsed"])
                XCTAssertEqual(movedChapters.first?.cachedFilename, "0.txt")
                await BookStore.queuedWritesLanded()
                let afterRequests = Array(fixture.peer.snapshot.requests.dropFirst(requestsBefore))
                let search = try XCTUnwrap(afterRequests.first { $0.target.hasPrefix(fixture.prefix + "/refresh-search?") })
                let components = try XCTUnwrap(URLComponents(string: "http://127.0.0.1" + search.target))
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "key" })?.value, before.title)
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "page" })?.value, "1")
                XCTAssertTrue(afterRequests.contains { $0.target == fixture.prefix + "/moved-book" })
                XCTAssertTrue(afterRequests.contains { $0.target == fixture.prefix + "/moved-toc" })
                XCTAssertEqual(afterRequests.filter { $0.target == fixture.prefix + "/moved-c1" }.count, 1)
                XCTAssertFalse(afterRequests.contains { $0.target == fixture.prefix + "/book" })
                let newID = await owned.store.originalStoredOnlineBookID(sourceID: source.id, bookURL: newURL)
                let oldID = await owned.store.originalStoredOnlineBookID(sourceID: source.id, bookURL: owned.dto.bookURL)
                XCTAssertEqual(newID, owned.book.id); XCTAssertNil(oldID)
                let reopened = await Task.detached { BookStore(metadataFileURL: fixture.metadata, legacyMetadataDefaults: nil) }.value
                let restoredValue = await MainActor.run { reopened.readingBook(id: owned.book.id) }
                let restored = try XCTUnwrap(restoredValue)
                XCTAssertEqual(restored.id, owned.book.id)
                XCTAssertEqual(restored.currentPosition, savedPosition)
                XCTAssertEqual(restored.bookInfoURL, newURL)
                XCTAssertEqual(restored.tocURL, fixture.baseURL + "/moved-toc")
                XCTAssertEqual(restored.runtimeVariables?["nativeRenewedBig"], String(repeating: "R", count: 10_000))
                XCTAssertNil(restored.runtimeVariables?["nativeBig"])
                XCTAssertEqual(restored.onlineChapters?.map(\.id), originalChapters.map(\.id))
                XCTAssertEqual(restored.onlineChapters?.first?.runtimeVariables?["nativeMovedParsed"], "yes")
                XCTAssertNil(restored.onlineChapters?.first?.runtimeVariables?["nativeParsed"])
                // After the real App handoff, obtain the next ordinary context
                // through its existing public preparer; no fabricated grant/DTO.
                let known = OnlineBook(name: restored.title, author: restored.author, intro: "", coverUrl: "",
                    bookUrl: newURL, tocUrl: try XCTUnwrap(restored.tocURL), wordCount: "", lastChapter: "", kind: "",
                    sourceId: source.id, sourceName: source.bookSourceName, runtimeVariables: restored.runtimeVariables)
                let restoredChapters = try XCTUnwrap(restored.onlineChapters)
                let live = LiveBookSourceFetcher(bookSourceFetcher: fetcher)
                let context = try await live.prepareOriginalStoredBookPreview(source: source, knownBook: known,
                    chapters: restoredChapters)
                let wire = try XCTUnwrap(context?[LegadoMainJSSourceService.originalPreviewContextKey])
                let reference = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
                XCTAssertEqual(reference["bookURL"] as? String, newURL)
                let snapshot = try await fixture.service.originalPreviewSnapshot(source: source, runtimeVariables: context)
                XCTAssertEqual(snapshot.bookURL, newURL)
                XCTAssertEqual(snapshot.chapters.map(\.url), restoredChapters.map(\.url))
                XCTAssertEqual(snapshot.runtimeVariables?["nativeRenewedBig"], String(repeating: "R", count: 10_000))
                XCTAssertNil(snapshot.runtimeVariables?["nativeBig"])
            }
        }
    }

    private struct Fixture: @unchecked Sendable {
        let runID: String
        let prefix: String
        let cookieName: String
        let baseURL: String
        let root: URL
        let contextDirectory: URL
        let metadata: URL
        let cacheDirectory: URL
        let cache: ChapterCacheRepository
        let peer: NativeOriginalLoopbackServer
        let source: BookSource
        let service: LegadoMainJSSourceService
    }
    private struct OwnedBook: @unchecked Sendable {
        let store: BookStore
        let book: ReadingBook
        let dto: LegadoOriginalBook
        let chapters: [OnlineChapterRef]
    }
    private func withFixture(tocRedirect: Bool = false, _ body: (Fixture) async throws -> Void) async throws {
        let diagnostics = await Task.detached { LegadoRuntime.diagnose() }.value
        let required: Bool
        #if LEGADO_REQUIRE_NATIVE_MAINJS
        required = true
        #else
        required = ProcessInfo.processInfo.environment["LEGADO_REQUIRE_NATIVE_MAINJS"] == "1"
            || UserDefaults.standard.bool(forKey: "LEGADO_REQUIRE_NATIVE_MAINJS")
        #endif
        guard diagnostics.available else {
            if required { throw NativeOriginalReaderError.failed("Required actual JNI payload unavailable: \(diagnostics.issues)") }
            throw XCTSkip("Requires the real ordinary runtime and native-reader build; source-only cannot pass")
        }
        let runID = UUID().uuidString.lowercased()
        let peer = try NativeOriginalLoopbackServer(runID: runID)
        let ready = expectation(description: "Owned original loopback is ready")
        peer.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        var problem: Error?
        var fixture: Fixture?
        do {
            let base = try peer.readyBaseURL()
            // readyBaseURL already owns this run's namespace. Append only the
            // route suffix; adding prefix again bypasses the real held target.
            XCTAssertEqual(URL(string: base)?.path, "/" + runID)
            XCTAssertEqual(URL(string: base + "/held")?.path, "/" + runID + "/held")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeOriginal-" + runID, isDirectory: true)
            try await Task.detached { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }.value
            let context = root.appendingPathComponent("contexts", isDirectory: true)
            let cache = root.appendingPathComponent("body", isDirectory: true)
            let value = Fixture(runID: runID, prefix: "/" + runID, cookieName: "native_" + runID.replacingOccurrences(of: "-", with: ""),
                baseURL: base, root: root, contextDirectory: context, metadata: root.appendingPathComponent("books_meta.json"),
                cacheDirectory: cache, cache: .init(rootDirectory: cache), peer: peer, source: Self.source(base: base, runID: runID, tocRedirect: tocRedirect),
                service: .init(contextDirectory: context, operationTimeout: 45))
            fixture = value
            try await body(value)
        } catch { problem = error }
        if let fixture {
            do { try await fixture.service.closeSessions() }
            catch {
                attach(["sessionCleanupFailed": true, "originalOperationAlreadyFailed": problem != nil], name: "OriginalNative-session-cleanup")
                if problem == nil { problem = error }
            }
        }
        let stopped = expectation(description: "Owned original listener and all connections stop")
        peer.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
        let snapshot = peer.snapshot
        XCTAssertEqual(snapshot.activeConnections, 0)
        XCTAssertTrue(snapshot.listenerCancelled)
        XCTAssertTrue(snapshot.errors.isEmpty, "\(snapshot.errors)")
        attach(["nativeBridgePresent": diagnostics.nativeBridgePresent, "requiredPayload": required,
            "fixtureRunID": runID, "requests": snapshot.requests.map(\.target),
            "allConnectionsStopped": snapshot.listenerCancelled && snapshot.activeConnections == 0,
            "executionPlatform": "actual native-reader target, not source-only or injected transport"], name: "OriginalNative-product-chain")
        await BookStore.queuedWritesLanded()
        if let fixture {
            do { try await Task.detached { try FileManager.default.removeItem(at: fixture.root) }.value }
            catch { if problem == nil { problem = error } }
        }
        if let problem { throw problem }
    }
    private func ownedBook(_ f: Fixture, title: String, url: String, tocURL: String,
                           chapters: [OnlineChapterRef], variables: [String: String]? = nil) async throws -> OwnedBook {
        let store = await Task.detached { BookStore(metadataFileURL: f.metadata, legacyMetadataDefaults: nil) }.value
        var book = ReadingBook(title: title, author: "Owned author", source: url, contentFilename: "")
        book.isOnline = true; book.isInBookshelf = false; book.bookSourceId = f.source.id
        book.bookInfoURL = url; book.tocURL = tocURL; book.onlineChapters = chapters; book.runtimeVariables = variables
        let actual = book
        await MainActor.run { store.saveReadingBook(actual) }
        await BookStore.queuedWritesLanded()
        return .init(store: store, book: actual,
            dto: .init(bookURL: url, origin: f.source.bookSourceUrl, name: title, author: "Owned author", tocURL: tocURL), chapters: chapters)
    }
    private func withPublicOwnedBook(_ fixture: Fixture,
        body: (BookSourceFetcher, OwnedBook) async throws -> Void) async throws {
        let fetcher = BookSourceFetcher(mainJSService: fixture.service)
        let books = try await fetcher.search(query: "native-original", in: fixture.source, page: 2)
        let found = try XCTUnwrap(books.first)
        let detail = try await fetcher.fetchBookInfoPackage(url: found.bookUrl, source: fixture.source,
            runtimeVariables: found.runtimeVariables, knownBook: found)
        let toc = try await fetcher.fetchTOCPackage(tocUrl: detail.tocUrl, source: fixture.source,
            runtimeVariables: detail.runtimeVariables, forceRefresh: true)
        XCTAssertEqual(toc.chapters.count, 2)
        let adoption = await OriginalBookAdoption.prepare(toc.runtimeVariables, chapters: toc.chapters)
        let owned = try await ownedBook(fixture, title: detail.name, url: found.bookUrl,
            tocURL: toc.tocURL, chapters: adoption.chapters, variables: adoption.variables)
        var problem: Error?
        do {
            _ = try await fetcher.transferOriginalPreview(source: fixture.source, runtimeVariables: toc.runtimeVariables,
                to: owned.store, bookID: owned.book.id)
            try await body(fetcher, owned)
        } catch { problem = error }
        // These UUIDs were created by this fixture; no existing user cache is read
        // or cleared, and cleanup awaits the same chapter persistence owner.
        do { try await fetcher.clearAllChapterCacheAwait(bookId: owned.book.id) }
        catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    private func publicMetadataFileFacts(_ fixture: Fixture, bookID: UUID) async throws -> [String] {
        try await Task.detached {
            let paths = [fixture.metadata.deletingPathExtension().appendingPathExtension("reading.json"),
                fixture.metadata.deletingPathExtension().appendingPathExtension("chapters")
                    .appendingPathComponent(bookID.uuidString + ".json")]
            return try paths.map { path in
                let bytes = try Data(contentsOf: path)
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
                return inode.stringValue + ":" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
        }.value
    }

    private func ownedBatchBook(_ f: Fixture, distinctURLs: Bool = false) async throws -> OwnedBook {
        let chapters = (0..<3).map { index in
            OnlineChapterRef(index: index, title: "Batch \(index)", url: f.baseURL + (index == 2 ? "/missing" : (distinctURLs && index == 1 ? "/held" : "/duplicate")))
        }
        return try await ownedBook(f, title: "Owned native batch", url: f.baseURL + "/book", tocURL: f.baseURL + "/toc", chapters: chapters)
    }
    private func manager(_ fixture: Fixture) async -> ChapterFetchManager {
        let webViewFetcher = await MainActor.run { WebViewFetcher.shared }
        return ChapterFetchManager(bookSourceFetcher: .init(mainJSService: fixture.service),
            webViewFetcher: webViewFetcher, sourceResolver: { _ in fixture.source })
    }
    private static func source(base: String, runID: String, tocRedirect: Bool = false) -> BookSource {
        var source = BookSource(bookSourceUrl: base, bookSourceName: "Native original controlled source")
        source.enabledCookieJar = true
        source.header = "{\"X-Legado-Native-Fixture\":\"" + runID + "\",\"Accept-Encoding\":\"identity\",\"Connection\":\"close\"}"
        source.searchUrl = base + "/search?key={{key}}&page={{page}}"
        source.ruleSearch.bookList = ".book"; source.ruleSearch.name = "a@text"
        source.ruleSearch.author = "b@text"; source.ruleSearch.bookUrl = "a@href"
        source.ruleBookInfo.initScript = "@js:book.putVariable('nativeInfo','ready');java.put('nativeBig','L'.repeat(10000));result"
        source.ruleBookInfo.name = "@XPath://h1/text()"; source.ruleBookInfo.tocUrl = "#toc@href"
        source.ruleBookInfo.canReName = "yes"
        source.ruleToc.preUpdateJs = "java.put('nativeToc','ready')"
        if tocRedirect {
            source.ruleToc.preUpdateJs += "; book.tocUrl=String(book.tocUrl).replace(/\\/toc$/, '/toc-rewritten')"
        }
        source.ruleToc.chapterList = "$.chapters"; source.ruleToc.chapterName = "$.name"
        source.ruleToc.chapterUrl = "$.url"; source.ruleToc.nextTocUrl = "$.next"
        source.ruleContent.content = "#text@html"; source.ruleContent.nextContentUrl = ".next@href"
        source.ruleContent.replaceRegex = "##REMOVE##"
        source.ruleContent.title = "@js:if(String(java.get('nativeBig')).length!==10000)throw new Error('lost big variable');chapter.putVariable('nativeParsed','yes');String(chapter.title)+'!'"
        source.ruleContent.contentBatch = """
        book.putVariable('nativeHost','accepted');
        for(var i=0;i<2;i++) {
          var chapter=result.get(i); var wire=String(java.ajax(chapter.getAbsoluteURL()));
          var body=i===0 ? wire+' INDEX_0' : "<usehtml><p>"+wire+" INDEX_1</p><img src='media.png'></usehtml>";
          if(!java.cacheContent(chapter,body))throw new Error('actual App body save refused');
        }
        book.variable=JSON.stringify({nativeHost:'accepted',nativeSetter:'final'});
        """
        return source
    }
    private func attach(_ value: [String: Any], name: String) {
        do {
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
                uniformTypeIdentifier: "public.json")
            attachment.name = name + ".json"; attachment.lifetime = .keepAlways; add(attachment)
        } catch { XCTFail("Could not attach original native evidence: \(error)") }
    }
}

private enum NativeOriginalReaderError: Error { case failed(String) }

/// Listener mechanics retained from the existing native-reader fixture; only the
/// finite rule-source response table, observed Cookie and held target are changed.
private final class NativeOriginalLoopbackServer: @unchecked Sendable {
    struct Request: Codable {
        let method: String
        let target: String
        let rawRequestBase64: String
        let fixtureHeader: String
        let cookie: String
        let responseBody: String
        var heldBody: Bool
        var headersSent = false
        var completeResponseWritten = false
    }
    struct Snapshot: Codable {
        let requests: [Request]
        let errors: [String]
        let heldHeadersSent: Bool
        let heldPeerClosed: Bool
        let heldHeadersAtEpochMs: Double?
        let heldPeerClosedAtEpochMs: Double?
        let listenerCancelled: Bool
        let activeConnections: Int
    }
    private let runID: String
    private let emitCookie: Bool
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LegadoNativeOriginal.loopback")
    private let lock = NSLock()
    private var base: String?
    private var requests: [Request] = []
    private var errors: [String] = []
    private var connections: [UUID: NWConnection] = [:]
    private var heldConnection: UUID?
    private var holdNext = false
    private var holdTarget: String?
    private var heldHeaders = false
    private var peerClosed = false
    private var heldHeadersAtEpochMs: Double?
    private var heldPeerClosedAtEpochMs: Double?
    private var cancelled = false
    private var stopping = false
    private var readyCallback: (() -> Void)?
    private var stopCallback: (() -> Void)?
    private var headersCallback: (() -> Void)?
    private var peerCallback: (() -> Void)?

    init(runID: String, emitCookie: Bool = true) throws {
        self.runID = runID
        self.emitCookie = emitCookie
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    var snapshot: Snapshot {
        lock.withLock { Snapshot(requests: requests, errors: errors, heldHeadersSent: heldHeaders,
            heldPeerClosed: peerClosed, heldHeadersAtEpochMs: heldHeadersAtEpochMs,
            heldPeerClosedAtEpochMs: heldPeerClosedAtEpochMs,
            listenerCancelled: cancelled, activeConnections: connections.count) }
    }
    func readyBaseURL() throws -> String {
        try lock.withLock {
            guard let base, errors.isEmpty else { throw NativeOriginalReaderError.failed("Listener not ready: \(errors)") }
            return base
        }
    }
    func start(ready: @escaping () -> Void) {
        lock.withLock { readyCallback = ready }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.withLock {
                    if let port = self.listener.port { self.base = "http://127.0.0.1:\(port.rawValue)/\(self.runID)" }
                    else { self.errors.append("Listener has no port") }
                }
                self.signalReady()
            case .failed(let error): self.recordError("Listener failed: \(error)"); self.signalReady()
            case .cancelled: self.lock.withLock { self.cancelled = true }; self.signalReady(); self.finishStop()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
    }
    func armHeldBody(target: String, headersSent: @escaping () -> Void, peerClosed: @escaping () -> Void) {
        lock.withLock { holdNext = true; holdTarget = target; headersCallback = headersSent; peerCallback = peerClosed }
    }
    func stop(completed: @escaping () -> Void) {
        let open = lock.withLock { stopping = true; stopCallback = completed; return Array(connections.values) }
        listener.newConnectionHandler = nil
        listener.cancel()
        open.forEach { $0.cancel() }
        finishStop()
    }
    private func signalReady() {
        let callback = lock.withLock { let value = readyCallback; readyCallback = nil; return value }
        callback?()
    }
    private func finishStop() {
        let callback = lock.withLock { () -> (() -> Void)? in
            guard stopping, cancelled, connections.isEmpty else { return nil }
            let value = stopCallback; stopCallback = nil; return value
        }
        callback?()
    }
    private func recordError(_ value: String) { lock.withLock { errors.append(value) } }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard !stopping else { return false }
            connections[id] = connection
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                if !self.isExpectedPeerClose(error, id: id) { self.recordError("Connection failed: \(error)") }
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
                _ = self.lock.withLock { self.connections.removeValue(forKey: id) }
                self.finishStop()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, id: id, data: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = data
            if let chunk { bytes.append(chunk) }
            guard error == nil, bytes.count < 65_536 else { self.recordError("Invalid fixture request size/transport"); connection.cancel(); return }
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                do { try self.respond(connection, id: id, bytes: bytes, boundary: boundary) }
                catch { self.recordError(String(describing: error)); connection.cancel() }
            } else if !done { self.receive(connection, id: id, data: bytes) }
            else { self.recordError("Incomplete request headers"); connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, bytes: Data, boundary: Range<Data.Index>) throws {
        guard bytes.count == boundary.upperBound,
              let head = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw NativeOriginalReaderError.failed("Expected header-only GET") }
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1" else { throw NativeOriginalReaderError.failed("Unexpected request line") }
        let target = first[1]
        let headers = try lines.dropFirst().map { line -> (String, String) in
            guard let colon = line.firstIndex(of: ":") else { throw NativeOriginalReaderError.failed("Malformed request header") }
            return (String(line[..<colon]).lowercased(), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        guard !headers.contains(where: { $0.0 == "transfer-encoding" || ($0.0 == "content-length" && $0.1 != "0") }) else {
            throw NativeOriginalReaderError.failed("Unexpected GET body")
        }
        let base = try readyBaseURL()
        let prefix = "/\(runID)"
        let body: String
        if target == prefix + "/search?key=native-original&page=2" {
            body = "<div class='book'><a href='\(prefix)/book'>Original JNI</a><b>Owned author</b></div>"
        } else if target.hasPrefix(prefix + "/refresh-search?") {
            guard let query = URLComponents(string: "http://127.0.0.1" + target)?.queryItems,
                  query.first(where: { $0.name == "key" })?.value == "Original JNI Updated",
                  query.first(where: { $0.name == "page" })?.value == "1" else {
                throw NativeOriginalReaderError.failed("Unexpected precise-search identity/page")
            }
            body = "<div class='book'><a href='\(prefix)/moved-book'>Original JNI Updated</a><b>Owned author</b></div>"
        } else if target == prefix + "/moved-c1" {
            body = "<div id='text'>moved first chapter</div>"
        } else if target == prefix + "/moved-book" {
            body = "<h1>Unwanted moved rename</h1><a id='toc' href='\(prefix)/moved-toc'>toc</a>"
        } else if target == prefix + "/moved-toc" {
            body = try Self.json(["chapters": [["name": "One", "url": prefix + "/moved-c1"],
                ["name": "Two", "url": prefix + "/moved-c2"]], "next": []])
        } else if target == prefix + "/book" {
            body = "<h1>Original JNI Updated</h1><a id='toc' href='\(prefix)/toc'>toc</a>"
        } else if target == prefix + "/toc" || target == prefix + "/toc-rewritten" {
            body = try Self.json(["chapters": [["name": "One", "url": prefix + "/c1"]], "next": [prefix + "/toc2"]])
        } else if target == prefix + "/toc2" {
            body = try Self.json(["chapters": [["name": "Two", "url": prefix + "/c2"]], "next": []])
        } else if target == prefix + "/c1" {
            body = "<div id='text'>first&amp;page</div><a class='next' href='\(prefix)/c1p2'>next</a>"
        } else if target == prefix + "/c1p2" {
            body = "<div id='text'>last pageREMOVE</div><a class='next' href='\(prefix)/c2'>next chapter</a>"
        } else if target == prefix + "/c2" { body = "<div id='text'>second chapter</div>" }
        else if target == prefix + "/duplicate" || target == prefix + "/held" { body = "Batch wire content" }
        else { throw NativeOriginalReaderError.failed("Unknown fixture route: \(target)") }
        let entry = lock.withLock { () -> (Int, Bool) in
            let held = holdNext && target == holdTarget
            if held { holdNext = false; heldConnection = id }
            let index = requests.count
            requests.append(Request(method: first[0], target: target, rawRequestBase64: bytes.base64EncodedString(),
                fixtureHeader: headers.first(where: { $0.0 == "x-legado-native-fixture" })?.1 ?? "",
                cookie: headers.first(where: { $0.0 == "cookie" })?.1 ?? "", responseBody: body, heldBody: held))
            return (index, held)
        }
        guard entry.0 < 16 else { throw NativeOriginalReaderError.failed("Fixture request limit exceeded") }
        let content = Data(body.utf8)
        let cookieName = "native_" + runID.replacingOccurrences(of: "-", with: "")
        let setCookie = emitCookie && target == prefix + "/search?key=native-original&page=2"
            ? "Set-Cookie: \(cookieName)=wire; Path=\(prefix)/; HttpOnly\r\n" : ""
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(content.count)\r\n" + setCookie + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(entry.1 ? Data(content.prefix(1)) : content)
        connection.send(content: response, contentContext: entry.1 ? .defaultMessage : .finalMessage, isComplete: !entry.1,
            completion: .contentProcessed { [weak self] error in
                guard let self else { connection.cancel(); return }
                if let error { self.recordError("Response write failed: \(error)"); connection.cancel(); return }
                let callback = self.lock.withLock { () -> (() -> Void)? in
                    self.requests[entry.0].headersSent = true
                    self.requests[entry.0].completeResponseWritten = !entry.1
                    guard entry.1 else { return nil }
                    self.heldHeaders = true
                    self.heldHeadersAtEpochMs = Date().timeIntervalSince1970 * 1000
                    let value = self.headersCallback; self.headersCallback = nil; return value
                }
                if entry.1 { self.monitorPeer(connection, id: id); callback?() }
                else { connection.cancel() }
            })
    }
    private func monitorPeer(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] bytes, _, done, error in
            guard let self else { connection.cancel(); return }
            if done && error == nil && (bytes == nil || bytes?.isEmpty == true) { self.signalPeerClose(id: id) }
            else if let error, self.isExpectedPeerClose(error, id: id) { /* Recorded reset from the cancelled client. */ }
            else { self.recordError("Held connection did not end with peer EOF/reset") }
            connection.cancel()
        }
    }
    private func isExpectedPeerClose(_ error: NWError, id: UUID) -> Bool {
        guard case .posix(.ECONNRESET) = error, lock.withLock({ heldConnection == id && !stopping }) else { return false }
        signalPeerClose(id: id)
        return true
    }
    private func signalPeerClose(id: UUID) {
        let callback = lock.withLock { () -> (() -> Void)? in
            guard heldConnection == id, !stopping else { return nil }
            peerClosed = true
            heldPeerClosedAtEpochMs = Date().timeIntervalSince1970 * 1000
            let value = peerCallback; peerCallback = nil; return value
        }
        callback?()
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// One test-owned WK instance and its actual navigation/evaluation callbacks.
/// No JSContext, source bridge, process transport, Cookie owner, or HTTP fixture.
@MainActor
private final class OriginalOrderedWebJSCharacterization: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private let jsonName: String
    private let evalName: String
    private var navigation: WKNavigation?
    private var navigationFinished: XCTestExpectation?
    private var navigationTerminal = false
    private var navigationFailure: Error?
    private var evaluationsInFlight = 0
    private var drain: CheckedContinuation<Void, Never>?
    private var closed = false

    override init() {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let capturedJSONName = "__yuedu_ordered_json_" + suffix
        let capturedEvalName = "__yuedu_ordered_eval_" + suffix
        jsonName = capturedJSONName
        evalName = capturedEvalName
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: "const \(capturedJSONName)=JSON.stringify; const \(capturedEvalName)=eval;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    func load(allowsEval: Bool, finished: XCTestExpectation) throws {
        guard !closed, evaluationsInFlight == 0, navigation == nil || navigationTerminal else {
            throw NativeOriginalReaderError.failed("Characterization load lifetime mismatch")
        }
        navigationTerminal = false
        navigationFailure = nil
        navigationFinished = finished
        let permission = allowsEval ? " 'unsafe-eval'" : ""
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-owned'\(permission)">
        <script nonce="owned">
        window.eval=function(){return 'page-eval';};
        window.JSON={stringify:function(){return 'page-json';}};
        </script></head><body>Owned ordered-result characterization</body></html>
        """
        navigation = view.loadHTMLString(html, baseURL: URL(string: "https://ordered-result.invalid/"))
        guard navigation != nil else {
            navigationFinished = nil
            throw NativeOriginalReaderError.failed("Characterization navigation not started")
        }
    }

    func requireLoaded() throws {
        guard !closed, navigationTerminal else {
            throw NativeOriginalReaderError.failed("Characterization navigation did not finish")
        }
        if let navigationFailure { throw navigationFailure }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completeNavigation(navigation, error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completeNavigation(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completeNavigation(navigation, error: error)
    }

    private func completeNavigation(_ completed: WKNavigation?, error: Error?) {
        guard !closed, completed === navigation, !navigationTerminal else { return }
        navigationTerminal = true
        navigationFailure = error
        let expectation = navigationFinished
        navigationFinished = nil
        expectation?.fulfill()
    }

    func captureStatus() async throws -> String {
        try await string("[typeof \(jsonName),typeof \(evalName),Object.prototype.hasOwnProperty.call(window,'\(jsonName)'),Object.prototype.hasOwnProperty.call(window,'\(evalName)')].join('|')")
    }

    func encodeExpression(_ expression: String) async throws -> String {
        // This prototype intentionally accepts test-owned single expressions.
        // It is not a parser or a production fallback for arbitrary scripts.
        try await string("\(jsonName)((\(expression)))")
    }

    func capturedEval(_ code: String) async throws -> String {
        // Only fixed tiny synthetic scripts enter this literal encoder.
        let encoded = try JSONSerialization.data(withJSONObject: code, options: [.fragmentsAllowed])
        let literal = String(decoding: encoded, as: UTF8.self)
        return try await string("\(jsonName)((()=>{try{return {ok:true,value:\(evalName)(\(literal))};}catch(e){return {ok:false,name:e.name};}})())")
    }

    func string(_ script: String) async throws -> String {
        try requireLoaded()
        evaluationsInFlight += 1
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            view.evaluateJavaScript(script) { [self] value, error in
                finishEvaluation()
                if let error { continuation.resume(throwing: error) }
                else if let result = value as? String { continuation.resume(returning: result) }
                else { continuation.resume(throwing: NativeOriginalReaderError.failed("Characterization expected native string result")) }
            }
        }
    }

    func dictionary(_ script: String) async throws -> [String: Int] {
        try requireLoaded()
        evaluationsInFlight += 1
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Int], Error>) in
            view.evaluateJavaScript(script) { [self] value, error in
                finishEvaluation()
                if let error { continuation.resume(throwing: error) }
                else if let result = value as? [String: NSNumber] {
                    continuation.resume(returning: result.mapValues(\.intValue))
                } else { continuation.resume(throwing: NativeOriginalReaderError.failed("Characterization expected native object result")) }
            }
        }
    }

    private func finishEvaluation() {
        evaluationsInFlight -= 1
        if evaluationsInFlight == 0 {
            let completion = drain
            drain = nil
            completion?.resume()
        }
    }

    func close() async {
        closed = true
        view.stopLoading()
        if evaluationsInFlight != 0 {
            await withCheckedContinuation { continuation in drain = continuation }
        }
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllUserScripts()
        navigationFinished = nil
        navigation = nil
    }
}

/// A test-owned single WKWebView, with actual Program callbacks. The flat native
/// observation contains UTF16 key units rather than Swift String dictionary keys.
/// An error is data here, not successful conversion or an encoder fallback.
@MainActor
private final class OriginalNativeResultBridgeCharacterization: NSObject, WKNavigationDelegate {
    struct Vector: Sendable {
        let id: String
        let program: String
        let pageObservation: String
        let expectedPageObservation: String?
        let androidExpectation: String
        let requiresOrdinaryNativeDictionary: Bool
    }
    struct Node: Codable, Sendable {
        let id: Int
        let parent: Int?
        let relation: String
        let index: Int?
        let keyUTF16: [UInt16]?
        let keyNativeClass: String?
        let nativeClass: String
        var kind: String
        var count: Int?
        var textUTF16: [UInt16]?
        var numberObjCType: String?
        var numberString: String?
        var doubleBitsHex: String?
        var doubleIsFinite: Bool?
        var booleanValue: Bool?
    }
    struct Observation: Codable, Sendable {
        let label: String
        let hasNativeValue: Bool
        let rawNativeClass: String?
        let errorDomain: String?
        let errorCode: Int?
        let errorDescriptionUTF16: [UInt16]?
        let javaScriptExceptionUTF16: [UInt16]?
        let projectionLimit: String?
        let nodes: [Node]
        var nativeString: String? {
            guard let root = nodes.first, root.kind == "string", let units = root.textUTF16 else { return nil }
            return String(decoding: units, as: UTF16.self)
        }
    }
    struct Record: Codable, Sendable {
        let id: String
        let sourceDerivedAndroidExpectation: String
        let native: Observation
        let pageAfterNativeCallback: Observation
    }
    struct Lifecycle: Codable, Sendable {
        let createdViews: Int
        let evaluationsIssued: Int
        let evaluationsCompleted: Int
        let evaluationsInFlight: Int
        let closed: Bool
    }
    struct Report: Codable, Sendable {
        let purpose = "WK native Program result information characterization; not Android execution or product compatibility approval"
        let actualAndroidExecuted = false
        let actualCallerFlagsProvenByPinnedSource = true
        let androidSourceCommit = "1b10defa68c2f01621bc3795169817d777aa714a"
        let callerFlags = "Ordinary caller sets DateAllowed/RegExpAllowed=true; no Function/Strategy/StripNull/NegativeZero setters"
        let fixtureGroups = 10
        let nativeProgramRecords = 14
        let records: [Record]
        let lifecycle: Lifecycle
        let infrastructureFailure: String?
    }
    // WK returns a completed immutable Foundation graph. This probe never
    // mutates or shares it before the off-main bounded snapshot finishes.
    private struct Completion: @unchecked Sendable {
        let value: Any?
        let error: NSError?
    }

    nonisolated static var vectors: [Vector] {
        let bodies: [(String, String, String, String?, String, Bool)] = [
            ("object-special-members", "window.__bridgeValue={present:1,undefinedValue:undefined,functionValue:function(){},symbolValue:Symbol('owned'),nan:NaN,positiveInfinity:Infinity,negativeInfinity:-Infinity,nullValue:null};window.__bridgeValue",
             "Object.keys(window.__bridgeValue).length", "1|8",
             "Default converter omits undefined/function/symbol/nonfinite object members; preserves present=1 and nullValue=null", false),
            ("array-special-members", "window.__bridgeValue=[undefined,function(){},Symbol('owned'),NaN,Infinity,-Infinity,null,1];window.__bridgeValue",
             "window.__bridgeValue.length", "2|8",
             "Converter array slots for unsupported values become null and array length/order remain eight", false),
            ("raw-unicode-and-numeric-keys", "window.__bridgeValue={'\\u00e9':1,'e\\u0301':2,'2':2,'10':10,b:2,a:1};window.__bridgeValue",
             "Object.getOwnPropertyNames(window.__bridgeValue).map(function(k){var r=[];for(var i=0;i<k.length;i++)r.push(k.charCodeAt(i));return r.join(',');}).join(';')",
             "3|50;49,48;233;101,769;98;97",
             "Base dictionary stores distinct UTF8 names and sorts keys; Swift canonical-equivalent String keys must not silently coalesce", true),
            ("numeric-boundaries", "window.__bridgeValue={minimum:-2147483648,maximum:2147483647,overflow:2147483648,minusZero:-0,one:1.0,fraction:1.25,large:1e100};window.__bridgeValue",
             "String(Object.is(window.__bridgeValue.minusZero,-0))+'|'+String(window.__bridgeValue.overflow)+'|'+String(window.__bridgeValue.large)", "4|true|2147483648|1e+100",
             "Converter tests IsInt32 before double; default writer preserves double category. Observe NSNumber type/bits, especially negative zero and integral overflow", true),
            ("cycle", "window.__bridgeValue={};window.__bridgeValue.self=window.__bridgeValue;window.__bridgeValue",
             "window.__bridgeValue.self===window.__bridgeValue", "5|true",
             "Converter replaces the cyclic child with null; native bridge may instead reject the whole completion, which remains an information gap", false),
            ("dom-api-wrapper", "window.__bridgeValue=document.body;window.__bridgeValue",
             "window.__bridgeValue.tagName", "6|BODY",
             "Bound converter API wrapper branch yields empty dictionary; a WK error or a different native projection must be recorded", false),
            ("throwing-getter", "window.__bridgeGetterReads=0;window.__bridgeValue={get a(){window.__bridgeGetterReads++;throw Error('owned getter');},b:2};window.__bridgeValue",
             "window.__bridgeGetterReads", nil,
             "Converter catches a throwing getter, substitutes null for that property, and does not execute the authored Program a second time", false),
            ("observable-toJSON", "window.__bridgeToJSONCalls=0;window.__bridgeValue={a:1,toJSON:function(){window.__bridgeToJSONCalls++;return 7;}};window.__bridgeValue",
             "window.__bridgeToJSONCalls", nil,
             "Converter does not invoke toJSON; its function-valued property is omitted. Page counter must show whether WK projection introduces an incompatible call", false),
            ("date-and-regexp-caller-flags", "window.__bridgeValue={date:new Date(1250),regexp:/owned/gi};window.__bridgeValue",
             "String(window.__bridgeValue.date.getTime())+'|'+String(window.__bridgeValue.regexp)", "9|1250|/owned/gi",
             "Actual ordinary caller explicitly allows Date as seconds-double (1.25) and RegExp as string (/owned/gi); constructor defaults are not the caller contract", false),
            ("special-objects.boxed-number", "window.__bridgeValue=new Number(7);window.__bridgeValue",
             "typeof window.__bridgeValue+'|'+String(window.__bridgeValue)", "10|object|7",
             "Number wrapper enters converter Object handling rather than scalar Number; native unboxing would lose that distinction", false),
            ("special-objects.boxed-string", "window.__bridgeValue=new String('owned');window.__bridgeValue",
             "typeof window.__bridgeValue+'|'+String(window.__bridgeValue)", "11|object|owned",
             "String wrapper enters Object own-property conversion rather than scalar String; record whether WK silently unboxes it", false),
            ("special-objects.boxed-boolean", "window.__bridgeValue=new Boolean(false);window.__bridgeValue",
             "typeof window.__bridgeValue+'|'+String(window.__bridgeValue)", "12|object|false",
             "Boolean wrapper enters Object handling rather than scalar Boolean; native NSNumber unboxing would be irreversible", false),
            ("special-objects.promise", "window.__bridgeValue=Promise.resolve('owned');window.__bridgeValue",
             "window.__bridgeValue instanceof Promise", "13|true",
             "Ordinary native Program execution has no ForTests resolve_promises flag; record actual WK result/error rather than awaiting or stringifying the Promise", false),
            ("special-objects.typed-array", "window.__bridgeValue=new Uint8Array([1,2]);window.__bridgeValue",
             "String(window.__bridgeValue.byteLength)+'|'+String(window.__bridgeValue[0])", "14|2|1",
             "Converter returns binary storage for typed arrays; default WriteJson refuses binary and callback becomes empty text. Native unboxing into ordinary array/object must not be treated as parity", false)
        ]
        return bodies.map { body in
            Vector(id: body.0,
                program: "window.__nativeBridgeRuns=(window.__nativeBridgeRuns||0)+1;\n" + body.1,
                pageObservation: "String(window.__nativeBridgeRuns)+'|'+String((" + body.2 + "))",
                expectedPageObservation: body.3, androidExpectation: body.4,
                requiresOrdinaryNativeDictionary: body.5)
        }
    }

    private let view: WKWebView
    private var navigation: WKNavigation?
    private var navigationFinished: XCTestExpectation?
    private var navigationTerminal = false
    private var navigationFailure: Error?
    private var issued = 0
    private var completed = 0
    private var inFlight = 0
    private var drain: CheckedContinuation<Void, Never>?
    private var closed = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    func load(finished: XCTestExpectation) throws {
        guard !closed, navigation == nil, inFlight == 0 else {
            throw NativeOriginalReaderError.failed("Native-result probe lifetime mismatch")
        }
        navigationFinished = finished
        // No page eval/JSON helper or source bridge is installed. The finite
        // owned HTML blocks network loads; all scripts below use native Program.
        navigation = view.loadHTMLString("<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'\"></head><body>Owned native result</body></html>",
            baseURL: URL(string: "https://native-result.invalid/"))
        guard navigation != nil else { throw NativeOriginalReaderError.failed("Native-result navigation did not start") }
    }

    func requireLoaded() throws {
        guard !closed, navigationTerminal else { throw NativeOriginalReaderError.failed("Native-result navigation did not finish") }
        if let navigationFailure { throw navigationFailure }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNavigation(navigation, error: nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNavigation(navigation, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNavigation(navigation, error: error) }
    private func finishNavigation(_ finished: WKNavigation?, error: Error?) {
        guard !closed, finished === navigation, !navigationTerminal else { return }
        navigationTerminal = true
        navigationFailure = error
        let waiting = navigationFinished
        navigationFinished = nil
        waiting?.fulfill()
    }

    func evaluate(_ script: String, label: String) async throws -> Observation {
        try Task.checkCancellation()
        try requireLoaded()
        issued += 1
        inFlight += 1
        let completion: Completion = await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { [self] value, error in
                completed += 1
                inFlight -= 1
                if inFlight == 0 {
                    let waiting = drain
                    drain = nil
                    waiting?.resume()
                }
                continuation.resume(returning: Completion(value: value, error: error as NSError?))
            }
        }
        return await Self.inspect(completion, label: label)
    }

    nonisolated private static func inspect(_ completion: Completion, label: String) async -> Observation {
        SourcePerfTrace.span("legado.test.webview.native-result", "main=\(Thread.isMainThread) values=1") {
            var nodes: [Node] = []
            var active: Set<ObjectIdentifier> = []
            var limit: String?
            func units(_ value: NSString, maximum: Int = 4096) -> [UInt16] {
                (0..<min(value.length, maximum)).map { value.character(at: $0) }
            }
            func append(_ candidate: Any?, parent: Int?, relation: String, index: Int? = nil,
                        key: NSString? = nil, depth: Int = 0) {
                guard nodes.count < 512, depth <= 16 else { limit = "native observation depth/node budget"; return }
                let id = nodes.count
                let nativeClass = candidate.map { String(reflecting: type(of: $0)) } ?? "nil"
                var node = Node(id: id, parent: parent, relation: relation, index: index,
                    keyUTF16: key.map { units($0) }, keyNativeClass: key.map { String(reflecting: type(of: $0)) },
                    nativeClass: nativeClass, kind: "opaque-native-value")
                guard let candidate else { node.kind = "nil"; nodes.append(node); return }
                if candidate is NSNull { node.kind = "null"; nodes.append(node); return }
                if let number = candidate as? NSNumber {
                    let boolean = CFGetTypeID(number) == CFBooleanGetTypeID()
                    node.kind = boolean ? "boolean" : "number"
                    node.numberObjCType = String(cString: number.objCType)
                    node.numberString = number.stringValue
                    node.doubleBitsHex = String(number.doubleValue.bitPattern, radix: 16)
                    node.doubleIsFinite = number.doubleValue.isFinite
                    if boolean { node.booleanValue = number.boolValue }
                    nodes.append(node); return
                }
                if let text = candidate as? NSString {
                    node.kind = "string"; node.count = text.length; node.textUTF16 = units(text)
                    if text.length > 4096 { limit = "native observation string budget" }
                    nodes.append(node); return
                }
                if let dictionary = candidate as? NSDictionary {
                    node.kind = "dictionary"; node.count = dictionary.count
                    let identity = ObjectIdentifier(dictionary)
                    guard active.insert(identity).inserted else { node.kind = "native-cycle"; nodes.append(node); return }
                    nodes.append(node)
                    let keys = dictionary.keyEnumerator()
                    var offset = 0
                    while let rawKey = keys.nextObject() {
                        guard offset < 64 else { limit = "native observation dictionary budget"; break }
                        // Keep the native NSString key and exact code units. Do
                        // not convert through Dictionary<String, Any>.
                        if let text = rawKey as? NSString {
                            append(dictionary.object(forKey: text), parent: id, relation: "member", index: offset,
                                key: text, depth: depth + 1)
                        } else {
                            append(rawKey, parent: id, relation: "non-string-key", index: offset, depth: depth + 1)
                        }
                        offset += 1
                    }
                    active.remove(identity); return
                }
                if let array = candidate as? NSArray {
                    node.kind = "array"; node.count = array.count
                    let identity = ObjectIdentifier(array)
                    guard active.insert(identity).inserted else { node.kind = "native-cycle"; nodes.append(node); return }
                    nodes.append(node)
                    if array.count > 64 { limit = "native observation array budget" }
                    for index in 0..<min(array.count, 64) {
                        append(array.object(at: index), parent: id, relation: "element", index: index, depth: depth + 1)
                    }
                    active.remove(identity); return
                }
                nodes.append(node)
            }
            append(completion.value, parent: nil, relation: "root")
            let error = completion.error
            let exception = error?.userInfo["WKJavaScriptExceptionMessage"] as? NSString
            return Observation(label: label, hasNativeValue: completion.value != nil,
                rawNativeClass: completion.value.map { String(reflecting: type(of: $0)) },
                errorDomain: error?.domain, errorCode: error?.code,
                errorDescriptionUTF16: error.map { units($0.localizedDescription as NSString) },
                javaScriptExceptionUTF16: exception.map { units($0) }, projectionLimit: limit, nodes: nodes)
        }
    }

    nonisolated static func encodeReport(_ report: Report) async throws -> Data {
        try SourcePerfTrace.span("legado.test.webview.native-result-report", "main=\(Thread.isMainThread) cases=\(report.records.count)") {
            try JSONEncoder().encode(report)
        }
    }

    func close() async -> Lifecycle {
        closed = true
        view.stopLoading()
        if inFlight != 0 { await withCheckedContinuation { drain = $0 } }
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllUserScripts()
        navigationFinished = nil
        navigation = nil
        return Lifecycle(createdViews: 1, evaluationsIssued: issued, evaluationsCompleted: completed,
            evaluationsInFlight: inFlight, closed: closed)
    }
}
