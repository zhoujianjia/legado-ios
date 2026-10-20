import Foundation

struct SelfRenewalDeveloperAccountResponse: Sendable {
    let statusCode: Int
    let body: Data
}
enum SelfRenewalDeveloperAccountTransportFailure: Int, Error, Sendable {
    case cancelled = 1, network, wrongEndpoint, responseLimit, redirect, response
}
protocol SelfRenewalDeveloperAccountTransport: Sendable {
    func send(_ request: URLRequest) async throws -> SelfRenewalDeveloperAccountResponse
}

/// The account client's one reused ephemeral session. Book-source cookies,
/// global credentials and caches are deliberately not account credentials.
final class SelfRenewalDeveloperURLSessionTransport: @unchecked Sendable, SelfRenewalDeveloperAccountTransport {
    private let session: URLSession
    private let delegate = Delegate()
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }
    #if DEBUG
    /// Same actual URLSession transport, intercepted by an owned URLProtocol.
    /// No alternate HTTP host, skipped TLS result or simulated Apple authority.
    init(protocolClasses: [AnyClass]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 30
        configuration.protocolClasses = protocolClasses
        session = URLSession(configuration: configuration)
    }
    #endif
    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> SelfRenewalDeveloperAccountResponse {
        let maximum = SelfRenewalDERPropertyList.Limits.bytes
        guard let url = request.url, url.scheme == "https", url.port == nil, url.user == nil, url.password == nil,
              Self.allowedEndpoint(url, method: request.httpMethod) else {
            throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        do {
            try Task.checkCancellation()
            let (stream, response) = try await session.bytes(for: request, delegate: delegate)
            // Close this actual owned task on every response-limit, redirect,
            // parse or cancellation exit; no abandoned response keeps draining.
            defer { stream.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw SelfRenewalDeveloperAccountTransportFailure.response
            }
            guard !(300...399).contains(http.statusCode) else { throw SelfRenewalDeveloperAccountTransportFailure.redirect }
            guard response.expectedContentLength <= Int64(maximum) else { throw SelfRenewalDeveloperAccountTransportFailure.responseLimit }
            var body = Data(); body.reserveCapacity(min(maximum, 65_536))
            for try await byte in stream {
                try Task.checkCancellation()
                guard body.count < maximum else { throw SelfRenewalDeveloperAccountTransportFailure.responseLimit }
                body.append(byte)
            }
            return SelfRenewalDeveloperAccountResponse(statusCode: http.statusCode, body: body)
        } catch is CancellationError { throw SelfRenewalDeveloperAccountTransportFailure.cancelled }
        catch let error as SelfRenewalDeveloperAccountTransportFailure { throw error }
        catch let error as URLError where error.code == .cancelled { throw SelfRenewalDeveloperAccountTransportFailure.cancelled }
        catch { throw SelfRenewalDeveloperAccountTransportFailure.network }
    }
    private static func allowedEndpoint(_ url: URL, method: String?) -> Bool {
        if url.host == "developerservices2.apple.com" { return url.path.hasPrefix("/services/QH65B2/") && method == "POST" }
        guard url.host == "gsa.apple.com", url.query == nil, url.fragment == nil else { return false }
        switch (url.absoluteString, method) {
        case ("https://gsa.apple.com/grandslam/GsService2", "POST"),
             ("https://gsa.apple.com/auth/verify/trusteddevice", "GET"),
             ("https://gsa.apple.com/grandslam/GsService2/validate", "GET"): return true
        default: return false
        }
    }
    private final class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // Never forward Apple session/anisette headers to a redirect target.
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Preserve the system's genuine HTTPS hostname/chain verification.
            // No trust-all credential, root override or interactive HTTP auth.
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .rejectProtectionSpace, nil)
        }
    }
}
