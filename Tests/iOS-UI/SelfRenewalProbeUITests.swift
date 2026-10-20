import XCTest

/// Exercises the real opt-in screen. Simulator discovery is not physical-device evidence.
final class SelfRenewalProbeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
    }

    @MainActor
    func testReadOnlyConnectionProbeCanExportWithoutClaimingRenewal() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-yd_root_tab_visible_ids", "(bookshelf, settings)"
        ]
        app.launch()
        let settings = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        settings.tap()
        let entry = app.buttons["settings_self_renewal_probe"].firstMatch
        for _ in 0..<8 {
            if entry.exists && entry.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(entry.exists && entry.isHittable, app.debugDescription)
        entry.tap()

        let diagnostics = app.buttons["self_renewal_open_diagnostics"].firstMatch
        for _ in 0..<8 {
            if diagnostics.exists && diagnostics.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(diagnostics.exists && diagnostics.isHittable, app.debugDescription)
        diagnostics.tap()

        let run = app.buttons["self_renewal_run_probe"].firstMatch
        let export = app.buttons["self_renewal_export_report"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 10), app.debugDescription)
        // Merely visiting the diagnostic never starts the network operation.
        XCTAssertFalse(export.exists, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["self_renewal_discovery_outcome"].firstMatch.exists)
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Opt-in Local Network permission") { alert in
            let localNetwork = alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "local network")
            ).firstMatch
            let allow = alert.buttons["Allow"].firstMatch
            guard localNetwork.exists, allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }
        run.tap()
        // A harmless tap lets XCTest handle only the Local Network prompt caused
        // by the manual start. Other permission prompts are never authorized here.
        app.staticTexts["Unverified"].firstMatch.tap()
        XCTAssertTrue(export.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["self_renewal_discovery_outcome"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["self_renewal_discovery_phase"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["self_renewal_unverified"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unverified")).firstMatch.exists,
                      app.debugDescription)
        XCTAssertTrue(run.isEnabled, app.debugDescription)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "renewal-read-only-probe-result"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "renewal-read-only-probe-accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }
}
