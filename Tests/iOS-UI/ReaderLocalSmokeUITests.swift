import XCTest

/// A real local-reader loop, using the existing DEBUG auto-import entry point.
/// The second launch has no import argument or original file: restoring the
/// chapter must use the book and reading position the app actually persisted.
final class ReaderLocalSmokeUITests: XCTestCase {
    private var directory: URL!
    private var fixture: URL!
    private var title: String!
    private let targetChapter = "第三章 林間"
    private let firstMarker = "LOCAL_READER_SMOKE_OPENING"
    private let targetMarker = "LOCAL_READER_SMOKE_RESUME"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        title = "ReaderSmoke-" + UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(title, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        fixture = directory.appendingPathComponent("reader-smoke.txt")
        let chapters = [
            ("第一章 出發", firstMarker),
            ("第二章 渡河", "LOCAL_READER_SMOKE_CROSSING"),
            (targetChapter, targetMarker),
            ("第四章 歸途", "LOCAL_READER_SMOKE_RETURN")
        ]
        let text = chapters.map { heading, marker in
            let paragraph = "\(marker). The traveller follows the path beside the river, records the day's journey, and reads the map before continuing."
            return heading + "\n\n" + Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        try Data(text.utf8).write(to: fixture, options: .atomic)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    func testTXTImportTOCAndProgressSurviveRelaunch() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = launchArguments + [
            "-reset-reading-settings", "-auto-import-epub", fixture.path,
            "-auto-import-title", title!
        ]
        app.launch()
        openShelf(app)
        let imported = shelfBook(app)
        XCTAssertTrue(imported.waitForExistence(timeout: 40), "Auto-import must reach the real bookshelf.\n\(app.debugDescription)")
        capture(app, name: "01-imported-on-bookshelf")
        imported.tap()
        waitForVisiblePage(app, marker: firstMarker)
        capture(app, name: "02-first-chapter-rendered")

        let contents = showControls(app, identifier: "reader_tool_tableOfContents")
        contents.tap()
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", targetChapter)).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 15), "TXT chapter parsing must expose its real contents row.\n\(app.debugDescription)")
        XCTAssertTrue(chapter.isHittable, app.debugDescription)
        chapter.tap()
        waitForVisiblePage(app, marker: targetMarker)
        capture(app, name: "03-target-chapter-rendered")

        showControls(app, identifier: "reader_back_button").tap()
        let before = shelfBook(app)
        XCTAssertTrue(before.waitForExistence(timeout: 15), "Closing the reader must return to the shelf")
        let progressSaved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.progressPercent(before).map { $0 > 0 && $0 < 100 } == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [progressSaved], timeout: 15), .completed,
                       "The middle chapter must publish nonzero shelf progress.\n\(app.debugDescription)")
        let expectedProgress = try XCTUnwrap(progressPercent(before))
        capture(app, name: "04-progress-before-relaunch")
        // The importer has copied the TXT into its own storage. Removing the
        // external fixture and the import launch argument prevents re-import
        // from making an empty shelf or lost position appear successful.
        try FileManager.default.removeItem(at: fixture)
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 10), .completed,
                       "The normal background save path must run")
        app.terminate()

        app.launchArguments = launchArguments
        app.launch()
        openShelf(app)
        let restored = shelfBook(app)
        XCTAssertTrue(restored.waitForExistence(timeout: 30), "The imported book must survive without the original TXT or import hook")
        XCTAssertEqual(progressPercent(restored), expectedProgress, "The shelf must load its saved progress")
        restored.tap()
        waitForVisiblePage(app, marker: targetMarker)
        capture(app, name: "05-restored-target-chapter")
        let report: [String: Any] = [
            "fixtureTitle": title!, "targetChapter": targetChapter,
            "savedProgressPercent": expectedProgress,
            "originalFixtureRemoved": true, "secondLaunchImports": false,
            "visibleRestoredBodyMarker": targetMarker
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "TXT-reader-smoke-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private var launchArguments: [String] {
        ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
         "-yd_root_tab_visible_ids", "(bookshelf, settings)", "-bookLayoutIsGrid", "NO",
         "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
         "-yd_appearance_reader_interface", "classic"]
    }

    @MainActor
    private func openShelf(_ app: XCUIApplication) {
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30), app.debugDescription)
        library.tap()
    }

    @MainActor
    private func shelfBook(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title!)).firstMatch
    }

    @MainActor
    private func progressPercent(_ element: XCUIElement) -> Int? {
        let label = element.label
        guard let range = label.range(of: #"[0-9]+%"#, options: .regularExpression) else { return nil }
        return Int(label[range].dropLast())
    }

    @MainActor
    private func waitForVisiblePage(_ app: XCUIApplication, marker: String) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker))
                .allElementsBoundByIndex.contains { element in
                    element.exists && element.isHittable && element.frame.contains(
                        CGPoint(x: app.frame.midX, y: app.frame.midY)
                    )
                }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 45), .completed,
                       "The real CoreText page must visibly render \(marker), not a prefetched neighbor.\n\(app.debugDescription)")
    }

    @MainActor
    private func showControls(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let control = app.buttons[identifier].firstMatch
        if !control.exists || !control.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, app.debugDescription)
        return control
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
