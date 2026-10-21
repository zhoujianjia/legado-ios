import Foundation
@preconcurrency import Network
import WebKit
import XCTest

/// Standalone test-only candidate, NOT registered in the current target/controls.
/// Uses an additional WebKit-managed extension background context. It executes
/// only owned fixture code and never invokes source rules, HTTP/Cookie owners,
/// original JVM policy, a private WebKit API, or a replacement production loader.
final class LegadoNativeWebRequestCharacterizationTests: XCTestCase {
    func testPublicWebRequestCharacterizesOwnedFramesResourcesAndObserverCancellation() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("UNSUPPORTED_PUBLIC_API: WKWebExtension requires iOS 18.4; this is not a resource-compatibility pass")
        }
        executionTimeAllowance = 120
        let nonce = UUID().uuidString.lowercased()
        let peer = try WebRequestOwnedPeer(nonce: nonce)
        let listening = expectation(description: "Owned loopback listener ready")
        peer.start { listening.fulfill() }
        await fulfillment(of: [listening], timeout: 10)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("webrequest-" + nonce, isDirectory: true)
        var probe: PublicWebRequestProbe?
        var failure: Error?
        do {
            let origins = try peer.origins()
            try await Task.detached { try PublicWebRequestFixtures.writeExtension(to: directory, nonce: nonce) }.value
            let ready = expectation(description: "Exact extension context registered real webRequest listeners")
            let page = expectation(description: "Owned parent child worker image redirect and cache completed")
            let held = expectation(description: "Real resource native message awaiting its ACK")
            let stopped = expectation(description: "Exact background removed listeners after stop ACK")
            let redirect = expectation(description: "Actual extension HTTP redirect event")
            let routes = ["parent", "child", "child-only", "image", "redirect", "redirect-target", "worker.js", "worker-only", "cache"]
            let events = routes.map { expectation(description: "Actual webRequest before: " + $0) }
            let current = try await PublicWebRequestProbe(directory: directory, nonce: nonce,
                origin: origins.parent, childOrigin: origins.child, ready: ready, page: page,
                held: held, stopped: stopped, redirect: redirect, required: Dictionary(uniqueKeysWithValues: zip(routes, events)))
            probe = current
            await fulfillment(of: [ready], timeout: 15)
            try await current.navigate()
            await fulfillment(of: [page, redirect] + events, timeout: 25)
            let first = await current.snapshot()
            XCTAssertNil(first.failure)
            XCTAssertEqual(first.contextErrors, [])
            XCTAssertTrue(first.ready)
            XCTAssertTrue(first.pageFinished)
            let child = try XCTUnwrap(first.events.first { $0.event == "before" && $0.route == "child" })
            let nested = try XCTUnwrap(first.events.first { $0.event == "before" && $0.route == "child-only" })
            XCTAssertEqual(child.type, "sub_frame")
            XCTAssertGreaterThan(child.frameID, 0)
            XCTAssertEqual(nested.frameID, child.frameID)
            XCTAssertFalse(first.parentTiming.contains { $0.contains("/child-only?") })
            XCTAssertFalse(first.parentTiming.contains { $0.contains("/worker-only?") })
            XCTAssertTrue(first.events.allSatisfy { !$0.requestID.isEmpty && $0.timeStamp > 0 })
            XCTAssertTrue(first.events.contains { $0.event == "redirect" && $0.route == "redirect" && $0.redirectURL == origins.child + "/redirect-target?n=" + nonce })
            let requests = peer.requests()
            for route in routes where route != "cache" { XCTAssertEqual(requests[route], 1, route) }
            XCTAssertTrue((1...2).contains(requests["cache"] ?? 0))
            // Cache-repeat event count and event timing are observations, not
            // assumptions of Android onLoadResource equivalence.
            try await current.beginCancellationFetch()
            await fulfillment(of: [held], timeout: 10)
            try await current.sealAndStop()
            await fulfillment(of: [stopped], timeout: 10)
            try await current.unload()
            let final = await current.snapshot()
            XCTAssertTrue(final.stopped)
            XCTAssertFalse(final.loaded)
            XCTAssertEqual(final.heldReplies, 0)
        } catch { failure = error }
        if let probe {
            do { try await probe.unload() }
            catch {
                if failure == nil { failure = error }
                else { XCTFail("Secondary public extension cleanup failed: \((error as NSError).domain)/\((error as NSError).code)") }
            }
            do {
                let snapshot = await probe.snapshot()
                let report = try await Task.detached { try JSONEncoder().encode(WebRequestProbeReport(
                    observation: snapshot, actualHTTP: peer.requests(), fixtureErrors: peer.errors(), extraBackgroundContext: true)) }.value
                let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
                attachment.name = "owned-webrequest-observations.json"
                attachment.lifetime = .keepAlways
                add(attachment)
            } catch { if failure == nil { failure = error } else { XCTFail("Secondary observation encoding failed") } }
        }
        let ended = expectation(description: "Owned loopback listener and accepted connections drained")
        peer.stop { ended.fulfill() }
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertEqual(peer.errors(), [])
        do {
            try await Task.detached {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            }.value
        } catch { if failure == nil { failure = error } else { XCTFail("Secondary owned fixture cleanup failed") } }
        if let failure { throw failure }
    }
}

