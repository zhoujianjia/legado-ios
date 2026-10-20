from pathlib import Path
import difflib
import hashlib
import json
import re
import subprocess

ROOT=Path('F:/yuedu-reader')
STAGE=ROOT/'.build/native-210-login-single-process-repair-step'
GIT='D:/app/Git/cmd/git.exe'
assert not (STAGE/'work').exists()
paths=['Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift','Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift']
def fact(raw):return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
def replace_once(text,old,new):
    assert text.count(old)==1,old[:100]
    return text.replace(old,new,1)
baseline={p:(ROOT/p).read_bytes() for p in paths}
manager=baseline[paths[0]].decode()
manager=replace_once(manager,'        advanceRuntimeLoginInfoRevision(sourceUrl: sourceUrl)\n        recordEffect("sourceLoginInfoCommitted")\n        return true','        // The accepted Keychain write is already irreversible. Publish that\n        // fact before a synchronous revision notification can cancel its caller.\n        recordEffect("sourceLoginInfoCommitted")\n        advanceRuntimeLoginInfoRevision(sourceUrl: sourceUrl)\n        return true')
text=baseline[paths[1]].decode()
old=text[text.index('            let accepted = expectation(description: "Actual pure persistence Keychain write accepted")'):text.index('        } catch { problem = error }\n        do { try await Task.detached { try fixture.cleanup()',text.index('            let accepted = expectation(description: "Actual pure persistence Keychain write accepted")'))]
new='''            let process = LegadoRuntimeProcess.shared
            let runtime = try await process.executor()
            let owner = try await process.bindPersistentSource(sourceURL: fixture.a, sourceRevision: "native-persist-v1")
            var session: LegadoSourceSession?
            do {
                let current = try await runtime.createSession(sourceJSON: fixture.source(fixture.a, loginUrl: admitted.loginUrl),
                    options: .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional))
                session = current
                let accepted = expectation(description: "Actual pure persistence Keychain write accepted")
                let cancellation = AcceptedWriteCancellation()
                let notification = NotificationCenter.default.addObserver(forName: .bookSourceLoginInfoDidChange,
                    object: nil, queue: nil) { event in
                    guard event.userInfo?["sourceURL"] as? String == fixture.a,
                          cancellation.accept() else { return }
                    accepted.fulfill()
                }
                defer { cancellation.finish(); NotificationCenter.default.removeObserver(notification) }
                let pending = Task { try await runtime.persistLoginInfoOriginal(session: current,
                    credentials: ["password": "accepted-synthetic"], taskID: UUID().uuidString) }
                cancellation.install { pending.cancel() }
                await fulfillment(of: [accepted], timeout: 15)
                do { _ = try await pending.value; XCTFail("Actual cancellation must retain its checked commit fact") }
                catch let failure as LegadoRuntimeError {
                    XCTAssertEqual(failure.code, "CANCELLED")
                    XCTAssertTrue(failure.completedEffects?.contains("sourceLoginInfoCommitted") == true)
                }
                let actual = await Task.detached { fixture.login.getLoginInfo(sourceUrl: fixture.a) }.value
                XCTAssertEqual(actual, ["password": "accepted-synthetic"])
            } catch { problem = error }
            if let session {
                do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
            }
            await process.revokePersistentSource(owner: owner)
'''
text=replace_once(text,old,new)
start=text.index('    func testNativeOriginalLoginInfoCancellationRetainsAcceptedKeychainEffect() async throws {')
end=text.index('    private func exercise(',start)
text=text[:start]+'''    func testNativeOriginalLoginInfoCancellationRetainsAcceptedKeychainEffect() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        let process = LegadoRuntimeProcess.shared
        let runtime = try await process.executor()
        let owner = try await process.bindPersistentSource(sourceURL: fixture.a, sourceRevision: "native-login-v1")
        var session: LegadoSourceSession?
        var problem: Error?
        do {
            let current = try await runtime.createSession(sourceJSON: fixture.source(fixture.a),
                options: .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional))
            session = current
            _ = try await runtime.openExploreContextOriginal(session: current)
            let accepted = expectation(description: "Actual App Keychain write accepted")
            let cancellation = AcceptedWriteCancellation()
            let notification = NotificationCenter.default.addObserver(forName: .bookSourceLoginInfoDidChange,
                object: nil, queue: nil) { event in
                guard event.userInfo?["sourceURL"] as? String == fixture.a,
                      cancellation.accept() else { return }
                accepted.fulfill()
            }
            defer { cancellation.finish(); NotificationCenter.default.removeObserver(notification) }
            let taskID = UUID().uuidString
            let pending = Task {
                try await runtime.evaluateExploreContextOriginal(session: current,
                    // After the real accepted write, only the actual Rhino
                    // instruction observer/cancel path can release this loop.
                    script: "source.putLoginInfo('accepted-synthetic');while(true){};source.putLoginInfo('late-synthetic');'late';",
                    taskID: taskID)
            }
            cancellation.install { pending.cancel() }
            await fulfillment(of: [accepted], timeout: 15)
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
        if let session {
            do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
        }
        await process.revokePersistentSource(owner: owner)
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

'''+text[end:]
text=replace_once(text,'        let configuration = try XCTUnwrap(LegadoRuntime.Configuration.bundled())\n        let runtime = LegadoRuntime(configuration: configuration, host: fixture.host)\n        let owner = try await fixture.host.bind(sourceURL: source, sourceRevision: "native-login-v1")\n        let session = try await runtime.createSession(sourceJSON: fixture.source(source, loginUi: loginUi, loginUrl: loginUrl),\n            options: .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional))\n        var problem: Error?\n        do {\n            _ = try await runtime.openExploreContextOriginal(session: session)\n            let actual = try await runtime.evaluateExploreContextOriginal(session: session, script: script)\n            XCTAssertEqual(actual.result, expected)\n        } catch { problem = error }\n        do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }\n        await fixture.host.revoke(owner: owner)', '''        let process = LegadoRuntimeProcess.shared
        let runtime = try await process.executor()
        let owner = try await process.bindPersistentSource(sourceURL: source, sourceRevision: "native-login-v1")
        var session: LegadoSourceSession?
        var problem: Error?
        do {
            let current = try await runtime.createSession(sourceJSON: fixture.source(source, loginUi: loginUi, loginUrl: loginUrl),
                options: .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional))
            session = current
            _ = try await runtime.openExploreContextOriginal(session: current)
            let actual = try await runtime.evaluateExploreContextOriginal(session: current, script: script)
            XCTAssertEqual(actual.result, expected)
        } catch { problem = error }
        if let session {
            do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
        }
        await process.revokePersistentSource(owner: owner)''')
