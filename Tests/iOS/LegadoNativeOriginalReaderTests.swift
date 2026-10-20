import CryptoKit
import Foundation
import LegadoRuntime
@preconcurrency import Network
import XCTest
@testable import yuedu_app

/// The existing native-reader target must link the real ordinary JAR and Zero VM.
/// All service/executor/Host/client/cache implementations below are production defaults.
/// The loopback peer supplies bytes only; it is never a runtime transport substitute.
final class LegadoNativeOriginalReaderTests: XCTestCase {
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
                XCTAssertEqual(refreshed.tocURL, fixture.baseURL + fixture.prefix + "/toc-rewritten")
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
                let before = try await Task.detached {
                    try [firstSource, secondSource].map { source in
                        try LegadoCacheBridge.runtimeSnapshot(sourceId: source.bookSourceUrl, key: "infoMap_" + source.bookSourceUrl)
                    }
                }.value
                XCTAssertTrue(before.allSatisfy { $0.values.isEmpty })
                let requestedURL = fixture.baseURL + fixture.prefix + "/search?key=native-original&page=2"
                let script = "@js:if(infoMap.get('genre')!=='first')throw new Error('wrong original context');'" + requestedURL + "'"
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
            XCTAssertEqual(saved.0.content, "Batch wire content INDEX_0")
            XCTAssertEqual(saved.1.content, "<usehtml><p>Batch wire content INDEX_1</p><img src='media.png'></usehtml>")
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
            XCTAssertEqual(saved.0?.content, "Batch wire content INDEX_0")
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
                java.ajax('\(fixture.baseURL)\(fixture.prefix)/duplicate');
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
                authored.ruleContent.callBackJs = "book.putVariable('nativeCallbackBeforeCancel','kept');java.ajax('\(fixture.baseURL)\(fixture.prefix)/held');book.putVariable('nativeCallbackAfterCancel','bad')"
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

    init(runID: String) throws {
        self.runID = runID
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
        let setCookie = target == prefix + "/search?key=native-original&page=2"
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
