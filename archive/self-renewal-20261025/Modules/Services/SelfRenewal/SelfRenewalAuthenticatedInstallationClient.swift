import CryptoKit
import Foundation

/// A bounded Direct Lockdown TCP installation substrate. It consumes explicit
/// handles/addresses and owned archive chunks, never account or pairing files.
/// This does not discover or prove an on-device/no-VPN route or Apple authority.
enum SelfRenewalAuthenticatedInstallationClient {
    typealias Transport = SelfRenewalAuthenticatedDeviceTransport
    typealias Value = SelfRenewalDERPropertyList.Value
    enum Failure: Error, Sendable, Equatable {
        case invalidArchive, invalidIdentity, malformedPlist, malformedResponse
        case remoteError(String), unauthenticatedService(String), invalidServicePort
        case malformedAFC, afcStatus(UInt64), archiveChanged, progressLimit
        case lookupMismatch, sessionMismatch
    }
    enum Stage: Int, Sendable { case session, services, upload, upgrade, lookup, cleanup, stopSession }
    struct OperationFailure: Error, @unchecked Sendable {
        let stage: Stage
        let underlying: Error
        let ownedRemoteStagingPath: String?
        let remoteStagingRemovalVerified: Bool
        let remoteCreationAttempted: Bool
        let cleanupAttempted: Bool
        let cleanupErrors: [Error]
        /// A disconnect after submitting Upgrade is not proof of failure and
        /// must not cause an automatic second Upgrade submission.
        var upgradeMayHaveExecuted: Bool { stage.rawValue >= Stage.upgrade.rawValue }
    }
    /// The package orchestrator bridges its immutable, unlinked snapshot FD to
    /// this closure. It retains ownership; no mutable pathname or private key
    /// bytes are introduced. These fields are inputs, not authorization proof.
    struct ArchiveInput: Sendable {
        let byteCount: Int
        let sha256: Data
        let read: @Sendable (_ offset: Int, _ count: Int) async throws -> Data
        init(byteCount: Int, sha256: Data,
             read: @escaping @Sendable (Int, Int) async throws -> Data) {
            self.byteCount = byteCount; self.sha256 = sha256; self.read = read
        }
    }
    struct UpgradeSubmission: Sendable {
        let remotePackagePath: String
        let archiveSHA256: Data
        let uploadedBytes: Int
        let bundleIdentifier: String
        let bundleVersion: String
        let deviceCertificateSHA256: Data
        fileprivate init(path: String, digest: Data, bytes: Int, bundle: String, version: String, device: Data) {
            remotePackagePath = path; archiveSHA256 = digest; uploadedBytes = bytes
            bundleIdentifier = bundle; bundleVersion = version; deviceCertificateSHA256 = device
        }
    }
    struct UploadIntent: Sendable {
        let remotePackagePath: String
        let expectedArchiveSHA256: Data
        let expectedArchiveBytes: Int
        let bundleIdentifier: String
        let bundleVersion: String
        let deviceCertificateSHA256: Data
        fileprivate init(path: String, archive: ArchiveInput, bundle: String, version: String, device: Data) {
            remotePackagePath = path; expectedArchiveSHA256 = archive.sha256; expectedArchiveBytes = archive.byteCount
            bundleIdentifier = bundle; bundleVersion = version; deviceCertificateSHA256 = device
        }
    }
    struct LookupObservation: Sendable {
        enum Presence: Sendable, Equatable {
            case notFound
            case reported(bundleIdentifier: String, bundleVersion: String)
        }
        let presence: Presence
        let lockdownAuthentication: Transport.Authentication
        let installationAuthentication: Transport.Authentication
        var installedArchiveDigestVerified: Bool { false }
        var installedProfileOrEntitlementsVerified: Bool { false }
        var appRelaunchOrDataPreservationVerified: Bool { false }
        fileprivate init(presence: Presence, lockdown: Transport.Authentication, installation: Transport.Authentication) {
            self.presence = presence; lockdownAuthentication = lockdown; installationAuthentication = installation
        }
    }
    struct Receipt: Sendable {
        let bundleIdentifier: String
        let bundleVersion: String
        let archiveSHA256: Data
        let uploadedBytes: Int
        let progressMessages: Int
        let lockdownAuthentication: Transport.Authentication
        let afcAuthentication: Transport.Authentication
        let installationAuthentication: Transport.Authentication
        let remoteStagingRemoved: Bool
        let submission: UpgradeSubmission
        var upgradeReportedComplete: Bool { true }
        var exactLookupIdentityObserved: Bool { true }
        var appleInstallationAuthorityVerified: Bool { false }
        var samePhysicalDeviceVerified: Bool { false }
        var noVPNRouteVerified: Bool { false }
        var unattendedRenewalVerified: Bool { false }
        fileprivate init(bundle: String, version: String, digest: Data, bytes: Int, progress: Int,
            lockdown: Transport.Authentication, afc: Transport.Authentication, installation: Transport.Authentication, submission: UpgradeSubmission) {
            bundleIdentifier = bundle; bundleVersion = version; archiveSHA256 = digest; uploadedBytes = bytes
            progressMessages = progress; lockdownAuthentication = lockdown; afcAuthentication = afc
            installationAuthentication = installation; remoteStagingRemoved = true; self.submission = submission
        }
    }
    /// A read from the paired TLS peer, not proof that it is this running App's
    /// physical device. Construction and validity remain inside the live session.
    struct RegistrationDeviceObservation: Sendable {
        let identifier: String
        let endpoint: Transport.Endpoint
        let sessionID: String
        let authentication: Transport.Authentication
        private let lifetime: RegistrationLifetime
        var samePhysicalDeviceVerified: Bool { false }
        var noVPNRouteVerified: Bool { false }
        fileprivate init(identifier: String, endpoint: Transport.Endpoint, sessionID: String,
            authentication: Transport.Authentication, lifetime: RegistrationLifetime) {
            self.identifier = identifier; self.endpoint = endpoint; self.sessionID = sessionID
            self.authentication = authentication; self.lifetime = lifetime
        }
        func check() throws { try lifetime.check() }
        func remainingSeconds() throws -> TimeInterval {
            try lifetime.check()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < lifetime.deadline else { throw Transport.Failure.deadlineExceeded }
            return TimeInterval(lifetime.deadline - now) / 1_000_000_000
        }
    }
    fileprivate final class RegistrationLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        let cancellation: Transport.Cancellation
        let deadline: UInt64
        init(cancellation: Transport.Cancellation, deadline: UInt64) { self.cancellation = cancellation; self.deadline = deadline }
        func end() { lock.lock(); active = false; lock.unlock() }
        func check() throws {
            try Task.checkCancellation(); try cancellation.check()
            lock.lock(); let current = active; lock.unlock()
            guard current else { throw Failure.sessionMismatch }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Transport.Failure.deadlineExceeded }
        }
    }
    struct RegistrationCleanupFailure: Error, @unchecked Sendable {
        let underlying: Error
        let stopSessionError: Error
    }
    struct RegistrationFinalizationFailure<Output: Sendable>: Error, @unchecked Sendable {
        let completed: Output
        let stopSessionError: Error
    }
    /// Exactly one existing authenticated Lockdown session; no StartService,
    /// upload, guessed identifier, cached device list or new transport owner.
    nonisolated static func withPairedRegistrationDevice<Output: Sendable>(pairing: Transport.PairingIdentity,
        lockdownEndpoint endpoint: Transport.Endpoint, at date: Date, timeoutSeconds: TimeInterval = 300,
        operation: @escaping @Sendable (RegistrationDeviceObservation) async throws -> Output) async throws -> Output {
        let cancellation = Transport.Cancellation()
        let worker = Task.detached(priority: .utility) {
            let started = SourcePerfTrace.now
            defer { SourcePerfTrace.record("renewal.install.registration-device", "main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
            let deadline = try Transport.Stream.deadline(seconds: timeoutSeconds)
            let lifetime = RegistrationLifetime(cancellation: cancellation, deadline: deadline)
            defer { lifetime.end() }
            let stream = try Transport.Stream(endpoint: endpoint, cancellation: cancellation, deadline: deadline)
            defer { stream.close() }
            let channel = PlistChannel(stream)
            let session = try openSession(channel, pairing: pairing, at: date)
            let output: Output
            do {
                try channel.send(["Label": .string("Reading"), "Request": .string("GetValue"), "Key": .string("UniqueDeviceID")])
                let response = try channel.receive(request: "GetValue")
                // ALTDevice treats the value as an opaque String. Do not confuse
                // it with IDFV/anisette UUID or assume only one UDID layout.
                guard case .string(let identifier)? = response["Value"], !identifier.isEmpty,
                      identifier.utf8.count <= 128,
                      identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw Failure.invalidIdentity }
                try lifetime.check(); try stream.check()
                let observation = RegistrationDeviceObservation(identifier: identifier, endpoint: endpoint,
                    sessionID: session.id, authentication: session.authentication, lifetime: lifetime)
                output = try await operation(observation)
            } catch {
                let original = error
                lifetime.end()
                do { try stopSession(channel, sessionID: session.id) }
                catch { throw RegistrationCleanupFailure(underlying: original, stopSessionError: error) }
                throw original
            }
            lifetime.end()
            do { try stopSession(channel, sessionID: session.id) }
            catch { throw RegistrationFinalizationFailure(completed: output, stopSessionError: error) }
            return output
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }

    enum Limits {
        static let archiveBytes = 1_073_741_824
        static let chunkBytes = 65_536
        static let plistBytes = 262_144
        static let progressMessages = 256
        static let progressBytes = 8_388_608
    }

    nonisolated static func upgrade(_ archive: ArchiveInput, pairing: Transport.PairingIdentity,
        lockdownEndpoint: Transport.Endpoint, bundleIdentifier: String, bundleVersion: String,
        at date: Date, timeoutSeconds: TimeInterval = 300,
        beforeUploadCreation: @escaping @Sendable (UploadIntent) async throws -> Void = { _ in },
        beforeUpgradeSubmission: @escaping @Sendable (UpgradeSubmission) async throws -> Void = { _ in }) async throws -> Receipt {
        let cancellation = Transport.Cancellation()
        let worker = Task.detached(priority: .utility) {
            let started = SourcePerfTrace.now
            defer {
                SourcePerfTrace.record("renewal.install.authenticated",
                    "bytes=\(archive.byteCount) main=\(Thread.isMainThread)", since: started, thresholdMs: 0)
            }
            return try await execute(archive, pairing: pairing, endpoint: lockdownEndpoint,
                bundle: bundleIdentifier, version: bundleVersion, at: date,
                cancellation: cancellation, deadline: Transport.Stream.deadline(seconds: timeoutSeconds),
                beforeUploadCreation: beforeUploadCreation, beforeUpgradeSubmission: beforeUpgradeSubmission)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }
    /// Recovery queries never upload a package or send Install/Upgrade. Matching
    /// identity/version is only a Lookup observation; it does not prove that a
    /// particular renewed profile or archive is installed.
    nonisolated static func lookup(pairing: Transport.PairingIdentity, lockdownEndpoint endpoint: Transport.Endpoint,
        bundleIdentifier bundle: String, at date: Date, timeoutSeconds: TimeInterval = 30) async throws -> LookupObservation {
        let cancellation = Transport.Cancellation()
        let worker = Task.detached(priority: .utility) {
            let started = SourcePerfTrace.now
            defer { SourcePerfTrace.record("renewal.install.lookup", "main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
            guard !bundle.isEmpty, bundle.utf8.count <= 256, !bundle.utf8.contains(0) else { throw Failure.invalidIdentity }
            let deadline = try Transport.Stream.deadline(seconds: timeoutSeconds)
            let lockdown = try Transport.Stream(endpoint: endpoint, cancellation: cancellation, deadline: deadline)
            defer { lockdown.close() }
            let channel = PlistChannel(lockdown)
            let session = try openSession(channel, pairing: pairing, at: date)
            let port = try startService("com.apple.mobile.installation_proxy", on: channel, endpoint: endpoint)
            let proxy = try Transport.Stream(endpoint: port, cancellation: cancellation, deadline: deadline)
            defer { proxy.close() }
            try proxy.authenticate(identity: pairing.hostIdentity, expectedPeerDER: pairing.deviceCertificateDER,
                rootDER: pairing.rootCertificateDER, at: date)
            guard let proof = proxy.authentication else { throw Transport.Failure.missingFreshAuthentication }
            let installed = try lookupOn(PlistChannel(proxy), bundle: bundle)
            try stopSession(channel, sessionID: session.id)
            try cancellation.check(); try lockdown.check()
            return LookupObservation(presence: installed, lockdown: session.authentication, installation: proof)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }
    private static func execute(_ archive: ArchiveInput, pairing: Transport.PairingIdentity,
        endpoint: Transport.Endpoint, bundle: String, version: String, at date: Date,
        cancellation: Transport.Cancellation, deadline: UInt64,
        beforeUploadCreation: @escaping @Sendable (UploadIntent) async throws -> Void,
        beforeUpgradeSubmission: @escaping @Sendable (UpgradeSubmission) async throws -> Void) async throws -> Receipt {
        precondition(!Thread.isMainThread)
        guard archive.byteCount > 0, archive.byteCount <= Limits.archiveBytes, archive.sha256.count == 32 else { throw Failure.invalidArchive }
        guard [bundle, version].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) else { throw Failure.invalidIdentity }
        var stage = Stage.session
        var ownedRemoteStagingPath: String?
        var remoteStagingRemovalVerified = false
        var remote: RemoteUpload?
        let lockdown = try Transport.Stream(endpoint: endpoint, cancellation: cancellation, deadline: deadline)
        defer { lockdown.close() }
        let channel = PlistChannel(lockdown)
        do {
            let session = try openSession(channel, pairing: pairing, at: date)
            let sessionID = session.id, lockdownProof = session.authentication
            stage = .services
            let afcEndpoint = try startService("com.apple.afc", on: channel, endpoint: endpoint)
            let proxyEndpoint = try startService("com.apple.mobile.installation_proxy", on: channel, endpoint: endpoint)
            let afc = try Transport.Stream(endpoint: afcEndpoint, cancellation: cancellation, deadline: deadline)
            defer { afc.close() }
            try afc.authenticate(identity: pairing.hostIdentity, expectedPeerDER: pairing.deviceCertificateDER,
                rootDER: pairing.rootCertificateDER, at: date)
            let proxy = try Transport.Stream(endpoint: proxyEndpoint, cancellation: cancellation, deadline: deadline)
            defer { proxy.close() }
            try proxy.authenticate(identity: pairing.hostIdentity, expectedPeerDER: pairing.deviceCertificateDER,
                rootDER: pairing.rootCertificateDER, at: date)
            guard let afcProof = afc.authentication, let proxyProof = proxy.authentication else { throw Transport.Failure.missingFreshAuthentication }
            let files = AFCChannel(afc)
            stage = .upload
            try files.ensureStagingDirectory()
            let path = "PublicStaging/reader-renewal-" + UUID().uuidString.lowercased() + ".ipa"
            try files.requireMissing(path)
            ownedRemoteStagingPath = path
            let upload = RemoteUpload(files: files, stream: afc, path: path)
            remote = upload
            // Runs before the first possible remote file creation. A caller can
            // durably retain this unique planned path even if cancellation later
            // prevents same-connection cleanup. No upload is claimed here.
            try await beforeUploadCreation(UploadIntent(path: path, archive: archive, bundle: bundle,
                version: version, device: afcProof.peerCertificateSHA256))
            try cancellation.check(); try afc.check()
            defer { upload.cleanupIfSafe(stage: stage) }
            upload.creationAttempted = true
            let handle = try files.open(path); upload.handle = handle
            var hash = SHA256()
            var offset = 0
            while offset < archive.byteCount {
                try cancellation.check(); try afc.check()
                let count = min(Limits.chunkBytes, archive.byteCount - offset)
                let bytes = try await archive.read(offset, count)
                try cancellation.check(); try afc.check()
                guard bytes.count == count else { throw Failure.archiveChanged }
                try files.write(handle, bytes: bytes)
                hash.update(data: bytes); offset += bytes.count
            }
            try files.close(handle); upload.handle = nil
            let digest = Data(hash.finalize())
            guard digest == archive.sha256 else { throw Failure.archiveChanged }
            let installation = PlistChannel(proxy)
            let submission = UpgradeSubmission(path: path, digest: digest, bytes: offset, bundle: bundle,
                version: version, device: proxyProof.peerCertificateSHA256)
            try await beforeUpgradeSubmission(submission)
            try cancellation.check()
            try proxy.check()
            stage = .upgrade
            try installation.send(["Command": .string("Upgrade"), "PackagePath": .string(path),
                "ClientOptions": .dictionary(["CFBundleIdentifier": .string(bundle)])])
            var progress = 0
            var progressBytes = 0
            while true {
                let response = try installation.receive()
                progress += 1; progressBytes += installation.lastResponseBytes
                guard progress <= Limits.progressMessages, progressBytes <= Limits.progressBytes else { throw Failure.progressLimit }
                if let percent = response["PercentComplete"] {
                    guard case .integer(let value) = percent, (0...100).contains(value) else { throw Failure.malformedResponse }
                }
                if response["Status"] == .string("Complete") { upload.upgradeReportedComplete = true; break }
                guard case .string(let state)? = response["Status"], !state.isEmpty, state.utf8.count <= 256 else { throw Failure.malformedResponse }
            }
            stage = .lookup
            let installed = try lookupOn(installation, bundle: bundle)
            guard installed == .reported(bundleIdentifier: bundle, bundleVersion: version) else { throw Failure.lookupMismatch }
            stage = .cleanup
            try files.remove(path)
            remoteStagingRemovalVerified = true; upload.removalVerified = true
            stage = .stopSession
            try stopSession(channel, sessionID: sessionID)
            try cancellation.check(); try lockdown.check()
            return Receipt(bundle: bundle, version: version, digest: digest, bytes: offset, progress: progress,
                lockdown: lockdownProof, afc: afcProof, installation: proxyProof, submission: submission)
        } catch { throw OperationFailure(stage: stage, underlying: error,
            ownedRemoteStagingPath: ownedRemoteStagingPath,
            remoteStagingRemovalVerified: remoteStagingRemovalVerified || remote?.removalVerified == true,
            remoteCreationAttempted: remote?.creationAttempted == true, cleanupAttempted: remote?.cleanupAttempted == true,
            cleanupErrors: remote?.cleanupErrors ?? []) }
    }
    private final class RemoteUpload {
        let files: AFCChannel
        let stream: Transport.Stream
        let path: String
        var handle: UInt64?
        var creationAttempted = false
        var upgradeReportedComplete = false
        var removalVerified = false
        var cleanupAttempted = false
        var cleanupErrors: [Error] = []
        init(files: AFCChannel, stream: Transport.Stream, path: String) { self.files = files; self.stream = stream; self.path = path }
        func cleanupIfSafe(stage: Stage) {
            // No new connection, no work beyond the existing absolute deadline,
            // no deletion while an interrupted submitted Upgrade may still read
            // the IPA. The original operation error is always retained.
            guard creationAttempted, !removalVerified, stream.authentication != nil,
                  stage.rawValue < Stage.upgrade.rawValue || upgradeReportedComplete else { return }
            cleanupAttempted = true
            if let handle {
                do { try files.close(handle); self.handle = nil }
                catch { cleanupErrors.append(error) }
            }
            guard stream.authentication != nil else { return }
            do { try files.remove(path); removalVerified = true }
            catch { cleanupErrors.append(error) }
        }
    }
    static func openSession(_ channel: PlistChannel, pairing: Transport.PairingIdentity, at date: Date) throws -> (id: String, authentication: Transport.Authentication) {
        try channel.send(["Label": .string("Reading"), "Request": .string("StartSession"),
            "HostID": .string(pairing.hostID), "SystemBUID": .string(pairing.systemBUID)])
        let session = try channel.receive(request: "StartSession")
        guard session["EnableSessionSSL"] == .boolean(true), case .string(let id)? = session["SessionID"],
              !id.isEmpty, id.utf8.count <= 256, !id.utf8.contains(0) else { throw Failure.sessionMismatch }
        try channel.stream.authenticate(identity: pairing.hostIdentity, expectedPeerDER: pairing.deviceCertificateDER,
            rootDER: pairing.rootCertificateDER, at: date)
        guard let authentication = channel.stream.authentication else { throw Transport.Failure.missingFreshAuthentication }
        return (id, authentication)
    }
    static func stopSession(_ channel: PlistChannel, sessionID: String) throws {
        try channel.send(["Label": .string("Reading"), "Request": .string("StopSession"), "SessionID": .string(sessionID)])
        let response = try channel.receive(request: "StopSession")
        if let echoed = response["SessionID"], echoed != .string(sessionID) { throw Failure.sessionMismatch }
    }
    private static func lookupOn(_ channel: PlistChannel, bundle: String) throws -> LookupObservation.Presence {
        try channel.send(["Command": .string("Lookup"), "ClientOptions": .dictionary([
            "ApplicationType": .string("Any"), "BundleIDs": .array([.string(bundle)])])])
        var observation: LookupObservation.Presence?
        var messages = 0
        var bytes = 0
        while true {
            // receive() rejects Error before any LookupResult from that frame.
            // A matching interim result is not a terminal Lookup ACK.
            let response = try channel.receive()
            messages += 1; bytes += channel.lastResponseBytes
            guard messages <= Limits.progressMessages, bytes <= Limits.progressBytes else { throw Failure.progressLimit }
            if let value = response["LookupResult"] {
                guard case .dictionary(let result) = value else { throw Failure.malformedResponse }
                // Upstream's lookup callback replaces the prior result, rather
                // than merging distinct snapshots. This query has one BundleID.
                if result.isEmpty { observation = .notFound }
                else {
                    guard result.count == 1, case .dictionary(let application)? = result[bundle],
                          application["CFBundleIdentifier"] == .string(bundle), case .string(let version)? = application["CFBundleVersion"],
                          !version.isEmpty, version.utf8.count <= 256, !version.utf8.contains(0) else { throw Failure.lookupMismatch }
                    observation = .reported(bundleIdentifier: bundle, bundleVersion: version)
                }
            }
            if let percent = response["PercentComplete"] {
                guard case .integer(let value) = percent, (0...100).contains(value) else { throw Failure.malformedResponse }
            }
            if response["Status"] == .string("Complete") {
                guard let observation else { throw Failure.malformedResponse }
                return observation
            }
            if let status = response["Status"] {
                guard case .string(let name) = status, !name.isEmpty, name.utf8.count <= 256 else { throw Failure.malformedResponse }
            }
        }
    }
    static func startService(_ name: String, on channel: PlistChannel, endpoint: Transport.Endpoint) throws -> Transport.Endpoint {
        try channel.send(["Request": .string("StartService"), "Service": .string(name)])
        let result = try channel.receive(request: "StartService")
        guard case .integer(let raw)? = result["Port"], let port = UInt16(exactly: raw), port > 0 else { throw Failure.invalidServicePort }
        // Upstream permits plaintext services on USB. This direct TCP adapter
        // has no authenticated mux/tunnel provider, so it cannot safely assert
        // service identity for that branch. It never silently downgrades TLS.
        guard result["EnableServiceSSL"] == .boolean(true) else { throw Failure.unauthenticatedService(name) }
        return endpoint.service(port)
    }

    final class PlistChannel {
        let stream: Transport.Stream
        private(set) var lastResponseBytes = 0
        init(_ stream: Transport.Stream) { self.stream = stream }
        func send(_ dictionary: [String: Value]) throws {
            let bytes = try PropertyListSerialization.data(fromPropertyList: try object(.dictionary(dictionary)), format: .xml, options: 0)
            guard !bytes.isEmpty, bytes.count <= Limits.plistBytes else { throw Failure.malformedPlist }
            var length = UInt32(bytes.count).bigEndian
            try withUnsafeBytes(of: &length) { try stream.write(Data($0)) }
            try stream.write(bytes)
        }
        func receive(request: String? = nil) throws -> [String: Value] {
            let header = try stream.read(count: 4)
            let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count > 0, count <= UInt32(Limits.plistBytes) else { throw Failure.malformedPlist }
            let bytes = try stream.read(count: Int(count)); lastResponseBytes = bytes.count + 4
            guard case .dictionary(let value) = try SelfRenewalDERPropertyList.decodeXMLPropertyList(bytes) else { throw Failure.malformedPlist }
            if let error = value["Error"] {
                switch error {
                case .string(let message): throw Failure.remoteError(String(message.prefix(512)))
                case .integer(let code): throw Failure.remoteError("device-error-" + String(code))
                default: throw Failure.malformedResponse
                }
            }
            if value["ErrorDescription"] != nil { throw Failure.remoteError("installation-proxy-error") }
            if let request, let echoed = value["Request"], echoed != .string(request) { throw Failure.malformedResponse }
            return value
        }
        private func object(_ value: Value) throws -> Any {
            switch value {
            case .dictionary(let dictionary): return try dictionary.mapValues { try object($0) }
            case .array(let values): return try values.map { try object($0) }
            case .string(let value): return value
            case .data(let value): return value
            case .integer(let value): return value
            case .boolean(let value): return value
            case .date(let value): return value
            case .null: throw Failure.malformedPlist
            }
        }
    }

    final class AFCChannel {
        struct Packet {
            let operation: UInt64
            let sequence: UInt64
            let header: Data
            let payload: Data
        }
        private let stream: Transport.Stream
        private var sequence: UInt64 = 0
        init(_ stream: Transport.Stream) { self.stream = stream }
        static func integer(_ value: UInt64) -> Data {
            var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) }
        }
        static func unsigned(_ bytes: Data) throws -> UInt64 {
            guard bytes.count == 8 else { throw Failure.malformedAFC }
            return bytes.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        func exchange(_ operation: UInt64, header: Data = Data(), payload: Data = Data()) throws -> Packet {
            guard header.count <= 4_096, payload.count <= Limits.chunkBytes, sequence < UInt64.max else { throw Failure.malformedAFC }
            let current = sequence; sequence += 1
            let fields: [UInt64] = [0x4141504c36414643, UInt64(40 + header.count + payload.count), UInt64(40 + header.count), current, operation]
            var request = fields.reduce(into: Data()) { $0.append(Self.integer($1)) }
            request.append(header); request.append(payload)
            try stream.write(request)
            let response = try receive()
            guard response.sequence == current else { throw Failure.malformedAFC }
            if response.operation == 1 {
                guard response.payload.isEmpty else { throw Failure.malformedAFC }
                let status = try Self.unsigned(response.header)
                guard status == 0 else { throw Failure.afcStatus(status) }
            }
            return response
        }
        func receive() throws -> Packet {
            let raw = try stream.read(count: 40)
            let fields = try stride(from: 0, to: 40, by: 8).map { try Self.unsigned(Data(raw[$0..<($0 + 8)])) }
            guard fields[0] == 0x4141504c36414643, fields[1] >= 40, fields[1] <= UInt64(Limits.chunkBytes + 4_136),
                  fields[2] >= 40, fields[2] <= fields[1], fields[2] - 40 <= 4_096 else { throw Failure.malformedAFC }
            return Packet(operation: fields[4], sequence: fields[3],
                header: try stream.read(count: Int(fields[2] - 40)), payload: try stream.read(count: Int(fields[1] - fields[2])))
        }
        private func status(_ packet: Packet) throws {
            guard packet.operation == 1, packet.payload.isEmpty, try Self.unsigned(packet.header) == 0 else { throw Failure.malformedAFC }
        }
        private func path(_ path: String) -> Data { Data((path + "\0").utf8) }
        func requireMissing(_ path: String) throws {
            do { _ = try exchange(0x0a, header: self.path(path)); throw Failure.malformedAFC }
            catch Failure.afcStatus(8) { return }
        }
        func ensureStagingDirectory() throws {
            do {
                let response = try exchange(0x0a, header: path("PublicStaging"))
                guard response.operation == 2, response.header.isEmpty,
                      let text = String(data: response.payload, encoding: .utf8), text.last == "\0" else { throw Failure.malformedAFC }
                var fields = text.components(separatedBy: "\0"); fields.removeLast()
                guard fields.count % 2 == 0, fields.count <= 128 else { throw Failure.malformedAFC }
                var values: [String: String] = [:]
                for offset in stride(from: 0, to: fields.count, by: 2) {
                    guard values[fields[offset]] == nil else { throw Failure.malformedAFC }
                    values[fields[offset]] = fields[offset + 1]
                }
                guard values["st_ifmt"] == "S_IFDIR" else { throw Failure.malformedAFC }
            } catch Failure.afcStatus(8) { try status(exchange(9, header: path("PublicStaging"))) }
        }
        func open(_ path: String) throws -> UInt64 {
            let response = try exchange(0x0d, header: Self.integer(3) + self.path(path))
            guard response.operation == 0x0e, response.payload.isEmpty else { throw Failure.malformedAFC }
            let descriptor = try Self.unsigned(response.header)
            guard descriptor != 0 else { throw Failure.malformedAFC }; return descriptor
        }
        func write(_ descriptor: UInt64, bytes: Data) throws { try status(exchange(0x10, header: Self.integer(descriptor), payload: bytes)) }
        func close(_ descriptor: UInt64) throws { try status(exchange(0x14, header: Self.integer(descriptor))) }
        func remove(_ path: String) throws { try status(exchange(8, header: self.path(path))) }
    }
}
