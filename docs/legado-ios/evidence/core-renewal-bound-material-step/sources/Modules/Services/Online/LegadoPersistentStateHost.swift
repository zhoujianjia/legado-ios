import Foundation
import LegadoRuntime

/// A short-lived revision proof from the existing App owner, not another store.
struct LegadoOwnedStateSnapshot: Sendable, Equatable {
    let revision: UInt64
    let values: [String: Data]
}

enum LegadoOwnedStateDomain: Sendable, Equatable {
    case sourceVariable, sourceValues, loginHeader
    case cacheText(String)
}

struct LegadoRuntimeCacheEntry: Codable, Sendable, Equatable {
    let deadline: Int64
    let data: String

    init(text: String, deadline: Int64 = 0) {
        self.deadline = deadline
        self.data = Data(text.utf8).base64EncodedString()
    }

    func text() throws -> String {
        guard let bytes = Data(base64Encoded: data),
              let value = String(data: bytes, encoding: .utf8) else {
            throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Only UTF-8 cache text is connected to the App owner")
        }
        return value
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

protocol LegadoOwnedStateBacking: Sendable {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot
    /// False promises that this transaction changed no value.
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot,
                changes: [String: Data?]) throws -> Bool
}

/// Reuses the shipped source, login and cache owners. It never writes a second
/// source database, Cookie jar, chapter directory or shelf metadata file.
struct AppLegadoOwnedStateBacking: @unchecked Sendable, LegadoOwnedStateBacking {
    let sources: BookSourceRuntimeStateStore
    let login: LoginManager

    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        switch domain {
        case .sourceVariable: return sources.runtimeVariableSnapshot(for: sourceURL)
        case .sourceValues: return sources.runtimeValuesSnapshot(for: sourceURL, keys: fields)
        case .loginHeader: return login.runtimeHeaderSnapshot(sourceUrl: sourceURL)
        case .cacheText(let key): return try LegadoCacheBridge.runtimeSnapshot(sourceId: sourceURL, key: key)
        }
    }

    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot,
                changes: [String: Data?]) throws -> Bool {
        switch domain {
        case .sourceVariable:
            return sources.compareRuntimeVariable(for: sourceURL, expected: expected, value: changes["value"] ?? nil)
        case .sourceValues:
            return sources.compareRuntimeValues(for: sourceURL, expected: expected, changes: changes)
        case .loginHeader:
            return login.compareRuntimeHeader(sourceUrl: sourceURL, expected: expected, value: changes["value"] ?? nil)
        case .cacheText(let key):
            return try LegadoCacheBridge.compareRuntimeEntry(sourceId: sourceURL, key: key,
                expected: expected, value: changes["value"] ?? nil)
        }
    }
}

