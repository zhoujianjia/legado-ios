import CryptoKit
import Foundation
import Security

/// A user-selected trust boundary. There is deliberately no default server.
/// Decoding this public endpoint never authorizes Apple account access.
struct SelfRenewalAnisetteV3Configuration: Sendable, Codable, Equatable {
    let endpoint: URL
    init(endpoint: URL) throws {
        guard endpoint.scheme == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.port == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/",
              host != "apple.com", !host.hasSuffix(".apple.com"),
              let canonical = URL(string: "https://" + host.lowercased()) else {
            throw SelfRenewalAnisetteV3Provider.Failure.invalidConfiguration
        }
        self.endpoint = canonical
    }
    func validate() throws {
        guard try Self(endpoint: endpoint).endpoint == endpoint else {
            throw SelfRenewalAnisetteV3Provider.Failure.invalidConfiguration
        }
    }
    func url(_ path: String, webSocket: Bool = false) -> URL {
        // Only fixed protocol paths, never paths received from the provider.
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.scheme = webSocket ? "wss" : "https"; parts.path = path
        return parts.url!
    }
}

/// This typed surface has no Apple ID, password, token, code or arbitrary
/// headers. The same HTTP owner builds both provider and Apple requests.
enum SelfRenewalAnisetteRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Metadata: Sendable {
        let clientInfo: String; let userAgent: String
        let localUserID: String; let deviceID: String; let issuedAt: Date
    }
    case clientInfo(SelfRenewalAnisetteV3Configuration)
    case headers(SelfRenewalAnisetteV3Configuration, identifier: Data, adiPB: Data)
    case appleLookup(Metadata)
    case appleStart(URL, Metadata)
    case appleFinish(URL, Metadata, cpim: String)
    var description: String { "Anisette protocol request <redacted>" }
    var debugDescription: String { description }
}

protocol SelfRenewalAnisetteProvisioningSocket: Sendable {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close() async
}

