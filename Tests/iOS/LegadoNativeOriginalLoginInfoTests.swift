import Foundation
import LegadoRuntime
import XCTest
@testable import yuedu_app

/// Actual Zero/JNI/Rhino plus the production App credential owner. All accounts
/// are unique synthetic .invalid sources; no existing account is enumerated.
final class LegadoNativeOriginalLoginInfoTests: XCTestCase {
    func testNativeOriginalFormSubmissionUsesProductSourceServiceAndExistingOwners() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            var source = BookSource()
            source.bookSourceUrl = fixture.a
            source.enabledCookieJar = false
            source.loginUrl = "function login(){if(book!==null||chapter!==null||String(result.get('password'))!=='synthetic-native-password')throw new Error('wrong form Map');source.putLoginHeader('synthetic-native-header');return '{\"X-Fake-Header\":\"must-not-infer\"}';}"
            let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
            let result = try await service.originalFormLogin(source: source,
                credentials: ["password": "synthetic-native-password"])
            XCTAssertTrue(result.credentialsStored); XCTAssertTrue(result.executed)
            let stored = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            let header = await Task.detached { LoginManager.shared.getLoginHeader(sourceUrl: fixture.a) }.value
            XCTAssertEqual(stored, ["password": "synthetic-native-password"])
            XCTAssertEqual(header, "synthetic-native-header")
            source.loginUrl = "throw new Error('empty form must not execute');"
            let removed = try await service.originalFormLogin(source: source, credentials: [:])
            XCTAssertTrue(removed.credentialsCleared); XCTAssertFalse(removed.executed)
            let remainingHeader = await Task.detached { LoginManager.shared.getLoginHeader(sourceUrl: fixture.a) }.value
            XCTAssertEqual(remainingHeader, header)
        } catch { problem = error }
        await Task.detached { LoginManager.shared.removeLoginHeader(sourceUrl: fixture.a) }.value
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    func testNativeOriginalLoginInfoMapDefaultsUseExistingKeychainAndReopen() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            let staticForm = "[{name:'user',default:'synthetic-user'},{name:'password',type:'password',default:'synthetic-default'},{name:'button',type:'button',default:'never'}]"
            try await exercise(fixture, loginUi: staticForm,
                script: "var m=source.getLoginInfoMap();if(Number(m.size())!==2||String(m.get('password'))!=='synthetic-default'||m.containsKey('button'))throw new Error('wrong defaults');m.put('scratch','must-not-store');if(source.getLoginInfoMap().containsKey('scratch'))throw new Error('live secret Map');'static';", expected: "static")
            let stored = await Task.detached { LoginManager(defaults: fixture.loginDefaults).getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(stored, ["user": "synthetic-user", "password": "synthetic-default"])
            try await exercise(fixture, loginUi: "@js:throw new Error('stored raw must win')",
                script: "if(String(source.getLoginInfoMap().get('user'))!=='synthetic-user')throw new Error('not reopened');source.removeLoginInfo();'reopened';", expected: "reopened")
            try await exercise(fixture, loginUi: "{version:2}",
                script: "if(Number(source.getLoginInfoMap().size())!==0||source.getLoginInfo()!==null)throw new Error('v2 defaults fabricated');'v2';", expected: "v2")
            let dynamic = "@js:if(book!==null||chapter!==null||Number(source.getLoginInfoMap().size())!==0)throw new Error('wrong bindings/reentry');result.put('probe','synthetic-map');[{name:'password',type:'password',default:prefixValue},{name:'result',default:String(result.get('probe'))}];"
            try await exercise(fixture, loginUi: dynamic, loginUrl: "<js>var prefixValue='synthetic-prefix';function login(){throw new Error('login must not run');}</js>",
                script: "if(String(source.getLoginInfoMap().get('password'))!=='synthetic-prefix')throw new Error('wrong dynamic default');'dynamic';", expected: "dynamic")
            let dynamicStored = await Task.detached { LoginManager(defaults: fixture.loginDefaults).getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(dynamicStored, ["password": "synthetic-prefix", "result": "synthetic-map"])
            try await exercise(fixture, source: fixture.b, loginUi: staticForm,
                script: "if(String(source.getLoginInfoMap().get('password'))!=='synthetic-default')throw new Error('source isolation');'isolated';", expected: "isolated")
            let stillA = await Task.detached { fixture.login.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(stillA, dynamicStored)
        } catch { problem = error }
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    func testNativeOriginalLoginInfoUsesExistingKeychainAndReopens() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            try await exercise(fixture, script: "if(source.getLoginInfo()!==null)throw new Error('not missing');if(source.putLoginInfo(' raw synthetic \\n')!=true)throw new Error('not accepted');'saved';", expected: "saved")
            let raw = try await Task.detached {
                let reopened = LoginManager(defaults: fixture.loginDefaults)
                return try reopened.runtimeLoginInfo(sourceUrl: fixture.a, validate: {}, recordEffect: { _ in true })
            }.value
            XCTAssertEqual(raw, " raw synthetic \n")
            try await exercise(fixture, script: "if(String(source.getLoginInfo())!==' raw synthetic \\n')throw new Error('not reopened');source.putLoginInfo('{\"password\":\"synthetic-map\"}');'map';", expected: "map")
            let map = await Task.detached { fixture.login.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(map, ["password": "synthetic-map"])
            try await exercise(fixture, source: fixture.b, script: "if(source.getLoginInfo()!==null)throw new Error('source leak');'isolated';", expected: "isolated")
            try await exercise(fixture, script: "source.removeLoginInfo();if(source.getLoginInfo()!==null)throw new Error('not removed');'removed';", expected: "removed")
            let header = await Task.detached { fixture.login.getLoginHeader(sourceUrl: fixture.a) }.value
            XCTAssertEqual(header, "kept-header")
        } catch { problem = error }
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    func testNativeOriginalLoginInfoCancellationRetainsAcceptedKeychainEffect() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        let accepted = expectation(description: "Actual App Keychain write accepted")
        let host = HeldAcceptedHost(base: fixture.host, accepted: { accepted.fulfill() })
        let configuration = try XCTUnwrap(LegadoRuntime.Configuration.bundled())
        let runtime = LegadoRuntime(configuration: configuration, host: host)
        let owner = try await fixture.host.bind(sourceURL: fixture.a, sourceRevision: "native-login-v1")
        let session = try await runtime.createSession(sourceJSON: fixture.source(fixture.a),
            options: .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional))
        _ = try await runtime.openExploreContextOriginal(session: session)
        let taskID = UUID().uuidString
        let pending = Task {
            try await runtime.evaluateExploreContextOriginal(session: session,
                script: "source.putLoginInfo('accepted-synthetic');source.putLoginInfo('late-synthetic');'late';", taskID: taskID)
        }
        await fulfillment(of: [accepted], timeout: 15)
        var problem: Error?
        do {
            try await runtime.cancel(taskID: taskID)
            do { _ = try await pending.value; XCTFail("Expected actual runtime cancellation") }
            catch let error as LegadoRuntimeError {
                XCTAssertEqual(error.code, "CANCELLED")
                XCTAssertTrue(error.completedEffects?.contains("sourceLoginInfoCommitted") == true)
            }
            let actual = try await Task.detached {
                try fixture.login.runtimeLoginInfo(sourceUrl: fixture.a, validate: {}, recordEffect: { _ in true })
            }.value
            XCTAssertEqual(actual, "accepted-synthetic")
        } catch { problem = error }
        await host.release()
        _ = await pending.result
        do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
        await fixture.host.revoke(owner: owner)
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    private func exercise(_ fixture: Fixture, source: String? = nil, loginUi: String? = nil, loginUrl: String? = nil,
        script: String, expected: String) async throws {
        let source = source ?? fixture.a
        let configuration = try XCTUnwrap(LegadoRuntime.Configuration.bundled())
        let runtime = LegadoRuntime(configuration: configuration, host: fixture.host)
        let owner = try await fixture.host.bind(sourceURL: source, sourceRevision: "native-login-v1")
        let session = try await runtime.createSession(sourceJSON: fixture.source(source, loginUi: loginUi, loginUrl: loginUrl),
            options: .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional))
        var problem: Error?
        do {
            _ = try await runtime.openExploreContextOriginal(session: session)
            let actual = try await runtime.evaluateExploreContextOriginal(session: session, script: script)
            XCTAssertEqual(actual.result, expected)
        } catch { problem = error }
        do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
        await fixture.host.revoke(owner: owner)
        if let problem { throw problem }
    }

    private func requireNativeRuntime() async throws {
        let diagnostics = await Task.detached { LegadoRuntime.diagnose() }.value
        guard diagnostics.available else {
            #if LEGADO_REQUIRE_NATIVE_MAINJS
            throw LegadoRuntimeError(code: "missing_runtime", message: "Actual native login-info requires the ordinary JAR and Zero VM")
            #else
            if ProcessInfo.processInfo.environment["LEGADO_REQUIRE_NATIVE_MAINJS"] == "1" {
                throw LegadoRuntimeError(code: "missing_runtime", message: "Required actual native runtime unavailable")
            }
            throw XCTSkip("Requires real ordinary JAR/JNI and Keychain; source-only cannot pass")
            #endif
        }
    }

    private final class Fixture: @unchecked Sendable {
        let a: String
        let b: String
        let sourceDefaults: UserDefaults
        let loginDefaults: UserDefaults
        let login: LoginManager
        let host: LegadoPersistentStateHost
        private let sourceSuite: String
        private let loginSuite: String
        init() throws {
            let id = UUID().uuidString.lowercased()
            a = "https://native-login-a-\(id).invalid"; b = "https://native-login-b-\(id).invalid"
            sourceSuite = "native.login.sources." + id; loginSuite = "native.login.owner." + id
            sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
            loginDefaults = try XCTUnwrap(UserDefaults(suiteName: loginSuite))
            login = LoginManager(defaults: loginDefaults)
            let sources = BookSourceRuntimeStateStore(defaults: sourceDefaults)
            host = LegadoPersistentStateHost(backing: AppLegadoOwnedStateBacking(sources: sources, login: login))
            login.storeLoginHeader(sourceUrl: a, raw: "kept-header")
        }
        func source(_ url: String, loginUi: String? = nil, loginUrl: String? = nil) throws -> String {
            var source = BookSource()
            source.bookSourceUrl = url; source.enabledCookieJar = false
            source.loginUi = loginUi ?? ""; source.loginUrl = loginUrl ?? ""
            return String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        }
        func cleanup() throws {
            for source in [a,b] {
                guard try login.storeRuntimeLoginInfo(sourceUrl: source, value: nil, validate: {}, recordEffect: { _ in true }) else {
                    throw LegadoRuntimeError(code: "cleanup_failed", message: "Synthetic Keychain item was not removed")
                }
                UserDefaults(suiteName: "com.yuedu.cache." + source)?.removePersistentDomain(forName: "com.yuedu.cache." + source)
            }
            sourceDefaults.removePersistentDomain(forName: sourceSuite); loginDefaults.removePersistentDomain(forName: loginSuite)
        }
    }

    private actor HeldAcceptedHost: LegadoPlatformHost {
        let base: LegadoPersistentStateHost
        let accepted: @Sendable () -> Void
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(base: LegadoPersistentStateHost, accepted: @escaping @Sendable () -> Void) { self.base = base; self.accepted = accepted }
        func dispatch(_ request: LegadoHostRequest) async throws -> String {
            let response = try await base.dispatch(request)
            if request.operation == "source.login-info",
               let input = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) as? [String: Any],
               input["action"] as? String == "put", !released {
                await withCheckedContinuation { continuation in self.continuation = continuation; accepted() }
            }
            return response
        }
        func cancel(taskID: String) async { await base.cancel(taskID: taskID); release() }
        func release() { released = true; let pending = continuation; continuation = nil; pending?.resume() }
    }
}
