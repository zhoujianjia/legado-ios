import CryptoKit
import Foundation
import XCTest

/// Shared real import/navigation mechanics. HTTP bodies alone do not attest
/// interpreter execution or physical-device acceptance.
class ReaderBookSourceSmokeTestCase: XCTestCase {
    var directory: URL!
    var fixtureOrigin: URL { URL(string: "http://localhost:18769")! }
    var expectedFixtureID: String { "reader-book-source-smoke-v1" }
    var fixturePathPrefix: String { "/fixture/" }
    let query = "OnlineSmoke"
    let firstMarker = "JSC_ONLY_CHAPTER_ONE"
    let secondMarker = "JSC_ONLY_CHAPTER_TWO"
    let secondChapter = "Chapter 2 Crossing"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderBookSourceSmoke-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sources"), withIntermediateDirectories: true)
        // Existing public-library transport hook: its empty search feed cannot
        // introduce a public result or make this source test depend on a site.
        let feed = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><id>urn:online-smoke</id><title>Empty local feed</title></feed>"
        try Data(feed.utf8).write(to: directory.appendingPathComponent("ebooks_search.opds.xml"))
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    struct OnlineFixture {
        let runID: String
        let baseURL: String
        let sourceURL: String
        let title: String
    }

    @MainActor
    func importSourceAndOpenDetail(_ app: XCUIApplication) async throws -> OnlineFixture {
        let health = try await fetchJSON(path: "/health")
        XCTAssertEqual(health["fixture"] as? String, expectedFixtureID)
        let runID = try XCTUnwrap(health["runId"] as? String)
        XCTAssertNotNil(UUID(uuidString: runID))
        XCTAssertEqual(health["origin"] as? String, fixtureOrigin.absoluteString)
        let baseURL = fixtureOrigin.absoluteString + fixturePathPrefix + runID
        XCTAssertEqual(health["baseURL"] as? String, baseURL)
        let sourceURL = baseURL + "/sources.json"
        XCTAssertEqual(health["sourceURL"] as? String, sourceURL)
        let title = "OnlineSmoke Book " + runID
        let sourceName = "Online Smoke Source " + runID
        XCTAssertEqual(health["bookTitle"] as? String, title)
        XCTAssertEqual(health["sourceName"] as? String, sourceName)
        let initialTrace = try await fetchJSON(path: "/trace?runId=" + runID)
        XCTAssertEqual(try XCTUnwrap(initialTrace["requests"] as? [[String: Any]]).count, 0,
                       "A fresh server run must start with no business requests")
        attachJSON(health, name: "online-source-fixture-health")

        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-yd_root_tab_visible_ids", "(bookshelf, search, settings)", "-bookLayoutIsGrid", "NO",
            "-yd_source_disclaimer_accepted", "YES", "-yd_search_open_library", "NO",
            "-yd_search_source_scope_mode", "all", "-book-source-store-dir", directory.appendingPathComponent("sources").path,
            "-reset-explore-home", "-reset-reading-settings", "-yd_scroll_mode", "NO",
            "-yd_page_turn_style", "\u{6ED1}\u{52D5}", "-yd_appearance_reader_interface", "classic"
        ]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = directory.path
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        let deny = app.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Don\u{2019}t Allow", "Don't Allow"])).firstMatch
        if deny.waitForExistence(timeout: 2) { deny.tap() }

