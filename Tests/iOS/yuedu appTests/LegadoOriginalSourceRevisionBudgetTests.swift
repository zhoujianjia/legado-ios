import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

/// Replaces only the unavailable native invocation. Admission still crosses the
/// production originalSearch gate and real Host binding/revocation; this fixture
/// never claims that a user's rules, website or the JVM succeeded.
@Suite("Original source revision admission", .serialized)
struct LegadoOriginalSourceRevisionBudgetTests {
    @Test("all 1310 traditional sources reach the owned original executor")
    func scans1310OriginalSourcesThroughOwnedExecutor() async throws {
        let executor = SourceRevisionBudgetExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor)
        for index in 0..<1_310 {
            let result = try await service.originalSearch(query: "budget", source: source(String(index)))
            #expect(result.isEmpty)
        }
        let observed = await executor.observed()
        #expect(observed.calls == 1_310)
        #expect(observed.uniqueSources == 1_310)
        #expect(observed.peakBindings == 1)
        #expect(observed.remainingBindings == 0)
        #expect(observed.remainingHostRevisions == 0)
    }

    @Test("large scans retain the unchanged source clock high-water fence")
    func retainsRevisionHighWaterAfterLargeScan() async throws {
        let executor = SourceRevisionBudgetExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor)
        var first = source("first")
        _ = try await service.originalSearch(query: "budget", source: first)
        first.lastUpdateTime = 3
        _ = try await service.originalSearch(query: "budget", source: first)
        let firstSignature = try #require(await executor.lastRevision())
        for index in 0..<300 {
            _ = try await service.originalSearch(query: "budget", source: source("later-\(index)"))
        }
        var delayed = first
        delayed.lastUpdateTime = 2
        delayed.ruleSearch.name = "delayed different revision"
        await expectError("SOURCE_CHANGED") {
            _ = try await service.originalSearch(query: "budget", source: delayed)
        }
        #expect(await executor.observed().calls == 302)
        _ = try await service.originalSearch(query: "budget", source: first)
        #expect(await executor.lastRevision() == firstSignature)
        var current = first
        current.lastUpdateTime = 4
        current.ruleSearch.name = "current different revision"
        _ = try await service.originalSearch(query: "budget", source: current)
        #expect(await executor.lastRevision() != firstSignature)
        await expectError("SOURCE_CHANGED") {
            _ = try await service.originalSearch(query: "budget", source: first)
        }
        #expect(await executor.observed().calls == 304)
        #expect(await executor.observed().remainingBindings == 0)

        // The original fence floors a first negative source clock at zero.
        // An unchanged revision remains usable; a changed negative clock cannot
        // replace it just because it is less negative than the first value.
        var negative = source("negative-clock")
        negative.lastUpdateTime = -3
        _ = try await service.originalSearch(query: "budget", source: negative)
        negative.lastUpdateTime = -2
        _ = try await service.originalSearch(query: "budget", source: negative)
        var changedNegative = negative
        changedNegative.ruleSearch.name = "different negative-clock revision"
        await expectError("SOURCE_CHANGED") {
            _ = try await service.originalSearch(query: "budget", source: changedNegative)
        }
        #expect(await executor.observed().calls == 306)
        #expect(await executor.observed().remainingBindings == 0)
    }

    @Test("a full count budget rejects new sources without evicting or damaging admitted revisions")
    func rejectsCountBudgetWithoutDamagingAdmittedSources() async throws {
        let executor = SourceRevisionBudgetExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor,
            originalSourceRevisionBudget: .init(maximumSourceCount: 2, maximumPayloadBytes: 4_096))
        var first = source("count-first")
        let second = source("count-second"), rejected = source("count-rejected")
        _ = try await service.originalSearch(query: "budget", source: first)
        _ = try await service.originalSearch(query: "budget", source: second)
        await expectError("STATE_LIMIT") {
            _ = try await service.originalSearch(query: "budget", source: rejected)
        }
        first.lastUpdateTime = 3
        first.ruleSearch.name = "newer admitted source"
        _ = try await service.originalSearch(query: "budget", source: first)
        _ = try await service.originalSearch(query: "budget", source: second)
        var delayed = first
        delayed.lastUpdateTime = 2
        delayed.ruleSearch.name = "older changed source"
        await expectError("SOURCE_CHANGED") {
            _ = try await service.originalSearch(query: "budget", source: delayed)
        }
        await expectError("STATE_LIMIT") {
            _ = try await service.originalSearch(query: "budget", source: rejected)
        }
        #expect(await executor.observed().calls == 4)
        #expect(await executor.observed().uniqueSources == 2)
        #expect(await executor.observed().remainingBindings == 0)

        // Test injection can make the budget smaller, never disable its hard caps.
        let standard = LegadoMainJSSourceService.OriginalSourceRevisionBudget.standard
        for invalid in [
            LegadoMainJSSourceService.OriginalSourceRevisionBudget(
                maximumSourceCount: standard.maximumSourceCount + 1, maximumPayloadBytes: standard.maximumPayloadBytes),
            .init(maximumSourceCount: standard.maximumSourceCount, maximumPayloadBytes: standard.maximumPayloadBytes + 1)
        ] {
            let invalidService = LegadoMainJSSourceService(originalExecutor: executor, originalSourceRevisionBudget: invalid)
            await expectError("STATE_LIMIT") {
                _ = try await invalidService.originalSearch(query: "budget", source: rejected)
            }
        }
        #expect(await executor.observed().calls == 4)
    }

    @Test("the payload budget measures UTF-8 and failed admissions consume no capacity")
    func enforcesUTF8PayloadBudgetWithoutConsumingRejectedAdmission() async throws {
        let executor = SourceRevisionBudgetExecutor()
        let unicode = source("源"), ascii = source("x")
        #expect(unicode.bookSourceUrl.count == ascii.bookSourceUrl.count)
        #expect(unicode.bookSourceUrl.utf8.count > ascii.bookSourceUrl.utf8.count)
        let exactASCIIPayloadBytes = ascii.bookSourceUrl.utf8.count + 64
        let service = LegadoMainJSSourceService(originalExecutor: executor,
            originalSourceRevisionBudget: .init(maximumSourceCount: 10, maximumPayloadBytes: exactASCIIPayloadBytes))
        await expectError("STATE_LIMIT") {
            _ = try await service.originalSearch(query: "budget", source: unicode)
        }
        #expect(await executor.observed().calls == 0)
        _ = try await service.originalSearch(query: "budget", source: ascii)
        var changed = ascii
        changed.lastUpdateTime = 2
        changed.ruleSearch.name = "same-width replacement digest"
        _ = try await service.originalSearch(query: "budget", source: changed)
        await expectError("STATE_LIMIT") {
            _ = try await service.originalSearch(query: "budget", source: source("z"))
        }
        _ = try await service.originalSearch(query: "budget", source: changed)
        let observed = await executor.observed()
        #expect(observed.calls == 3)
        #expect(observed.uniqueSources == 1)
        #expect(observed.remainingBindings == 0)
        #expect(observed.remainingHostRevisions == 0)
    }

    private func source(_ name: String) -> BookSource {
        var value = BookSource(bookSourceUrl: "https://source-revision-budget.invalid/" + name, bookSourceName: "synthetic")
        value.searchUrl = "/search?key={{key}}"
        value.lastUpdateTime = 1
        return value
    }

    private func expectError(_ code: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected bounded source admission error \(code)")
        } catch let error as LegadoRuntimeError {
            #expect(error.code == code)
        } catch {
            Issue.record("Expected typed source admission error \(code)")
        }
    }
}

