import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

@Suite("Explicit App-owned Legado persistence", .serialized)
struct LegadoPersistentStateHostTests {
    @Test("original raw login Strings share the existing credential owner and survive reopen")
    func rawLoginInfoUsesCredentialOwnerAndSurvivesReopen() async throws {
        try await Self.fixture { f in
            let host = f.host()
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let missing = try await Self.login(host, owner: owner, source: f.a, action: "get")
            #expect(missing["value"] is NSNull)
            let raw = "  synthetic non-JSON \n\t"
            let saved = try await Self.login(host, owner: owner, source: f.a, action: "put", value: raw)
            #expect(saved["committed"] as? Bool == true)
            let reopened = LoginManager(defaults: f.loginDefaults, credentials: f.credentials)
            #expect(try reopened.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == raw)
            #expect(f.loginDefaults.string(forKey: "userInfo_" + f.a) == nil)
            #expect(LegadoCacheBridge(sourceId: f.a).get("userInfo_" + f.a) == nil)
            let ownerB = try await host.bind(sourceURL: f.b, sourceRevision: "r1")
            let other = try await Self.login(host, owner: ownerB, source: f.b, action: "get")
            #expect(other["value"] is NSNull)
            try await Self.error("INVALID_STATE_OWNER") { _ = try await Self.login(host, owner: owner, source: f.b, action: "get") }
            let empty = try await Self.login(host, owner: owner, source: f.a, action: "put", value: "")
            #expect(empty["committed"] as? Bool == true)
            let readEmpty = try await Self.login(host, owner: owner, source: f.a, action: "get")
            #expect(readEmpty["value"] as? String == "")
            f.login.storeLoginHeader(sourceUrl: f.a, raw: "kept-header")
            _ = try await Self.login(host, owner: owner, source: f.a, action: "remove")
            #expect(f.login.getLoginHeader(sourceUrl: f.a) == "kept-header")
            #expect(try reopened.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == nil)
        }
    }

    @Test("rejected secret writes locked reads and cancellation keep precise owner facts")
    func rawLoginInfoRejectsFailedWritesAndCancelledMutations() async throws {
        try await Self.fixture { f in
            let host = f.host()
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            _ = try await Self.login(host, owner: owner, source: f.a, action: "put", value: "kept-synthetic")
            let revision = f.login.loginInfoRevision(sourceUrl: f.a)
            f.credentials.failNextSave()
            let rejected = try await Self.login(host, owner: owner, source: f.a, action: "put", value: "rejected-synthetic")
            #expect(rejected["committed"] as? Bool == false)
            #expect(f.login.loginInfoRevision(sourceUrl: f.a) == revision)
            #expect(try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == "kept-synthetic")
            f.credentials.failNextDelete()
            try await Self.error("STATE_IO") { _ = try await Self.login(host, owner: owner, source: f.a, action: "remove") }
            #expect(try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == "kept-synthetic")
            f.credentials.failNextRead()
            try await Self.error("STATE_IO") { _ = try await Self.login(host, owner: owner, source: f.a, action: "get") }
            let denied = try Self.request("source.login-info", ["owner": owner, "sourceURL": f.a, "action": "put", "value": "cancelled"], task: "cancelled-login")
            await host.cancel(taskID: "cancelled-login")
            do { _ = try await host.dispatch(denied); Issue.record("Expected cancellation") } catch is CancellationError { }
            #expect(try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == "kept-synthetic")
            _ = try await host.bind(sourceURL: f.a, sourceRevision: "r2")
            try await Self.error("INVALID_STATE_OWNER") { _ = try await Self.login(host, owner: owner, source: f.a, action: "get") }
        }
    }

