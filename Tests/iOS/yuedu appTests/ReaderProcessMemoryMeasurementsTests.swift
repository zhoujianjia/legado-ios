import CoreText
import CryptoKit
import Darwin
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// Separate preparation, never part of the established fifty stage rows.
/// These are sampled bytes in the app process with XCTest loaded, not an
/// ordinary product launch, allocation total or a physical-device memory limit.
@Suite("Reader process memory observations", .serialized)
@MainActor
struct ReaderProcessMemoryMeasurementsTests {
    @Test("five samples each of the owned 100K and 1M CoreText chapters")
    func sampleOwnedCoreTextChapters() async throws {
        // Fixture generation/hashing is outside every memory interval and off
        // main. The retained fixture strings are included in each baseline.
        let fixtures = await Task.detached {
            [CoreTextPerformanceFixtures.plain100K, CoreTextPerformanceFixtures.plain1M].map {
                let bytes = Data($0.html.utf8)
                return MemoryFixture(fixture: $0, bytes: bytes.count,
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            }
        }.value
        let settings = EPUBTestFixtures.renderSettings(fontSize: 18, lineHeightMultiple: 1.5, paragraphSpacing: 8)
        let runID = UUID().uuidString
        var failures: [String] = []
        for fixture in fixtures {
            for iteration in 0..<5 {
                do { try await sample(fixture, iteration: iteration, runID: runID, settings: settings) }
                catch { failures.append("\(fixture.fixture.id)/\(iteration): \(error)") }
            }
        }
        // Failed samples still emit their original points/stages. No zero,
        // skipped iteration or successful rerun replaces a failed measurement.
        if !failures.isEmpty { throw MemoryMeasurementFailure.invalid(failures.joined(separator: "; ")) }
    }

    private func sample(_ fixture: MemoryFixture, iteration: Int, runID: String,
                        settings: ReaderRenderSettings) async throws {
        let sampler = ReaderProcessMemorySampler(runID: runID, fixture: fixture.fixture.id, iteration: iteration)
        await sampler.begin()
        var failure: String?
        var outputs: [String: Int] = [:]
        var jumps: [MemoryJump] = []
        do {
            try Task.checkCancellation()
            let size = CGSize(width: 390, height: 844)
            await sampler.phase("document.begin")
            let builder = OnlineProviderAttributedStringBuilder(
                provider: BenchmarkChapterProvider(html: fixture.fixture.html), renderSize: size)
            let store = ChapterDocumentStore(builder: builder)
            let request = ChapterDocumentRequest(spineIndex: 0, settings: settings,
                themeTextColor: settings.textColor, themeBackgroundColor: settings.backgroundColor)
            let document = try await store.document(for: request)
            try require(document.attributedString.length >= fixture.fixture.minimumTextCharacters, "short document")
            outputs["documentUTF16"] = document.attributedString.length
            await sampler.phase("document.end")

            let paginator = CoreTextPaginator()
            await sampler.phase("first-page.begin")
            let first = await paginator.paginateFirstPage(spineIndex: 0, attrStr: document.attributedString,
                imagePage: document.imagePage, pageBackgroundImage: document.pageBackgroundImage,
                pageBackgroundColor: document.pageBackgroundColor, anchorOffsets: document.anchorOffsets,
                renderSize: size, fontSize: settings.fontSize, paragraphSpacing: settings.paragraphSpacing,
                letterSpacing: settings.letterSpacing, contentInsets: settings.contentInsets,
                writingMode: settings.writingMode, revision: document.revision)
            let firstLayout = try #require(first)
            let firstRange = try #require(firstLayout.pageRanges.first)
            try require(firstLayout.spineIndex == 0 && firstLayout.attributedString.length == document.attributedString.length
                        && firstRange.location == 0 && firstRange.length > 0, "missing real first page text")
            outputs["firstPages"] = firstLayout.pageRanges.count
            await sampler.phase("first-page.end")

            await sampler.phase("pagination.begin")
            let full = await paginator.paginate(spineIndex: 0, attrStr: document.attributedString,
                imagePage: document.imagePage, pageBackgroundImage: document.pageBackgroundImage,
                pageBackgroundColor: document.pageBackgroundColor, anchorOffsets: document.anchorOffsets,
                renderSize: size, fontSize: settings.fontSize, paragraphSpacing: settings.paragraphSpacing,
                letterSpacing: settings.letterSpacing, contentInsets: settings.contentInsets,
                writingMode: settings.writingMode, revision: document.revision)
            var covered = 0
            try require(full.spineIndex == 0 && full.attributedString.length == document.attributedString.length,
                        "pagination bound to a different document")
            for range in full.pageRanges {
                try require(range.location == covered && range.length > 0, "noncontiguous pagination")
                covered += range.length
            }
            try require(covered == document.attributedString.length, "incomplete pagination")
            outputs["fullPages"] = full.pageRanges.count
            outputs["coveredUTF16"] = covered
            await sampler.phase("pagination.end")

            await sampler.phase("scroll.begin")
            let scroll = CoreTextScrollEngine(builder: builder, renderSettings: settings, chapterDocumentStore: store)
            await scroll.start(initialChapter: 0,
                contentWidth: size.width - settings.contentInsets.left - settings.contentInsets.right,
                viewportExtent: size.height, loadAdjacentChapters: false)
            try require(scroll.isReady, "scroll not ready")
            try require(scroll.chunks.reduce(0) { $0 + $1.charRange.length } == covered, "incomplete scroll chunks")
            outputs["scrollChunks"] = scroll.chunks.count
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let controller = CoreTextCollectionScrollViewController(engine: scroll, axis: .vertical,
                horizontalInset: settings.contentInsets.left, verticalInset: settings.contentInsets.top,
                backgroundColor: settings.backgroundColor)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            let host = UIViewController()
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.addChild(controller)
            controller.view.autoresizingMask = []
            controller.view.frame = CGRect(origin: .zero, size: size)
            host.view.addSubview(controller.view)
            controller.didMove(toParent: host)
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }
            controller.view.layoutIfNeeded()
            let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            collection.layoutIfNeeded()
            try require(collection.bounds.size == size, "actual viewport differs from 390x844")
            await sampler.phase("scroll.end")

            // Actual existing controller restores and samples its live leading
            // line. Avoid the final viewport where clamping is expected.
            let fractions = [85, 5, 75, 15, 65, 25, 55, 35, 45, 10]
            var offsets: [Int] = []
            for (jump, fraction) in fractions.enumerated() {
                try Task.checkCancellation()
                await sampler.phase("jump.\(jump).begin")
                let row = (scroll.chunks.count - 1) * fraction / 100
                guard let chunk = scroll.chunks[row].legacyChunk else {
                    throw MemoryMeasurementFailure.invalid("expected CoreText legacy chunk")
                }
                chunk.materializeFrameIfNeeded()
                let frame = try #require(chunk.frame)
                let lines = CTFrameGetLines(frame) as! [CTLine]
                let offset = CTLineGetStringRange(try #require(lines.first)).location
                try require(offset >= 0 && offset < document.attributedString.length, "invalid text anchor")
                controller.setInitialPosition(chapter: 0, charOffset: offset)
                controller.view.layoutIfNeeded()
                collection.layoutIfNeeded()
                let actual = try #require(controller.positionForPersistence())
                try require(actual.spineIndex == 0 && actual.charOffset == offset, "scroll anchor differs")
                offsets.append(actual.charOffset)
                let anchorLength = min(32, document.attributedString.length - offset)
                let anchorText = (document.attributedString.string as NSString).substring(
                    with: NSRange(location: offset, length: anchorLength))
                jumps.append(MemoryJump(index: jump, requestedOffsetUTF16: offset,
                    observedSpine: actual.spineIndex, observedOffsetUTF16: actual.charOffset,
                    anchorText: anchorText, anchorLengthUTF16: anchorLength))
                await sampler.phase("jump.\(jump).end")
            }
            try require(Set(offsets).count == 10, "ten jumps must visit distinct text anchors")
            outputs["verifiedJumps"] = offsets.count
        } catch { failure = String(describing: error) }
        let measurement = await sampler.finish(failure: failure)
        let row = ProcessMemoryObservation(runID: runID, fixture: fixture.fixture.id,
            iteration: iteration, fixtureSHA256: fixture.sha256, fixtureHTMLBytes: fixture.bytes,
            fixtureMinimumUTF16: fixture.fixture.minimumTextCharacters, outputs: outputs, jumps: jumps,
            style: MemoryRenderStyle(fontSize: Double(settings.fontSize), lineHeightMultiple: Double(settings.lineHeightMultiple),
                paragraphSpacing: Double(settings.paragraphSpacing), lineSpacing: Double(settings.lineSpacing),
                letterSpacing: Double(settings.letterSpacing), contentInsets: [Double(settings.contentInsets.top),
                    Double(settings.contentInsets.left), Double(settings.contentInsets.bottom), Double(settings.contentInsets.right)],
                writingMode: settings.writingMode == .horizontal ? "horizontal" : "nonhorizontal"),
            measurement: measurement)
        let data = try await Task.detached { try JSONEncoder().encode(row) }.value
        print("READER_PROCESS_MEMORY " + String(decoding: data, as: UTF8.self))
        if !measurement.complete { throw MemoryMeasurementFailure.invalid(measurement.errors.joined(separator: "; ")) }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw MemoryMeasurementFailure.invalid(message) }
    }
}

