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
    func sendAnisette(_ request: SelfRenewalAnisetteRequest) async throws -> SelfRenewalDeveloperAccountResponse
    func openAnisetteProvisioning(_ configuration: SelfRenewalAnisetteV3Configuration) async throws -> any SelfRenewalAnisetteProvisioningSocket
}
extension SelfRenewalDeveloperAccountTransport {
    // Existing account-only fixtures remain account-only. They cannot silently
    // stand in for an implemented remote registration protocol.
    func sendAnisette(_ request: SelfRenewalAnisetteRequest) async throws -> SelfRenewalDeveloperAccountResponse {
        throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
    }
    func openAnisetteProvisioning(_ configuration: SelfRenewalAnisetteV3Configuration) async throws -> any SelfRenewalAnisetteProvisioningSocket {
        throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
    }
}

/// One injected transport owns account networking. ADI/developer services reuse
/// its session; each allowlisted GSA auth request gets an isolated connection.
/// Book-source cookies, global credentials and caches never join these sessions.
final class SelfRenewalDeveloperURLSessionTransport: @unchecked Sendable, SelfRenewalDeveloperAccountTransport {
    private let session: URLSession
    private let delegate: Delegate
    #if DEBUG
    enum GSASessionEvent: Sendable { case created, invalidated }
    private let gsaSessionObservation: (@Sendable (GSASessionEvent, URLSession) -> Void)?
    #endif
    init() {
        let ownedDelegate = Delegate(); delegate = ownedDelegate
        let configuration = Self.sessionConfiguration()
        session = URLSession(configuration: configuration, delegate: ownedDelegate, delegateQueue: nil)
        #if DEBUG
        gsaSessionObservation = nil
        #endif
    }
    #if DEBUG
    /// Same actual URLSession transport, intercepted by an owned URLProtocol.
    /// No alternate HTTP host, skipped TLS result or simulated Apple authority.
    init(protocolClasses: [AnyClass], gsaSessionObservation: (@Sendable (GSASessionEvent, URLSession) -> Void)? = nil) {
        let ownedDelegate = Delegate(); delegate = ownedDelegate
        let configuration = Self.sessionConfiguration(protocolClasses: protocolClasses)
        session = URLSession(configuration: configuration, delegate: ownedDelegate, delegateQueue: nil)
        self.gsaSessionObservation = gsaSessionObservation
    }
    #endif
    deinit { session.invalidateAndCancel() }

    private static func sessionConfiguration(protocolClasses: [AnyClass]? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 30
        configuration.protocolClasses = protocolClasses
        return configuration
    }

    func send(_ request: URLRequest) async throws -> SelfRenewalDeveloperAccountResponse {
        guard let url = request.url, url.scheme == "https", url.port == nil, url.user == nil, url.password == nil,
              Self.allowedEndpoint(url, method: request.httpMethod) else {
            throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        if url.path == "/services/v1/certificates" {
            guard request.value(forHTTPHeaderField: "X-HTTP-Method-Override") == "GET",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json",
                  request.value(forHTTPHeaderField: "Accept") == "application/vnd.api+json" else {
                throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
            }
        }
        // This follows the allowlist above, so only the three existing GSA auth
        // routes enter here. ADI provisioning uses sendAnisette's shared session.
        if url.host == "gsa.apple.com" {
            return try await performGSAAuthentication(request)
        }
        return try await perform(request, maximum: SelfRenewalDERPropertyList.Limits.bytes)
    }

    func sendAnisette(_ input: SelfRenewalAnisetteRequest) async throws -> SelfRenewalDeveloperAccountResponse {
        var request: URLRequest
        switch input {
        case .clientInfo(let configuration):
            try configuration.validate()
            request = URLRequest(url: configuration.url("/v3/client_info")); request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        case .headers(let configuration, let identifier, let adiPB):
            try configuration.validate()
            guard identifier.count == 16, (1...SelfRenewalAnisetteV3Provider.maximumBlobBytes).contains(adiPB.count) else {
                throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
            }
            request = URLRequest(url: configuration.url("/v3/get_headers")); request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject:
                ["identifier": identifier.base64EncodedString(), "adi_pb": adiPB.base64EncodedString()], options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        case .appleLookup(let metadata):
            request = try Self.appleProvisioningRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!, metadata: metadata)
            request.httpMethod = "GET"
        case .appleStart(let url, let metadata):
            guard url.absoluteString == "https://gsa.apple.com/grandslam/MidService/startMachineProvisioning" else {
                throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
            }
            request = try Self.appleProvisioningRequest(url: url, metadata: metadata); request.httpMethod = "POST"
            request.httpBody = try PropertyListSerialization.data(fromPropertyList:
                ["Header": [String: String](), "Request": [String: String]()] as [String: Any], format: .xml, options: 0)
        case .appleFinish(let url, let metadata, let cpim):
            guard url.absoluteString == "https://gsa.apple.com/grandslam/MidService/finishMachineProvisioning",
                  cpim.utf8.count <= 87_384, let bytes = Data(base64Encoded: cpim), !bytes.isEmpty,
                  bytes.count <= SelfRenewalAnisetteV3Provider.maximumBlobBytes, bytes.base64EncodedString() == cpim else {
                throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
            }
            request = try Self.appleProvisioningRequest(url: url, metadata: metadata); request.httpMethod = "POST"
            request.httpBody = try PropertyListSerialization.data(fromPropertyList:
                ["Header": [String: String](), "Request": ["cpim": cpim]] as [String: Any], format: .xml, options: 0)
        }
        request.timeoutInterval = 30
        return try await perform(request, maximum: SelfRenewalAnisetteV3Provider.maximumRecordBytes)
    }