    @Test("legacy credentials migrate add-only and mutation effects are claimed before writes")
    func rawLoginInfoMigratesLegacyAndClaimsCommitBeforeMutation() async throws {
        try await Self.fixture { f in
            let legacy = "{\"password\":\"synthetic-legacy\"}"
            f.loginDefaults.set(legacy, forKey: "userInfo_" + f.a)
            var effects: [String] = []
            let actual = try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { effects.append($0); return true })
            #expect(actual == legacy)
            #expect(f.loginDefaults.object(forKey: "userInfo_" + f.a) == nil)
            #expect(effects == ["sourceLoginInfoMigrationMayCommit", "sourceLoginInfoMigrationCommitted"])
            do {
                _ = try f.login.storeRuntimeLoginInfo(sourceUrl: f.a, value: "denied", validate: {}, recordEffect: { _ in false })
                Issue.record("Expected sealed callback cancellation")
            } catch is CancellationError { }
            #expect(try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == legacy)
            effects.removeAll()
            let accepted = try f.login.storeRuntimeLoginInfo(sourceUrl: f.a, value: "accepted", validate: {}, recordEffect: { effects.append($0); return true })
            #expect(accepted)
            #expect(effects == ["sourceLoginInfoMayCommit", "sourceLoginInfoCommitted"])
            // A competing raw Keychain winner leaves a stale legacy Map. The
            // existing form getter must not confuse non-JSON/empty with missing
            // and overwrite that winner when the UI next reads the same owner.
            for winner in ["raw-synthetic-winner", ""] {
                #expect(try f.login.storeRuntimeLoginInfo(sourceUrl: f.a, value: nil, validate: {}, recordEffect: { _ in true }))
                f.loginDefaults.set(legacy, forKey: "userInfo_" + f.a)
                f.credentials.raceNextInsert(winner: winner)
                #expect(try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == winner)
                #expect(f.loginDefaults.string(forKey: "userInfo_" + f.a) == legacy)
                #expect(f.login.getLoginInfo(sourceUrl: f.a) == nil)
                #expect(try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == winner)
                f.credentials.failNextRead()
                #expect(f.login.getLoginInfo(sourceUrl: f.a) == nil)
                #expect(try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == winner)
            }
            #expect(try f.login.storeRuntimeLoginInfo(sourceUrl: f.a, value: nil, validate: {}, recordEffect: { _ in true }))
            f.loginDefaults.set(legacy, forKey: "userInfo_" + f.a)
            f.credentials.raceNextInsert(winner: "{\"password\":\"new-synthetic-winner\"}")
            #expect(f.login.getLoginInfo(sourceUrl: f.a) == ["password": "new-synthetic-winner"])
            #expect(try f.login.runtimeLoginInfo(sourceUrl: f.a, validate: {}, recordEffect: { _ in true }) == "{\"password\":\"new-synthetic-winner\"}")
        }
    }

    @Test("the actual source bridge removes a header while retaining owned credentials")
    func sourceBridgeRemovalPreservesCredentials() async throws {
        try await Self.fixture { f in
            f.login.storeLoginInfo(sourceUrl: f.a, info: ["password": "owned-secret"])
            f.login.storeLoginHeader(sourceUrl: f.a, raw: "owned-header")
            let value = await SourceScriptThread.run {
                var source = BookSource()
                source.bookSourceUrl = f.a
                source.bookSourceName = "Owned state fixture"
                let bridge = ModernParserBridge(source: source, loginManager: f.login, runtimeStateStore: f.sources)
                return bridge.evaluateSourceScript("source.removeLoginHeader(); source.getLoginInfoMap().password")
            }
            #expect(value == "owned-secret")
            #expect(f.login.getLoginHeader(sourceUrl: f.a) == nil)
            #expect(f.login.getLoginInfo(sourceUrl: f.a)?["password"] == "owned-secret")
        }
    }

    @Test("explicit owners isolate source variables and the existing cache namespace")
    func isolatesSourcesAndPreservesVerbatimValues() async throws {
        try await Self.fixture { f in
            let host = f.host()
            let a = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let b = try await host.bind(sourceURL: f.b, sourceRevision: "r1")
            let ka = try Self.key(f.a, "sourceVariable_" + f.a)
            let kb = try Self.key(f.b, "sourceVariable_" + f.b)
            let array = " [\"owned\", {\"n\":2}] "
            let ra = try await Self.read(host, owner: a, keys: [ka])
            let ca = try await Self.commit(host, owner: a, revision: ra.revision, changes: [ka: Self.value(array)])
            #expect(ca)
            let rb = try await Self.read(host, owner: b, keys: [kb])
            #expect(rb.values.isEmpty)
            #expect(f.sources.sourceVariableJSON(for: f.a) == array)
            #expect(f.sources.sourceVariableJSON(for: f.b) == nil)
            let next = try await Self.read(host, owner: a, keys: [ka])
            let empty = try await Self.commit(host, owner: a, revision: next.revision, changes: [ka: Self.value("")])
            #expect(empty)
            #expect(f.sources.sourceVariableJSON(for: f.a) == "")
            let cacheA = LegadoCacheBridge(sourceId: f.a)
            let cacheB = LegadoCacheBridge(sourceId: f.b)
            cacheA.put("same", "only-a")
            cacheB.put("same", "only-b")
            #expect(cacheA.get("same") == "only-a")
            #expect(cacheB.get("same") == "only-b")
            // Original SharedJsScope's ACache category shares this exact App
            // cache owner, but ordinary script keys cannot read/overwrite it.
            let urlMD5 = "a0b1c2d3e4f506172839405162738495"
            cacheA.put(urlMD5, "ordinary-md5")
            cacheA.put("shareJs/" + urlMD5, "ordinary-prefix")
            let libraryKey = try Self.key(f.a, urlMD5, area: "jslib-text")
            let initialLibrary = try await Self.read(host, owner: a, keys: [libraryKey])
            #expect(initialLibrary.values.isEmpty)
            let savedLibrary = try await Self.commit(host, owner: a, revision: initialLibrary.revision,
                changes: [libraryKey: Self.value("var sharedLibrary = 1;")])
            #expect(savedLibrary)
            let reopenedLibrary = try LegadoCacheBridge.runtimeSnapshot(sourceId: f.a, key: urlMD5, namespace: .sharedJsLibrary)
            let storedLibraryBytes = try #require(reopenedLibrary.values["value"])
            let storedLibrary = try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: storedLibraryBytes)
            let storedLibraryText = try storedLibrary.text()
            #expect(storedLibraryText == "var sharedLibrary = 1;")
            #expect(cacheA.get(urlMD5) == "ordinary-md5")
            #expect(cacheA.get("shareJs/" + urlMD5) == "ordinary-prefix")
            let otherLibrary = try await Self.read(host, owner: b, keys: [Self.key(f.b, urlMD5, area: "jslib-text")])
            #expect(otherLibrary.values.isEmpty)
            try await Self.error("INVALID_STATE_REQUEST") {
                _ = try await Self.read(host, owner: a, keys: [Self.key(f.a, "sourceVariable_" + f.a, area: "jslib-text")])
            }
            let deleteLibrary = try await Self.read(host, owner: a, keys: [libraryKey])
            let removedLibrary = try await Self.commit(host, owner: a, revision: deleteLibrary.revision, changes: [libraryKey: nil])
            #expect(removedLibrary)
            let afterLibraryDelete = try await Self.read(host, owner: a, keys: [libraryKey])
            #expect(afterLibraryDelete.values.isEmpty)
            #expect(cacheA.get(urlMD5) == "ordinary-md5")
            #expect(cacheA.get("shareJs/" + urlMD5) == "ordinary-prefix")
            try await Self.error("UNSUPPORTED_CAPABILITY") {
                _ = try await Self.read(host, owner: a, keys: [kb])
            }
        }
    }

    @Test("source edits credential changes and rebindings invalidate stale proofs")
    func rejectsStaleSourceLoginAndBindingRevisions() async throws {
        try await Self.fixture { f in
            let host = f.host()
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let variable = try Self.key(f.a, "sourceVariable_" + f.a)
            let proof = try await Self.read(host, owner: owner, keys: [variable])
            f.sources.setUserSourceVariableJSON("user-edit", for: f.a)
            let stale = try await Self.commit(host, owner: owner, revision: proof.revision, changes: [variable: Self.value("stale")])
            #expect(!stale)
            #expect(f.sources.sourceVariableJSON(for: f.a) == "user-edit")
            f.login.storeLoginHeader(sourceUrl: f.a, raw: "kept")
            let header = try Self.key(f.a, "loginHeader_" + f.a)
            let headerProof = try await Self.read(host, owner: owner, keys: [header])
            f.login.storeLoginInfo(sourceUrl: f.a, info: ["password": "new-owned-value"])
            let loginStale = try await Self.commit(host, owner: owner, revision: headerProof.revision, changes: [header: Self.value("stale")])
            #expect(!loginStale)
            #expect(f.login.getLoginHeader(sourceUrl: f.a) == "kept")
            _ = try await host.bind(sourceURL: f.a, sourceRevision: "r2")
            try await Self.error("INVALID_STATE_OWNER") {
                _ = try await Self.read(host, owner: owner, keys: [variable])
            }
        }
    }

    @Test("same-owner source values commit together and unchanged writes keep the revision")
    func commitsSameOwnerAtomicallyAndSkipsUnchangedWrites() async throws {
        try await Self.fixture { f in
            let host = f.host()
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let x = try Self.key(f.a, "v_" + f.a + "_x")
            let y = try Self.key(f.a, "v_" + f.a + "_y")
            let proof = try await Self.read(host, owner: owner, keys: [x, y])
            let committed = try await Self.commit(host, owner: owner, revision: proof.revision,
                changes: [x: Self.value("one"), y: Self.value("two")])
            #expect(committed)
            let before = f.sources.runtimeValuesSnapshot(for: f.a, keys: ["x", "y"])
            #expect(before.values == ["x": Data("one".utf8), "y": Data("two".utf8)])
            let same = try await Self.read(host, owner: owner, keys: [x, y])
            let unchanged = try await Self.commit(host, owner: owner, revision: same.revision,
                changes: [x: Self.value("one"), y: Self.value("two")])
            let after = f.sources.runtimeValuesSnapshot(for: f.a, keys: ["x", "y"])
            #expect(unchanged)
            #expect(after == before)
            // A mixed valid/invalid transaction must leave both original values.
            let invalid = try await Self.read(host, owner: owner, keys: [x, y])
            try await Self.error("STATE_LIMIT") {
                _ = try await Self.commit(host, owner: owner, revision: invalid.revision,
                    changes: [x: Self.value("replacement"), y: "invalid-base64"])
            }
            #expect(f.sources.runtimeValuesSnapshot(for: f.a, keys: ["x", "y"]) == before)
            let reopened = BookSourceRuntimeStateStore(defaults: f.sourceDefaults)
            #expect(reopened.sourceValue(for: f.a, key: "x") == "one")
            #expect(reopened.sourceValue(for: f.a, key: "y") == "two")
        }
    }

    @Test("owner and credential write failures preserve the old values and revision")
    func preservesOldStateWhenOwnerWritesFail() async throws {
        try await Self.fixture { f in
            f.sources.setSourceVariableJSON("old", for: f.a)
            let controlled = ControlledBacking(base: f.backing)
            let host = LegadoPersistentStateHost(backing: controlled)
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let key = try Self.key(f.a, "sourceVariable_" + f.a)
            let before = f.sources.runtimeVariableSnapshot(for: f.a)
            let proof = try await Self.read(host, owner: owner, keys: [key])
            controlled.failNextCommit()
            try await Self.error("STATE_IO") {
                _ = try await Self.commit(host, owner: owner, revision: proof.revision, changes: [key: Self.value("new")])
            }
            #expect(f.sources.runtimeVariableSnapshot(for: f.a) == before)
            f.login.storeLoginInfo(sourceUrl: f.a, info: ["password": "old-owned"])
            let loginRevision = f.login.loginInfoRevision(sourceUrl: f.a)
            f.credentials.failNextSave()
            f.login.storeLoginInfo(sourceUrl: f.a, info: ["password": "new-owned"])
            #expect(f.login.getLoginInfo(sourceUrl: f.a)?["password"] == "old-owned")
            #expect(f.login.loginInfoRevision(sourceUrl: f.a) == loginRevision)
        }
    }

    @Test("TTL and legacy cache records share the existing persistent key")
    func reusesLegacyCacheAndPreservesTTL() async throws {
        try await Self.fixture { f in
            let cache = LegadoCacheBridge(sourceId: f.a)
            cache.put("ttl", "legacy")
            let host = f.host()
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let key = try Self.key(f.a, "ttl")
            let proof = try await Self.read(host, owner: owner, keys: [key])
            let oldEntry = try Self.entry(proof.values[key])
            #expect(oldEntry.deadline == 0)
            let future = Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000
            let saved = try await Self.commit(host, owner: owner, revision: proof.revision,
                changes: [key: Self.value("host-value", deadline: future)])
            #expect(saved)
            #expect(cache.get("ttl") == "host-value")
            let reopened = LegadoCacheBridge(sourceId: f.a)
            #expect(reopened.get("ttl") == "host-value")
            let next = try await Self.read(host, owner: owner, keys: [key])
            let ttl = try Self.entry(next.values[key])
            #expect(ttl.deadline == future)
            let expired = Int64(Date().timeIntervalSince1970 * 1_000) - 60_000
            let expiredSave = try await Self.commit(host, owner: owner, revision: next.revision,
                changes: [key: Self.value("expired", deadline: expired)])
            #expect(expiredSave)
            #expect(cache.get("ttl") == nil)
            cache.put("ttl", "legacy-again")
            let legacyAgain = try await Self.read(host, owner: owner, keys: [key])
            let legacyEntry = try Self.entry(legacyAgain.values[key])
            #expect(legacyEntry.deadline == 0)
            #expect(reopened.get("ttl") == "legacy-again")
            reopened.delete("ttl")
            let removed = try await Self.read(host, owner: owner, keys: [key])
            #expect(removed.values.isEmpty)
            #expect(cache.get("ttl") == nil)
        }
    }

    @Test("unmapped Cookie book chapter binary and cross-owner transactions fail before writing")
    func rejectsUnsupportedTransactionsBeforeAnyWrite() async throws {
        try await Self.fixture { f in
            let controlled = ControlledBacking(base: f.backing)
            let host = LegadoPersistentStateHost(backing: controlled)
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let variable = try Self.key(f.a, "sourceVariable_" + f.a)
            let header = try Self.key(f.a, "loginHeader_" + f.a)
            let rejected = [
                try Self.keyParts([f.a, "cookies"]),
                try Self.keyParts([f.a, "variables", "book", "book-url", ""]),
                try Self.keyParts([f.a, "toc", "book-url"]),
                try Self.keyParts([f.a, "content", "book-url", "0"]),
                try Self.key(f.a, "binary", area: "cache-binary")
            ]
            for key in rejected {
                try await Self.error("UNSUPPORTED_CAPABILITY") {
                    _ = try await Self.read(host, owner: owner, keys: [key])
                }
            }
            try await Self.error("UNSUPPORTED_CAPABILITY") {
                _ = try await Self.read(host, owner: owner, keys: [variable, header])
            }
            #expect(controlled.counts().reads == 0)
            f.login.storeLoginHeader(sourceUrl: f.a, raw: "old-header")
            let proof = try await Self.read(host, owner: owner, keys: [header])
            try await Self.error("UNSUPPORTED_CAPABILITY") {
                _ = try await Self.commit(host, owner: owner, revision: proof.revision,
                    changes: [header: Self.value(#"{"Cookie":"owned-cookie"}"#)])
            }
            #expect(controlled.counts().commits == 0)
            #expect(f.login.getLoginHeader(sourceUrl: f.a) == "old-header")
        }
    }

    @Test("cancellation deadlines and bounded leases cannot acknowledge stale writes")
    func enforcesCancellationDeadlineAndBoundedLeases() async throws {
        try await Self.fixture { f in
            let controlled = ControlledBacking(base: f.backing)
            let host = LegadoPersistentStateHost(backing: controlled)
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let key = try Self.key(f.a, "sourceVariable_" + f.a)
            let request = try Self.request("state.read", ["owner": owner, "keys": [key]], task: "cancelled-owned")
            await host.cancel(taskID: request.taskID)
            do { _ = try await host.dispatch(request); Issue.record("Cancelled task was accepted") }
            catch is CancellationError {} // Exact cancellation must survive the host envelope.
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await Self.read(host, owner: owner, keys: [key])
            }
            do { _ = try await task.value; Issue.record("Caller cancellation was accepted") }
            catch is CancellationError {}
            try await Self.error("STATE_TIMEOUT") {
                _ = try await host.dispatch(Self.request("state.read", ["owner": owner, "keys": [key], "remainingTimeoutMs": 0]))
            }
            #expect(controlled.counts().reads == 0)
            let first = try await Self.read(host, owner: owner, keys: [key])
            var latest = first
            for _ in 0..<256 { latest = try await Self.read(host, owner: owner, keys: [key]) }
            let stale = try await Self.commit(host, owner: owner, revision: first.revision, changes: [key: Self.value("stale")])
            let fresh = try await Self.commit(host, owner: owner, revision: latest.revision, changes: [key: Self.value("fresh")])
            #expect(!stale)
            #expect(fresh)
            #expect(f.sources.sourceVariableJSON(for: f.a) == "fresh")
            await host.revoke(owner: owner)
            try await Self.error("INVALID_STATE_OWNER") {
                _ = try await Self.read(host, owner: owner, keys: [key])
            }
            let cleared = await host.ownershipCounts()
            #expect(cleared.bindings == 0)
            #expect(cleared.sourceRevisions == 0)
            #expect(cleared.leases == 0)
            var grants: [String] = []
            for index in 0..<256 {
                grants.append(try await host.bind(sourceURL: "\(f.a)/bounded/\(index)", sourceRevision: "r1"))
            }
            let full = await host.ownershipCounts()
            #expect(full.bindings == 256)
            #expect(full.sourceRevisions == 256)
            try await Self.error("STATE_LIMIT") {
                _ = try await host.bind(sourceURL: "\(f.a)/rejected", sourceRevision: "rejected-revision")
            }
            let rejected = await host.ownershipCounts()
            #expect(rejected.sourceRevisions == full.sourceRevisions)
            await host.revoke(owner: grants[0])
            let released = await host.ownershipCounts()
            #expect(released.bindings == 255)
            #expect(released.sourceRevisions == 255)
            _ = try await host.bind(sourceURL: "\(f.a)/rejected", sourceRevision: "current-revision")
            let rebound = await host.ownershipCounts()
            #expect(rebound.bindings == 256)
            #expect(rebound.sourceRevisions == 256)
        }
    }

    @Test("embedding options stay explicit and raw login headers retain their exact bytes")
    func preservesExplicitOptionsAndRawLoginPayloads() async throws {
        try await Self.fixture { f in
            let host = f.host()
            let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let encoder = JSONEncoder()
            let isolated = try JSONSerialization.jsonObject(with: encoder.encode(LegadoSessionOptions(httpTransport: .jvmOkHttp))) as? [String: Any]
            let options = LegadoSessionOptions(httpTransport: .jvmOkHttp, stateOwner: owner)
            let bound = try JSONSerialization.jsonObject(with: encoder.encode(options)) as? [String: Any]
            #expect(isolated?["stateOwner"] == nil)
            #expect(bound?["stateOwner"] as? String == owner)
            let header = try Self.key(f.a, "loginHeader_" + f.a)
            let binary = try Self.key(f.a, "loginHeader_" + f.a, area: "cache-binary")
            let raw = "  owned-bare-token  "
            let proof = try await Self.read(host, owner: owner, keys: [header, binary])
            let stored = try await Self.commit(host, owner: owner, revision: proof.revision,
                changes: [header: Self.value(raw), binary: nil])
            #expect(stored)
            #expect(f.login.getLoginHeader(sourceUrl: f.a) == raw)
            let reopened = LoginManager(defaults: f.loginDefaults, credentials: f.credentials)
            #expect(reopened.getLoginHeader(sourceUrl: f.a) == raw)
            let next = try await Self.read(host, owner: owner, keys: [header])
            let entry = try Self.entry(next.values[header])
            let text = try entry.text()
            #expect(text == raw)
            let deleted = try await Self.commit(host, owner: owner, revision: next.revision, changes: [header: nil])
            #expect(deleted)
            #expect(f.login.getLoginHeader(sourceUrl: f.a) == nil)
        }
    }

    @Test("one bounded decode rejects malformed JSON and inexact revisions before consuming an owner proof")
    func malformedStateInputsHaveTypedErrorsAndRetainProofs() async throws {
        try await Self.fixture { f in
            let host = f.host(); let owner = try await host.bind(sourceURL: f.a, sourceRevision: "r1")
            let key = try Self.key(f.a, "v_" + f.a + "_typed")
            let proof = try await Self.read(host, owner: owner, keys: [key])
            try await Self.error("INVALID_STATE_REQUEST") {
                _ = try await host.dispatch(.init(taskID: "malformed-json", operation: "state.read", requestJSON: "{"))
            }
            try await Self.error("INVALID_STATE_REQUEST") {
                _ = try await Self.read(host, owner: owner, keys: ["not a JSON key"])
            }
            for revision in [true as Any, 1.5 as Any, "1" as Any] {
                let request = try Self.request("state.commit", ["owner": owner, "revision": revision, "changes": [key: Self.value("must-not-write")]])
                try await Self.error("INVALID_STATE_REQUEST") { _ = try await host.dispatch(request) }
            }
            try await Self.error("INVALID_STATE_REQUEST") {
                _ = try await host.dispatch(.init(taskID: "too-large-revision", operation: "state.commit",
                    requestJSON: "{\"owner\":\"\(owner)\",\"revision\":9223372036854775808,\"changes\":{}}"))
            }
            let unknown = try Self.keyParts([f.a, "cookies", "*"])
            try await Self.error("UNSUPPORTED_CAPABILITY") { _ = try await Self.read(host, owner: owner, keys: [unknown]) }
            #expect(f.sources.sourceValue(for: f.a, key: "typed") == nil)
            #expect(try await Self.commit(host, owner: owner, revision: proof.revision, changes: [key: Self.value("accepted")]))
            #expect(f.sources.sourceValue(for: f.a, key: "typed") == "accepted")
        }
    }

    private struct ReadReply: Decodable, Sendable { let revision: Int64; let values: [String: String] }
    private struct CommitReply: Decodable { let committed: Bool }

    nonisolated private static func fixture(_ action: @escaping @Sendable (Fixture) async throws -> Void) async throws {
        try await Task.detached {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try await action(fixture)
        }.value
    }

    nonisolated private static func key(_ source: String, _ raw: String, area: String = "cache-text") throws -> String {
        try keyParts([source, area, raw])
    }
    nonisolated private static func keyParts(_ parts: [String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: parts, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }
    nonisolated private static func value(_ text: String, deadline: Int64 = 0) throws -> String {
        try LegadoRuntimeCacheEntry(text: text, deadline: deadline).encoded().base64EncodedString()
    }
    nonisolated private static func entry(_ value: String?) throws -> LegadoRuntimeCacheEntry {
        let text = try #require(value)
        let bytes = try #require(Data(base64Encoded: text))
        return try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: bytes)
    }
    nonisolated private static func request(_ operation: String, _ input: [String: Any], task: String = UUID().uuidString) throws -> LegadoHostRequest {
        .init(taskID: task, operation: operation,
            requestJSON: String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self))
    }
    nonisolated private static func login(_ host: LegadoPersistentStateHost, owner: String, source: String,
        action: String, value: String? = nil) async throws -> [String: Any] {
        var input: [String: Any] = ["owner": owner, "sourceURL": source, "action": action]
        if let value { input["value"] = value }
        let raw = try await host.dispatch(request("source.login-info", input))
        return try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
    nonisolated private static func read(_ host: LegadoPersistentStateHost, owner: String, keys: [String]) async throws -> ReadReply {
        let json = try await host.dispatch(request("state.read", ["owner": owner, "keys": keys]))
        return try JSONDecoder().decode(ReadReply.self, from: Data(json.utf8))
    }
    nonisolated private static func commit(_ host: LegadoPersistentStateHost, owner: String, revision: Int64,
        changes: [String: String?]) async throws -> Bool {
        let values = changes.mapValues { value -> Any in value.map { $0 as Any } ?? NSNull() }
        let json = try await host.dispatch(request("state.commit", ["owner": owner, "revision": revision, "changes": values]))
        return try JSONDecoder().decode(CommitReply.self, from: Data(json.utf8)).committed
    }
    nonisolated private static func error(_ code: String, _ action: @escaping @Sendable () async throws -> Void) async throws {
        do { try await action(); Issue.record("Expected state error \(code)") }
        catch let error as LegadoRuntimeError { #expect(error.code == code) }
    }

    private final class OwnedCredentials: @unchecked Sendable, LoginCredentialStorage {
        private let lock = NSLock()
        private var records: [String: String] = [:]
        private var fail = false
        private var failRead = false
        private var failDelete = false
        private var nextInsertWinner: String?
        func failNextSave() { lock.lock(); defer { lock.unlock() }; fail = true }
        func failNextRead() { lock.lock(); defer { lock.unlock() }; failRead = true }
        func failNextDelete() { lock.lock(); defer { lock.unlock() }; failDelete = true }
        func raceNextInsert(winner: String) { lock.lock(); defer { lock.unlock() }; nextInsertWinner = winner }
        func load(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return records[account] }
        func save(account: String, json: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fail { fail = false; return false }
            records[account] = json
            return true
        }
        func delete(account: String) { lock.lock(); defer { lock.unlock() }; records.removeValue(forKey: account) }
        func loadChecked(account: String, maximumBytes: Int) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            if failRead { failRead = false; throw CocoaError(.fileReadNoPermission) }
            guard (records[account]?.utf8.count ?? 0) <= maximumBytes else { throw LoginCredentialOwnerFailure.valueLimit }
            return records[account]
        }
        func saveChecked(account: String, raw: String) throws -> Bool { save(account: account, json: raw) }
        func deleteChecked(account: String) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if failDelete { failDelete = false; return false }
            records.removeValue(forKey: account); return true
        }
        func insertLegacyIfMissing(account: String, raw: String) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let winner = nextInsertWinner { nextInsertWinner = nil; records[account] = winner; return false }
            guard records[account] == nil else { return false }
            records[account] = raw; return true
        }
    }

    private final class ControlledBacking: @unchecked Sendable, LegadoOwnedStateBacking {
        let base: AppLegadoOwnedStateBacking
        private let lock = NSLock()
        private var fail = false
        private var reads = 0
        private var commits = 0
        init(base: AppLegadoOwnedStateBacking) { self.base = base }
        func failNextCommit() { lock.lock(); defer { lock.unlock() }; fail = true }
        func counts() -> (reads: Int, commits: Int) { lock.lock(); defer { lock.unlock() }; return (reads, commits) }
        func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
            lock.lock(); reads += 1; lock.unlock()
            return try base.read(sourceURL: sourceURL, domain: domain, fields: fields)
        }
        func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot, changes: [String: Data?]) throws -> Bool {
            lock.lock()
            commits += 1
            let failing = fail
            fail = false
            lock.unlock()
            if failing { throw CocoaError(.fileWriteUnknown) }
            return try base.commit(sourceURL: sourceURL, domain: domain, expected: expected, changes: changes)
        }
    }

    private final class Fixture: @unchecked Sendable {
        let a: String
        let b: String
        let sourceDefaults: UserDefaults
        let loginDefaults: UserDefaults
        let sources: BookSourceRuntimeStateStore
        let login: LoginManager
        let credentials = OwnedCredentials()
        private let sourceSuite: String
        private let loginSuite: String
        var backing: AppLegadoOwnedStateBacking { .init(sources: sources, login: login) }
        init() throws {
            let identity = UUID().uuidString.lowercased()
            a = "https://owned-a-\(identity).invalid"
            b = "https://owned-b-\(identity).invalid"
            sourceSuite = "owned.legado.state.sources.\(identity)"
            loginSuite = "owned.legado.state.login.\(identity)"
            sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
            loginDefaults = try #require(UserDefaults(suiteName: loginSuite))
            sources = BookSourceRuntimeStateStore(defaults: sourceDefaults)
            login = LoginManager(defaults: loginDefaults, credentials: credentials)
        }
        func host() -> LegadoPersistentStateHost { LegadoPersistentStateHost(backing: backing) }
        func cleanup() {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            loginDefaults.removePersistentDomain(forName: loginSuite)
            for source in [a, b] {
                let name = "com.yuedu.cache.\(source)"
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }
    }
}