private struct MemoryFixture: Sendable {
    let fixture: CoreTextPerformanceFixtures.Fixture
    let bytes: Int
    let sha256: String
}
private enum MemoryMeasurementFailure: Error { case invalid(String) }
private struct MemoryJump: Encodable, Sendable {
    let index: Int
    let requestedOffsetUTF16: Int
    let observedSpine: Int
    let observedOffsetUTF16: Int
    let anchorText: String
    let anchorLengthUTF16: Int
}
private struct MemoryRenderStyle: Encodable, Sendable {
    let fontSize: Double
    let lineHeightMultiple: Double
    let paragraphSpacing: Double
    let lineSpacing: Double
    let letterSpacing: Double
    let contentInsets: [Double]
    let writingMode: String
}

private struct ProcessMemoryObservation: Encodable, Sendable {
    let schemaVersion = 1
    let kind = "reader-process-memory"
    let processScope = "app-process-with-xctest-loaded"
    #if targetEnvironment(simulator)
    let platform = "ios-simulator"
    #else
    let platform = "ios-device-test-host"
    #endif
    let units = "bytes"
    let metricMethod = "task_info(TASK_VM_INFO): phys_footprint and resident_size; same snapshot"
    let nominalIntervalMilliseconds = 10
    let maximumAllowedGapMilliseconds = 50
    let viewport = [390, 844]
    let fontSize = 18
    let lineHeightMultiple = 1.5
    let paragraphSpacing = 8
    let fixtureConstructionInsideInterval = false
    let baselineIncludesRetainedFixtureHTML = true
    let cachesPurged = false
    let deviceCold = false
    let improvementEstablished = false
    let measurementOverheadExcluded = false
    let exactKernelPeakClaimed = false
    let runID: String
    let fixture: String
    let iteration: Int
    let fixtureSHA256: String
    let fixtureHTMLBytes: Int
    let fixtureMinimumUTF16: Int
    let outputs: [String: Int]
    let jumps: [MemoryJump]
    let style: MemoryRenderStyle
    let measurement: ReaderProcessMemorySampler.Result
}