        var link = URLComponents()
        link.scheme = "yuedu"
        link.host = "import"
        link.path = "/bookSource"
        link.queryItems = [URLQueryItem(name: "src", value: sourceURL)]
        // The existing system entry preserves launch arguments and the empty
        // source-store override; XCUIApplication.open would relaunch the app.
        XCUIDevice.shared.system.open(try XCTUnwrap(link.url))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemOpen = springboard.buttons["Open"].firstMatch
        if systemOpen.waitForExistence(timeout: 3) { systemOpen.tap() }
        let confirm = app.buttons["Import"].firstMatch
        tapReady(confirm, app: app)
        let incomingSource = app.buttons[sourceName].firstMatch
        XCTAssertTrue(incomingSource.waitForExistence(timeout: 20), "The real download must reach import review.\n\(app.debugDescription)")
        capture(app, name: "online-01-real-source-import-review")
        tapReady(app.navigationBars.buttons["Import"].firstMatch, app: app)
        XCTAssertTrue(app.staticTexts["Imported 1 source."].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        tapReady(app.buttons["Done"].firstMatch, app: app)

        tapReady(app.tabBars.buttons["Search"].firstMatch, app: app)
        let field = app.searchFields.firstMatch
        tapReady(field, app: app)
        field.typeText(query + "\n")
        let found = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 35), "The real source search must return its current-run book.\n\(app.debugDescription)")
        capture(app, name: "online-02-http-search-result")
        tapReady(found, app: app)
        let detail = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "ONLINE_DETAIL_HTTP_RESPONSE")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "The detail HTTP response must be parsed and shown.\n\(app.debugDescription)")
        capture(app, name: "online-03-source-detail-and-toc")
        let addBook = app.buttons["Add to Library"].firstMatch
        for _ in 0..<4 where !addBook.isHittable { app.swipeDown() }
        tapReady(addBook, app: app)
        XCTAssertTrue(app.buttons["Remove"].firstMatch.waitForExistence(timeout: 15), "Adding must create the real shelf copy.\n\(app.debugDescription)")
        return OnlineFixture(runID: runID, baseURL: baseURL, sourceURL: sourceURL, title: title)
    }

    @MainActor
    func fetchJSON(path: String) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: fixtureOrigin.absoluteString + path))
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func verifyHTTPTrace(_ trace: [String: Any], runID: String, baseURL: String) throws -> [String: Int] {
        XCTAssertEqual(trace["runId"] as? String, runID)
        XCTAssertEqual(trace["origin"] as? String, fixtureOrigin.absoluteString)
        XCTAssertEqual(trace["baseURL"] as? String, baseURL)
        let basePath = try XCTUnwrap(URL(string: baseURL)?.path)
        let names = ["sources.json", "search", "book.html", "toc.html", "chapter0.html", "chapter1.html"]
        var counts = Dictionary(uniqueKeysWithValues: names.map { (basePath + "/" + $0, 0) })
        let records = try XCTUnwrap(trace["requests"] as? [[String: Any]])
        for (index, record) in records.enumerated() {
            XCTAssertEqual(record["sequence"] as? Int, index + 1)
            XCTAssertEqual(record["method"] as? String, "GET")
            XCTAssertEqual(record["bodyBase64"] as? String, "")
            let path = try XCTUnwrap(record["path"] as? String)
            XCTAssertNotNil(counts[path], "No unknown business route may be ignored")
            counts[path, default: 0] += 1
            let parameters = try XCTUnwrap(record["query"] as? [String: [String]])
            XCTAssertEqual(parameters, path.hasSuffix("/search") ? ["q": [query], "page": ["1"]] : [:])
            let response = try XCTUnwrap(record["response"] as? [String: Any])
            XCTAssertEqual(response["status"] as? Int, 200)
            XCTAssertEqual(response["writeCompleted"] as? Bool, true)
            let encoded = try XCTUnwrap(response["bodyBase64"] as? String)
            let body = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertEqual(response["bodyBytes"] as? Int, body.count)
            XCTAssertEqual(response["bodySHA256"] as? String,
                           SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertFalse(text.contains("JSC_ONLY_"), "The HTTP fixture must never precompute the JS-only marker")
            if path.hasSuffix("/chapter0.html") { XCTAssertTrue(text.contains("RAW_ONLY_CHAPTER_ONE")) }
            if path.hasSuffix("/chapter1.html") { XCTAssertTrue(text.contains("RAW_ONLY_CHAPTER_TWO")) }
        }
        for (path, count) in counts { XCTAssertGreaterThan(count, 0, "Missing actual HTTP request: " + path) }
        return counts
    }

    @MainActor
    func tapReady(_ element: XCUIElement, app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
        element.tap()
    }

    @MainActor
    func waitForVisiblePage(_ app: XCUIApplication, marker: String, otherChapter: String) throws -> String {
        func visible() -> XCUIElement? {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).allElementsBoundByIndex.first {
                $0.exists && $0.isHittable && $0.frame.contains(CGPoint(x: app.frame.midX, y: app.frame.midY))
            }
        }
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visible() != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 45), .completed,
                       "The centered real CoreText page must show \(marker), not a prefetched neighbor.\n\(app.debugDescription)")
        let label = try XCTUnwrap(visible()).label
        XCTAssertFalse(label.contains("RAW_ONLY_"))
        XCTAssertFalse(label.contains(otherChapter))
        return label
    }

    @MainActor
    func showControls(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let control = app.buttons[identifier].firstMatch
        if !control.exists || !control.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, app.debugDescription)
        return control
    }

    @MainActor
    func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func attachJSON(_ value: [String: Any], name: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch { XCTFail("Could not retain JSON evidence: \(error)") }
    }
}

