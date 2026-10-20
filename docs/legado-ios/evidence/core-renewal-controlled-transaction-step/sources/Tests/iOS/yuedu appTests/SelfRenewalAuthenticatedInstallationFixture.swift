import CryptoKit
import Darwin
import Foundation
import Security
@testable import yuedu_app

/// Real loopback BSD sockets and SecureTransport mTLS on both sides. Service
/// responses are owned protocol fixtures; no Apple device or pairing record is
/// contacted. Keys are generated in a unique test Keychain namespace and only
/// public certificates leave the handle owner.
enum SelfRenewalAuthenticatedInstallationFixture {
    typealias Client = SelfRenewalAuthenticatedInstallationClient
    typealias Transport = SelfRenewalAuthenticatedDeviceTransport
    typealias PKI = SelfRenewalSigningOwnedPKIFixture
    enum Mode: Sendable, Equatable {
        case normal, wrongDeviceCertificate, wrongHostCertificate, expiredPeer
        case falseSession, wrongSession, missingServiceSSL, invalidPort
        case badAFCSequence, truncatedAFC, afcError, midUploadError, midUploadCleanupError
        case installError, noComplete, wrongLookup, stallSession
        case excessivePlist, excessiveProgress, unusedInput, lookupOnly, lookupMissing, disconnectAfterUpgradeThenRecover
        case disconnectAfterUpgradeThenLookupMissing
        case partialUploadThenRecover, cleanupAfterInterruptedUpload, cleanupAlreadyAbsent, cleanupStopDisconnectThenRetry
        case cleanupRemoveDeniedThenRetry, cleanupStallThenRetry, cleanupWrongServerCertificate, cleanupAfterReportedComplete
        var isUnknownUpgradeRecovery: Bool {
            self == .disconnectAfterUpgradeThenRecover || self == .disconnectAfterUpgradeThenLookupMissing
        }
        var cleanupSessionCount: Int {
            switch self {
            case .cleanupStopDisconnectThenRetry, .cleanupRemoveDeniedThenRetry, .cleanupStallThenRetry: return 3
            case .partialUploadThenRecover, .cleanupAfterInterruptedUpload, .cleanupAlreadyAbsent, .cleanupWrongServerCertificate, .cleanupAfterReportedComplete: return 2
            default: return 1
            }
        }
        var sessionCount: Int { isUnknownUpgradeRecovery ? 2 : cleanupSessionCount }
    }
    struct Observation: Sendable {
        var uploaded = Data()
        var upgradeRequests = 0
        var lookupRequests = 0
        var removedPaths: [String] = []
        var stoppedSessions: [String] = []
        var authenticatedChannels = 0
        var closedFileHandles = 0
        var openedFileHandles = 0
        var removeAttempts = 0
    }
    final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Observation()
        func update(_ action: (inout Observation) -> Void) { lock.lock(); defer { lock.unlock() }; action(&value) }
        var snapshot: Observation { lock.lock(); defer { lock.unlock() }; return value }
    }
    struct Context: Sendable {
        let endpoint: Transport.Endpoint
        let pairing: Transport.PairingIdentity
        let archive: Client.ArchiveInput
        let bytes: Data
        let date: Date
        let bundle: String
        let version: String
        let observed: Observations
        let sessionRequestReceived: AsyncStream<Bool>
        let recoveryRemoveRequestReceived: AsyncStream<Bool>
        let wrongDeviceCertificateDER: Data
        func upgrade(timeout: TimeInterval = 8, archive alternate: Client.ArchiveInput? = nil,
            beforeCreation: @escaping @Sendable (Client.UploadIntent) async throws -> Void = { _ in },
            beforeSubmission: @escaping @Sendable (Client.UpgradeSubmission) async throws -> Void = { _ in }) async throws -> Client.Receipt {
            try await Client.upgrade(alternate ?? archive, pairing: pairing, lockdownEndpoint: endpoint,
                bundleIdentifier: bundle, bundleVersion: version, at: date, timeoutSeconds: timeout,
                beforeUploadCreation: beforeCreation, beforeUpgradeSubmission: beforeSubmission)
        }
        func lookup() async throws -> Client.LookupObservation {
            try await Client.lookup(pairing: pairing, lockdownEndpoint: endpoint, bundleIdentifier: bundle, at: date, timeoutSeconds: 8)
        }
    }
    enum FixtureFailure: Error { case invalidRequest, keychain(OSStatus), descriptor(Int32) }

    private final class Identity: @unchecked Sendable {
        let tag: Data
        let label: String
        let identity: SecIdentity
        let certificate: Data
        init(issuer: SelfRenewalSigningMaterialVault.KeyMaterial, serial: UInt8, at date: Date) throws {
            let tag = Data(("reader-install-test-" + UUID().uuidString).utf8)
            let label = "reader-install-test-" + UUID().uuidString
            let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048,
                kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: tag, kSecAttrLabel as String: label,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(options as CFDictionary, &error) else {
                if let error { _ = error.takeRetainedValue() }; throw FixtureFailure.invalidRequest
            }
            do {
                let certificate = try Self.reserialise(PKI.certificate(for: key, signedBy: issuer, at: date), serial: serial, issuer: issuer)
                guard let cert = SecCertificateCreateWithData(nil, certificate as CFData) else { throw FixtureFailure.invalidRequest }
                let status = SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert,
                    kSecAttrLabel as String: label] as CFDictionary, nil)
                guard status == errSecSuccess else { throw FixtureFailure.keychain(status) }
                var item: CFTypeRef?
                let found = SecItemCopyMatching([kSecClass as String: kSecClassIdentity,
                    kSecAttrLabel as String: label, kSecReturnRef as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &item)
                guard found == errSecSuccess, let item, CFGetTypeID(item) == SecIdentityGetTypeID() else { throw FixtureFailure.keychain(found) }
                self.identity = (item as! SecIdentity)
                self.certificate = certificate; self.tag = tag; self.label = label
            } catch {
                SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
                SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
                throw error
            }
        }
        deinit {
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
        }
        /// The shared PKI's ordinary developer leaf has serial 2. Distinct TLS
        /// identities under one CA need distinct issuer/serial Keychain keys.
        /// Reuse its certificate structure, changing only serial and the actual
        /// issuer signature; no private key representation is requested.
        private static func reserialise(_ original: Data, serial: UInt8,
            issuer: SelfRenewalSigningMaterialVault.KeyMaterial) throws -> Data {
            let fields = try SelfRenewalCMSVerifier.children(of: SelfRenewalCMSVerifier.parseDER(original))
            var body = try SelfRenewalCMSVerifier.children(of: fields[0]).map(\.originalDER)
            guard body.count >= 8, body[1] == Data([2, 1, 2]), (2...127).contains(serial) else { throw FixtureFailure.invalidRequest }
            body[1] = Data([2, 1, serial])
            let tbs = der(0x30, body.reduce(into: Data()) { $0.append($1) })
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(issuer.privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                tbs as CFData, &error) as Data? else {
                if let error { _ = error.takeRetainedValue() }; throw FixtureFailure.invalidRequest
            }
            return der(0x30, tbs + fields[1].originalDER + der(3, Data([0]) + signature))
        }
        private static func der(_ tag: UInt8, _ value: Data) -> Data {
            var size = value.count; var length = Data()
            repeat { length.insert(UInt8(size & 255), at: 0); size >>= 8 } while size > 0
            let header = value.count < 128 ? Data([tag, UInt8(value.count)]) : Data([tag, 0x80 | UInt8(length.count)]) + length
            return header + value
        }
    }
    private final class Listener: @unchecked Sendable {
        let descriptor: Int32
        let port: UInt16
        init() throws {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw FixtureFailure.descriptor(errno) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(descriptor, 1) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                let code = errno; Darwin.close(descriptor); throw FixtureFailure.descriptor(code)
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            guard named == 0 else { let code = errno; Darwin.close(descriptor); throw FixtureFailure.descriptor(code) }
            self.descriptor = descriptor; port = UInt16(bigEndian: address.sin_port)
        }
        deinit { Darwin.close(descriptor) }
        func accept(cancellation: Transport.Cancellation, deadline: UInt64) throws -> Transport.Stream {
            try cancellation.prepare()
            while true {
                try cancellation.check()
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw Transport.Failure.deadlineExceeded }
                var items = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                             pollfd(fd: cancellation.descriptor, events: Int16(POLLIN), revents: 0)]
                let timeout = Int32(max(1, (deadline - now + 999_999) / 1_000_000))
                let itemCount = nfds_t(items.count)
                let result = poll(&items, itemCount, timeout)
                if result < 0 { if errno == EINTR { continue }; throw FixtureFailure.descriptor(errno) }
                try cancellation.check()
                if items[0].revents & Int16(POLLIN) == 0 { continue }
                let fd = Darwin.accept(descriptor, nil, nil)
                if fd < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw FixtureFailure.descriptor(errno) }
                return try Transport.Stream(acceptedDescriptor: fd, cancellation: cancellation, deadline: deadline)
            }
        }
    }
    /// Error capture is used only to join a deliberately rejected peer. Positive
    /// fixtures require all three independently scheduled real peer loops to pass.
    private struct PeerResult: @unchecked Sendable { let error: Error? }

    static func withPeer(_ mode: Mode = .normal, bytes overrideBytes: Data? = nil,
        bundle: String = "owned.reader", version: String = "42", at date: Date = Date(),
        beforeRecoveryRemoveReply: @escaping @Sendable () throws -> Void = {},
        _ action: @escaping @Sendable (Context) async throws -> Void) async throws {
        let cancellation = Transport.Cancellation()
        let worker = Task.detached(priority: .utility) {
            let issuer = try PKI.issuer(at: date)
            let host = try Identity(issuer: issuer, serial: 2, at: date)
            let device = try Identity(issuer: issuer, serial: 3, at: date)
            let wrong = try Identity(issuer: issuer, serial: 4, at: date)
            let lockdown = try Listener(), afc = try Listener(), proxy = try Listener()
            let deadline = try Transport.Stream.deadline(seconds: 20)
            let observed = Observations()
            let signal = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let removalSignal = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let bytes = overrideBytes ?? Data((0..<150_001).map { UInt8(truncatingIfNeeded: $0 * 37) })
            guard !bytes.isEmpty, bytes.count <= 67_108_864 else { throw FixtureFailure.invalidRequest }
            let pairing = try Transport.PairingIdentity(hostIdentity: host.identity,
                deviceCertificateDER: mode == .wrongDeviceCertificate ? wrong.certificate : device.certificate,
                rootCertificateDER: issuer.certificateChainDER[0], hostID: "owned-host", systemBUID: "owned-system")
            let root = issuer.certificateChainDER[0]
            let peerHost = mode == .wrongHostCertificate ? wrong.certificate : host.certificate
            let peers: [Task<PeerResult, Never>] = [
                peerTask {
                    for round in 0..<mode.sessionCount {
                    let stream = try lockdown.accept(cancellation: cancellation, deadline: deadline); defer { stream.close() }
                    let channel = Client.PlistChannel(stream)
                    let start = try channel.receive(request: "StartSession")
                    guard start["Request"] == .string("StartSession"), start["HostID"] == .string("owned-host"),
                          start["SystemBUID"] == .string("owned-system") else { throw FixtureFailure.invalidRequest }
                    let sessionID = round == 0 ? "owned-session" : "owned-recovery-session"
                    try channel.send(["Request": .string("StartSession"), "SessionID": .string(sessionID),
                        "EnableSessionSSL": .boolean(mode != .falseSession)])
                    signal.continuation.yield(true)
                    if mode == .falseSession { return }
                    if mode == .stallSession { _ = try stream.read(count: 1_048_576); return }
                    let serverIdentity = mode == .cleanupWrongServerCertificate && round > 0 ? wrong.identity : device.identity
                    try stream.authenticate(identity: serverIdentity, expectedPeerDER: peerHost, rootDER: root, at: date, server: true)
                    observed.update { $0.authenticatedChannels += 1 }
                    for _ in 0..<(round > 0 || mode == .lookupOnly || mode == .lookupMissing ? 1 : 2) {
                        let request = try channel.receive(request: "StartService")
                        guard request["Request"] == .string("StartService") else { throw FixtureFailure.invalidRequest }
                        let port: UInt16
                        if request["Service"] == .string("com.apple.afc") { port = afc.port }
                        else if request["Service"] == .string("com.apple.mobile.installation_proxy") { port = proxy.port }
                        else { throw FixtureFailure.invalidRequest }
                        var response: [String: Client.Value] = ["Request": .string("StartService"),
                            "Port": .integer(mode == .invalidPort ? 65_536 : Int64(port))]
                        if mode != .missingServiceSSL { response["EnableServiceSSL"] = .boolean(true) }
                        try channel.send(response)
                    }
                    do {
                        let stop = try channel.receive(request: "StopSession")
                        guard stop["Request"] == .string("StopSession"), stop["SessionID"] == .string(sessionID) else { throw FixtureFailure.invalidRequest }
                        observed.update { $0.stoppedSessions.append(sessionID) }
                        if mode == .cleanupStopDisconnectThenRetry, round == 1 { continue }
                        try channel.send(["Request": .string("StopSession"), "SessionID": .string(mode == .wrongSession ? "wrong-session" : sessionID)])
                    } catch {
                        if (mode.isUnknownUpgradeRecovery || mode.cleanupSessionCount > 1), error is Transport.Failure {
                            if round == 0 || (mode == .cleanupStallThenRetry && round == 1) || (mode == .cleanupRemoveDeniedThenRetry && round == 1) { continue }
                        }
                        throw error
                    }
                    }
                },
                peerTask {
                    var path: Data?
                    var remoteExists = false
                    for round in 0..<mode.cleanupSessionCount {
                    let stream = try afc.accept(cancellation: cancellation, deadline: deadline); defer { stream.close() }
                    try stream.authenticate(identity: device.identity, expectedPeerDER: peerHost, rootDER: root, at: date, server: true)
                    observed.update { $0.authenticatedChannels += 1 }
                    let channel = Client.AFCChannel(stream)
                    requestLoop: while true {
                        let request: Client.AFCChannel.Packet
                        do { request = try channel.receive() }
                        catch {
                            if error is Transport.Failure {
                                if mode.isUnknownUpgradeRecovery, observed.snapshot.closedFileHandles == 1 { return }
                                if mode.cleanupSessionCount > 1 {
                                    if round == 0, mode == .cleanupAlreadyAbsent { remoteExists = false }
                                    break
                                }
                            }
                            throw error
                        }
                        if round > 0 {
                            // Cleanup has no valid old-session handle. Its only
                            // AFC command is Remove of this actual original path.
                            guard request.operation == 8, request.header == path,
                                  let path, let text = String(data: path.dropLast(), encoding: .utf8) else { throw FixtureFailure.invalidRequest }
                            observed.update { $0.removeAttempts += 1 }
                            removalSignal.continuation.yield(true)
                            if mode == .cleanupStallThenRetry, round == 1 {
                                do { _ = try stream.read(count: 1); throw FixtureFailure.invalidRequest }
                                catch { if error is Transport.Failure { break }; throw error }
                            }
                            try beforeRecoveryRemoveReply()
                            if mode == .cleanupRemoveDeniedThenRetry, round == 1 {
                                try sendAFC(stream, sequence: request.sequence, operation: 1, header: Client.AFCChannel.integer(10))
                                continue
                            }
                            let status: UInt64 = remoteExists ? 0 : 8
                            if remoteExists { observed.update { $0.removedPaths.append(text) }; remoteExists = false }
                            try sendAFC(stream, sequence: request.sequence, operation: 1, header: Client.AFCChannel.integer(status))
                            break
                        }
                        if mode == .truncatedAFC { try stream.write(Data(repeating: 0, count: 9)); return }
                        let sequence = request.sequence + (mode == .badAFCSequence ? 1 : 0)
                        if mode == .afcError { try sendAFC(stream, sequence: sequence, operation: 1, header: Client.AFCChannel.integer(10)); return }
                        switch request.operation {
                        case 0x0a:
                            if request.header == Data("PublicStaging\0".utf8) {
                                try sendAFC(stream, sequence: sequence, operation: 2, payload: Data("st_ifmt\0S_IFDIR\0".utf8))
                            } else {
                                path = request.header
                                try sendAFC(stream, sequence: sequence, operation: 1, header: Client.AFCChannel.integer(8))
                            }
                        case 0x0d:
                            guard request.header.prefix(8) == Client.AFCChannel.integer(3),
                                  let text = String(data: request.header.dropFirst(8), encoding: .utf8),
                                  text.hasPrefix("PublicStaging/reader-renewal-"), text.hasSuffix(".ipa\0") else { throw FixtureFailure.invalidRequest }
                            path = Data(request.header.dropFirst(8))
                            remoteExists = true
                            observed.update { $0.openedFileHandles += 1 }
                            try sendAFC(stream, sequence: sequence, operation: 0x0e, header: Client.AFCChannel.integer(42))
                        case 0x10:
                            guard request.header == Client.AFCChannel.integer(42), !request.payload.isEmpty else { throw FixtureFailure.invalidRequest }
                            observed.update { $0.uploaded.append(request.payload) }
                            if mode == .partialUploadThenRecover { stream.close(); break requestLoop }
                            let code: UInt64 = mode == .midUploadError || mode == .midUploadCleanupError ? 10 : 0
                            try sendAFC(stream, sequence: sequence, operation: 1, header: Client.AFCChannel.integer(code))
                        case 0x14:
                            guard request.header == Client.AFCChannel.integer(42),
                                  observed.snapshot.uploaded == bytes || mode == .midUploadError || mode == .midUploadCleanupError else { throw FixtureFailure.invalidRequest }
                            observed.update { $0.closedFileHandles += 1 }
                            try sendAFC(stream, sequence: sequence, operation: 1, header: Client.AFCChannel.integer(0))
                        case 8:
                            guard request.header == path, let path, let text = String(data: path.dropLast(), encoding: .utf8) else { throw FixtureFailure.invalidRequest }
                            observed.update { $0.removeAttempts += 1 }
                            if mode == .midUploadCleanupError {
                                try sendAFC(stream, sequence: sequence, operation: 1, header: Client.AFCChannel.integer(10)); return
                            }
                            observed.update { $0.removedPaths.append(text) }
                            remoteExists = false
                            try sendAFC(stream, sequence: sequence, operation: 1, header: Client.AFCChannel.integer(0))
                            if mode.cleanupSessionCount > 1 { break requestLoop }
                            return
                        default: throw FixtureFailure.invalidRequest
                        }
                    }
                    }
                },
                peerTask {
                    for round in 0..<(mode.isUnknownUpgradeRecovery ? 2 : 1) {
                    let stream = try proxy.accept(cancellation: cancellation, deadline: deadline); defer { stream.close() }
                    try stream.authenticate(identity: device.identity, expectedPeerDER: peerHost, rootDER: root, at: date, server: true)
                    observed.update { $0.authenticatedChannels += 1 }
                    let channel = Client.PlistChannel(stream)
                    if round > 0 || mode == .lookupOnly || mode == .lookupMissing {
                        let lookup = try channel.receive()
                        guard lookup["Command"] == .string("Lookup"),
                              lookup["ClientOptions"] == .dictionary(["ApplicationType": .string("Any"), "BundleIDs": .array([.string(bundle)])]) else { throw FixtureFailure.invalidRequest }
                        observed.update { $0.lookupRequests += 1 }
                        let result: [String: Client.Value] = mode == .lookupMissing || mode == .disconnectAfterUpgradeThenLookupMissing ? [:] : [bundle: .dictionary([
                            "CFBundleIdentifier": .string(bundle), "CFBundleVersion": .string(version)])]
                        try channel.send(["LookupResult": .dictionary(result)]); return
                    }
                    let upgrade: [String: Client.Value]
                    do { upgrade = try channel.receive() }
                    catch { if mode.cleanupSessionCount > 1, error is Transport.Failure { return }; throw error }
                    guard upgrade["Command"] == .string("Upgrade"),
                          upgrade["ClientOptions"] == .dictionary(["CFBundleIdentifier": .string(bundle)]),
                          case .string(let path)? = upgrade["PackagePath"], path.hasPrefix("PublicStaging/reader-renewal-") else { throw FixtureFailure.invalidRequest }
                    observed.update { $0.upgradeRequests += 1 }
                    if mode.isUnknownUpgradeRecovery { stream.close(); continue }
                    if mode == .installError { try channel.send(["Error": .string("OwnedInstallError"), "Status": .string("Complete")]); return }
                    if mode == .excessivePlist { try stream.write(Data([0, 16, 0, 0])); return }
                    let messages = mode == .excessiveProgress ? 257 : 1
                    for _ in 0..<messages { try channel.send(["Status": .string("Installing"), "PercentComplete": .integer(100)]) }
                    if mode == .excessiveProgress || mode == .noComplete { _ = try stream.read(count: 1); return }
                    try channel.send(["Status": .string("Complete")])
                    let lookup = try channel.receive()
                    guard lookup["Command"] == .string("Lookup"),
                          lookup["ClientOptions"] == .dictionary(["ApplicationType": .string("Any"), "BundleIDs": .array([.string(bundle)])]) else { throw FixtureFailure.invalidRequest }
                    observed.update { $0.lookupRequests += 1 }
                    try channel.send(["LookupResult": .dictionary([bundle: .dictionary([
                        "CFBundleIdentifier": .string(bundle), "CFBundleVersion": .string(mode == .wrongLookup ? "other" : version)])])])
                    }
                },
            ]
            let context = Context(endpoint: Transport.Endpoint(numericAddress: "127.0.0.1", port: lockdown.port),
                pairing: pairing, archive: Client.ArchiveInput(byteCount: bytes.count, sha256: Data(SHA256.hash(data: bytes))) { offset, count in
                    Data(bytes[offset..<(offset + count)])
                }, bytes: bytes, date: mode == .expiredPeer ? date.addingTimeInterval(86_400 * 31) : date,
                bundle: bundle, version: version, observed: observed, sessionRequestReceived: signal.stream,
                recoveryRemoveRequestReceived: removalSignal.stream, wrongDeviceCertificateDER: wrong.certificate)
            do {
                try await action(context)
                let requirePeerSuccess = mode == .normal || mode.isUnknownUpgradeRecovery || (mode.cleanupSessionCount > 1 && mode != .cleanupWrongServerCertificate)
                if !requirePeerSuccess { cancellation.cancel() }
                for peer in peers {
                    let result = await peer.value
                    if requirePeerSuccess, let error = result.error { throw error }
                }
                signal.continuation.finish(); removalSignal.continuation.finish(); cancellation.cancel()
            } catch {
                cancellation.cancel(); signal.continuation.finish(); removalSignal.continuation.finish()
                for peer in peers { _ = await peer.value }
                throw error
            }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }
    private static func capture(_ action: () throws -> Void) -> PeerResult {
        do { try action(); return PeerResult(error: nil) }
        catch { return PeerResult(error: error) }
    }
    /// Blocking peer accept/TLS loops use GCD workers, so three waiting peers
    /// cannot exhaust a small Swift cooperative executor before its client runs.
    private static func peerTask(_ action: @escaping @Sendable () throws -> Void) -> Task<PeerResult, Never> {
        Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: capture(action))
                }
            }
        }
    }
    private static func sendAFC(_ stream: Transport.Stream, sequence: UInt64, operation: UInt64,
        header: Data = Data(), payload: Data = Data()) throws {
        let fields: [UInt64] = [0x4141504c36414643, UInt64(40 + header.count + payload.count), UInt64(40 + header.count), sequence, operation]
        var bytes = fields.reduce(into: Data()) { $0.append(Client.AFCChannel.integer($1)) }
        bytes.append(header); bytes.append(payload); try stream.write(bytes)
    }
}