private enum WebRequestProbeError: Error { case failed(String) }
private struct WebRequestEvent: Codable, Sendable {
    let event: String, route: String, url: String, type: String, requestID: String
    let redirectURL: String?, frameID: Int, parentFrameID: Int, tabID: Int
    let timeStamp: Double, fromCache: Bool?, nativeOrdinal: Int
}
private struct WebRequestSnapshot: Codable, Sendable {
    let ready: Bool, pageFinished: Bool, stopped: Bool, loaded: Bool
    let heldReplies: Int, rejectedAfterSeal: Int, failure: String?
    let parentTiming: [String], events: [WebRequestEvent]
    let contextErrors: [String]
}
private struct WebRequestProbeReport: Codable, Sendable {
    let observation: WebRequestSnapshot
    let actualHTTP: [String: Int]
    let fixtureErrors: [String]
    let extraBackgroundContext: Bool
}

@available(iOS 18.4, *)
@MainActor
private final class PublicWebRequestProbe: NSObject, WKWebExtensionControllerDelegate,
    WKWebExtensionTab, WKWebExtensionWindow, WKScriptMessageHandler {
    private let controller: WKWebExtensionController
    private let context: WKWebExtensionContext
    private let view: WKWebView
    private let nonce: String
    private let origin: String
    private let childOrigin: String
    private let readySignal: XCTestExpectation, pageSignal: XCTestExpectation
    private let heldSignal: XCTestExpectation, stoppedSignal: XCTestExpectation, redirectSignal: XCTestExpectation
    private var required: [String: XCTestExpectation]
    private var ready = false, pageFinished = false, closing = false, stopped = false, redirected = false
    private var failure: String?
    private var timing: [String] = []
    private var events: [WebRequestEvent] = []
    private var heldReply: ((Any?, Error?) -> Void)?
    private var rejectedAfterSeal = 0

    init(directory: URL, nonce: String, origin: String, childOrigin: String,
         ready: XCTestExpectation, page: XCTestExpectation, held: XCTestExpectation,
         stopped: XCTestExpectation, redirect: XCTestExpectation, required: [String: XCTestExpectation]) async throws {
        let ext = try await WKWebExtension(resourceBaseURL: directory)
        guard ext.errors.isEmpty else { throw WebRequestProbeError.failed("Owned manifest errors") }
        let storage = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = storage
        let ownedController = WKWebExtensionController(configuration: configuration)
        let ownedContext = WKWebExtensionContext(for: ext)
        ownedContext.uniqueIdentifier = "owned-webrequest-" + nonce
        // Only this empty, test-owned non-persistent data store is admitted.
        // No real browser private window or existing Cookie data is consulted.
        ownedContext.hasAccessToPrivateData = true
        ownedContext.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission.webRequest)
        ownedContext.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission.nativeMessaging)
        ownedContext.setPermissionStatus(.grantedExplicitly, for: URL(string: origin)!)
        ownedContext.setPermissionStatus(.grantedExplicitly, for: URL(string: childOrigin)!)
        let web = WKWebViewConfiguration()
        web.websiteDataStore = storage
        web.webExtensionController = ownedController
        view = WKWebView(frame: .zero, configuration: web)
        controller = ownedController
        context = ownedContext
        self.nonce = nonce; self.origin = origin; self.childOrigin = childOrigin
        readySignal = ready; pageSignal = page; heldSignal = held; stoppedSignal = stopped; redirectSignal = redirect
        self.required = required
        super.init()
        controller.delegate = self
        view.configuration.userContentController.add(self, name: "ownedFixture")
        do {
            try controller.load(context)
            controller.didOpenWindow(self)
            controller.didOpenTab(self)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                context.loadBackgroundContent { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            let primary = error
            do { try unload() }
            catch { throw WebRequestProbeError.failed("EXTENSION_SETUP_AND_CLEANUP_FAILED") }
            throw primary
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [self] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [self] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { self }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { view }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { true }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }

    func navigate() throws {
        guard ready, !closing, context.isLoaded else { throw WebRequestProbeError.failed("No extension ready ACK") }
        view.load(URLRequest(url: URL(string: origin + "/parent?n=" + nonce)!))
    }
    func beginCancellationFetch() async throws {
        guard !closing, heldReply == nil else { throw WebRequestProbeError.failed("Invalid cancellation phase") }
        try await evaluate("window.ownedCancel=new AbortController();void fetch('/cancel?n=\(nonce)',{signal:window.ownedCancel.signal}).catch(()=>{});")
    }
    func sealAndStop() async throws {
        guard let reply = heldReply else { throw WebRequestProbeError.failed("No real held native ACK") }
        closing = true
        do { try await evaluate("window.ownedCancel.abort();") }
        catch { heldReply = nil; reply(nil, error); throw error }
        view.stopLoading()
        heldReply = nil
        reply(["stop": true], nil)
    }
    private func evaluate(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            view.evaluateJavaScript(script) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func unload() throws {
        closing = true
        if let reply = heldReply { heldReply = nil; reply(nil, WebRequestProbeError.failed("CANCELLED")) }
        view.stopLoading()
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "ownedFixture")
            controller.delegate = nil
        }
        if context.isLoaded { try controller.unload(context) }
        guard !context.isLoaded else { throw WebRequestProbeError.failed("Extension unload not acknowledged") }
    }
    func snapshot() -> WebRequestSnapshot {
        .init(ready: ready, pageFinished: pageFinished, stopped: stopped, loaded: context.isLoaded,
            heldReplies: heldReply == nil ? 0 : 1, rejectedAfterSeal: rejectedAfterSeal,
            failure: failure, parentTiming: timing, events: events,
            contextErrors: context.errors.map { "\(($0 as NSError).domain)/\(($0 as NSError).code)" })
    }

    func webExtensionController(_ sender: WKWebExtensionController, sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void) {
        guard sender === controller, extensionContext === context, applicationIdentifier == "owned.characterization",
              let packet = message as? [String: Any], packet["nonce"] as? String == nonce,
              let kind = packet["kind"] as? String else {
            replyHandler(nil, WebRequestProbeError.failed("Foreign extension packet")); return
        }
        if kind == "stopped", closing, !stopped {
            stopped = true; stoppedSignal.fulfill(); replyHandler(["accepted": true], nil); return
        }
        guard !closing, context.isLoaded else {
            rejectedAfterSeal += 1; replyHandler(["stop": true], nil); return
        }
        if kind == "ready", !ready {
            ready = true; readySignal.fulfill(); replyHandler(["accepted": true], nil); return
        }
        guard kind == "event", events.count < 256, let rawURL = packet["url"] as? String,
              rawURL.utf8.count < 4096, let url = URL(string: rawURL),
              (rawURL.hasPrefix(origin + "/") || rawURL.hasPrefix(childOrigin + "/")),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "n" && $0.value == nonce }) == true,
              let event = packet["event"] as? String, let type = packet["type"] as? String,
              let requestID = packet["requestId"] as? String, requestID.utf8.count < 256,
              let frame = packet["frameId"] as? NSNumber, let parent = packet["parentFrameId"] as? NSNumber,
              let tab = packet["tabId"] as? NSNumber, let stamp = packet["timeStamp"] as? NSNumber else {
            failure = "INVALID_EXTENSION_EVENT"; replyHandler(nil, WebRequestProbeError.failed("Invalid owned event")); return
        }
        let route = String(url.path.dropFirst())
        events.append(.init(event: event, route: route, url: rawURL, type: type, requestID: requestID,
            redirectURL: packet["redirectUrl"] as? String, frameID: frame.intValue, parentFrameID: parent.intValue,
            tabID: tab.intValue, timeStamp: stamp.doubleValue, fromCache: packet["fromCache"] as? Bool, nativeOrdinal: events.count))
        if event == "before" { required.removeValue(forKey: route)?.fulfill() }
        if event == "redirect", route == "redirect", !redirected { redirected = true; redirectSignal.fulfill() }
        if route == "cancel", event == "before", heldReply == nil {
            heldReply = replyHandler; heldSignal.fulfill(); return
        }
        replyHandler(["accepted": true], nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closing, message.frameInfo.isMainFrame, let packet = message.body as? [String: Any],
              packet["nonce"] as? String == nonce, !pageFinished else { return }
        if packet["kind"] as? String == "done", let entries = packet["timing"] as? [String], entries.count < 64 {
            timing = entries; pageFinished = true; pageSignal.fulfill()
        } else { failure = "OWNED_PAGE_FAILED"; pageSignal.fulfill(); pageFinished = true }
    }
}

