import Foundation

extension CookieStore {
    /// Uses the caller's existing URLSession/pool. Cookie ingestion is the only
    /// added concern; no session, parser or alternate HTTP path is constructed.
    func data(for request: URLRequest, session: URLSession,
              redirect: (@Sendable (URL) -> Bool)? = nil, authoredCookie: String? = nil) async throws -> (Data, URLResponse) {
        let cancellation = OriginalRuntimeCommitCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let managed = try await managedRequest(request)
            let delegate = CookieRequestDelegate(owner: self, original: request, authoredCookie: authoredCookie,
                cancellation: cancellation, allows: redirect)
            let result = try await session.data(for: managed, delegate: delegate)
            if let failure = delegate.failure { throw failure }
            try cancellation.check(deadline: .distantFuture)
            try await acceptResponse(result.1) { try cancellation.check(deadline: .distantFuture) }
            return result
        } onCancel: { cancellation.cancel() }
    }

    /// Source-script compatibility only. The async call and the Cookie actor
    /// carry the cancellation of this same caller; main never waits for them.
    func dataForScript(request: URLRequest, session: URLSession, timeout: TimeInterval) throws -> (Data, URLResponse) {
        guard !Thread.isMainThread else { throw CookieOwnerError(code: "STATE_THREAD", message: "Source HTTP requires a source-script worker") }
        let completion = DispatchSemaphore(value: 0)
        let box = CookieHTTPResult()
        let operation = Task.detached {
            do { box.set(.success(try await self.data(for: request, session: session, authoredCookie: request.value(forHTTPHeaderField: "Cookie")))) }
            catch { box.set(.failure(error)) }
            completion.signal()
        }
        guard completion.wait(timeout: .now() + timeout) == .success else {
            operation.cancel()
            throw URLError(.timedOut)
        }
        return try box.get().get()
    }

    fileprivate func managedRequest(_ request: URLRequest, authoredCookie: String? = nil, replaceCookie: Bool = false) async throws -> URLRequest {
        try await prepare()
        var result = request
        // This per-request switch also prevents implicit response-cookie writes,
        // including when an injected existing pool has automatic handling on.
        result.httpShouldHandleCookies = false
        if replaceCookie { result.setValue(nil, forHTTPHeaderField: "Cookie") }
        if let authoredCookie { result.setValue(authoredCookie, forHTTPHeaderField: "Cookie") }
        if result.value(forHTTPHeaderField: "Cookie") == nil, let url = result.url {
            result.setValue(try await requestHeader(url: url), forHTTPHeaderField: "Cookie")
        }
        return result
    }

    func acceptResponse(_ response: URLResponse, validate: @escaping @Sendable () throws -> Void = {}) async throws {
        guard let response = response as? HTTPURLResponse, let url = response.url,
              let fields = response.allHeaderFields as? [String: String] else { return }
        try await ingest(HTTPCookie.cookies(withResponseHeaderFields: fields, for: url),
            provenance: .httpResponse, originURL: url, validate: validate)
    }
}

private final class CookieHTTPResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<(Data, URLResponse), Error>?
    func set(_ result: Result<(Data, URLResponse), Error>) { lock.withLock { value = result } }
    func get() -> Result<(Data, URLResponse), Error> { lock.withLock { value! } }
}

private final class CookieRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let owner: CookieStore
    private let host: String?
    private let authoredCookie: String?
    private let cancellation: OriginalRuntimeCommitCancellation
    private let allows: (@Sendable (URL) -> Bool)?
    private let lock = NSLock()
    private var firstFailure: Error?
    var failure: Error? { lock.withLock { firstFailure } }

    init(owner: CookieStore, original: URLRequest, authoredCookie: String?, cancellation: OriginalRuntimeCommitCancellation,
         allows: (@Sendable (URL) -> Bool)?) {
        self.owner = owner; self.host = original.url?.host; self.authoredCookie = authoredCookie
        self.cancellation = cancellation; self.allows = allows
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        do {
            try cancellation.check(deadline: .distantFuture)
            try await owner.acceptResponse(response) { try self.cancellation.check(deadline: .distantFuture) }
            guard let target = request.url, allows?(target) != false else { return nil }
            let next = try await owner.managedRequest(request,
                authoredCookie: target.host == host ? authoredCookie : nil, replaceCookie: true)
            try cancellation.check(deadline: .distantFuture)
            return next
        } catch {
            lock.withLock { if firstFailure == nil { firstFailure = error } }
            return nil
        }
    }
}