private actor ReaderProcessMemorySampler {
    struct Point: Encodable, Sendable {
        let kind: String
        let phase: String
        let beforeUptimeSeconds: TimeInterval
        let afterUptimeSeconds: TimeInterval
        let footprintBytes: Int64?
        let residentBytes: Int64?
        let kernelReturn: Int32
        let sufficientReturnCount: Bool
        let onMain: Bool
    }
    struct Event: Encodable, Sendable { let name: String; let uptimeSeconds: TimeInterval }
    private struct RawPhase: Encodable {
        let runID: String
        let fixture: String
        let iteration: Int
        let event: Event
    }
    struct Result: Encodable, Sendable {
        let processID: Int
        let beginUptimeSeconds: TimeInterval
        let endUptimeSeconds: TimeInterval
        let complete: Bool
        let errors: [String]
        let periodicSamples: Int
        let maximumObservedGapMilliseconds: Double
        let baselineFootprintBytes: Int64?
        let baselineResidentBytes: Int64?
        let sampledPeakFootprintBytes: Int64?
        let sampledPeakResidentBytes: Int64?
        let points: [Point]
        let events: [Event]
    }
    private var timer: Task<Void, Never>?
    private var points: [Point] = []
    private var events: [Event] = []
    private var currentPhase = "baseline"
    private var running = false
    private var overflowed = false
    private var phaseEmissionFailed = false
    private let runID: String
    private let fixture: String
    private let iteration: Int

    init(runID: String, fixture: String, iteration: Int) {
        self.runID = runID
        self.fixture = fixture
        self.iteration = iteration
    }

    func begin() {
        running = true
        phase("baseline")
        let recorder = self
        timer = Task.detached(priority: .utility) {
            // Explicit measurement timer, never a delay to let UI/state settle.
            // Task scheduling is not real-time: retain actual timestamp gaps.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { break }
                if !(await recorder.periodic()) { break }
            }
        }
    }

    func phase(_ name: String) {
        currentPhase = name
        let event = Event(name: name, uptimeSeconds: ProcessInfo.processInfo.systemUptime)
        events.append(event)
        capture(kind: "boundary")
        do {
            let data = try JSONEncoder().encode(RawPhase(runID: runID, fixture: fixture, iteration: iteration, event: event))
            print("READER_PROCESS_MEMORY_EVENT " + String(decoding: data, as: UTF8.self))
        } catch { phaseEmissionFailed = true }
    }

    private func periodic() -> Bool {
        guard running else { return false }
        guard points.count < 12_000 else { overflowed = true; return false }
        capture(kind: "periodic")
        return true
    }

    func finish(failure: String?) async -> Result {
        phase(failure == nil ? "complete" : "failed")
        running = false
        let pending = timer
        timer = nil
        pending?.cancel()
        await pending?.value
        var errors = failure.map { [$0] } ?? []
        if overflowed { errors.append("sample-buffer-limit") }
        if phaseEmissionFailed { errors.append("raw-phase-emission-failed") }
        if points.contains(where: { $0.kernelReturn != KERN_SUCCESS || !$0.sufficientReturnCount
            || $0.footprintBytes == nil || $0.residentBytes == nil || $0.onMain }) {
            errors.append("memory-query-invalid-or-on-main")
        }
        let periodic = points.filter { $0.kind == "periodic" }.count
        if periodic == 0 { errors.append("no-periodic-samples") }
        // Boundary captures must not conceal a missing periodic sampler. Quality
        // uses only baseline, periodic ticks and the terminal boundary.
        let timingPoints = [points[0]] + points.filter { $0.kind == "periodic" } + [points[points.count - 1]]
        let gaps = zip(timingPoints, timingPoints.dropFirst()).map { pair in
            max(0, pair.1.beforeUptimeSeconds - pair.0.beforeUptimeSeconds) * 1_000
        }
        let maximumGap = gaps.max() ?? 0
        if maximumGap > 50 { errors.append("sampling-gap-exceeded-50ms") }
        return Result(processID: Int(ProcessInfo.processInfo.processIdentifier),
            beginUptimeSeconds: points.first?.beforeUptimeSeconds ?? 0,
            endUptimeSeconds: points.last?.afterUptimeSeconds ?? 0,
            complete: errors.isEmpty, errors: errors, periodicSamples: periodic,
            maximumObservedGapMilliseconds: maximumGap,
            baselineFootprintBytes: points.first?.footprintBytes, baselineResidentBytes: points.first?.residentBytes,
            sampledPeakFootprintBytes: points.compactMap(\.footprintBytes).max(),
            sampledPeakResidentBytes: points.compactMap(\.residentBytes).max(), points: points, events: events)
    }

    private func capture(kind: String) {
        let before = ProcessInfo.processInfo.systemUptime
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let returned = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprintEnd = (MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint) ?? Int.max)
            .addingReportingOverflow(MemoryLayout<mach_vm_size_t>.size)
        let sufficient = !footprintEnd.overflow && Int(count) * MemoryLayout<natural_t>.size >= footprintEnd.partialValue
        let valid = returned == KERN_SUCCESS && sufficient
            && info.phys_footprint > 0 && info.phys_footprint <= UInt64(Int64.max)
            && info.resident_size > 0 && info.resident_size <= UInt64(Int64.max)
        points.append(Point(kind: kind, phase: currentPhase, beforeUptimeSeconds: before,
            afterUptimeSeconds: ProcessInfo.processInfo.systemUptime,
            footprintBytes: valid ? Int64(info.phys_footprint) : nil,
            residentBytes: valid ? Int64(info.resident_size) : nil,
            kernelReturn: returned, sufficientReturnCount: sufficient, onMain: Thread.isMainThread))
    }
}
