import XCTest

/// A real local-reader loop, using the existing DEBUG auto-import entry point.
/// The second launch has no import argument or original file: restoring the
/// chapter must use the book and reading position the app actually persisted.
final class ReaderLocalSmokeUITests: ReaderLocalTXTScenarioTestCase {
    @MainActor
    func testTXTImportTOCAndProgressSurviveRelaunch() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        launchAndImportTXT(app)
        let accessibilityReport = try verifyQuickReaderAccessibility(app)

        selectTXTTargetChapter(app)

        let expectedProgress = try persistTXTTargetAndTerminate(app)

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
            "visibleRestoredBodyMarker": targetMarker,
            "quickReaderAccessibility": accessibilityReport
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "TXT-reader-smoke-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    private func verifyQuickReaderAccessibility(_ app: XCUIApplication) throws -> [String: Any] {
        showControls(app, identifier: "reader_tool_settings").tap()
        let increase = app.buttons["reader_quick_font_increase"].firstMatch
        let decrease = app.buttons["reader_quick_font_decrease"].firstMatch
        XCTAssertTrue(increase.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(increase.label, "Increase Font Size")
        XCTAssertEqual(decrease.label, "Decrease Font Size")
        let originalFontValue = try XCTUnwrap(increase.value as? String)
        let originalFontSize = try XCTUnwrap(Int(originalFontValue.replacingOccurrences(of: " pt", with: "")))
        XCTAssertEqual(originalFontValue, "\(originalFontSize) pt")
        XCTAssertEqual(decrease.value as? String, originalFontValue)

        increase.tap()
        let increasedValue = "\(originalFontSize + 1) pt"
        let announcedIncrease = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            increase.value as? String == increasedValue && decrease.value as? String == increasedValue
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [announcedIncrease], timeout: 10), .completed,
                       "Both font actions must expose the current font size after increasing it.\n\(app.debugDescription)")
        decrease.tap()
        let restoredFont = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            increase.value as? String == originalFontValue && decrease.value as? String == originalFontValue
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredFont], timeout: 10), .completed,
                       "Decreasing must restore the announced font size.\n\(app.debugDescription)")

        let brightness = app.sliders["reader_quick_brightness"].firstMatch
        XCTAssertTrue(brightness.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(brightness.label, "Brightness")
        let originalBrightnessValue = try XCTUnwrap(brightness.value as? String)
        let originalBrightnessPercent = try XCTUnwrap(Double(originalBrightnessValue.replacingOccurrences(of: "%", with: "")))
        XCTAssertGreaterThanOrEqual(originalBrightnessPercent, 5)
        XCTAssertLessThanOrEqual(originalBrightnessPercent, 100)
        dragSliderToEndpoint(brightness, maximum: false)
        let minimumAnnounced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "5%"), object: brightness)
        XCTAssertEqual(XCTWaiter.wait(for: [minimumAnnounced], timeout: 5), .completed,
                       "Minimum slider position means 5% screen brightness, not 0%.\n\(app.debugDescription)")
        dragSliderToEndpoint(brightness, maximum: true)
        let maximumAnnounced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "100%"), object: brightness)
        XCTAssertEqual(XCTWaiter.wait(for: [maximumAnnounced], timeout: 5), .completed, app.debugDescription)
        for symbol in ["sun.min.fill", "sun.max.fill"] {
            XCTAssertFalse(app.images[symbol].exists, "Decorative brightness symbols must not be independent accessibility elements")
        }
        capture(app, name: "02a-quick-reader-accessibility")
        brightness.adjust(toNormalizedSliderPosition: CGFloat((originalBrightnessPercent / 100 - 0.05) / 0.95))
        let restoredBrightness = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = brightness.value as? String,
                  let percent = Double(value.replacingOccurrences(of: "%", with: "")) else { return false }
            // XCUI drives the real thumb in physical pixels, so restoring an
            // intermediate value allows one percentage point of drag rounding.
            return abs(percent - originalBrightnessPercent) <= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredBrightness], timeout: 5), .completed,
                       "Restore brightness before returning to the book.\n\(app.debugDescription)")
        let restoredBrightnessValue = try XCTUnwrap(brightness.value as? String)

        let close = app.buttons["reader_quick_close"].firstMatch
        XCTAssertTrue(close.isHittable, app.debugDescription)
        close.tap()
        XCTAssertTrue(increase.waitForNonExistence(timeout: 10), "The native quick panel must dismiss.\n\(app.debugDescription)")
        return [
            "fontSizeBefore": originalFontValue, "fontSizeAfterIncrease": increasedValue,
            "fontSizeRestored": true, "brightnessLabel": "Brightness",
            "minimumBrightnessValue": "5%", "maximumBrightnessValue": "100%",
            "brightnessEndpointInput": "center-thumb-to-track-edge drag",
            "brightnessBefore": originalBrightnessValue, "brightnessRestored": restoredBrightnessValue,
            "decorativeSymbolsHidden": true
        ]
    }

    @MainActor
    private func dragSliderToEndpoint(_ slider: XCUIElement, maximum: Bool) {
        // XCTest documents normalized adjustment as best effort: the old call
        // to position 0 stopped at 6% on the real 5%...100% brightness slider.
        // Bring the thumb to the middle, then drag it to the track's outer edge
        // so the native control clamps to its actual endpoint. Keep the exact
        // announced-value assertions above; neither endpoint permits rounding.
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let center = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let edge = slider.coordinate(withNormalizedOffset: CGVector(dx: maximum ? 1 : 0, dy: 0.5))
        center.press(forDuration: 0, thenDragTo: edge)
    }

}
