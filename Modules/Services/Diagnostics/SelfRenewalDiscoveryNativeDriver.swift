import Foundation
import Darwin
import dnssd
@preconcurrency import Network

/// DNS-SD resolution only. This adapter never creates a candidate connection or reads TXT.
/// Its serial queue is an SDK requirement: DNSServiceRefDeallocate must run on the same
/// queue passed to DNSServiceSetDispatchQueue. No caller synchronously waits on this queue.
final class SelfRenewalDiscoveryNativeDriver: @unchecked Sendable {
    private static let serviceType = "_remotepairing._tcp"
    private static let domain = "local."
    private static let maximumServices = 8
    private static let maximumAddressCallbacks = 32
    private static let maximumCallbacks = 128
    private static let windowSeconds: TimeInterval = 3

    private struct Identity: Hashable {
        let name: String
        let type: String
        let domain: String
    }

    private struct Key: Hashable {
        let identity: Identity
        let interfaceIndex: UInt32
    }

    private final class CallbackContext {
        weak var driver: SelfRenewalDiscoveryNativeDriver?
        let key: Key
        let id: UUID
        var active = true

        init(driver: SelfRenewalDiscoveryNativeDriver, key: Key, id: UUID) {
            self.driver = driver
            self.key = key
            self.id = id
        }
    }

    private final class Record {
        let id = UUID()
        let key: Key
        var resolveRef: DNSServiceRef?
        var addressRef: DNSServiceRef?
        var resolveContext: CallbackContext?
        var addressContext: CallbackContext?
        var target: String?
        var port: UInt16?

        init(key: Key) { self.key = key }
    }

    private let queue = DispatchQueue(label: "reader.selfRenewal.dnssd", qos: .utility)
    private var continuation: AsyncStream<SelfRenewalDiscoveryEvent>.Continuation?
    private var browser: NWBrowser?
    private var timer: DispatchSourceTimer?
    private var records: [Key: Record] = [:]
    private var examinedKeys: Set<Key> = []
    private var interfaceHistory: [Identity: Set<UInt32>] = [:]
    private var callbackCount = 0
    private var addressCallbackCount = 0
    private var serviceGenerationCount = 0
    private var started = false
    private var cancelled = false
    private var finished = false
    /// Keeps the driver alive until its bounded SDK operation has been torn down.
    private var activeOwner: SelfRenewalDiscoveryNativeDriver?