private struct SourceRevisionBudgetNoState: LegadoOwnedStateBacking {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Synthetic source scan grants no state reads")
    }
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot,
                changes: [String: Data?]) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Synthetic source scan grants no state writes")
    }
}

private actor SourceRevisionBudgetExecutor: LegadoOriginalPreviewExecuting {
    struct Observation: Sendable {
        let calls: Int
        let uniqueSources: Int
        let peakBindings: Int
        let remainingBindings: Int
        let remainingHostRevisions: Int
    }
    private struct SourceIdentity: Decodable {
        let bookSourceUrl: String
    }
    private let host = LegadoPersistentStateHost(backing: SourceRevisionBudgetNoState())
    private var calls = 0
    private var sources = Set<String>()
    private var peakBindings = 0
    private var revision: String?

    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
                 grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
                 deadline: Date) async throws -> LegadoOriginalPreviewResult {
        try Task.checkCancellation()
        let identity = try JSONDecoder().decode(SourceIdentity.self, from: Data(sourceJSON.utf8))
        guard grant == nil, identity.bookSourceUrl == sourceURL,
              sourceRevision.utf8.count == 64, sourceRevision.allSatisfy({ "0123456789abcdef".contains($0) }),
              case .search(let query, let page) = operation, query == "budget", page == 1,
              deadline.timeIntervalSinceNow > 0 else {
            throw LegadoRuntimeError(code: "INVALID_ARGUMENT", message: "Synthetic original invocation lost its source binding")
        }
        let owner = try await host.bind(sourceURL: sourceURL, sourceRevision: sourceRevision)
        let live = await host.ownershipCounts()
        peakBindings = max(peakBindings, live.bindings)
        calls += 1
        sources.insert(sourceURL)
        revision = sourceRevision
        await host.revoke(owner: owner)
        return .search([])
    }

    func lastRevision() -> String? { revision }
    func observed() async -> Observation {
        let current = await host.ownershipCounts()
        return .init(calls: calls, uniqueSources: sources.count, peakBindings: peakBindings,
            remainingBindings: current.bindings, remainingHostRevisions: current.sourceRevisions)
    }
}