/// Independent implementation of the published SideStore v3 wire contract.
/// The random 16-byte identifier is a logical protocol identity, not a
/// measurement of this physical device. Apple alone validates its outputs.
actor SelfRenewalAnisetteV3Provider {
    enum Failure: Error, Sendable, Equatable {
        case invalidConfiguration, malformedResponse, limit, storageUnavailable
        case storage, staleRegistration, registrationBoundToAnotherEndpoint
        case provisioningOutcomeUnknown, registrationRejected, remoteRejected
        case resetNotRequired, resetCommitUnknown
        case busy, timedOut, http(Int)
    }
    struct RegistrationObservation: Sendable, Equatable {
        enum Phase: String, Sendable { case unprovisioned, provisioningOutcomeUnknown, resetOutcomeUnknown, provisioned }
        let phase: Phase
    }
    private struct Registration: Codable {
        enum Phase: String, Codable { case unprovisioned, provisioningStarted, resetPending, provisioned }
        let schema: Int; let namespaceID: UUID; let endpoint: URL
        let identifier: Data
        var phase: Phase
        var adiPB: Data?
        // An interrupted explicit reset retains its one proposed identity in
        // this same record. Retrying reset must reuse it, never rotate again.
        var resetIdentifier: Data? = nil
    }
    private struct Loaded { let record: Registration; let encoded: String }
    private struct ClientInfo: Decodable { let client_info: String; let user_agent: String }
    private struct Message: Decodable {
        let result: String
        let cpim: String?
        let adi_pb: String?
    }
    private struct Headers: Decodable {
        let result: String
        let machineID: String?
        let oneTimePassword: String?
        let routingInfo: String?
        enum CodingKeys: String, CodingKey {
            case result
            case machineID = "X-Apple-I-MD-M", oneTimePassword = "X-Apple-I-MD"
            case routingInfo = "X-Apple-I-MD-RINFO"
        }
    }
    private let configuration: SelfRenewalAnisetteV3Configuration
    private let namespaceID: UUID
    private let transport: any SelfRenewalDeveloperAccountTransport
    private let storage: any SelfRenewalDeveloperSessionStorage
    private let clock: @Sendable () -> Date
    private let randomIdentifier: @Sendable () throws -> Data
    private var busy = false
    static let maximumBlobBytes = 65_536
    static let maximumRecordBytes = 131_072

    init(configuration: SelfRenewalAnisetteV3Configuration, namespaceID: UUID,
        transport: any SelfRenewalDeveloperAccountTransport, storage: any SelfRenewalDeveloperSessionStorage,
        clock: @escaping @Sendable () -> Date = { Date() },
        randomIdentifier: @escaping @Sendable () throws -> Data = SelfRenewalAnisetteV3Provider.makeIdentifier) throws {
        try configuration.validate()
        self.configuration = configuration; self.namespaceID = namespaceID
        self.transport = transport; self.storage = storage; self.clock = clock; self.randomIdentifier = randomIdentifier
    }

    func observeRegistration() throws -> RegistrationObservation? {
        try Self.observeRegistration(configuration: configuration, namespaceID: namespaceID, storage: storage)
    }

    /// Read-only local observation: no ID creation, URLSession or network.
    static func observeRegistration(configuration: SelfRenewalAnisetteV3Configuration, namespaceID: UUID,
        storage: any SelfRenewalDeveloperSessionStorage) throws -> RegistrationObservation? {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.anisette.phase", "bytesLimit=\(maximumRecordBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        try configuration.validate()
        guard let loaded = try load(configuration: configuration, namespaceID: namespaceID, storage: storage) else { return nil }
        let phase: RegistrationObservation.Phase
        switch loaded.record.phase {
        case .unprovisioned: phase = .unprovisioned
        case .provisioningStarted: phase = .provisioningOutcomeUnknown
        case .resetPending: phase = .resetOutcomeUnknown
        case .provisioned: phase = .provisioned
        }
        return RegistrationObservation(phase: phase)
    }

    /// Only the Session's explicit, confirmed-signout use case calls this in
    /// production. No provider or Apple request is performed. Provisioned blobs
    /// cannot be erased; a failed reset never rolls back over newer storage.
    static func resetUnknownRegistration(configuration: SelfRenewalAnisetteV3Configuration, namespaceID: UUID,
        storage: any SelfRenewalDeveloperSessionStorage,
        randomIdentifier: @Sendable () throws -> Data = SelfRenewalAnisetteV3Provider.makeIdentifier) throws -> RegistrationObservation {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.anisette.reset", "bytesLimit=\(maximumRecordBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        try configuration.validate(); try Task.checkCancellation()
        guard let loaded = try load(configuration: configuration, namespaceID: namespaceID, storage: storage) else {
            throw Failure.resetNotRequired
        }
        let pending: Loaded
        switch loaded.record.phase {
        case .provisioningStarted:
            let identifier = try randomIdentifier()
            guard identifier.count == 16, identifier != loaded.record.identifier else { throw Failure.invalidConfiguration }
            var record = loaded.record; record.phase = .resetPending; record.resetIdentifier = identifier
            pending = try saveReset(record, replacing: loaded.encoded, namespaceID: namespaceID, storage: storage)
        case .resetPending:
            pending = loaded
        case .unprovisioned, .provisioned:
            throw Failure.resetNotRequired
        }
        try Task.checkCancellation()
        guard let identifier = pending.record.resetIdentifier else { throw Failure.storage }
        let completed = Registration(schema: pending.record.schema, namespaceID: pending.record.namespaceID, endpoint: pending.record.endpoint,
            identifier: identifier, phase: .unprovisioned, adiPB: nil)
        _ = try saveReset(completed, replacing: pending.encoded, namespaceID: namespaceID, storage: storage)
        return RegistrationObservation(phase: .unprovisioned)
    }

    private static func saveReset(_ record: Registration, replacing previous: String, namespaceID: UUID,
        storage: any SelfRenewalDeveloperSessionStorage) throws -> Loaded {
        let previousBytes = Data(previous.utf8)
        guard try storage.loadAnisetteRegistration(namespace: namespaceID).map({ Data($0.utf8) }) == previousBytes else { throw Failure.staleRegistration }
        let raw = try JSONEncoder().encode(record)
        guard raw.count <= maximumRecordBytes, let encoded = String(data: raw, encoding: .utf8) else { throw Failure.limit }
        var writeError: Error?
        do { try storage.saveAnisetteRegistration(namespace: namespaceID, value: encoded) }
        catch { writeError = error }
        let observed: String?
        do { observed = try storage.loadAnisetteRegistration(namespace: namespaceID) }
        catch { throw Failure.resetCommitUnknown }
        let observedBytes = observed.map { Data($0.utf8) }
        if observedBytes == Data(encoded.utf8) { return Loaded(record: record, encoded: encoded) }
        if observedBytes == previousBytes {
            // Exact old bytes prove this step did not apply. No rollback write.
            if let writeError { throw writeError }
            throw Failure.storage
        }
        // Missing/conflicting bytes and unreadable post-write state cannot be
        // called a failed write or a success. Keep the durable reset intent.
        throw Failure.resetCommitUnknown
    }

    func freshAnisette() async throws -> SelfRenewalDeveloperAccountClient.Anisette {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        let started = SourcePerfTrace.now
        var responseBytes = 0
        defer { SourcePerfTrace.record("renewal.anisette.v3", "bytes=\(responseBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        try Task.checkCancellation()
        var loaded = try loadOrCreate()
        guard loaded.record.phase != .provisioningStarted else { throw Failure.provisioningOutcomeUnknown }
        guard loaded.record.phase != .resetPending else { throw Failure.resetCommitUnknown }
        // Fetching client metadata is read-only; a failure does not change a
        // registration or choose another server.
        let rawClient = try await response(.clientInfo(configuration))
        responseBytes += rawClient.count
        let client: ClientInfo
        do { client = try JSONDecoder().decode(ClientInfo.self, from: rawClient) }
        catch { throw Failure.malformedResponse }
        guard Self.header(client.client_info, maximum: 4_096), Self.header(client.user_agent, maximum: 1_024) else {
            throw Failure.malformedResponse
        }
        if loaded.record.phase == .unprovisioned { loaded = try await provision(loaded, client: client) }
        try Task.checkCancellation()
        guard let adiPB = loaded.record.adiPB else { throw Failure.storage }
        let raw = try await response(.headers(configuration, identifier: loaded.record.identifier, adiPB: adiPB))
        responseBytes += raw.count
        let headers: Headers
        do { headers = try JSONDecoder().decode(Headers.self, from: raw) }
        catch { throw Failure.malformedResponse }
        // A rejected registration is an explicit recovery requirement. It
        // never discards adi_pb, silently reprovisions, rotates or retries.
        guard headers.result != "GetHeadersError" else { throw Failure.registrationRejected }
        guard headers.result == "Headers", let machine = headers.machineID, let otp = headers.oneTimePassword,
              let routing = headers.routingInfo, Self.header(machine, maximum: 4_096), Self.header(otp, maximum: 4_096),
              !routing.isEmpty, routing.utf8.count <= 20, routing.utf8.allSatisfy({ (48...57).contains($0) }),
              let routingInfo = UInt64(routing), String(routingInfo) == routing else { throw Failure.malformedResponse }
        let now = clock(); guard now.timeIntervalSince1970.isFinite else { throw Failure.invalidConfiguration }
        return SelfRenewalDeveloperAccountClient.Anisette(machineID: machine, oneTimePassword: otp,
            localUserID: Self.localUserID(loaded.record.identifier), routingInfo: routingInfo,
            // SideStore's pinned AnisetteKit uses the literal protocol marker
            // "0" for this field. It is not a physical serial measurement.
            // No device serial, machine ID or OTP is invented from our ID.
            deviceID: Self.deviceID(loaded.record.identifier), deviceSerialNumber: "0",
            clientInfo: client.client_info, issuedAt: now, locale: "en_US", timeZone: "UTC")
    }

    private func provision(_ loaded: Loaded, client: ClientInfo) async throws -> Loaded {
        let record = loaded.record
        let now = clock(); guard now.timeIntervalSince1970.isFinite else { throw Failure.invalidConfiguration }
        let metadata = SelfRenewalAnisetteRequest.Metadata(clientInfo: client.client_info, userAgent: client.user_agent,
            localUserID: Self.localUserID(record.identifier), deviceID: Self.deviceID(record.identifier), issuedAt: now)
        let lookup = try Self.dictionary(SelfRenewalDERPropertyList.decodeXMLPropertyList(try await response(.appleLookup(metadata))))
        let urls = try Self.dictionary(lookup["urls"])
        let start = try Self.provisioningURL(urls["midStartProvisioning"], path: "/grandslam/MidService/startMachineProvisioning")
        let finish = try Self.provisioningURL(urls["midFinishProvisioning"], path: "/grandslam/MidService/finishMachineProvisioning")
        try Task.checkCancellation()
        var intent = record; intent.phase = .provisioningStarted
        let pending = try save(intent, replacing: loaded.encoded)
        // Durable intent precedes the first remote provisioning side effect.
        // Interruption preserves this exact ID and refuses automatic replay.
        let socket = try await transport.openAnisetteProvisioning(configuration)
        do {
            let committed = try await withTaskCancellationHandler {
                for step in 0..<4 {
                    try Task.checkCancellation()
                    let data = try await receiveMessage(socket)
                    guard data.count <= Self.maximumRecordBytes else { throw Failure.limit }
                    let message: Message
                    do { message = try JSONDecoder().decode(Message.self, from: data) }
                    catch { throw Failure.malformedResponse }
                    switch (step, message.result) {
                    case (0, "GiveIdentifier"):
                        try await sendMessage(try Self.json(["identifier": record.identifier.base64EncodedString()]), to: socket)
                    case (1, "GiveStartProvisioningData"):
                        let values = try Self.appleResponse(try await response(.appleStart(start, metadata)))
                        let spim = try Self.base64Text(values["spim"])
                        try await sendMessage(try Self.json(["spim": spim]), to: socket)
                    case (2, "GiveEndProvisioningData"):
                        guard let cpim = message.cpim else { throw Failure.malformedResponse }
                        _ = try Self.blob(cpim)
                        let values = try Self.appleResponse(try await response(.appleFinish(finish, metadata, cpim: cpim)))
                        let ptm = try Self.base64Text(values["ptm"]), tk = try Self.base64Text(values["tk"])
                        try await sendMessage(try Self.json(["ptm": ptm, "tk": tk]), to: socket)
                    case (3, "ProvisioningSuccess"):
                        guard let value = message.adi_pb else { throw Failure.malformedResponse }
                        var completed = intent; completed.adiPB = try Self.blob(value); completed.phase = .provisioned
                        // Success is committed before closing or fetching an
                        // OTP. Normal socket close cannot race get_headers.
                        // A cancellation racing this confirmed success must
                        // still retain the registration; no post-success await
                        // or cancellation check precedes the secure save.
                        return try save(completed, replacing: pending.encoded)
                    default: throw Failure.remoteRejected
                    }
                }
                throw Failure.malformedResponse
            } onCancel: {
                // Closing the actual socket unblocks receive. The caller still
                // awaits this operation and its close before releasing busy.
                Task { await socket.close() }
            }
            await socket.close()
            return committed
        } catch {
            await socket.close()
            throw error
        }
    }

    private func response(_ request: SelfRenewalAnisetteRequest) async throws -> Data {
        let value = try await transport.sendAnisette(request)
        try Task.checkCancellation()
        guard value.statusCode == 200 else { throw Failure.http(value.statusCode) }
        guard !value.body.isEmpty, value.body.count <= Self.maximumRecordBytes else { throw Failure.limit }
        return value.body
    }
    private func receiveMessage(_ socket: any SelfRenewalAnisetteProvisioningSocket) async throws -> Data {
        try await socketDeadline(socket) { try await socket.receive() }
    }
    private func sendMessage(_ data: Data, to socket: any SelfRenewalAnisetteProvisioningSocket) async throws {
        try await socketDeadline(socket) { try await socket.send(data) }
    }
    private func socketDeadline<T: Sendable>(_ socket: any SelfRenewalAnisetteProvisioningSocket,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                // Network deadline for a stalled server/handshake. This is not
                // a timing-based retry or a wait for local state to settle.
                try await Task.sleep(for: .seconds(30))
                await socket.close()
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw Failure.malformedResponse }
            return value
        }
    }
    private func loadOrCreate() throws -> Loaded {
        if let loaded = try load() { return loaded }
        let identifier = try randomIdentifier(); guard identifier.count == 16 else { throw Failure.invalidConfiguration }
        return try save(Registration(schema: 1, namespaceID: namespaceID, endpoint: configuration.endpoint,
            identifier: identifier, phase: .unprovisioned, adiPB: nil), replacing: nil)
    }
    private func load() throws -> Loaded? {
        try Self.load(configuration: configuration, namespaceID: namespaceID, storage: storage)
    }
    private static func load(configuration: SelfRenewalAnisetteV3Configuration, namespaceID: UUID,
        storage: any SelfRenewalDeveloperSessionStorage) throws -> Loaded? {
        guard let encoded = try storage.loadAnisetteRegistration(namespace: namespaceID) else { return nil }
        guard encoded.utf8.count <= Self.maximumRecordBytes else { throw Failure.storage }
        let value: Registration
        do { value = try JSONDecoder().decode(Registration.self, from: Data(encoded.utf8)) }
        catch { throw Failure.storage }
        guard value.schema == 1, value.namespaceID == namespaceID, value.identifier.count == 16,
              value.adiPB == nil || (1...Self.maximumBlobBytes).contains(value.adiPB!.count),
              (value.phase == .provisioned) == (value.adiPB != nil) else { throw Failure.storage }
        if value.phase == .resetPending {
            guard let proposed = value.resetIdentifier, proposed.count == 16, proposed != value.identifier else { throw Failure.storage }
        } else if value.resetIdentifier != nil { throw Failure.storage }
        guard value.endpoint == configuration.endpoint else { throw Failure.registrationBoundToAnotherEndpoint }
        return Loaded(record: value, encoded: encoded)
    }
    private func save(_ record: Registration, replacing previous: String?) throws -> Loaded {
        let current = try storage.loadAnisetteRegistration(namespace: namespaceID)
        guard current.map({ Data($0.utf8) }) == previous.map({ Data($0.utf8) }) else { throw Failure.staleRegistration }
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= Self.maximumRecordBytes, let encoded = String(data: bytes, encoding: .utf8) else { throw Failure.limit }
        // One session actor and its flock own this Keychain scope. This is an
        // equality guard, not a claimed cross-process Keychain CAS.
        try storage.saveAnisetteRegistration(namespace: namespaceID, value: encoded)
        return Loaded(record: record, encoded: encoded)
    }
    static func makeIdentifier() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.storage }
        return Data(bytes)
    }
    private static func localUserID(_ identifier: Data) -> String { SHA256.hash(data: identifier).map { String(format: "%02x", $0) }.joined() }
    private static func deviceID(_ identifier: Data) -> String {
        let bytes = Array(identifier)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }
    private static func header(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }
    private static func blob(_ value: String) throws -> Data {
        guard value.utf8.count <= 87_384, let bytes = Data(base64Encoded: value), !bytes.isEmpty,
              bytes.count <= maximumBlobBytes, bytes.base64EncodedString() == value else { throw Failure.malformedResponse }
        return bytes
    }
    private static func json(_ dictionary: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    }
    private static func dictionary(_ value: SelfRenewalDERPropertyList.Value?) throws -> [String: SelfRenewalDERPropertyList.Value] {
        guard case .dictionary(let result)? = value else { throw Failure.malformedResponse }; return result
    }
    private static func base64Text(_ value: SelfRenewalDERPropertyList.Value?) throws -> String {
        guard case .string(let text)? = value else { throw Failure.malformedResponse }
        _ = try blob(text); return text
    }
    private static func appleResponse(_ data: Data) throws -> [String: SelfRenewalDERPropertyList.Value] {
        let root = try dictionary(SelfRenewalDERPropertyList.decodeXMLPropertyList(data))
        return try dictionary(root["Response"])
    }
    private static func provisioningURL(_ value: SelfRenewalDERPropertyList.Value?, path: String) throws -> URL {
        guard case .string(let text)? = value, text == "https://gsa.apple.com" + path, let url = URL(string: text) else {
            throw Failure.malformedResponse
        }
        return url
    }
}
