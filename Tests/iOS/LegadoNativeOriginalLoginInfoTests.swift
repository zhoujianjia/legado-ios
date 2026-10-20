import Foundation
import LegadoRuntime
import XCTest
@testable import yuedu_app

/// Actual Zero/JNI/Rhino plus the production App credential owner. All accounts
/// are unique synthetic .invalid sources; no existing account is enumerated.
final class LegadoNativeOriginalLoginInfoTests: XCTestCase {
    func testNativeOriginalDismissPersistenceUsesCheckedOwnerWithoutExecutingLoginJS() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            var source = BookSource()
            source.bookSourceUrl = fixture.a; source.enabledCookieJar = false
            source.loginUrl = "function login( { malformed source.putLoginHeader('must-not-run')"
            let admitted = source
            let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
            let saved = try await service.originalPersistLoginInfo(source: admitted,
                values: ["hidden": "synthetic-hidden", "password": ""], sourceResolver: { _ in admitted })
            XCTAssertTrue(saved.credentialsStored); XCTAssertFalse(saved.executed)
            let stored = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(stored, ["hidden": "synthetic-hidden", "password": ""])
            let removed = try await service.originalPersistLoginInfo(source: admitted, values: [:],
                sourceResolver: { _ in admitted })
            XCTAssertTrue(removed.credentialsCleared); XCTAssertFalse(removed.executed)
            let header = await Task.detached { fixture.login.getLoginHeader(sourceUrl: fixture.a) }.value
            XCTAssertEqual(header, "kept-header")
            do {
                _ = try await service.originalPersistLoginInfo(source: admitted, values: ["must": "reject"],
                    sourceResolver: { _ in nil })
                XCTFail("Removed sources must reject before mutation admission")
            } catch { XCTAssertEqual((error as? LegadoRuntimeError)?.code, "SOURCE_CHANGED") }
            var changed = admitted; changed.loginUrl = "changed definition"
            let changedDefinition = changed
            do {
                _ = try await service.originalPersistLoginInfo(source: admitted, values: ["must": "reject"],
                    sourceResolver: { _ in changedDefinition })
                XCTFail("Changed definitions must reject before mutation admission")
            } catch { XCTAssertEqual((error as? LegadoRuntimeError)?.code, "SOURCE_CHANGED") }
            let remaining = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertNil(remaining)

