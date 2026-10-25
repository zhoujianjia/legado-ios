import CryptoKit
import Darwin
import Foundation
import Security

/// A single-owner BSD stream with an in-place, certificate-pinned TLS 1.2
/// upgrade. SecureTransport is public but deprecated on iOS 13; actual iOS 17
/// SDK/handshake acceptance remains a separate gate. There is no TLS downgrade,
/// DNS discovery, pairing-record lookup or device permission assertion here.
enum SelfRenewalAuthenticatedDeviceTransport {
    enum Failure: Error, Sendable, Equatable {
        case invalidEndpoint, invalidCredentials, invalidLimit
        case cancelled, deadlineExceeded, endOfStream, transferLimit
        case posix(Int32), tls(OSStatus), peerMismatch, peerTrustFailed
        case missingFreshAuthentication, missingMutualAuthentication
    }
    struct Endpoint: Sendable, Equatable {
        let numericAddress: String
        let port: UInt16
        let interfaceIndex: UInt32
        init(numericAddress: String, port: UInt16, interfaceIndex: UInt32 = 0) {
            self.numericAddress = numericAddress; self.port = port; self.interfaceIndex = interfaceIndex
        }
        func service(_ port: UInt16) -> Self {
            Self(numericAddress: numericAddress, port: port, interfaceIndex: interfaceIndex)
        }
    }
    /// Only a handle and public certificates are accepted; this layer never
    /// exports, persists or creates a host private key or reads a pairing file.
    struct PairingIdentity: @unchecked Sendable {
        let hostIdentity: SecIdentity
        let hostCertificateDER: Data
        let deviceCertificateDER: Data
        let rootCertificateDER: Data
        let hostID: String
        let systemBUID: String
        init(hostIdentity: SecIdentity, deviceCertificateDER: Data, rootCertificateDER: Data,
             hostID: String, systemBUID: String) throws {
            precondition(!Thread.isMainThread, "Pairing handle/Keychain validation must remain off main")
            guard [deviceCertificateDER, rootCertificateDER].allSatisfy({ !$0.isEmpty && $0.count <= 65_536 }),
                  [hostID, systemBUID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }),
                  SecCertificateCreateWithData(nil, deviceCertificateDER as CFData) != nil,
                  SecCertificateCreateWithData(nil, rootCertificateDER as CFData) != nil else { throw Failure.invalidCredentials }
            var certificate: SecCertificate?
            var key: SecKey?
            guard SecIdentityCopyCertificate(hostIdentity, &certificate) == errSecSuccess, let certificate,
                  SecIdentityCopyPrivateKey(hostIdentity, &key) == errSecSuccess, let key,
                  let publicKey = SecKeyCopyPublicKey(key), let certificateKey = SecCertificateCopyKey(certificate) else { throw Failure.invalidCredentials }
            var publicError: Unmanaged<CFError>?
            guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &publicError) as Data? else {
                if let publicError { _ = publicError.takeRetainedValue() }; throw Failure.invalidCredentials
            }
            guard let certificateBytes = SecKeyCopyExternalRepresentation(certificateKey, &publicError) as Data? else {
                if let publicError { _ = publicError.takeRetainedValue() }; throw Failure.invalidCredentials
            }
            guard publicBytes == certificateBytes else { throw Failure.invalidCredentials }
            let der = SecCertificateCopyData(certificate) as Data
            guard !der.isEmpty, der.count <= 65_536 else { throw Failure.invalidCredentials }
            self.hostIdentity = hostIdentity; hostCertificateDER = der
            self.deviceCertificateDER = deviceCertificateDER; self.rootCertificateDER = rootCertificateDER
            self.hostID = hostID; self.systemBUID = systemBUID
        }
    }
    /// Wakes the actual socket poll; cancellation does not wait for an idle
    /// network timeout. Pipe lifetime and writes are protected by this lock.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var reader: Int32 = -1
        private var writer: Int32 = -1
        init() {}
        func prepare() throws {
            lock.lock(); defer { lock.unlock() }
            if reader >= 0 { return }
            if stopped { throw Failure.cancelled }
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { throw Failure.posix(errno) }
            reader = descriptors[0]; writer = descriptors[1]
            for fd in descriptors {
                if fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 {
                    let code = errno; Darwin.close(reader); Darwin.close(writer)
                    reader = -1; writer = -1; throw Failure.posix(code)
                }
            }
        }
        deinit {
            lock.lock()
            if reader >= 0 { Darwin.close(reader) }
            if writer >= 0 { Darwin.close(writer) }
            lock.unlock()
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            if !stopped {
                stopped = true
                var byte: UInt8 = 1
                _ = Darwin.write(writer, &byte, 1)
            }
        }
        func check() throws {
            if isCancelled { throw Failure.cancelled }
        }
        var isCancelled: Bool { lock.lock(); let cancelled = stopped; lock.unlock(); return cancelled || Task.isCancelled }
        var descriptor: Int32 { reader }
    }
    struct Authentication: Sendable, Equatable {
        let peerCertificateSHA256: Data
        let rootCertificateSHA256: Data
        let negotiatedTLSVersion: String
        fileprivate init(peer: Data, root: Data) {
            peerCertificateSHA256 = Data(SHA256.hash(data: peer))
            rootCertificateSHA256 = Data(SHA256.hash(data: root))
            negotiatedTLSVersion = "TLS1.2"
        }
    }
    /// Not an actor: a single detached operation owns every method and the FD.
    /// Only Cancellation.cancel() may be invoked concurrently.
    final class Stream {
        private var authenticatedState: Authentication?
        var authentication: Authentication? {
            guard descriptor >= 0, !cancellation.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            return authenticatedState
        }
        let cancellation: Cancellation
        let deadline: UInt64
        private var descriptor: Int32
        private var context: SSLContext?
        private var callbackFailure: Failure?
        private var transferred: Int64 = 0
        private static let totalTransportBytes: Int64 = 1_342_177_280
        private static let handshakeBytes: Int64 = 1_179_648

        static func deadline(seconds: TimeInterval) throws -> UInt64 {
            guard seconds.isFinite, seconds > 0, seconds <= 900 else { throw Failure.invalidLimit }
            return DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        }
        init(endpoint: Endpoint, cancellation: Cancellation, deadline: UInt64) throws {
            precondition(!Thread.isMainThread, "Device stream I/O must remain off main")
            self.cancellation = cancellation; self.deadline = deadline
            try cancellation.prepare()
            guard endpoint.port > 0, !endpoint.numericAddress.isEmpty, endpoint.numericAddress.utf8.count <= 64,
                  !endpoint.numericAddress.utf8.contains(0) else { throw Failure.invalidEndpoint }
            var v4 = sockaddr_in(); v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            v4.sin_family = sa_family_t(AF_INET); v4.sin_port = endpoint.port.bigEndian
            var v6 = sockaddr_in6(); v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6); v6.sin6_port = endpoint.port.bigEndian
            v6.sin6_scope_id = endpoint.interfaceIndex
            let family: Int32
            if inet_pton(AF_INET, endpoint.numericAddress, &v4.sin_addr) == 1 { family = AF_INET }
            else if inet_pton(AF_INET6, endpoint.numericAddress, &v6.sin6_addr) == 1 { family = AF_INET6 }
            else { throw Failure.invalidEndpoint }
            descriptor = socket(family, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw Failure.posix(errno) }
            do {
                try configureDescriptor()
                let status: Int32
                if family == AF_INET {
                    status = withUnsafePointer(to: &v4) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                    }
                } else {
                    status = withUnsafePointer(to: &v6) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                    }
                }
                if status < 0 {
                    guard errno == EINPROGRESS else { throw Failure.posix(errno) }
                    try wait(events: Int16(POLLOUT))
                    var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw Failure.posix(errno) }
                    guard error == 0 else { throw Failure.posix(error) }
                }
            } catch { Darwin.close(descriptor); descriptor = -1; throw error }
        }
        /// Test-owned listeners use the identical stream/callback path on their
        /// accepted socket, rather than synthesizing a successful TLS result.
        init(acceptedDescriptor: Int32, cancellation: Cancellation, deadline: UInt64) throws {
            precondition(!Thread.isMainThread)
            descriptor = acceptedDescriptor; self.cancellation = cancellation; self.deadline = deadline
            do { try cancellation.prepare(); try configureDescriptor() }
            catch { Darwin.close(descriptor); descriptor = -1; throw error }
        }
        deinit { close() }
        func close() {
            authenticatedState = nil; context = nil
            if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1 }
        }
        private func configureDescriptor() throws {
            var yes: Int32 = 1
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Failure.posix(errno)
            }
        }
        func check() throws {
            try cancellation.check()
            guard descriptor >= 0 else { throw Failure.endOfStream }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.deadlineExceeded }
        }
        private func wait(events: Int16) throws {
            while true {
                try check()
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw Failure.deadlineExceeded }
                let remaining = deadline - now
                let milliseconds = Int32(min(900_000, max(1, (remaining + 999_999) / 1_000_000)))
                var items = [pollfd(fd: descriptor, events: events, revents: 0),
                             pollfd(fd: cancellation.descriptor, events: Int16(POLLIN), revents: 0)]
                let itemCount = nfds_t(items.count)
                let status = poll(&items, itemCount, milliseconds)
                if status < 0 { if errno == EINTR { continue }; throw Failure.posix(errno) }
                try check()
                if status == 0 { continue }
                if items[1].revents != 0 { throw Failure.cancelled }
                if items[0].revents & events != 0 { return }
                if items[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw Failure.endOfStream }
            }
        }
        private func raw(_ pointer: UnsafeMutableRawPointer, count: Int, writing: Bool) throws {
            var offset = 0
            while offset < count {
                try check()
                let result = writing ? Darwin.send(descriptor, pointer.advanced(by: offset), count - offset, 0)
                                     : Darwin.recv(descriptor, pointer.advanced(by: offset), count - offset, 0)
                if result < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { try wait(events: Int16(writing ? POLLOUT : POLLIN)); continue }
                    throw Failure.posix(errno)
                }
                guard result > 0 else { throw Failure.endOfStream }
                guard Int64(result) <= Self.totalTransportBytes - transferred else { throw Failure.transferLimit }
                transferred += Int64(result); offset += result
                if context != nil, authenticatedState == nil, transferred > Self.handshakeBytes { throw Failure.transferLimit }
            }
        }
        private static let readCallback: SSLReadFunc = { connection, bytes, length in
            let stream = Unmanaged<Stream>.fromOpaque(connection).takeUnretainedValue()
            do { try stream.raw(bytes, count: length.pointee, writing: false); return errSecSuccess }
            catch { length.pointee = 0; stream.callbackFailure = (error as? Failure) ?? .tls(errSSLInternal); return errSSLClosedAbort }
        }
        private static let writeCallback: SSLWriteFunc = { connection, bytes, length in
            let stream = Unmanaged<Stream>.fromOpaque(connection).takeUnretainedValue()
            do { try stream.raw(UnsafeMutableRawPointer(mutating: bytes), count: length.pointee, writing: true); return errSecSuccess }
            catch { length.pointee = 0; stream.callbackFailure = (error as? Failure) ?? .tls(errSSLInternal); return errSSLClosedAbort }
        }
        private func status(_ value: OSStatus) throws {
            if let failure = callbackFailure { throw failure }
            guard value == errSecSuccess else { throw Failure.tls(value) }
        }
        /// Starts TLS on this FD, never by making another TCP connection.
        /// Each fresh context has tickets disabled and a unique cache peer ID.
        func authenticate(identity: SecIdentity, expectedPeerDER: Data, rootDER: Data,
                          at date: Date, server: Bool = false) throws {
            try check()
            guard context == nil, authentication == nil,
                  !expectedPeerDER.isEmpty, expectedPeerDER.count <= 65_536,
                  !rootDER.isEmpty, rootDER.count <= 65_536,
                  let tls = SSLCreateContext(nil, server ? .serverSide : .clientSide, .streamType) else { throw Failure.invalidCredentials }
            context = tls
            do {
                try status(SSLSetIOFuncs(tls, Self.readCallback, Self.writeCallback))
                try status(SSLSetConnection(tls, Unmanaged.passUnretained(self).toOpaque()))
                try status(SSLSetProtocolVersionMin(tls, .tlsProtocol12))
                try status(SSLSetProtocolVersionMax(tls, .tlsProtocol12))
                try status(SSLSetSessionOption(tls, .enableSessionTickets, false))
                try status(SSLSetSessionOption(tls, .allowRenegotiation, false))
                try status(SSLSetSessionOption(tls, .falseStart, false))
                let cacheID = Data(UUID().uuidString.utf8)
                try cacheID.withUnsafeBytes { try status(SSLSetPeerID(tls, $0.baseAddress!, $0.count)) }
                try status(SSLSetCertificate(tls, [identity] as CFArray))
                try status(SSLSetSessionOption(tls, server ? .breakOnClientAuth : .breakOnServerAuth, true))
                if server { try status(SSLSetClientSideAuthenticate(tls, .alwaysAuthenticate)) }
                var freshPeerAuthentication = false
                var handshakeCalls = 0
                while true {
                    try check()
                    handshakeCalls += 1
                    guard handshakeCalls <= 256 else { throw Failure.tls(errSSLNegotiation) }
                    let result = SSLHandshake(tls)
                    if let failure = callbackFailure { throw failure }
                    if result == errSSLPeerAuthCompleted {
                        try verifyPeer(tls, expectedPeerDER: expectedPeerDER, rootDER: rootDER, at: date)
                        freshPeerAuthentication = true
                        continue
                    }
                    if result == errSSLWouldBlock { try wait(events: Int16(POLLIN)); continue }
                    try status(result); break
                }
                guard freshPeerAuthentication else { throw Failure.missingFreshAuthentication }
                // Always repeat against this context's actual peer chain after
                // handshake completion, even if a platform cache changes behavior.
                try verifyPeer(tls, expectedPeerDER: expectedPeerDER, rootDER: rootDER, at: date)
                if !server {
                    guard var clientState = (SSLClientCertificateState(rawValue: 0) as SSLClientCertificateState?) else {
                        throw Failure.missingMutualAuthentication
                    }
                    try status(SSLGetClientCertificateState(tls, &clientState))
                    // The client must have received CertificateRequest and sent
                    // its configured identity (public header: CertSent = 2).
                    guard clientState.rawValue == 2 else { throw Failure.missingMutualAuthentication }
                }
                // Server authentication is established by alwaysAuthenticate,
                // the fresh client-auth break, the actual pinned peer chain
                // verified above and completion of the TLS proof of possession.
                // Apple's SecureTransport implementation writes clientCertState
                // only in its client-side CertificateRequest callback; using
                // that field here rejects an otherwise authenticated server.
                // See Apple Security db15acbe, tlsCallbacks.c/sslContext.c.
                // No absent or mismatched client certificate passes verifyPeer.
                var version = SSLProtocol.tlsProtocol12
                try status(SSLGetNegotiatedProtocolVersion(tls, &version))
                guard version == .tlsProtocol12 else { throw Failure.tls(errSSLNegotiation) }
                try check()
                authenticatedState = Authentication(peer: expectedPeerDER, root: rootDER)
            } catch { close(); throw error }
        }
        private func verifyPeer(_ tls: SSLContext, expectedPeerDER: Data, rootDER: Data, at date: Date) throws {
            var trust: SecTrust?
            try status(SSLCopyPeerTrust(tls, &trust))
            guard let trust, let root = SecCertificateCreateWithData(nil, rootDER as CFData) else { throw Failure.peerMismatch }
            // Pairing certificates have device identities, not a DNS hostname.
            // Exact DER pin plus the explicit pairing CA replace DNS PKI here;
            // real TLS key possession is still checked by SSLHandshake.
            try status(SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()))
            try status(SecTrustSetAnchorCertificates(trust, [root] as CFArray))
            try status(SecTrustSetAnchorCertificatesOnly(trust, true))
            try status(SecTrustSetNetworkFetchAllowed(trust, false))
            try status(SecTrustSetVerifyDate(trust, date as CFDate))
            var error: CFError?
            guard SecTrustEvaluateWithError(trust, &error),
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  !chain.isEmpty, chain.count <= 16,
                  chain.allSatisfy({ CFDataGetLength(SecCertificateCopyData($0)) <= 65_536 }),
                  chain.last.map({ SecCertificateCopyData($0) as Data }) == rootDER else { throw Failure.peerTrustFailed }
            guard chain.first.map({ SecCertificateCopyData($0) as Data }) == expectedPeerDER else { throw Failure.peerMismatch }
        }
        func read(count: Int) throws -> Data {
            guard count >= 0, count <= 1_048_576 else { throw Failure.invalidLimit }
            do {
                try check()
                var result = Data(count: count)
                try result.withUnsafeMutableBytes { buffer in
                    guard count > 0 else { return }
                    if let tls = context {
                        guard authentication != nil else { throw Failure.missingFreshAuthentication }
                        var offset = 0
                        while offset < count {
                            try check()
                            var processed = 0
                            let code = SSLRead(tls, buffer.baseAddress!.advanced(by: offset), count - offset, &processed)
                            if let failure = callbackFailure { throw failure }
                            offset += processed
                            if code == errSSLWouldBlock { if processed == 0 { try wait(events: Int16(POLLIN)) }; continue }
                            try status(code)
                            guard processed > 0 else { throw Failure.endOfStream }
                        }
                    } else { try raw(buffer.baseAddress!, count: count, writing: false) }
                }
                return result
            } catch { close(); throw error }
        }
        func write(_ bytes: Data) throws {
            guard bytes.count <= 1_048_576 else { throw Failure.invalidLimit }
            do {
                try check()
                try bytes.withUnsafeBytes { buffer in
                    guard !buffer.isEmpty else { return }
                    if let tls = context {
                        guard authentication != nil else { throw Failure.missingFreshAuthentication }
                        var offset = 0
                        while offset < buffer.count {
                            try check()
                            var processed = 0
                            let code = SSLWrite(tls, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, &processed)
                            if let failure = callbackFailure { throw failure }
                            offset += processed
                            if code == errSSLWouldBlock { if processed == 0 { try wait(events: Int16(POLLOUT)) }; continue }
                            try status(code)
                            guard processed > 0 else { throw Failure.endOfStream }
                        }
                    } else { try raw(UnsafeMutableRawPointer(mutating: buffer.baseAddress!), count: buffer.count, writing: true) }
                }
            } catch { close(); throw error }
        }
    }
}