private enum PublicWebRequestFixtures {
    nonisolated static func writeExtension(to directory: URL, nonce: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Owned observation", "version": "1.0",
            "permissions": ["webRequest", "nativeMessaging"],
            "host_permissions": ["http://127.0.0.1/*", "http://localhost/*"],
            "background": ["scripts": ["background.js"], "type": "module"]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"))
        let script = """
        const nonce='\(nonce)', filter={urls:['http://127.0.0.1/*','http://localhost/*']};
        let chain=Promise.resolve(),stopped=false; const hooks=[];
        async function stop(){if(stopped)return;stopped=true;for(const [event,listener]of hooks)event.removeListener(listener);await browser.runtime.sendNativeMessage('owned.characterization',{kind:'stopped',nonce});}
        function enqueue(packet){chain=chain.then(async()=>{if(stopped)return;const ack=await browser.runtime.sendNativeMessage('owned.characterization',packet);if(ack?.stop)await stop();});}
        for(const [event,name]of [[browser.webRequest.onBeforeRequest,'before'],[browser.webRequest.onBeforeRedirect,'redirect'],[browser.webRequest.onCompleted,'completed'],[browser.webRequest.onErrorOccurred,'error']]){
          const listener=d=>enqueue({kind:'event',nonce,event:name,url:d.url,type:d.type,requestId:d.requestId,frameId:d.frameId,parentFrameId:d.parentFrameId,tabId:d.tabId,timeStamp:d.timeStamp,redirectUrl:d.redirectUrl??null,fromCache:d.fromCache??null});
          event.addListener(listener,filter);hooks.push([event,listener]);
        }
        enqueue({kind:'ready',nonce});
        """
        try Data(script.utf8).write(to: directory.appendingPathComponent("background.js"))
    }
    nonisolated static func response(route: String, parent: String, child: String, nonce: String) throws -> (String, Data, String) {
        let q = "?n=" + nonce
        switch route {
        case "parent":
            let html = """
            <!doctype html><script>
            const q='\(q)';
            const child=new Promise(resolve=>addEventListener('message',e=>{if(e.origin==='\(child)'&&e.data===q)resolve();}));
            const image=new Promise((resolve,reject)=>{const i=new Image();i.onload=resolve;i.onerror=reject;i.src='/image'+q;});
            const worker=new Promise((resolve,reject)=>{const w=new Worker('/worker.js'+q);w.onmessage=()=>{w.terminate();resolve();};w.onerror=reject;});
            const redirect=fetch('/redirect'+q).then(r=>r.text());
            const cache=fetch('/cache'+q,{cache:'force-cache'}).then(r=>r.text()).then(()=>fetch('/cache'+q,{cache:'force-cache'})).then(r=>r.text());
            Promise.all([child,image,worker,redirect,cache]).then(()=>window.webkit.messageHandlers.ownedFixture.postMessage({kind:'done',nonce:'\(nonce)',timing:performance.getEntriesByType('resource').map(e=>e.name)})).catch(()=>window.webkit.messageHandlers.ownedFixture.postMessage({kind:'error',nonce:'\(nonce)'}));
            </script><iframe src='\(child)/child\(q)'></iframe>
            """
            return ("text/html", Data(html.utf8), "Cache-Control: no-store\r\n")
        case "child":
            return ("text/html", Data("<script>fetch('/child-only\(q)').then(r=>r.text()).then(()=>parent.postMessage('\(q)','\(parent)'));</script>".utf8), "Cache-Control: no-store\r\n")
        case "worker.js": return ("text/javascript", Data("fetch('/worker-only\(q)').then(r=>r.text()).then(()=>postMessage('done'));".utf8), "Cache-Control: no-store\r\n")
        case "image": return ("image/gif", Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!, "Cache-Control: no-store\r\n")
        case "cache": return ("text/plain", Data("owned-cache".utf8), "Cache-Control: public, max-age=3600\r\n")
        case "child-only", "worker-only", "redirect-target", "cancel": return ("text/plain", Data("owned".utf8), "Cache-Control: no-store\r\n")
        default: throw WebRequestProbeError.failed("Unknown owned route")
        }
    }
}