final class ReaderBookSourceSmokeUITests: ReaderBookSourceSmokeTestCase {
    @MainActor
    func testHTTPSourceImportSearchDetailsTOCAndJSCNativeReading() async throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        let fixture = try await importSourceAndOpenDetail(app)
        let runID = fixture.runID, baseURL = fixture.baseURL
        let sourceURL = fixture.sourceURL, title = fixture.title
        tapReady(app.buttons["Resume"].firstMatch, app: app)
        let firstPage = try waitForVisiblePage(app, marker: firstMarker, otherChapter: secondMarker)
        capture(app, name: "online-04-first-jsc-transformed-coretext-page")

        showControls(app, identifier: "reader_tool_tableOfContents").tap()
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", secondChapter)).firstMatch
        tapReady(chapter, app: app)
        let secondPage = try waitForVisiblePage(app, marker: secondMarker, otherChapter: firstMarker)
        capture(app, name: "online-05-selected-second-jsc-transformed-page")
        showControls(app, identifier: "reader_back_button").tap()
        XCTAssertTrue(app.buttons["Resume"].firstMatch.waitForExistence(timeout: 15), "Closing returns to the source detail")
        tapReady(app.navigationBars.buttons.firstMatch, app: app)
        tapReady(app.tabBars.buttons["Library"].firstMatch, app: app)
        let shelf = app.descendants(matching: .any).matching(identifier: "home_book_list")
        XCTAssertTrue(shelf.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(shelf.count, 1, "The visible bookshelf must have one list")
        // A row exposes nested accessibility buttons. Count matching book cells,
        // not both button representations of the same persisted shelf entry.
        let shelved = shelf.firstMatch.cells.containing(.staticText, identifier: title)
        XCTAssertTrue(shelved.firstMatch.waitForExistence(timeout: 20), "The imported online book must be on the bookshelf.\n\(app.debugDescription)")
        XCTAssertEqual(shelved.count, 1, "The flow must add one shelf copy")
        capture(app, name: "online-06-returned-to-real-bookshelf")

        let trace = try await fetchJSON(path: "/trace?runId=" + runID)
        attachJSON(trace, name: "online-source-raw-http-trace")
        let counts = try verifyHTTPTrace(trace, runID: runID, baseURL: baseURL)
        attachJSON(["runId": runID, "sourceURL": sourceURL, "bookTitle": title, "routeCounts": counts,
                    "visibleFirstPage": firstPage, "visibleSelectedPage": secondPage,
                    "rawHTTPDidNotContainJSCMarker": true, "realImportReviewConfirmed": true,
                    "returnedToBookshelf": true, "jvmIntegratedIntoReading": false,
                    "deliveredIPAExecuted": false, "deviceValidationPassed": false],
                   name: "online-source-reader-smoke-evidence")
    }

}

/// A separate fixture process, namespace, trace and 1/1 verdict from the success smoke.
final class ReaderChapterFailureExitUITests: ReaderBookSourceSmokeTestCase {
    override var fixtureOrigin: URL { URL(string: "http://localhost:18770")! }
    override var expectedFixtureID: String { "reader-chapter-failure-smoke-v1" }
    override var fixturePathPrefix: String { "/failure-fixture/" }