    /// Single-run stream. Only an explicit windowEnded permits the caller to use results.
    /// A dropped event stops all producers and finishes without windowEnded, so partial
    /// observations cannot become permission to connect.
    func start() -> AsyncStream<SelfRenewalDiscoveryEvent> {
        AsyncStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.cancel() }
            queue.async { self.begin(continuation) }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.finish()
        }
    }

    private func begin(_ continuation: AsyncStream<SelfRenewalDiscoveryEvent>.Continuation) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !started, !cancelled, !finished else {
            // Rejecting a second stream must not let that stream's termination cancel
            // the first stream, which owns the live SDK operations.
            continuation.onTermination = nil
            continuation.finish()
            return
        }
        started = true
        activeOwner = self
        self.continuation = continuation

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // A real foreground discovery deadline, not a settling delay.
        timer.schedule(deadline: .now() + Self.windowSeconds)
        timer.setEventHandler { [weak self] in self?.finish(terminal: .windowEnded) }
        self.timer = timer
        timer.resume()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: Self.domain), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in self?.browserChanged(state) }
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.browseChanged(results) }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func enterCallback() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return false }
        callbackCount += 1
        guard callbackCount <= Self.maximumCallbacks else {
            finish(terminal: .limitExceeded)
            return false
        }
        return true
    }

    private func browserChanged(_ state: NWBrowser.State) {
        guard enterCallback() else { return }
        switch state {
        case .ready: emit(.ready)
        case .waiting(let error): emit(.waiting(SelfRenewalTransportNetworkError(error)))
        case .failed(let error): finish(terminal: .failed(SelfRenewalTransportNetworkError(error)))
        case .cancelled: finish()
        default: break
        }
    }

    private func browseChanged(_ results: Set<NWBrowser.Result>) {
        guard enterCallback() else { return }
        guard results.count <= Self.maximumServices else { finish(terminal: .limitExceeded); return }
        var keys: Set<Key> = []
        var interfaces: [Identity: Set<UInt32>] = [:]
        for result in results {
            guard case let .service(name, type, domain, endpointInterface) = result.endpoint,
                  !name.isEmpty, name.utf8.count <= 63, !name.utf8.contains(0),
                  type.utf8.count <= 64, domain.utf8.count <= 64,
                  Self.canonicalType(type) == Self.serviceType,
                  domain.lowercased() == Self.domain else { continue }
            let identity = Identity(name: name, type: Self.serviceType, domain: Self.domain)
            guard result.interfaces.count <= Self.maximumServices else { finish(terminal: .limitExceeded); return }
            let discoveredInterfaces = result.interfaces.isEmpty ? endpointInterface.map { [$0] } ?? [] : result.interfaces
            for interface in discoveredInterfaces {
                guard let index = UInt32(exactly: interface.index), index > 0 else { continue }
                if let endpointInterface, endpointInterface.index != interface.index { continue }
                keys.insert(Key(identity: identity, interfaceIndex: index))
                interfaces[identity, default: []].insert(index)
            }
        }
        guard keys.count <= Self.maximumServices else { finish(terminal: .limitExceeded); return }
        for (identity, indices) in interfaces {
            if let previous = interfaceHistory[identity], previous != indices {
                finish(terminal: .invalidated)
                return
            }
            interfaceHistory[identity] = indices
        }
        for key in Array(records.keys) where !keys.contains(key) {
            guard let record = records.removeValue(forKey: key) else { continue }
            tearDown(record)
            emit(.removed(record.id))
            if finished { return }
        }
        for key in keys where records[key] == nil {
            examinedKeys.insert(key)
            serviceGenerationCount += 1
            guard examinedKeys.count <= Self.maximumServices, serviceGenerationCount <= Self.maximumServices else {
                finish(terminal: .limitExceeded)
                return
            }
            let record = Record(key: key)
            records[key] = record
            emit(.found(record.id))
            guard !finished else { return }
            beginResolve(record)
            if finished { return }
        }
    }

    private static func canonicalType(_ type: String) -> String {
        let value = type.lowercased()
        return value.hasSuffix(".") ? String(value.dropLast()) : value
    }

    private func beginResolve(_ record: Record) {
        let context = CallbackContext(driver: self, key: record.key, id: record.id)
        record.resolveContext = context
        let error = DNSServiceResolve(
            &record.resolveRef, 0, record.key.interfaceIndex, record.key.identity.name,
            Self.serviceType, Self.domain, Self.resolveReply,
            Unmanaged.passUnretained(context).toOpaque()
        )
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else { resolverFailed(record, error); return }
        guard let ref = record.resolveRef else { finish(terminal: .invalidated); return }
        let scheduleError = DNSServiceSetDispatchQueue(ref, queue)
        if scheduleError != DNSServiceErrorType(kDNSServiceErr_NoError) { resolverFailed(record, scheduleError) }
    }

    private static let resolveReply: DNSServiceResolveReply = {
        _, _, interfaceIndex, error, _, host, port, _, _, rawContext in
        guard let rawContext else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(rawContext).takeUnretainedValue()
        guard context.active, let driver = context.driver else { return }
        withExtendedLifetime(context) {
            driver.resolved(context, interfaceIndex: interfaceIndex, error: error, host: host, networkPort: port)
        }
    }

    private func resolved(
        _ context: CallbackContext, interfaceIndex: UInt32, error: DNSServiceErrorType,
        host: UnsafePointer<CChar>?, networkPort: UInt16
    ) {
        guard enterCallback(), let record = current(context) else { return }
        // DNS-SD leaves all other callback parameters undefined when error is nonzero.
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else { resolverFailed(record, error); return }
        guard interfaceIndex == record.key.interfaceIndex, let host,
              let target = Self.boundedString(host, maximumBytes: 1009), Self.allowedTarget(target) else {
            finish(terminal: .invalidated)
            return
        }
        let port = UInt16(bigEndian: networkPort)
        guard port > 0 else { finish(terminal: .invalidated); return }
        if let previous = record.target {
            if previous != target || record.port != port { finish(terminal: .invalidated) }
            return
        }
        record.target = target
        record.port = port
        let addressContext = CallbackContext(driver: self, key: record.key, id: record.id)
        record.addressContext = addressContext
        let addressError = DNSServiceGetAddrInfo(
            &record.addressRef, 0, record.key.interfaceIndex,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), target,
            Self.addressReply, Unmanaged.passUnretained(addressContext).toOpaque()
        )
        guard addressError == DNSServiceErrorType(kDNSServiceErr_NoError) else { resolverFailed(record, addressError); return }
        guard let ref = record.addressRef else { finish(terminal: .invalidated); return }
        let scheduleError = DNSServiceSetDispatchQueue(ref, queue)
        if scheduleError != DNSServiceErrorType(kDNSServiceErr_NoError) { resolverFailed(record, scheduleError) }
    }

    private static let addressReply: DNSServiceGetAddrInfoReply = {
        _, flags, interfaceIndex, error, _, address, ttl, rawContext in
        guard let rawContext else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(rawContext).takeUnretainedValue()
        guard context.active, let driver = context.driver else { return }
        withExtendedLifetime(context) {
            driver.addressed(context, flags: flags, interfaceIndex: interfaceIndex, error: error, address: address, ttl: ttl)
        }
    }

    private func addressed(
        _ context: CallbackContext, flags: DNSServiceFlags, interfaceIndex: UInt32,
        error: DNSServiceErrorType, address: UnsafePointer<sockaddr>?, ttl: UInt32
    ) {
        guard enterCallback(), let record = current(context) else { return }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else { resolverFailed(record, error); return }
        addressCallbackCount += 1
        guard addressCallbackCount <= Self.maximumAddressCallbacks else { finish(terminal: .limitExceeded); return }
        guard interfaceIndex == record.key.interfaceIndex, let address, let port = record.port else {
            finish(terminal: .invalidated)
            return
        }
        let numeric = SourcePerfTrace.span(
            "diagnostic.selfRenewalDiscovery.address", "main=\(Thread.isMainThread) bytes=\(Self.socketHeader(address).length)"
        ) { Self.numericAddress(address, interfaceIndex: interfaceIndex) }
        guard let numeric else { finish(terminal: .invalidated); return }
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) == 0 || ttl == 0 {
            emit(.addressRemoved(record.id, numeric))
        } else {
            emit(.resolved(record.id, SelfRenewalDiscoveredEndpoint(
                address: numeric, port: port, expiresAtUptime: SourcePerfTrace.now + TimeInterval(ttl)
            )))
        }
    }

    private func current(_ context: CallbackContext) -> Record? {
        guard context.active, let record = records[context.key], record.id == context.id else { return nil }
        return record
    }

    private func resolverFailed(_ record: Record, _ error: DNSServiceErrorType) {
        tearDown(record)
        // An address query can fail after it already returned an address. Invalidate
        // that candidate before reporting the error, so partial data cannot survive it.
        emit(.removed(record.id))
        emit(.resolutionFailed(SelfRenewalTransportNetworkError(.dns(error))))
    }

    private static func boundedString(_ pointer: UnsafePointer<CChar>, maximumBytes: Int) -> String? {
        let length = strnlen(pointer, maximumBytes + 1)
        guard length > 0, length <= maximumBytes else { return nil }
        return String(bytes: UnsafeBufferPointer(start: pointer, count: length).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    private static func allowedTarget(_ target: String) -> Bool {
        let value = target.lowercased()
        return value == "localhost" || value == "localhost." || value.hasSuffix(".local.")
    }

    private func emit(_ event: SelfRenewalDiscoveryEvent) {
        guard !finished, let continuation else { return }
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped, .terminated: finish()
        @unknown default: finish()
        }
    }

    private func finish(terminal: SelfRenewalDiscoveryEvent? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        finished = true
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        for record in records.values { tearDown(record) }
        records.removeAll()
        let continuation = self.continuation
        self.continuation = nil
        // If this final event is dropped, windowEnded is absent and the consumer fails closed.
        if let terminal { continuation?.yield(terminal) }
        continuation?.finish()
        examinedKeys.removeAll()
        interfaceHistory.removeAll()
        activeOwner = nil
    }

    private func tearDown(_ record: Record) {
        dispatchPrecondition(condition: .onQueue(queue))
        record.resolveContext?.active = false
        record.addressContext?.active = false
        if let ref = record.resolveRef { DNSServiceRefDeallocate(ref) }
        if let ref = record.addressRef { DNSServiceRefDeallocate(ref) }
        record.resolveRef = nil
        record.addressRef = nil
        // Keep context ownership until same-queue deallocation has returned. C pointers never
        // cross an async hop; Apple's client stub prevents further callbacks after deallocation.
        record.resolveContext = nil
        record.addressContext = nil
    }

    static func interfaceSnapshot() async -> SelfRenewalLocalAddressSnapshot? {
        guard !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) { captureInterfaces() }.value
    }

    private static func captureInterfaces() -> SelfRenewalLocalAddressSnapshot? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = SourcePerfTrace.now
        var entries: [SelfRenewalLocalInterfaceAddress] = []
        defer {
            SourcePerfTrace.record(
                "diagnostic.selfRenewalDiscovery.snapshot", "main=\(Thread.isMainThread) addresses=\(entries.count)", since: started
            )
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        var examinedNodes = 0
        while let node = cursor {
            examinedNodes += 1
            guard examinedNodes <= 256 else { return nil }
            cursor = node.pointee.ifa_next
            guard let raw = node.pointee.ifa_addr,
                  raw.pointee.sa_family == sa_family_t(AF_INET) || raw.pointee.sa_family == sa_family_t(AF_INET6),
                  let rawName = node.pointee.ifa_name,
                  let name = boundedString(rawName, maximumBytes: Int(IFNAMSIZ) - 1) else { continue }
            let index = if_nametoindex(rawName)
            guard index > 0, let address = numericAddress(UnsafePointer(raw), interfaceIndex: index) else { return nil }
            let flags = node.pointee.ifa_flags
            let loopback = flags & UInt32(IFF_LOOPBACK) != 0
            let pointToPoint = flags & UInt32(IFF_POINTOPOINT) != 0
            let netmask = address.family == .ipv4
                ? node.pointee.ifa_netmask.flatMap { ipv4MaskBytes(UnsafePointer($0)) } : nil
            let broadcast = flags & UInt32(IFF_BROADCAST) != 0
                ? node.pointee.ifa_dstaddr.flatMap { ipv4Bytes(UnsafePointer($0)) } : nil
            let knownInterface = isNumberedInterface(name, prefix: loopback ? "lo" : "en")
            entries.append(SelfRenewalLocalInterfaceAddress(
                address: address, interfaceIndex: index, rawFlags: flags,
                isUp: flags & UInt32(IFF_UP) != 0, isLoopback: loopback, isPointToPoint: pointToPoint,
                isEligibleInterface: knownInterface && !pointToPoint,
                ipv4Netmask: netmask, ipv4Broadcast: broadcast
            ))
            guard entries.count <= SelfRenewalLocalAddressSnapshot.maximumAddresses else { return nil }
        }
        return SelfRenewalLocalAddressSnapshot(entries: entries)
    }

    private static func isNumberedInterface(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func ipv4Bytes(_ address: UnsafePointer<sockaddr>) -> [UInt8]? {
        let header = socketHeader(address)
        guard header.family == sa_family_t(AF_INET),
              header.length >= MemoryLayout<sockaddr_in>.size else { return nil }
        var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    private static func ipv4MaskBytes(_ mask: UnsafePointer<sockaddr>) -> [UInt8]? {
        // Darwin netmasks may be shortened and use AF_UNSPEC. The parent interface
        // address supplied the family; do not load a full sockaddr_in from a short mask.
        let header = socketHeader(mask)
        guard header.family == sa_family_t(AF_INET) || header.family == sa_family_t(AF_UNSPEC),
              let offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr) else { return nil }
        let length = header.length
        guard length > offset, length <= MemoryLayout<sockaddr_in>.size else { return nil }
        let count = min(4, length - offset)
        let bytes = UnsafeRawPointer(mask).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        var result = Array(UnsafeBufferPointer(start: bytes, count: count))
        result.append(contentsOf: repeatElement(UInt8(0), count: 4 - count))
        return result
    }

    private static func numericAddress(_ address: UnsafePointer<sockaddr>, interfaceIndex: UInt32) -> SelfRenewalNumericAddress? {
        if let bytes = ipv4Bytes(address) { return SelfRenewalNumericAddress(family: .ipv4, bytes: bytes) }
        let header = socketHeader(address)
        guard header.family == sa_family_t(AF_INET6),
              header.length >= MemoryLayout<sockaddr_in6>.size else { return nil }
        let socketAddress = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
        var value = socketAddress.sin6_addr
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        let scope = socketAddress.sin6_scope_id
        // A DNS-SD reply and an ifaddrs node both carry an explicit interface index. A
        // zero sin6_scope_id can use that association; a conflicting scope is never guessed.
        if isLinkLocal {
            guard interfaceIndex > 0, scope == 0 || scope == interfaceIndex else { return nil }
            return SelfRenewalNumericAddress(family: .ipv6, bytes: bytes, scopeID: interfaceIndex)
        }
        guard scope == 0 else { return nil }
        return SelfRenewalNumericAddress(family: .ipv6, bytes: bytes)
    }

    private static func socketHeader(_ address: UnsafePointer<sockaddr>) -> (length: Int, family: sa_family_t) {
        // Darwin sockaddr begins with two bytes: sa_len and sa_family. Short netmask
        // objects may contain only those bytes plus mask data, not a full sockaddr value.
        let bytes = UnsafeRawPointer(address)
        return (Int(bytes.load(fromByteOffset: 0, as: UInt8.self)), bytes.load(fromByteOffset: 1, as: sa_family_t.self))
    }

    #if DEBUG
    /// Synthetic owned sockaddr bytes only; these helpers never start discovery or I/O.
    static func numericAddressForTesting(bytes: Data, interfaceIndex: UInt32) -> SelfRenewalNumericAddress? {
        withOwnedSocketAddress(bytes) { numericAddress($0, interfaceIndex: interfaceIndex) }
    }

    static func ipv4MaskForTesting(bytes: Data) -> [UInt8]? {
        withOwnedSocketAddress(bytes) { ipv4MaskBytes($0) }
    }

    private static func withOwnedSocketAddress<T>(_ bytes: Data, body: (UnsafePointer<sockaddr>) -> T?) -> T? {
        guard bytes.count >= 2, bytes.count <= MemoryLayout<sockaddr_storage>.size,
              let declaredLength = bytes.first, declaredLength >= 2, Int(declaredLength) <= bytes.count else { return nil }
        // sockaddr_storage supplies suitable alignment; Data itself need not be aligned.
        var storage = sockaddr_storage()
        return withUnsafeMutableBytes(of: &storage) { destination in
            bytes.copyBytes(to: destination)
            guard let base = destination.baseAddress else { return nil }
            return body(UnsafePointer(base.assumingMemoryBound(to: sockaddr.self)))
        }
    }
    #endif
}

extension SelfRenewalNumericAddress {
    /// Pure numeric formatting; this string is never a service hostname or report field.
    var numericHost: String {
        if family == .ipv4 { return bytes.map(String.init).joined(separator: ".") }
        let components = stride(from: 0, to: 16, by: 2).map { index in
            String((UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]), radix: 16)
        }
        let host = components.joined(separator: ":")
        return isLinkLocal && scopeID > 0 ? "\(host)%\(scopeID)" : host
    }
}
