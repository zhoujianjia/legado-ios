import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

private struct ExploreNoStateBacking: LegadoOwnedStateBacking {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "A scope identity grants no cache authority")
    }
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot, changes: [String: Data?]) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "A scope identity grants no cache authority")
    }
}

@Suite("Original exploration backing identity", .serialized)
struct LegadoExploreOwnerTests {
    private func request(owner: String, source: String = "https://explore-owned.invalid", task: String = UUID().uuidString,
                         extra: [String: Any] = [:]) throws -> LegadoHostRequest {
        var input: [String: Any] = ["owner": owner, "sourceURL": source]
        input.merge(extra) { _, value in value }
        return .init(taskID: task, operation: "explore.owner.scope", requestJSON: String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self))
    }
    private func scope(_ host: LegadoPersistentStateHost, _ owner: String, source: String = "https://explore-owned.invalid") async throws -> String {
        struct Reply: Decodable { let scope: String }
        let raw = try await host.dispatch(request(owner: owner, source: source))
        return try JSONDecoder().decode(Reply.self, from: Data(raw.utf8)).scope
    }
    @Test("scope is stable across per-invocation grants but distinct for backing source and revision")
    func stableIdentityDoesNotUseTheEphemeralRuntimeGrant() async throws {
        let host = LegadoPersistentStateHost(backing: ExploreNoStateBacking())
        let first = try await host.bind(sourceURL: "https://explore-owned.invalid", sourceRevision: "r1")
        let before = try await scope(host, first)
        await host.revoke(owner: first)
        let second = try await host.bind(sourceURL: "https://explore-owned.invalid", sourceRevision: "r1")
        #expect(first != second)
        #expect(try await scope(host, second) == before)
        let other = try await host.bind(sourceURL: "https://other-owned.invalid", sourceRevision: "r1")
        #expect(try await scope(host, other, source: "https://other-owned.invalid") != before)
        let changed = try await host.bind(sourceURL: "https://explore-owned.invalid", sourceRevision: "r2")
        #expect(try await scope(host, changed) != before)
        let another = LegadoPersistentStateHost(backing: ExploreNoStateBacking())
        let grant = try await another.bind(sourceURL: "https://explore-owned.invalid", sourceRevision: "r1")
        #expect(try await scope(another, grant) != before)
    }
    @Test("revoked mismatched cancelled and expired source grants cannot acquire an exploration context")
    func scopeStillChecksTheActualGrantAndCannotAuthorizeCacheWrites() async throws {
        let host = LegadoPersistentStateHost(backing: ExploreNoStateBacking())
        let owner = try await host.bind(sourceURL: "https://explore-owned.invalid", sourceRevision: "r1")
        do { _ = try await scope(host, owner, source: "https://other-owned.invalid"); Issue.record("Wrong source received scope") }
        catch let error as LegadoRuntimeError { #expect(error.code == "INVALID_STATE_OWNER") }
        do {
            _ = try await host.dispatch(request(owner: owner, extra: ["deadlineEpochMs": 1]))
            Issue.record("Expired scope request succeeded")
        } catch let error as LegadoRuntimeError { #expect(error.code == "STATE_TIMEOUT") }
        await host.cancel(taskID: "cancelled-explore")
        do { _ = try await host.dispatch(request(owner: owner, task: "cancelled-explore")); Issue.record("Cancelled scope request succeeded") }
        catch is CancellationError {}
        let identity = try await scope(host, owner)
        let bad = LegadoHostRequest(taskID: UUID().uuidString, operation: "explore.owner.scope",
            requestJSON: String(decoding: try JSONSerialization.data(withJSONObject: ["owner": identity, "sourceURL": "https://explore-owned.invalid"]), as: UTF8.self))
        do { _ = try await host.dispatch(bad); Issue.record("A scope string became a state owner grant") }
        catch let error as LegadoRuntimeError { #expect(error.code == "INVALID_STATE_OWNER") }
        await host.revoke(owner: owner)
        do { _ = try await scope(host, owner); Issue.record("Revoked source received scope") }
        catch let error as LegadoRuntimeError { #expect(error.code == "INVALID_STATE_OWNER") }
    }
}