    @MainActor
    func testSecondChapterFailureCanExitWithChromeHidden() async throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        let fixture = try await importSourceAndOpenDetail(app)
        tapReady(app.buttons["Resume"].firstMatch, app: app)
        _ = try waitForVisiblePage(app, marker: firstMarker, otherChapter: secondMarker)
        let held = try await fetchJSON(path: "/failure-held?runId=" + fixture.runID)
        XCTAssertEqual(held["firstRequestHeld"] as? Bool, true)
        showControls(app, identifier: "reader_tool_tableOfContents").tap()
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", secondChapter)).firstMatch
        tapReady(chapter, app: app)
        requireHiddenChrome(app)
        let released = try await fetchJSON(path: "/release-failure?runId=" + fixture.runID)
        XCTAssertEqual(released["firstRequestHeld"] as? Bool, true)

        try await requireFailure(app, runID: fixture.runID, completedFailures: 1)
        capture(app, name: "failure-01-hidden-chrome-and-http-500")
        tapReady(app.buttons["reader_chapter_failure_retry"].firstMatch, app: app)
        try await requireFailure(app, runID: fixture.runID, completedFailures: 2)
        capture(app, name: "failure-02-explicit-retry-still-exitable")
        tapReady(app.buttons["reader_chapter_failure_back"].firstMatch, app: app)
        XCTAssertTrue(app.buttons["Resume"].firstMatch.waitForExistence(timeout: 15),
                      "The failure card must return to the existing source detail.\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["reader_chapter_failure_back"].firstMatch.exists)
        XCTAssertEqual(app.alerts.count, 0, "A chapter failure must not present a navigation-blocking alert")
        capture(app, name: "failure-03-returned-to-detail")
        tapReady(app.navigationBars.buttons.firstMatch, app: app)
        tapReady(app.tabBars.buttons["Library"].firstMatch, app: app)
        let shelf = app.descendants(matching: .any).matching(identifier: "home_book_list").firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(shelf.cells.containing(.staticText, identifier: fixture.title).firstMatch.exists)
        XCTAssertFalse(app.buttons["reader_chapter_failure_back"].firstMatch.exists,
                       "The failed reader must not take navigation back from the library")
        XCTAssertEqual(app.alerts.count, 0)
        capture(app, name: "failure-04-library-remains-usable")
        let trace = try await fetchJSON(path: "/trace?runId=" + fixture.runID)
        let records = try XCTUnwrap(trace["requests"] as? [[String: Any]])
        let failedPath = try XCTUnwrap(URL(string: fixture.baseURL)?.path) + "/chapter1.html"
        let failures = records.filter { ($0["path"] as? String) == failedPath }
        XCTAssertEqual(failures.count, 2, "Only the initial attempt and one explicit retry may reach the failed chapter")
        XCTAssertTrue(failures.allSatisfy { ($0["response"] as? [String: Any])?["status"] as? Int == 500 })
        attachJSON(trace, name: "reader-failure-owned-http-trace")
    }

    @MainActor
    private func requireFailure(_ app: XCUIApplication, runID: String, completedFailures: Int) async throws {
        // The server awaits its actual completed response write; no UI-settling sleep.
        let observed = try await fetchJSON(path: "/failure-observed?runId=" + runID + "&count=" + String(completedFailures))
        XCTAssertEqual(observed["completedFailures"] as? Int, completedFailures)
        let back = app.buttons["reader_chapter_failure_back"].firstMatch
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: back)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 15), .completed, app.debugDescription)
        requireHiddenChrome(app)
        XCTAssertEqual(app.alerts.count, 0)
    }

    @MainActor
    private func requireHiddenChrome(_ app: XCUIApplication) {
        let chrome = app.buttons["reader_back_button"].firstMatch
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: chrome)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed,
                       "The card's exit must work with reader chrome hidden.\n\(app.debugDescription)")
    }
}
