import XCTest

/// Five fresh app processes observed from the separate UI-test runner. Import,
/// fixture generation and progress setup happen before any measured launch.
final class ReaderProcessLaunchMeasurementsUITests: ReaderLocalTXTScenarioTestCase {
    override var uniqueParagraphMarkers: Bool { true }

    @MainActor
    func testFiveProcessLaunchesToSubmittedReadableTXTAnchor() async throws {
        executionTimeAllowance = 600
        let app = XCUIApplication()
        defer { app.terminate() }
        let flag = ["-reader-launch-measurement"]
        let marker = targetMarker + "_P0000."
        // The same real importer and TOC actions as the existing smoke. This is
        // setup, not an extra importer or a measured launch iteration.
        launchAndImportTXT(app, extraArguments: flag)
        selectTXTTargetChapter(app)
        let sourceText = try String(contentsOf: fixture, encoding: .utf8)
        guard sourceText.components(separatedBy: marker).count == 2 else {
            throw LaunchObservationFailure.invalid("owned input marker must be unique")
        }
        let expected = try await submittedPage(app, marker: marker)
        let expectedProgress = try persistTXTTargetAndTerminate(app)
        guard !FileManager.default.fileExists(atPath: fixture.path) else {
            throw LaunchObservationFailure.invalid("original import input still exists")
        }
        app.launchArguments = launchArguments + flag
        let runID = UUID().uuidString
        var processObservationIDs = Set<String>()
        var failures: [String] = []
        for iteration in 0..<5 {
            var times: [String: Double] = [:]
            var observed: SubmittedPage?
            var failure: String?
            var phase = "terminate"
            do {
                times["terminateRequested"] = ProcessInfo.processInfo.systemUptime
                app.terminate()
                try await waitFor("app process terminated", timeout: 10) { app.state == .notRunning }
                times["notRunningObserved"] = ProcessInfo.processInfo.systemUptime
                phase = "launch"
                times["launchRequested"] = ProcessInfo.processInfo.systemUptime
                app.launch()
                times["launchReturned"] = ProcessInfo.processInfo.systemUptime
                phase = "shelf"
                let library = app.tabBars.buttons["Library"].firstMatch
                try await waitFor("real Library tab", timeout: 30) { library.exists && library.isHittable }
                library.tap()
                let book = shelfBook(app)
                try await waitFor("persisted owned book", timeout: 30) { book.exists && book.isHittable }
                times["shelfObserved"] = ProcessInfo.processInfo.systemUptime
                guard progressPercent(book) == expectedProgress else {
                    throw LaunchObservationFailure.invalid("persisted shelf progress differs")
                }
                phase = "readable-anchor"
                times["bookTapRequested"] = ProcessInfo.processInfo.systemUptime
                book.tap()
                let page = try await submittedPage(app, marker: marker)
                times["pageObserved"] = ProcessInfo.processInfo.systemUptime
                observed = page
                guard page.spineIndex == expected.spineIndex,
                      page.pageStartUTF16 == expected.pageStartUTF16,
                      page.pageLengthUTF16 == expected.pageLengthUTF16,
                      page.documentLengthUTF16 == expected.documentLengthUTF16,
                      Data(page.pageText.utf8) == Data(expected.pageText.utf8),
                      try markerOffset(page, marker: marker) == markerOffset(expected, marker: marker) else {
                    throw LaunchObservationFailure.invalid("actual rendered UTF16/text anchor differs")
                }
                guard page.processObservationID != expected.processObservationID,
                      processObservationIDs.insert(page.processObservationID).inserted else {
                    throw LaunchObservationFailure.invalid("the app process observation identity was reused")
                }
                phase = "complete"
            } catch { failure = String(describing: error) }
            let row = LaunchObservation(runID: runID, iteration: iteration,
                fixtureSHA256: fixtureSHA256, fixtureBytes: fixtureBytes,
                expectedMarker: marker, expectedMarkerUTF16: try markerOffset(expected, marker: marker),
                expected: expected, observed: observed, timestamps: times,
                complete: failure == nil, terminalPhase: phase, error: failure)
            let data = try JSONEncoder().encode(row)
            print("READER_PROCESS_LAUNCH " + String(decoding: data, as: UTF8.self))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "process-launch-sample-\(iteration)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let failure { failures.append("sample \(iteration): \(failure)") }
            app.terminate()
        }
        if !failures.isEmpty { throw LaunchObservationFailure.invalid(failures.joined(separator: "; ")) }
    }