            let accepted = expectation(description: "Actual pure persistence Keychain write accepted")
            let held = HeldAcceptedHost(base: fixture.host, accepted: { accepted.fulfill() })
            let runtime = LegadoRuntime(configuration: try XCTUnwrap(LegadoRuntime.Configuration.bundled()), host: held)
            let owner = try await fixture.host.bind(sourceURL: fixture.a, sourceRevision: "native-persist-v1")
            let session = try await runtime.createSession(sourceJSON: fixture.source(fixture.a, loginUrl: admitted.loginUrl),
                options: .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional))
            let taskID = UUID().uuidString
            let pending = Task { try await runtime.persistLoginInfoOriginal(session: session,
                credentials: ["password": "accepted-synthetic"], taskID: taskID) }
            await fulfillment(of: [accepted], timeout: 15)
            do {
                try await runtime.cancel(taskID: taskID)
                do { _ = try await pending.value; XCTFail("Actual cancellation must retain its checked commit fact") }
                catch let failure as LegadoRuntimeError {
                    XCTAssertEqual(failure.code, "CANCELLED")
                    XCTAssertTrue(failure.completedEffects?.contains("sourceLoginInfoCommitted") == true)
                }
                let actual = await Task.detached { fixture.login.getLoginInfo(sourceUrl: fixture.a) }.value
                XCTAssertEqual(actual, ["password": "accepted-synthetic"])
            } catch { problem = error }
            await held.release(); _ = await pending.result
            do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
            await fixture.host.revoke(owner: owner)
        } catch { problem = error }
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    func testNativeOriginalLoginUIEventsReachExistingFormProjectionAfterServiceGateRelease() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            let stored = ["hidden": "synthetic-hidden", "username": "stored-user"]
            await Task.detached { LoginManager.shared.storeLoginInfo(sourceUrl: fixture.a, info: stored) }.value
            var source = BookSource()
            source.bookSourceUrl = fixture.a; source.enabledCookieJar = false
            source.loginUi = "[{name:'username',default:'reset-user'},{name:'caption',type:'button',viewName:\"'Original'\"}]"
            source.loginUrl = "var prefix='present';"
            let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
            let rendered = try await service.originalLoginUI(source: source, values: nil)
            var events: [LegadoOriginalLoginUIEvent] = []
            do {
                _ = try await service.originalLoginAction(source: source,
                    action: "result.put('username','callback-user');result.put('caption','Callback');java.upLoginData(result);java.reLoginView(false);throw new Error('synthetic failure');",
                    credentials: stored, isLongClick: false)
                XCTFail("Accepted callbacks cannot turn a script failure into success")
            } catch let failure as LegadoRuntimeError {
                XCTAssertEqual(failure.code, "SCRIPT_ERROR")
                events = failure.loginUIEvents ?? []
                XCTAssertEqual(events.map(\.kind), [.updateData, .render])
                XCTAssertEqual(events.map(\.sequence), [1, 2])
            }
            let first = try XCTUnwrap(events.first)
            let updated = try LegadoOriginalLoginUIForm.applying(entries: first.entries,
                rows: rendered.rows, fields: rendered.fields, labels: rendered.labels,
                values: rendered.values, controls: rendered.controls)
            XCTAssertEqual(updated.values["username"], "callback-user")
            XCTAssertNil(updated.values["caption"])
            let caption = try XCTUnwrap(rendered.fields.first { $0.type == .button })
            XCTAssertEqual(updated.labels[caption.id], "Callback")
            // This second real service invocation occurs after the action throws
            // and releases its source gate, rather than inside NativeHost dispatch.
            let rerendered = try await service.originalLoginUI(source: source, values: updated.values,
                evaluationValues: LegadoOriginalLoginUIForm.submissionValues(fields: rendered.fields,
                    values: updated.values, controls: updated.controls))
            XCTAssertEqual(rerendered.values["username"], "callback-user")
            let reset = try await service.originalLoginAction(source: source,
                action: "java.upLoginData(null)", credentials: updated.values, isLongClick: false)
            let resetEvent = try XCTUnwrap(reset.loginUIEvents?.first)
            XCTAssertNil(resetEvent.entries)
            let resetForm = try LegadoOriginalLoginUIForm.applying(entries: resetEvent.entries,
                rows: rerendered.rows, fields: rerendered.fields, labels: rerendered.labels,
                values: rerendered.values, controls: rerendered.controls)
            XCTAssertEqual(resetForm.values, ["username": "reset-user"])
            let unchanged = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(unchanged, stored)
        } catch { problem = error }
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    func testNativeOriginalRowActionUsesProductServiceWithoutImplicitCredentialWrite() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            let original = ["hidden": "synthetic-hidden", "username": ""]
            await Task.detached { LoginManager.shared.storeLoginInfo(sourceUrl: fixture.a, info: original) }.value
            var source = BookSource()
            source.bookSourceUrl = fixture.a; source.enabledCookieJar = false
            source.loginUi = "[{name:'username',default:'must-not-replace-empty'},{name:'action',type:'button'}]"
            source.loginUrl = "function login(){throw new Error('must-not-submit');}"
            let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
            let rendered = try await service.originalLoginUI(source: source, values: nil)
            let values = BookSourceFormLoginView.originalFormSubmissionValues(fields: rendered.fields, values: rendered.values)
            let result = try await service.originalLoginAction(source: source,
                action: "if(java===source||book!==null||chapter!==null||isLongClick!==true||String(result.get('hidden'))!=='synthetic-hidden'||String(result.get('username'))!=='')throw new Error('wrong action Map');java.setContent('<p>native action</p>');if(String(java.getString('p@text'))!=='native action')throw new Error('wrong original parser');source.putLoginHeader('synthetic-action-header');JSON.stringify({XFake:'must-not-be-header'});",
                credentials: values, isLongClick: true)
            XCTAssertTrue(result.executed)
            let stored = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            let header = await Task.detached { LoginManager.shared.getLoginHeader(sourceUrl: fixture.a) }.value
            XCTAssertEqual(stored, original)
            XCTAssertEqual(header, "synthetic-action-header")
            do {
                _ = try await service.originalLoginAction(source: source,
                    action: "java.reLoginView(true)", credentials: values, isLongClick: false)
                XCTFail("UI callback must not become a successful action")
            } catch { XCTAssertEqual((error as? LegadoRuntimeError)?.code, "UNSUPPORTED_CAPABILITY") }
        } catch { problem = error }
        await Task.detached { LoginManager.shared.removeLoginHeader(sourceUrl: fixture.a) }.value
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    func testNativeOriginalLoginUIUsesProductSourceServiceAndStoredMap() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            await Task.detached {
                LoginManager.shared.storeLoginInfo(sourceUrl: fixture.a,
                    info: ["hidden": "synthetic-hidden", "password": ""])
            }.value
            var source = BookSource()
            source.bookSourceUrl = fixture.a
            source.enabledCookieJar = false
            source.loginUrl = "var prefixValue='native-prefix';function login(){throw new Error('must-not-submit');}"
            source.loginUi = "@js:if(java!==source||book!==null||chapter!==null||String(result.get('hidden'))!=='synthetic-hidden')throw new Error('wrong UI Map');[{name:'password',type:'password',default:'must-not-replace-empty',viewName:\"prefixValue+':'+String(result.get('hidden'))\"},{name:'caption',type:'label',viewName:\"throw new Error('must-not-eval-label')\"}];"
            let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
            let rendered = try await service.originalLoginUI(source: source, values: nil)
            XCTAssertEqual(rendered.fields.count, 1)
            XCTAssertEqual(rendered.fields[0].type, .password)
            XCTAssertEqual(rendered.labels[rendered.fields[0].id], "native-prefix:synthetic-hidden")
            XCTAssertEqual(rendered.values, ["hidden": "synthetic-hidden", "password": ""])
            let stored = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(stored, rendered.values)
            source.loginUi = "[{name:'password',type:'password',viewName:\"String(result.get('password'))\"}]"
            let edited = try await service.originalLoginUI(source: source,
                values: ["hidden": "synthetic-hidden", "password": "synthetic-edit"])
            XCTAssertEqual(edited.labels[edited.fields[0].id], "synthetic-edit")
            let unchanged = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(unchanged, stored)
        } catch { problem = error }
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

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
