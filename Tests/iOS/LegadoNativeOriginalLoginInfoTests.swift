import Foundation
import LegadoRuntime
import Network
import WebKit
import XCTest
@testable import yuedu_app

/// Actual Zero/JNI/Rhino plus the production App credential owner. All accounts
/// are unique synthetic .invalid sources; no existing account is enumerated.
final class LegadoNativeOriginalLoginInfoTests: XCTestCase {
    func testNativeOriginalLoginV2UsesProductRhinoAndCheckedLoginBeforeClose() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            let initial = ["hidden": "synthetic-hidden", "username": "stored-user"]
            await Task.detached { LoginManager.shared.storeLoginInfo(sourceUrl: fixture.a, info: initial) }.value
            var source = BookSource()
            source.bookSourceUrl = fixture.a; source.enabledCookieJar = false
            source.loginUi = #"{"version":2}"#
            source.loginUrl = """
            function loginUi(s){if(java!==source||book!==null||chapter!==null)throw new Error('wrong original host');return {rows:[{name:String(s.phase),key:'username',value:'render-user'},{name:'Remember',type:'toggle',key:'remember',value:true},{name:'Nullable',type:'select',key:'choice',options:[null,'b']},{name:'Submit',type:'button',action:'submit',countdown:2}]};}
            function loginAction(a,s,f){if(java!==source||book!==null||chapter!==null||s.phase!==2)throw new Error('wrong original action');if(a==='invalid')return {state:[],login:{token:'must-not-save'},close:true};return {login:{token:f.password},state:{phase:3},close:true};}
            """
            let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
            do {
                _ = try await service.originalLoginUI(source: source, values: nil)
                XCTFail("Same original marker owner must request the distinct V2 protocol")
            } catch let failure as LegadoRuntimeError { XCTAssertEqual(failure.code, "LOGIN_UI_V2") }
            let rendered = try await service.originalLoginV2UI(source: source, stateJSON: #"{"phase":2}"#)
            XCTAssertEqual(rendered.render.rows.map(\.type), ["text", "toggle", "select", "button"])
            XCTAssertEqual(rendered.render.rows[2].options, [nil, "b"])
            XCTAssertEqual(rendered.render.rows[0].name, "2")
            XCTAssertEqual(rendered.render.storedValues, initial)
            let unchanged = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(unchanged, initial)
            let saved = try await service.originalLoginV2Action(source: source, action: "submit",
                stateJSON: #"{"phase":2}"#, form: ["password": "accepted-synthetic"])
            XCTAssertTrue(saved.command.loginStored); XCTAssertTrue(saved.command.close)
            XCTAssertEqual(saved.command.stateJSON, #"{"phase":3}"#)
            XCTAssertTrue(saved.completedEffects.contains("sourceLoginInfoCommitted"))
            let committed = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(committed, ["token": "accepted-synthetic"])
            do {
                _ = try await service.originalLoginV2Action(source: source, action: "invalid",
                    stateJSON: #"{"phase":2}"#, form: [:])
                XCTFail("Malformed command must validate before explicit login save or close")
            } catch let failure as LegadoRuntimeError { XCTAssertEqual(failure.code, "INVALID_RESULT") }
            let retained = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(retained, committed)
        } catch { problem = error }
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

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

            let process = LegadoRuntimeProcess.shared
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
            let callback = try await service.originalLoginAction(source: source,
                action: "java.reLoginView(true)", credentials: values, isLongClick: false)
            XCTAssertTrue(callback.executed)
            XCTAssertEqual(callback.loginUIEvents.map(\.kind), [.render])
            XCTAssertEqual(callback.loginUIEvents.map(\.sequence), [1])
            XCTAssertEqual(callback.loginUIEvents.first?.deltaUp, true)
            XCTAssertFalse(callback.completedEffects.contains("sourceLoginInfoMayCommit"))
            XCTAssertFalse(callback.completedEffects.contains("sourceLoginInfoCommitted"))
        } catch { problem = error }
        await Task.detached { LoginManager.shared.removeLoginHeader(sourceUrl: fixture.a) }.value
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    func testNativeOriginalDeltaLoginUIReusesPhysicalControlsThroughProductServiceWithoutCredentialWrite() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        var problem: Error?
        do {
            let stored = ["hidden": "synthetic-hidden", "username": "stored-user", "phase": "first"]
            await Task.detached { LoginManager.shared.storeLoginInfo(sourceUrl: fixture.a, info: stored) }.value
            var source = BookSource()
            source.bookSourceUrl = fixture.a; source.enabledCookieJar = false
            source.loginUrl = "function login(){throw new Error('must-not-submit');}"
            source.loginUi = """
            @js:if(String(result.get('phase'))==='next'){
              [{name:'caption',type:'password',default:'must-not-reset',action:'newAction()',viewName:"throw new Error('must-not-evaluate-reused')"},
               {name:'username',type:'button',action:'newWatcher()',viewName:"throw new Error('must-not-evaluate-reused')"}];
            }else{
              [{name:'username',action:'oldWatcher()',viewName:"'Original user'"},
               {name:'caption',type:'button',action:'oldAction()',viewName:"'Original button'"}];
            }
            """
            let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
            let first = try await service.originalLoginUI(source: source, values: nil)
            XCTAssertEqual(first.fields.count, 2)
            let text = try XCTUnwrap(first.fields.first { $0.name == "username" })
            let button = try XCTUnwrap(first.fields.first { $0.name == "caption" })
            var controls = first.controls
            controls[text.id]?.value = "visible-edit"
            let credentials = try BookSourceFormLoginView.originalFormSubmissionValues(rows: first.rows,
                layout: first.layout, values: first.values, controls: controls)
            let receipt = try await service.originalLoginAction(source: source,
                action: "result.put('phase','next');java.upLoginData(result);java.reLoginView(true)",
                credentials: credentials, isLongClick: false)
            XCTAssertTrue(receipt.executed)
            XCTAssertEqual(receipt.loginUIEvents.map(\.kind), [.updateData, .render])
            XCTAssertEqual(receipt.loginUIEvents.last?.deltaUp, true)
            let update = try XCTUnwrap(receipt.loginUIEvents.first)
            let updated = try LegadoOriginalLoginUIForm.applying(entries: update.entries,
                rows: first.rows, fields: first.fields, labels: first.labels,
                values: first.values, controls: controls, layout: first.layout)
            let snapshot = try LegadoOriginalLoginUIForm.reuseState(layout: first.layout,
                labels: updated.labels, controls: updated.controls)
            let evaluation = try BookSourceFormLoginView.originalFormSubmissionValues(rows: first.rows,
                layout: first.layout, values: updated.values, controls: updated.controls)
            // The real action has returned and released the source gate before
            // the same service/JVM receives this retained physical snapshot.
            let moved = try await service.originalLoginUI(source: source, values: updated.values,
                evaluationValues: evaluation, reuseState: snapshot)
            XCTAssertEqual(moved.fields.map(\.id), [button.id, text.id])
            XCTAssertEqual(moved.layout.children.map(\.rowIndex), [0, 1])
            XCTAssertEqual(moved.rows.map(\.type), ["password", "button"])
            XCTAssertEqual(moved.fields.map(\.type), [.button, .text])
            XCTAssertEqual(moved.fields.map(\.action), ["oldAction()", "oldWatcher()"])
            XCTAssertEqual(moved.labels[button.id], "Original button")
            XCTAssertEqual(moved.labels[text.id], "Original user")
            XCTAssertEqual(moved.controls[text.id]?.value, "visible-edit")
            XCTAssertEqual(moved.values, updated.values)
            XCTAssertFalse(moved.workingMapChanged)
            do {
                _ = try BookSourceFormLoginView.originalFormSubmissionValues(rows: moved.rows,
                    layout: moved.layout, values: moved.values, controls: moved.controls)
                XCTFail("A new password row bound to the retained Button must stay a binding error")
            } catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "UI_BINDING_ERROR") }
            do {
                _ = try await service.originalLoginAction(source: source, action: button.action,
                    credentials: [:], isLongClick: false, inputBindingFailed: true)
                XCTFail("A present original prelude requires the missing input to fail before authored JS")
            } catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "UI_BINDING_ERROR") }
            // The locked action first checks its original login script. An
            // absent script skips before attempting to bind current controls.
            source.loginUrl = ""
            let skipped = try await service.originalLoginAction(source: source, action: button.action,
                credentials: [:], isLongClick: false, inputBindingFailed: true)
            XCTAssertFalse(skipped.executed); XCTAssertTrue(skipped.loginUIEvents.isEmpty)
            XCTAssertFalse(skipped.completedEffects.contains("sourceLoginInfoMayCommit"))
            XCTAssertFalse(skipped.completedEffects.contains("sourceLoginInfoCommitted"))
            let unchanged = await Task.detached { LoginManager.shared.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertEqual(unchanged, stored)
        } catch { problem = error }
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
            do {
                try await runtime.cancel(taskID: taskID)
                do { _ = try await pending.value; XCTFail("Expected actual runtime cancellation") }
                catch let error as LegadoRuntimeError {
                    XCTAssertEqual(error.code, "CANCELLED")
                    XCTAssertTrue(error.completedEffects?.contains("sourceLoginInfoCommitted") == true)
                }
            } catch { problem = error }
            // Drain even if explicit cancellation itself reports a failure.
            pending.cancel()
            _ = await pending.result
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

    /// Actual product JNI and UIKit. No second Runtime/HostBox or synthetic
    /// presentation ACK is installed; only the existing process opens this page.
    func testNativeOriginalBrowserUsesSharedProcessAndKeepsAcceptedPageUntilActualDismissal() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        let process = LegadoRuntimeProcess.shared
        let runtime = try await process.executor()
        let owner = try await process.bindPersistentSource(sourceURL: fixture.a, sourceRevision: "native-browser-v1")
        let taskID = UUID().uuidString
        let effects = OriginalBrowserEffects()
        var session: LegadoSourceSession?
        var problem: Error?
        do {
            let current = try await runtime.createSession(sourceJSON: fixture.source(fixture.a, loginUrl: "var browserPrelude=true;"),
                options: .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional))
            session = current
            let accepted = try await runtime.loginActionOriginal(session: current,
                action: "java.startBrowser('https://synthetic-browser.invalid/page,{\"headers\":{\"X-Page\":\"synthetic\"}}','Synthetic browser');",
                credentials: [:], taskID: taskID, onReportedEffects: { effects.record($0) })
            XCTAssertTrue(accepted.executed)
            XCTAssertTrue(effects.snapshot().contains("sourceBrowserPresented"))
            let activeAfterProducer = await SourceBrowserPresenter.isOriginalPageActive(taskID: taskID)
            XCTAssertTrue(activeAfterProducer)
            try await runtime.close(session: current)
            session = nil
            await process.revokePersistentSource(owner: owner)
            let activeAfterNormalCleanup = await SourceBrowserPresenter.isOriginalPageActive(taskID: taskID)
            XCTAssertTrue(activeAfterNormalCleanup, "Normal producer/session cleanup must leave an accepted nonawait page open")
            await SourceBrowserPresenter.cancelOriginal(taskID: taskID)
            let activeAfterDismissal = await SourceBrowserPresenter.isOriginalPageActive(taskID: taskID)
            XCTAssertFalse(activeAfterDismissal, "Explicit close waits for actual UIKit dismissal, without a fixed delay")
            let info = await Task.detached { fixture.login.getLoginInfo(sourceUrl: fixture.a) }.value
            XCTAssertNil(info)
            let header = await Task.detached { fixture.login.getLoginHeader(sourceUrl: fixture.a) }.value
            XCTAssertEqual(header, "kept-header")
        } catch { problem = error }
        // Drain the same page even after a failed assertion path or source error.
        await SourceBrowserPresenter.cancelOriginal(taskID: taskID)
        if let session {
            do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
        }
        await process.revokePersistentSource(owner: owner)
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    /// Executes the ordinary JAR through the sole product process, the default
    /// Presenter, real WK page confirmation, Cookie owner and UIKit dismissal.
    /// The loopback server is only a synthetic HTTP peer; no Host receipt is mocked.
    func testNativeOriginalAwaitBrowserConfirmsThroughRealPageAndCancelsWithoutLateCredentialWrite() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        let peer = try OriginalAwaitHTTPPeer()
        let ready = expectation(description: "Synthetic await HTTP peer ready")
        peer.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        let process = LegadoRuntimeProcess.shared
        let runtime = try await process.executor()
        let owner = try await process.bindPersistentSource(sourceURL: fixture.a, sourceRevision: "native-browser-await-v1")
        var session: LegadoSourceSession?
        var problem: Error?
        let confirmedTaskID = UUID().uuidString
        let cancelledTaskID = UUID().uuidString
        do {
            let url = try peer.readyURL()
            try await exerciseCancelledInitialCookieSeed(url: XCTUnwrap(URL(string: url)), peer: peer)
            var source = BookSource()
            source.bookSourceUrl = fixture.a; source.enabledCookieJar = true
            source.loginUrl = "var browserAwaitPrelude=true;"
            let admittedSource = source
            let sourceJSON = try await Task.detached {
                String(decoding: try JSONEncoder().encode(admittedSource), as: UTF8.self)
            }.value
            let current = try await runtime.createSession(sourceJSON: sourceJSON,
                options: .init(httpTransport: .jvmOkHttp, stateOwner: owner,
                    sourceMode: .originalTraditional, cookieAccess: .appOwnerText))
            session = current
            let presented = expectation(description: "Real awaited page presented")
            let pageDidPresent = await SourceBrowserPresenter.originalPageDidPresent
            let firstObserver = NotificationCenter.default.addObserver(forName: pageDidPresent,
                object: nil, queue: nil) { event in
                if event.userInfo?["taskID"] as? String == confirmedTaskID { presented.fulfill() }
            }
            defer { NotificationCenter.default.removeObserver(firstObserver) }
            let effects = OriginalBrowserEffects()
            let pending = Task {
                try await runtime.loginActionOriginal(session: current,
                    action: "var r=java.startBrowserAwait('\(url)','Synthetic await');if(String(r.body())!=='<html>synthetic-await-body</html>'||String(r.url())!=='\(url)'||r.code()!==200||String(r.message())!=='OK'||r.headers().size()!==0)throw new Error('wrong original owner result');",
                    credentials: [:], taskID: confirmedTaskID,
                    onReportedEffects: { effects.record($0) })
            }
            await fulfillment(of: [presented], timeout: 15)
            // This calls the mounted Coordinator's page-close path, not a fake
            // Completion. Success waits for Cookie capture and actual dismissal.
            await SourceBrowserPresenter.requestOriginalPageClose(taskID: confirmedTaskID)
            do {
                let result = try await pending.value
                XCTAssertTrue(result.executed)
            } catch {
                pending.cancel(); _ = await pending.result
                throw error
            }
            XCTAssertTrue(effects.snapshot().contains("sourceBrowserPresented"))
            XCTAssertTrue(effects.snapshot().contains("sourceBrowserCookieCaptureCompleted"))
            let activeAfterConfirm = await SourceBrowserPresenter.isOriginalPageActive(taskID: confirmedTaskID)
            XCTAssertFalse(activeAfterConfirm)
            XCTAssertGreaterThanOrEqual(peer.requestCount, 1)

            let secondPresented = expectation(description: "Second real awaited page presented")
            let secondObserver = NotificationCenter.default.addObserver(forName: pageDidPresent,
                object: nil, queue: nil) { event in
                if event.userInfo?["taskID"] as? String == cancelledTaskID { secondPresented.fulfill() }
            }
            defer { NotificationCenter.default.removeObserver(secondObserver) }
            let cancelled = Task {
                try await runtime.loginActionOriginal(session: current,
                    action: "java.startBrowserAwait('\(url)','Cancelled await',false);source.putLoginInfo('must-not-write');",
                    credentials: [:], taskID: cancelledTaskID)
            }
            await fulfillment(of: [secondPresented], timeout: 15)
            cancelled.cancel()
            do {
                try await runtime.cancel(taskID: cancelledTaskID)
                do { _ = try await cancelled.value; XCTFail("Await must fail after actual task cancellation") }
                catch let failure as LegadoRuntimeError {
                    XCTAssertEqual(failure.code, "CANCELLED")
                    XCTAssertTrue(failure.completedEffects?.contains("sourceBrowserPresented") == true)
                }
            } catch {
                cancelled.cancel(); _ = await cancelled.result
                throw error
            }
            _ = await cancelled.result
            await SourceBrowserPresenter.cancelOriginal(taskID: cancelledTaskID)
            let activeAfterCancel = await SourceBrowserPresenter.isOriginalPageActive(taskID: cancelledTaskID)
            XCTAssertFalse(activeAfterCancel)
            let raw = try await Task.detached {
                try fixture.login.runtimeLoginInfo(sourceUrl: fixture.a, validate: {}, recordEffect: { _ in true })
            }.value
            XCTAssertNil(raw)
            let header = await Task.detached { fixture.login.getLoginHeader(sourceUrl: fixture.a) }.value
            XCTAssertEqual(header, "kept-header")
        } catch { problem = error }
        await SourceBrowserPresenter.cancelOriginal(taskID: confirmedTaskID)
        await SourceBrowserPresenter.cancelOriginal(taskID: cancelledTaskID)
        if let session {
            do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
        }
        await process.revokePersistentSource(owner: owner)
        let stopped = expectation(description: "Synthetic HTTP peer stopped and all connections drained")
        peer.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    func testNativeOriginalPostBrowserDisplaysPrefetchedHtmlAndReusesSingleHttpBody() async throws {
        executionTimeAllowance = 180
        try await requireNativeRuntime()
        let fixture = try await Task.detached { try Fixture() }.value
        let peer = try OriginalAwaitHTTPPeer()
        let ready = expectation(description: "Synthetic POST HTTP peer ready")
        peer.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        let process = LegadoRuntimeProcess.shared
        let runtime = try await process.executor()
        let owner = try await process.bindPersistentSource(sourceURL: fixture.a, sourceRevision: "native-browser-post-v1")
        var session: LegadoSourceSession?
        var problem: Error?
        var taskIDs: [String] = []
        do {
            let url = try peer.readyURL()
            var source = BookSource()
            source.bookSourceUrl = fixture.a; source.enabledCookieJar = true
            source.loginUi = "[]"; source.loginUrl = "var browserPostPrelude=true;"
            let admittedSource = source
            let sourceJSON = try await Task.detached {
                String(decoding: try JSONEncoder().encode(admittedSource), as: UTF8.self)
            }.value
            let current = try await runtime.createSession(sourceJSON: sourceJSON,
                options: .init(httpTransport: .jvmOkHttp, stateOwner: owner,
                    sourceMode: .originalTraditional, cookieAccess: .appOwnerText))
            session = current
            let pageDidLoad = await SourceBrowserPresenter.originalPageDidLoad
            let pageDidPresent = await SourceBrowserPresenter.originalPageDidPresent
            for refetch in [true, false] {
                let taskID = UUID().uuidString
                taskIDs.append(taskID)
                let loaded = expectation(description: "Actual POST HTML WK didFinish")
                loaded.assertForOverFulfill = false
                let presented = expectation(description: "Actual POST page UIKit presentation completed")
                let presentationObserver = NotificationCenter.default.addObserver(forName: pageDidPresent,
                    object: nil, queue: nil) { event in
                    if event.userInfo?["taskID"] as? String == taskID { presented.fulfill() }
                }
                let observer = NotificationCenter.default.addObserver(forName: pageDidLoad,
                    object: nil, queue: nil) { event in
                    if event.userInfo?["taskID"] as? String == taskID { loaded.fulfill() }
                }
                let effects = OriginalBrowserEffects()
                let postURL = url + ",{\"method\":\"POST\",\"body\":\"field=synthetic\"}"
                let mode = refetch ? "true" : "false"
                let bodyCheck = refetch
                    ? "String(r.body())==='<html>synthetic-await-body</html>'"
                    : "String(r.body()).indexOf('synthetic-await-body')>=0"
                let pending = Task {
                    try await runtime.loginActionOriginal(session: current,
                        action: "var r=java.startBrowserAwait('\(postURL)','Synthetic POST',\(mode));if(!(\(bodyCheck))||String(r.url())!=='\(url)'||r.code()!==200||String(r.message())!=='OK'||r.headers().size()!==0)throw new Error('wrong POST owner response');",
                        credentials: [:], taskID: taskID, onReportedEffects: { effects.record($0) })
                }
                // Inline HTML can finish before UIKit's presentation animation.
                // Mounted close requires both real signals, in either order.
                await fulfillment(of: [presented, loaded], timeout: 20)
                NotificationCenter.default.removeObserver(presentationObserver)
                NotificationCenter.default.removeObserver(observer)
                // Actual DOM is loaded and UIKit presented, then mounted confirmation performs
                // checked Cookie capture and waits for real UIKit dismissal.
                await SourceBrowserPresenter.requestOriginalPageClose(taskID: taskID)
                do { let result = try await pending.value; XCTAssertTrue(result.executed) }
                catch { pending.cancel(); _ = await pending.result; throw error }
                let active = await SourceBrowserPresenter.isOriginalPageActive(taskID: taskID)
                XCTAssertFalse(active)
                XCTAssertTrue(effects.snapshot().contains("sourceBrowserPostMaySend"))
                XCTAssertTrue(effects.snapshot().contains("sourceBrowserPostResponseReceived"))
                XCTAssertTrue(effects.snapshot().contains("sourceBrowserCookieCaptureCompleted"))
            }
            XCTAssertEqual(peer.requestMethods, ["POST", "POST"], "Neither HTML display nor true confirmation may repeat POST or issue GET")
            XCTAssertEqual(peer.requestBodies, ["field=synthetic", "field=synthetic"])
            XCTAssertTrue(peer.requestContentTypes.allSatisfy { $0.hasPrefix("application/x-www-form-urlencoded") })
            let raw = try await Task.detached {
                try fixture.login.runtimeLoginInfo(sourceUrl: fixture.a, validate: {}, recordEffect: { _ in true })
            }.value
            XCTAssertNil(raw)
        } catch { problem = error }
        for taskID in taskIDs { await SourceBrowserPresenter.cancelOriginal(taskID: taskID) }
        if let session {
            do { try await runtime.close(session: session) } catch { if problem == nil { problem = error } }
        }
        await process.revokePersistentSource(owner: owner)
        let stopped = expectation(description: "POST peer stopped and all connections drained")
        peer.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
        do { try await Task.detached { try fixture.cleanup() }.value } catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    @MainActor
    private func exerciseCancelledInitialCookieSeed(url: URL, peer: OriginalAwaitHTTPPeer) async throws {
        let name = "synthetic_initial_seed_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: name, .value: "synthetic"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let coordinator = JsBridgeBrowserRepresentable.Coordinator()
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        let barrier = OriginalCookieSeedBarrier()
        let cancellation = OriginalRuntimeCommitCancellation()
        let deadline = Date().addingTimeInterval(30)
        coordinator.originalAwaitPolicy = .init(refetchAfterSuccess: true, deadline: deadline,
            authorize: { try cancellation.check(deadline: deadline) },
            validateCommit: { try cancellation.check(deadline: deadline) },
            recordEffect: { barrier.record($0); return true })
        coordinator.originalPageLoadCheck = { try cancellation.check(deadline: deadline) }
        let seeded = expectation(description: "Actual WK setCookie completed but its notification remains held")
        coordinator.initialCookieSeeder = { store, cookie, completion in
            let holdThisCallback = cookie.name == name
            store.setCookie(cookie) {
                if holdThisCallback { barrier.hold(completion); seeded.fulfill() }
                else { completion() }
            }
        }
        var request = URLRequest(url: url)
        request.setValue("synthetic-must-not-load", forHTTPHeaderField: "X-Synthetic-Initial")
        coordinator.load(url: url, request: request, in: webView)
        await fulfillment(of: [seeded], timeout: 10)
        // The real mutation has already happened. Only delivery of its actual
        // completion is delayed; no fake Cookie or presentation ACK is injected.
        guard barrier.isHeld else {
            coordinator.originalPageControls().stopLoading()
            throw LegadoRuntimeError(code: "fixture_seed_failed", message: "Actual Cookie callback was not held")
        }
        XCTAssertEqual(peer.requestCount, 0)
        let controls = coordinator.originalPageControls()
        cancellation.cancel()
        controls.stopLoading()
        let drainStarted = expectation(description: "Cancellation has entered the actual seed drain")
        let drain = Task { @MainActor in
            drainStarted.fulfill()
            await controls.cancelAndDrain()
            barrier.markDrained()
        }
        await fulfillment(of: [drainStarted], timeout: 10)
        XCTAssertFalse(barrier.didDrain, "Cancellation must await the already issued native callback")
        XCTAssertEqual(peer.requestCount, 0)
        barrier.release()
        await drain.value
        XCTAssertTrue(barrier.didDrain)
        XCTAssertEqual(peer.requestCount, 0, "Releasing the old Cookie callback must never load its old URL or header")
        XCTAssertNil(webView.url)
        XCTAssertTrue(barrier.effects.contains("sourceBrowserCookieSeedIssued"))
        XCTAssertTrue(barrier.effects.contains("sourceBrowserCookieSeedCompleted"), "Already accepted Cookie mutation remains a completed fact after cancellation")
        let actualCookieExists = await withCheckedContinuation { continuation in
            configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.contains { $0.name == name })
            }
        }
        XCTAssertTrue(actualCookieExists)
        webView.navigationDelegate = nil
    }

    private final class OriginalCookieSeedBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable () -> Void)?
        private var drained = false
        private var recorded: [String] = []
        var isHeld: Bool { lock.withLock { callback != nil } }
        var didDrain: Bool { lock.withLock { drained } }
        var effects: [String] { lock.withLock { recorded } }
        func hold(_ completion: @escaping @Sendable () -> Void) { lock.withLock { callback = completion } }
        func release() {
            let completion = lock.withLock { let value = callback; callback = nil; return value }
            completion?()
        }
        func markDrained() { lock.withLock { drained = true } }
        func record(_ value: String) { lock.withLock { recorded.append(value) } }
    }

    /// Bounded test-only HTTP peer. Ready/stop are actual NWListener signals.
    private final class OriginalAwaitHTTPPeer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "native.original.await.http.peer")
        private let lock = NSLock()
        private var url: String?
        private var count = 0
        private var methods: [String] = []
        private var bodies: [String] = []
        private var contentTypes: [String] = []
        private var failure: String?
        private var connections: [UUID: NWConnection] = [:]
        private var stopping = false
        private var cancelled = false
        private var ready: (@Sendable () -> Void)?
        private var stopped: (@Sendable () -> Void)?
        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }
        var requestCount: Int { lock.withLock { count } }
        var requestMethods: [String] { lock.withLock { methods } }
        var requestBodies: [String] { lock.withLock { bodies } }
        var requestContentTypes: [String] { lock.withLock { contentTypes } }
        func readyURL() throws -> String {
            try lock.withLock {
                guard let url, failure == nil else {
                    throw LegadoRuntimeError(code: "fixture_peer_failed", message: "Synthetic HTTP peer did not become ready")
                }
                return url
            }
        }
        func start(ready: @escaping @Sendable () -> Void) {
            lock.withLock { self.ready = ready }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.withLock {
                        if let port = self.listener.port { self.url = "http://127.0.0.1:\(port.rawValue)/synthetic-await" }
                        else { self.failure = "Missing port" }
                    }
                    self.signalReady()
                case .failed:
                    self.lock.withLock { self.failure = "Listener failed" }
                    self.signalReady()
                case .cancelled:
                    self.lock.withLock { self.cancelled = true }
                    self.signalReady(); self.finishStop()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        func stop(completed: @escaping @Sendable () -> Void) {
            let active = lock.withLock {
                stopping = true; stopped = completed
                return Array(connections.values)
            }
            listener.newConnectionHandler = nil
            listener.cancel()
            active.forEach { $0.cancel() }
            finishStop()
        }
        private func signalReady() {
            let callback = lock.withLock { let value = ready; ready = nil; return value }
            callback?()
        }
        private func finishStop() {
            let callback = lock.withLock { () -> (@Sendable () -> Void)? in
                guard stopping, cancelled, connections.isEmpty else { return nil }
                let value = stopped; stopped = nil; return value
            }
            callback?()
        }
        private func accept(_ connection: NWConnection) {
            let id = UUID()
            let accepted = lock.withLock {
                guard !stopping else { return false }
                connections[id] = connection
                return true
            }
            guard accepted else { connection.cancel(); return }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed: connection.cancel()
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    _ = self.lock.withLock { self.connections.removeValue(forKey: id) }
                    self.finishStop()
                default: break
                }
            }
            connection.start(queue: queue)
            receive(connection, bytes: Data())
        }
        private func receive(_ connection: NWConnection, bytes: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
                guard let self else { connection.cancel(); return }
                var current = bytes
                if let data { current.append(data) }
                guard error == nil, current.count < 65_536 else { connection.cancel(); return }
                if let boundary = current.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(decoding: current[..<boundary.lowerBound], as: UTF8.self)
                    let lines = headers.components(separatedBy: "\r\n")
                    var contentLength = 0
                    var contentType = ""
                    for line in lines.dropFirst() {
                        let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                        guard pair.count == 2 else { connection.cancel(); return }
                        if pair[0].lowercased() == "content-length" {
                            guard let parsed = Int(pair[1].trimmingCharacters(in: .whitespaces)), (0..<65_536).contains(parsed) else { connection.cancel(); return }
                            contentLength = parsed
                        }
                        if pair[0].lowercased() == "content-type" { contentType = pair[1].trimmingCharacters(in: .whitespaces) }
                    }
                    guard current.count >= boundary.upperBound + contentLength else {
                        if !done { self.receive(connection, bytes: current) } else { connection.cancel() }
                        return
                    }
                    let method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
                    let bodyText = String(decoding: current[boundary.upperBound..<(boundary.upperBound + contentLength)], as: UTF8.self)
                    let accepted = self.lock.withLock {
                        self.count += 1; self.methods.append(method); self.bodies.append(bodyText); self.contentTypes.append(contentType)
                        return self.count <= 16
                    }
                    guard accepted else { connection.cancel(); return }
                    let body = "<html>synthetic-await-body</html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
                } else if !done { self.receive(connection, bytes: current) }
                else { connection.cancel() }
            }
        }
    }

    private final class OriginalBrowserEffects: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ effects: [String]) { lock.withLock { values = effects } }
        func snapshot() -> [String] { lock.withLock { values } }
    }

    private func exercise(_ fixture: Fixture, source: String? = nil, loginUi: String? = nil, loginUrl: String? = nil,
        script: String, expected: String) async throws {
        let source = source ?? fixture.a
        let process = LegadoRuntimeProcess.shared
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
        await process.revokePersistentSource(owner: owner)
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
        let loginDefaults: UserDefaults
        let login: LoginManager
        private let loginSuite: String
        init() throws {
            let id = UUID().uuidString.lowercased()
            a = "https://native-login-a-\(id).invalid"; b = "https://native-login-b-\(id).invalid"
            loginSuite = "native.login.owner." + id
            loginDefaults = try XCTUnwrap(UserDefaults(suiteName: loginSuite))
            // Real sessions use the existing process Host and its App owner.
            // This independent defaults suite is only for Keychain reopen probes.
            login = .shared
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
                login.removeLoginHeader(sourceUrl: source)
                UserDefaults(suiteName: "com.yuedu.cache." + source)?.removePersistentDomain(forName: "com.yuedu.cache." + source)
            }
            loginDefaults.removePersistentDomain(forName: loginSuite)
        }
    }

    /// Observes only this synthetic account's real accepted-write notification.
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