    func openAnisetteProvisioning(_ configuration: SelfRenewalAnisetteV3Configuration) async throws -> any SelfRenewalAnisetteProvisioningSocket {
        try Task.checkCancellation(); try configuration.validate()
        let url = configuration.url("/v3/provisioning_session", webSocket: true)
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = SelfRenewalAnisetteV3Provider.maximumRecordBytes
        task.resume()
        return ProvisioningSocket(task: task, url: url)
    }

    private static func appleProvisioningRequest(url: URL, metadata: SelfRenewalAnisetteRequest.Metadata) throws -> URLRequest {
        let values = [metadata.clientInfo, metadata.userAgent, metadata.localUserID, metadata.deviceID]
        guard metadata.issuedAt.timeIntervalSince1970.isFinite,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 && $0.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) }) else {
            throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        var request = URLRequest(url: url)
        let headers = ["X-Mme-Client-Info": metadata.clientInfo, "User-Agent": metadata.userAgent,
            "Content-Type": "text/x-xml-plist", "X-Apple-I-MD-LU": metadata.localUserID,
            "X-Mme-Device-Id": metadata.deviceID, "X-Apple-I-Client-Time": ISO8601DateFormatter().string(from: metadata.issuedAt),
            "X-Apple-I-TimeZone": "UTC", "X-Apple-Locale": "en_US"]
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private func perform(_ request: URLRequest, maximum: Int) async throws -> SelfRenewalDeveloperAccountResponse {
        try await perform(request, maximum: maximum, session: session, delegate: delegate)
    }

    private func performGSAAuthentication(_ request: URLRequest) async throws -> SelfRenewalDeveloperAccountResponse {
        guard !Task.isCancelled else { throw SelfRenewalDeveloperAccountTransportFailure.cancelled }
        // Apple's edge can reject later requests on a pooled GSA connection.
        // Isolate each request, never retry it or weaken its HTTPS/security path.
        // Remove only when the upstream connection restriction no longer holds.
        // https://github.com/xtool-org/xtool/pull/247
        // https://github.com/rileytestut/AltSign/pull/52
        let configuration = Self.sessionConfiguration(protocolClasses: session.configuration.protocolClasses)
        configuration.httpMaximumConnectionsPerHost = 1
        #if DEBUG
        let ownedDelegate = Delegate(gsaSessionObservation: gsaSessionObservation)
        #else
        let ownedDelegate = Delegate()
        #endif
        let ownedSession = URLSession(configuration: configuration, delegate: ownedDelegate, delegateQueue: nil)
        #if DEBUG
        gsaSessionObservation?(.created, ownedSession)
        #endif
        let result: Result<SelfRenewalDeveloperAccountResponse, Error>
        do { result = .success(try await perform(request, maximum: SelfRenewalDERPropertyList.Limits.bytes, session: ownedSession, delegate: ownedDelegate)) }
        catch { result = .failure(error) }
        // Await the real invalidation callback on success, rejection or cancel;
        // no request-scoped session remains alive until transport deinitializes.
        await ownedDelegate.finishAndAwaitInvalidation(ownedSession)
        return try result.get()
    }

    private func perform(_ request: URLRequest, maximum: Int, session: URLSession, delegate: Delegate) async throws -> SelfRenewalDeveloperAccountResponse {
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

    private final class ProvisioningSocket: SelfRenewalAnisetteProvisioningSocket, @unchecked Sendable {
        let task: URLSessionWebSocketTask
        let url: URL
        init(task: URLSessionWebSocketTask, url: URL) { self.task = task; self.url = url }
        func receive() async throws -> Data {
            let message = try await withTaskCancellationHandler(operation: { try await task.receive() },
                onCancel: { self.task.cancel(with: .goingAway, reason: nil) })
            var handshake = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            handshake.scheme = "https"
            guard let response = task.response as? HTTPURLResponse, response.statusCode == 101,
                  task.originalRequest?.url == url,
                  response.url == url || response.url == handshake.url else { throw SelfRenewalDeveloperAccountTransportFailure.response }
            guard case .string(let value) = message else { throw SelfRenewalDeveloperAccountTransportFailure.response }
            let bytes = Data(value.utf8)
            guard bytes.count <= SelfRenewalAnisetteV3Provider.maximumRecordBytes else { throw SelfRenewalDeveloperAccountTransportFailure.responseLimit }
            return bytes
        }
        func send(_ data: Data) async throws {
            guard data.count <= SelfRenewalAnisetteV3Provider.maximumRecordBytes,
                  let value = String(data: data, encoding: .utf8) else { throw SelfRenewalDeveloperAccountTransportFailure.responseLimit }
            try await withTaskCancellationHandler(operation: { try await task.send(.string(value)) },
                onCancel: { self.task.cancel(with: .goingAway, reason: nil) })
        }
        func close() async {
            // A bounded handshake observation only: no URL, headers or body.
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            AppLogger.parse("Renewal anisette socket close httpStatus=\(status)")
            task.cancel(with: .normalClosure, reason: nil)
        }
    }
    private static func allowedEndpoint(_ url: URL, method: String?) -> Bool {
        if url.host == "developerservices2.apple.com" {
            if url.absoluteString == "https://developerservices2.apple.com/services/v1/certificates" { return method == "POST" }
            return url.path.hasPrefix("/services/QH65B2/") && method == "POST"
        }
        guard url.host == "gsa.apple.com", url.query == nil, url.fragment == nil else { return false }
        switch (url.absoluteString, method) {
        case ("https://gsa.apple.com/grandslam/GsService2", "POST"),
             ("https://gsa.apple.com/auth/verify/trusteddevice", "GET"),
             ("https://gsa.apple.com/grandslam/GsService2/validate", "GET"): return true
        default: return false
        }
    }
    private final class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let invalidationLock = NSLock()
        private var invalidation: CheckedContinuation<Void, Never>?
        private var invalidated = false
        #if DEBUG
        private let gsaSessionObservation: (@Sendable (GSASessionEvent, URLSession) -> Void)?
        init(gsaSessionObservation: (@Sendable (GSASessionEvent, URLSession) -> Void)? = nil) {
            self.gsaSessionObservation = gsaSessionObservation
            super.init()
        }
        #endif

        func finishAndAwaitInvalidation(_ session: URLSession) async {
            await withCheckedContinuation { continuation in
                invalidationLock.lock()
                precondition(invalidation == nil)
                if invalidated {
                    invalidationLock.unlock()
                    continuation.resume()
                    return
                }
                invalidation = continuation
                invalidationLock.unlock()
                session.finishTasksAndInvalidate()
            }
        }

        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
            #if DEBUG
            gsaSessionObservation?(.invalidated, session)
            #endif
            invalidationLock.lock()
            invalidated = true
            let completion = invalidation
            invalidation = nil
            invalidationLock.unlock()
            completion?.resume()
        }

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