/// JNI's existing HostCallback now has an explicitly bound state adapter.
/// Bindings are granted by the embedding App; imported JSON never grants an
/// owner or selects a filesystem path. Chapter/Cookie identity remains separate.
actor LegadoPersistentStateHost: LegadoPlatformHost {
    private struct Binding {
        let sourceURL: String
        let sourceRevision: String
    }
    private struct Key {
        let wire: String
        let domain: LegadoOwnedStateDomain
        let field: String
        let binaryCompanion: Bool
    }
    private struct Lease {
        let owner: String
        let binding: Binding
        let keys: [Key]
        let snapshot: LegadoOwnedStateSnapshot
    }
    private let backing: any LegadoOwnedStateBacking
    private let fallback: any LegadoPlatformHost
    private var bindings: [String: Binding] = [:]
    private var revisions: [String: String] = [:]
    private var leases: [Int64: Lease] = [:]
    private var leaseOrder: [Int64] = []
    private var nextLease: Int64 = 0
    private var cancelled = Set<String>()
    private var cancellationOrder: [String] = []

    init(backing: any LegadoOwnedStateBacking, fallback: any LegadoPlatformHost = UnsupportedLegadoHost()) {
        self.backing = backing
        self.fallback = fallback
    }

    /// Call with the owning App's immutable source snapshot. Rebinding a changed
    /// source revokes prior grants and pending CAS proofs for that source.
    func bind(sourceURL: String, sourceRevision: String) throws -> String {
        guard !sourceURL.isEmpty, sourceURL.utf8.count <= 8_192,
              !sourceRevision.isEmpty, sourceRevision.utf8.count <= 256 else {
            throw failure("INVALID_STATE_OWNER", "An explicit source identity and revision are required")
        }
        if revisions[sourceURL] != sourceRevision {
            bindings = bindings.filter { $0.value.sourceURL != sourceURL }
            leases = leases.filter { $0.value.binding.sourceURL != sourceURL }
        }
        guard bindings.count < 256 else { throw failure("STATE_LIMIT", "Too many active source state owners") }
        let owner = UUID().uuidString
        revisions[sourceURL] = sourceRevision
        bindings[owner] = Binding(sourceURL: sourceURL, sourceRevision: sourceRevision)
        return owner
    }

    func revoke(owner: String) {
        let removed = bindings.removeValue(forKey: owner)
        leases = leases.filter { $0.value.owner != owner }
        if let removed, !bindings.values.contains(where: { $0.sourceURL == removed.sourceURL }) {
            revisions.removeValue(forKey: removed.sourceURL)
        }
    }

    /// Value-free diagnostics for verifying bounded ownership bookkeeping.
    func ownershipCounts() -> (bindings: Int, sourceRevisions: Int, leases: Int) {
        (bindings.count, revisions.count, leases.count)
    }

    func dispatch(_ request: LegadoHostRequest) async throws -> String {
        if request.operation != "state.read" && request.operation != "state.commit" {
            return try await fallback.dispatch(request)
        }
        try check(request)
        do {
          return try SourcePerfTrace.span("legado.state.host", "bytes=\(request.requestJSON.utf8.count) main=\(Thread.isMainThread)") {
            guard request.requestJSON.utf8.count <= 2_097_152,
                  let bytes = request.requestJSON.data(using: .utf8),
                  let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let owner = input["owner"] as? String, let binding = bindings[owner],
                  revisions[binding.sourceURL] == binding.sourceRevision else {
                throw failure("INVALID_STATE_OWNER", "State request has no current embedding-owner grant")
            }
            if request.operation == "state.read" {
                guard let rawKeys = input["keys"] as? [String], !rawKeys.isEmpty,
                      rawKeys.count <= 64, Set(rawKeys).count == rawKeys.count else {
                    throw failure("STATE_LIMIT", "State read requires 1...64 unique keys")
                }
                let keys = try parse(rawKeys, binding: binding)
                let snapshot = try backing.read(sourceURL: binding.sourceURL, domain: keys[0].domain,
                    fields: Set(keys.filter { !$0.binaryCompanion }.map(\.field)))
                try check(request)
                guard nextLease < Int64.max else { throw failure("STATE_LIMIT", "State revision space exhausted") }
                var values: [String: String] = [:]
                var total = 0
                for key in keys where !key.binaryCompanion {
                    if let value = snapshot.values[key.field] {
                        let wire = try wireValue(value, domain: key.domain)
                        total += wire.count
                        guard total <= 1_048_576 else { throw failure("STATE_LIMIT", "State read exceeds its byte limit") }
                        values[key.wire] = wire.base64EncodedString()
                    }
                }
                nextLease += 1
                leases[nextLease] = Lease(owner: owner, binding: binding, keys: keys, snapshot: snapshot)
                leaseOrder.append(nextLease)
                if leaseOrder.count > 256 { leases.removeValue(forKey: leaseOrder.removeFirst()) }
                return try encoded(["revision": nextLease, "values": values])
            }
            struct Commit: Decodable { let revision: Int64 }
            let commit = try JSONDecoder().decode(Commit.self, from: bytes)
            guard commit.revision > 0,
                  let rawChanges = input["changes"] as? [String: Any], !rawChanges.isEmpty, rawChanges.count <= 64 else {
                throw failure("INVALID_STATE_REQUEST", "State commit requires a revision and bounded changes")
            }
            let revision = commit.revision
            guard let lease = leases.removeValue(forKey: revision), lease.owner == owner,
                  lease.binding.sourceURL == binding.sourceURL,
                  lease.binding.sourceRevision == binding.sourceRevision else { return try encoded(["committed": false]) }
            let allowed = Dictionary(uniqueKeysWithValues: lease.keys.map { ($0.wire, $0) })
            guard rawChanges.keys.allSatisfy({ allowed[$0] != nil }) else {
                throw failure("INVALID_STATE_REQUEST", "State commit changed an unread key")
            }
            var changes: [String: Data?] = [:]
            for (wire, raw) in rawChanges {
                let key = allowed[wire]!
                if key.binaryCompanion {
                    guard raw is NSNull else { throw failure("UNSUPPORTED_CAPABILITY", "App binary cache storage is not connected") }
                    continue
                }
                if raw is NSNull { changes.updateValue(nil, forKey: key.field) }
                else {
                    guard let text = raw as? String, text.utf8.count <= 1_398_104,
                          let value = Data(base64Encoded: text), value.count <= 1_048_576 else {
                        throw failure("STATE_LIMIT", "State value is malformed or oversized")
                    }
                    changes.updateValue(try storedValue(value, domain: key.domain), forKey: key.field)
                }
            }
            try check(request)
            let committed: Bool
            if changes.isEmpty {
                committed = try backing.read(sourceURL: binding.sourceURL, domain: lease.keys[0].domain,
                    fields: Set(lease.keys.filter { !$0.binaryCompanion }.map(\.field))) == lease.snapshot
            } else {
                committed = try backing.commit(sourceURL: binding.sourceURL,
                    domain: lease.keys[0].domain, expected: lease.snapshot, changes: changes)
            }
            // The synchronous owner commit is the transaction boundary. Once
            // it succeeds, report that fact rather than pretend a late cancel
            // rolled the existing owner's accepted mutation back.
            return try encoded(["committed": committed])
          }
        } catch let error as LegadoRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            AppLogger.error("JVM source state owner failed", error: error)
            throw failure("STATE_IO", "The App state owner did not complete the request")
        }
    }

    func cancel(taskID: String) async {
        if cancelled.insert(taskID).inserted { cancellationOrder.append(taskID) }
        if cancellationOrder.count > 1_024 { cancelled.remove(cancellationOrder.removeFirst()) }
        await fallback.cancel(taskID: taskID)
    }

    private func check(_ request: LegadoHostRequest) throws {
        try Task.checkCancellation()
        guard !cancelled.contains(request.taskID) else { throw CancellationError() }
        guard request.remainingTimeoutSeconds > 0 else { throw failure("STATE_TIMEOUT", "State request deadline expired") }
    }

    private func parse(_ values: [String], binding: Binding) throws -> [Key] {
        var result: [Key] = []
        for wire in values {
            guard wire.utf8.count <= 16_384, let data = wire.data(using: .utf8),
                  let parts = try JSONSerialization.jsonObject(with: data) as? [String], parts.count == 3,
                  parts[0] == binding.sourceURL, ["cache-text", "cache-binary"].contains(parts[1]) else {
                throw failure("UNSUPPORTED_CAPABILITY", "State key has no connected App source owner")
            }
            let source = binding.sourceURL
            let raw = parts[2]
            let domain: LegadoOwnedStateDomain
            let field: String
            if raw == "sourceVariable_" + source { domain = .sourceVariable; field = "value" }
            else if raw == "loginHeader_" + source { domain = .loginHeader; field = "value" }
            else if raw.hasPrefix("v_" + source + "_") {
                domain = .sourceValues
                field = String(raw.dropFirst(("v_" + source + "_").count))
            } else { domain = .cacheText(raw); field = "value" }
            result.append(Key(wire: wire, domain: domain, field: field, binaryCompanion: parts[1] == "cache-binary"))
        }
        guard let first = result.first, result.allSatisfy({ $0.domain == first.domain }),
              result.contains(where: { !$0.binaryCompanion }),
              Set(result.filter { !$0.binaryCompanion }.map(\.field)).count == result.filter({ !$0.binaryCompanion }).count else {
            throw failure("UNSUPPORTED_CAPABILITY", "Transactions spanning App owners or binary caches are not connected")
        }
        for key in result where key.binaryCompanion {
            guard result.contains(where: { !$0.binaryCompanion && $0.field == key.field }) else {
                throw failure("UNSUPPORTED_CAPABILITY", "A binary cache key is supported only as an empty deletion companion")
            }
        }
        return result
    }

    private func wireValue(_ data: Data, domain: LegadoOwnedStateDomain) throws -> Data {
        if case .cacheText = domain { return data }
        guard let value = String(data: data, encoding: .utf8) else { throw failure("STATE_IO", "App source state is not UTF-8") }
        return try LegadoRuntimeCacheEntry(text: value).encoded()
    }

    private func storedValue(_ data: Data, domain: LegadoOwnedStateDomain) throws -> Data {
        let entry = try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: data)
        let text = try entry.text()
        if case .cacheText = domain { return try entry.encoded() }
        guard entry.deadline == 0 else { throw failure("UNSUPPORTED_CAPABILITY", "TTL on App source variables or login headers is not connected") }
        if case .loginHeader = domain {
            let object: [String: Any]?
            do { object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] }
            catch { object = nil } // A bare token is a valid verbatim login payload.
            if object?.contains(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame && ($0.value as? String) != "" }) == true {
                throw failure("UNSUPPORTED_CAPABILITY", "Login headers with Cookie require the complete Cookie owner adapter")
            }
        }
        return Data(text.utf8)
    }

    private func encoded(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    private func failure(_ code: String, _ message: String) -> LegadoRuntimeError {
        LegadoRuntimeError(code: code, message: message)
    }
}