text=replace_once(text,'        let sourceDefaults: UserDefaults\n','')
text=replace_once(text,'        let host: LegadoPersistentStateHost\n','')
text=replace_once(text,'        private let sourceSuite: String\n','')
text=replace_once(text,'            sourceSuite = "native.login.sources." + id; loginSuite = "native.login.owner." + id\n            sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))\n','            loginSuite = "native.login.owner." + id\n')
text=replace_once(text,'            login = LoginManager(defaults: loginDefaults)\n            let sources = BookSourceRuntimeStateStore(defaults: sourceDefaults)\n            host = LegadoPersistentStateHost(backing: AppLegadoOwnedStateBacking(sources: sources, login: login))','            // Real sessions use the existing process Host and its App owner.\n            // This independent defaults suite is only for Keychain reopen probes.\n            login = .shared')
text=replace_once(text,'                UserDefaults(suiteName: "com.yuedu.cache." + source)?.removePersistentDomain(forName: "com.yuedu.cache." + source)','                login.removeLoginHeader(sourceUrl: source)\n                UserDefaults(suiteName: "com.yuedu.cache." + source)?.removePersistentDomain(forName: "com.yuedu.cache." + source)')
text=replace_once(text,'            sourceDefaults.removePersistentDomain(forName: sourceSuite); loginDefaults.removePersistentDomain(forName: loginSuite)','            loginDefaults.removePersistentDomain(forName: loginSuite)')
start=text.index('    private actor HeldAcceptedHost: LegadoPlatformHost {')
text=text[:start]+'''    /// Observes only this synthetic account's real accepted-write notification.
    /// Notification delivery may precede Task handle registration; either order
    /// cancels exactly once without blocking the Host actor or the main thread.
    private final class AcceptedWriteCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var accepted = false
        private var cancellation: (@Sendable () -> Void)?
        func install(_ action: @escaping @Sendable () -> Void) {
            let shouldCancel = lock.withLock { cancellation = action; return accepted }
            if shouldCancel { action() }
        }
        func accept() -> Bool {
            let result = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
                guard !accepted else { return (false, nil) }
                accepted = true
                return (true, cancellation)
            }
            result.1?()
            return result.0
        }
        func finish() { lock.withLock { cancellation = nil } }
    }
}
'''
assert 'LegadoRuntime(configuration:' not in text and 'HeldAcceptedHost' not in text and 'fixture.host' not in text
assert re.findall(r'func (test\w+)\(',baseline[paths[1]].decode())==re.findall(r'func (test\w+)\(',text)
rows=[]
for path,newtext in [(paths[0],manager),(paths[1],text)]:
    raw=newtext.encode(); out=STAGE/'work'/path; out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(raw)
    diff=''.join(difflib.unified_diff(baseline[path].decode().splitlines(True),newtext.splitlines(True),fromfile='a/'+path,tofile='b/'+path))
    dp=STAGE/'diffs'/(path+'.diff');dp.parent.mkdir(parents=True,exist_ok=True);dp.write_bytes(diff.encode())
    rows.append({'path':path,'baseline':fact(baseline[path]),'candidate':fact(raw),'diff':{'path':dp.relative_to(ROOT).as_posix(),**fact(dp.read_bytes())}})
manifest={'schemaVersion':1,'status':'prepared-single-process-login-tests-and-accepted-effect-order-awaiting-grammar-and-independent-review','canonicalParent':subprocess.check_output([GIT,'rev-parse','HEAD'],cwd=ROOT).decode().strip(),'files':rows,'actualNativeFailureSource':'210fb0597dcc4081db9324876c4be922ba186367','rootCauses':['Direct fixture Runtime and different HostBox cannot reconfigure the process-scoped JVM after the product service starts it.','Accepted Keychain persistence notified synchronous cancellation observers before recording its irreversible Committed fact.'],'scope':['Preserve the sole existing process runtime and Host; bind/revoke fresh synthetic .invalid source grants.','Record accepted irreversible commit before revision notification; rejection/IO and current owners remain unchanged.','Use actual accepted-write notifications and a bounded test-only lock box to synchronously cancel the existing pending task, including notification-before-registration.','Retain real checked Keychain/reopen/source isolation and committed-cancellation assertions; no second interpreter/router or production test hook.'],'existingNativeTestDefinitionsUnchanged':len(re.findall(r'func (test\w+)\(',text)),'newAppNativeOrPackageDefinitions':0,'actualSwiftCompilerSDKJNIExecutions':0,'currentSourcesUnchanged':True}
(STAGE/'preparation-v1.json').write_bytes((json.dumps(manifest,indent=2)+'\n').encode())
print(json.dumps({'sourceFiles':2,'unchangedNativeDefinitions':manifest['existingNativeTestDefinitionsUnchanged'],'manifest':fact((STAGE/'preparation-v1.json').read_bytes()),'actualSDKJNI':0}))