    @MainActor
    private func waitFor(_ name: String, timeout: TimeInterval, condition: @escaping () -> Bool) async throws {
        let signal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        // A real state predicate with a failure deadline, never a settle sleep.
        guard await XCTWaiter.fulfillment(of: [signal], timeout: timeout) == .completed else {
            throw LaunchObservationFailure.invalid("deadline: " + name)
        }
    }

    @MainActor
    private func submittedPage(_ app: XCUIApplication, marker: String) async throws -> SubmittedPage {
        var result: SubmittedPage?
        var malformed: Error?
        try await waitFor("submitted page, visible body and actual UTF16 anchor", timeout: 45) {
            for element in app.staticTexts.matching(identifier: "reader_measurement_submitted_page").allElementsBoundByIndex {
                guard element.exists, element.isHittable,
                      element.frame.contains(CGPoint(x: app.frame.midX, y: app.frame.midY)),
                      let value = element.value as? String,
                      let bytes = value.data(using: .utf8)
                else { continue }
                do {
                    let page = try JSONDecoder().decode(SubmittedPage.self, from: bytes)
                    guard page.schemaVersion == 1, page.boundary == "cpu-layer-submitted-and-ax-readable",
                          page.processID > 0, !page.processObservationID.isEmpty,
                          page.viewBindingRevision > 0, !page.viewID.isEmpty, page.pageIndex >= 0,
                          page.submissionUptimeSeconds.isFinite, page.submissionUptimeSeconds > 0,
                          ["drawn", "prerendered"].contains(page.imageSource),
                          page.pageStartUTF16 >= 0, page.pageLengthUTF16 > 0, page.pageLengthUTF16 <= 16_384,
                          page.documentLengthUTF16 >= page.pageLengthUTF16,
                          page.pageLengthUTF16 == page.pageText.utf16.count,
                          page.pageStartUTF16 <= page.documentLengthUTF16 - page.pageLengthUTF16 else {
                        throw LaunchObservationFailure.invalid("malformed submitted-page contract")
                    }
                    guard page.spineIndex == 2, page.pageText.components(separatedBy: marker).count == 2,
                          element.label == page.pageText.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                    result = page
                    return true
                } catch { malformed = error; return true }
            }
            return false
        }
        if let malformed { throw malformed }
        guard let result else { throw LaunchObservationFailure.invalid("missing page snapshot") }
        return result
    }

    private func markerOffset(_ page: SubmittedPage, marker: String) throws -> Int {
        let local = (page.pageText as NSString).range(of: marker)
        guard local.location != NSNotFound, local.length == marker.utf16.count,
              local.location + local.length <= page.pageLengthUTF16 else {
            throw LaunchObservationFailure.invalid("marker is outside actual UTF16 page range")
        }
        return page.pageStartUTF16 + local.location
    }
}

private enum LaunchObservationFailure: Error { case invalid(String) }
private struct SubmittedPage: Codable {
    let schemaVersion: Int
    let boundary: String
    let processID: Int
    let processObservationID: String
    let viewID: String
    let viewBindingRevision: UInt64
    let spineIndex: Int
    let pageIndex: Int
    let pageStartUTF16: Int
    let pageLengthUTF16: Int
    let documentLengthUTF16: Int
    let pageText: String
    let imageSource: String
    let submissionUptimeSeconds: Double
}
private struct LaunchObservation: Encodable {
    let schemaVersion = 1
    let kind = "reader-process-launch"
    let timingProcess = "separate-xctest-ui-runner"
    let observedProcess = "debug-app-under-ui-automation"
    let boundary = "launch-request-to-cpu-layer-submitted-and-ax-readable-visible-anchor"
    let fixturePreparationInsideInterval = false
    let originalImportInputRemoved = true
    let measuredLaunchImports = false
    let systemCachesPurged = false
    let deviceCold = false
    let gpuPresentationMeasured = false
    let launchToReadableIncludesAutomationNavigation = true
    let improvementEstablished = false
    let runID: String
    let iteration: Int
    let fixtureSHA256: String
    let fixtureBytes: Int
    let expectedMarker: String
    let expectedMarkerUTF16: Int
    let expected: SubmittedPage
    let observed: SubmittedPage?
    let timestamps: [String: Double]
    let complete: Bool
    let terminalPhase: String
    let error: String?
}