/// Test-only peer serves existing WK requests. No URLSession/proxy re-fetch.
private final class WebRequestOwnedPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "owned.webrequest.peer")
    private let lock = NSLock()
    private let nonce: String
    private var connections: [UUID: NWConnection] = [:]
    private var counts: [String: Int] = [:]
    private var failures: [String] = []
    private var ready: (() -> Void)?, ended: (() -> Void)?
    private var stopping = false, cancelled = false
    init(nonce: String) throws {
        self.nonce = nonce
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(ready: @escaping () -> Void) {
        lock.withLock { self.ready = ready }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { let callback = self.lock.withLock { let c=self.ready;self.ready=nil;return c };callback?() }
            if case .cancelled = state { self.lock.withLock { self.cancelled=true };self.finish() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    func origins() throws -> (parent: String, child: String) {
        guard let port=listener.port else { throw WebRequestProbeError.failed("Loopback not ready") }
        return ("http://127.0.0.1:\(port.rawValue)", "http://localhost:\(port.rawValue)")
    }
    func requests() -> [String: Int] { lock.withLock { counts } }
    func errors() -> [String] { lock.withLock { failures } }
    func stop(completed: @escaping () -> Void) {
        let all=lock.withLock { stopping=true;ended=completed;return Array(connections.values) }
        listener.newConnectionHandler=nil;listener.cancel();all.forEach { $0.cancel() };finish()
    }
    private func finish() {
        let callback=lock.withLock { () -> (() -> Void)? in guard stopping,cancelled,connections.isEmpty else{return nil};let c=ended;ended=nil;return c }
        callback?()
    }
    private func accept(_ connection: NWConnection) {
        let id=UUID()
        let accepted=lock.withLock { () -> Bool in guard !stopping else{return false};connections[id]=connection;return true }
        guard accepted else { connection.cancel();return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else{return}
            if case .failed = state { connection.cancel() }
            if case .cancelled = state { _=self.lock.withLock { self.connections.removeValue(forKey:id) };self.finish() }
        }
        connection.start(queue:queue);receive(connection,id:id,bytes:Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] part,_,done,error in
            guard let self else{connection.cancel();return}
            var data=bytes;if let part { data.append(part) }
            guard error == nil,data.count < 16_384 else{connection.cancel();return}
            if data.range(of:Data("\r\n\r\n".utf8)) != nil {
                do { try self.respond(connection,data:data) }
                catch { self.lock.withLock { self.failures.append(String(describing:error)) };connection.cancel() }
            } else if !done { self.receive(connection,id:id,bytes:data) } else { connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, data: Data) throws {
        guard let text=String(data:data,encoding:.utf8),let line=text.components(separatedBy:"\r\n").first else{throw WebRequestProbeError.failed("Invalid request")}
        let fields=line.split(separator:" ")
        guard fields.count==3,fields[0]=="GET",let parts=URLComponents(string:String(fields[1])),
              parts.queryItems?.contains(where:{$0.name=="n"&&$0.value==nonce})==true else{throw WebRequestProbeError.failed("Unowned request")}
        let route=String(parts.path.dropFirst()),bases=try origins()
        let count=lock.withLock { counts[route,default:0]+=1;return counts.values.reduce(0,+) }
        guard count<=32 else{throw WebRequestProbeError.failed("HTTP fixture limit")}
        let status: String,content: Data,headers: String,mime: String
        if route=="redirect" { status="302 Found";content=Data();mime="text/plain";headers="Location: \(bases.child)/redirect-target?n=\(nonce)\r\nCache-Control: no-store\r\n" }
        else { let response=try PublicWebRequestFixtures.response(route:route,parent:bases.parent,child:bases.child,nonce:nonce);status="200 OK";mime=response.0;content=response.1;headers=response.2 }
        var packet=Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(content.count)\r\nAccess-Control-Allow-Origin: *\r\n\(headers)Connection: close\r\n\r\n".utf8)
        packet.append(content)
        connection.send(content:packet,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed {_ in connection.cancel()})
    }
}
