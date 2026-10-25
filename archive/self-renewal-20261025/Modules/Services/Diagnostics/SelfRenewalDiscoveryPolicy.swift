import Foundation

/// Addresses and service tokens stay in memory. None of these types is Codable.
struct SelfRenewalNumericAddress: Hashable, Sendable {
    enum Family: String, Codable, Sendable { case ipv4, ipv6 }
    let family: Family
    let bytes: [UInt8]
    let scopeID: UInt32

    init?(family: Family, bytes: [UInt8], scopeID: UInt32 = 0) {
        guard bytes.count == (family == .ipv4 ? 4 : 16) else { return nil }
        self.family = family
        self.bytes = bytes
        self.scopeID = scopeID
    }

    var isLoopback: Bool {
        family == .ipv4 ? bytes[0] == 127 : bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }

    var isLinkLocal: Bool {
        family == .ipv4 ? bytes[0] == 169 && bytes[1] == 254 : bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
    }

    var isEligibleUnicast: Bool {
        switch family {
        case .ipv4:
            return scopeID == 0 && bytes[0] != 0 && bytes[0] < 224
        case .ipv6:
            guard bytes[0] != 0xff, bytes.contains(where: { $0 != 0 }) else { return false }
            // IPv4-compatible/mapped addresses are not a second route around IPv4 policy.
            if bytes.prefix(12).allSatisfy({ $0 == 0 }) && !isLoopback { return false }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff { return false }
            return isLinkLocal ? scopeID != 0 : scopeID == 0
        }
    }
}

struct SelfRenewalDiscoveredEndpoint: Hashable, Sendable {
    let address: SelfRenewalNumericAddress
    let port: UInt16
    /// DNS address TTL, measured at receipt; retained in memory only.
    let expiresAtUptime: TimeInterval
}

struct SelfRenewalLocalInterfaceAddress: Hashable, Sendable {
    let address: SelfRenewalNumericAddress
    let interfaceIndex: UInt32
    let rawFlags: UInt32
    let isUp: Bool
    let isLoopback: Bool
    let isPointToPoint: Bool
    /// False for peer/tunnel and unclassified interface kinds. A name is not exported.
    let isEligibleInterface: Bool
    let ipv4Netmask: [UInt8]?
    let ipv4Broadcast: [UInt8]?

    var isEligible: Bool {
        guard isUp, interfaceIndex > 0, !isPointToPoint, isEligibleInterface,
              address.isEligibleUnicast, address.isLoopback == isLoopback else { return false }
        if address.family == .ipv6 {
            return !address.isLinkLocal || address.scopeID == interfaceIndex
        }
        guard let mask = ipv4Netmask, mask.count == 4 else { return false }
        if let broadcast = ipv4Broadcast, broadcast == address.bytes { return false }
        // Missing or malformed netmasks cannot authorize a broadcast-looking endpoint.
        let maskBits = mask.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let inverse = ~maskBits
        guard inverse & (inverse &+ 1) == 0 else { return false }
        if inverse > 1 && zip(address.bytes, mask).allSatisfy({ ($0.0 | $0.1) == 255 }) { return false }
        return true
    }
}

struct SelfRenewalLocalAddressSnapshot: Equatable, Sendable {
    static let maximumAddresses = 128
    let entries: Set<SelfRenewalLocalInterfaceAddress>

    init?(entries: [SelfRenewalLocalInterfaceAddress]) {
        guard entries.count <= Self.maximumAddresses else { return nil }
        self.entries = Set(entries)
    }

    func category(for endpoint: SelfRenewalDiscoveredEndpoint) -> SelfRenewalDiscoveryAddressCategory? {
        guard endpoint.port != 0, endpoint.address.isEligibleUnicast,
              entries.contains(where: { $0.isEligible && $0.address == endpoint.address }) else { return nil }
        return endpoint.address.isLoopback ? .loopback : .localInterface
    }
}

enum SelfRenewalDiscoveryAddressCategory: String, Codable, Sendable { case loopback, localInterface }

enum SelfRenewalDiscoveryOutcome: String, Codable, Sendable {
    case tcpConnected, noLocalCandidate, discoveryTimedOut, discoveryUnavailable, resolutionFailed
    case transportFailed, timedOut, cancelled, interfaceChanged, discoveryChanged, limitExceeded, internalError
}

enum SelfRenewalDiscoveryPhase: String, Codable, Sendable {
    case snapshotting, discovering, resolving, checkingOwnership, connecting, completed
}

struct SelfRenewalDiscoveryTCPAttempt: Codable, Sendable {
    let family: SelfRenewalNumericAddress.Family
    let addressCategory: SelfRenewalDiscoveryAddressCategory
    let outcome: SelfRenewalDiscoveryOutcome
    let elapsedMilliseconds: Double
    let networkError: SelfRenewalTransportNetworkError?
    let lastWaitingError: SelfRenewalTransportNetworkError?
}

struct SelfRenewalRemotePairingDiscoveryReport: Codable, Sendable {
    let discoveryStarted: Bool
    let outcome: SelfRenewalDiscoveryOutcome
    let phase: SelfRenewalDiscoveryPhase
    let elapsedMilliseconds: Double
    let discoveredServiceCount: Int
    let resolvedAddressCount: Int
    let rejectedAddressCount: Int
    let approvedEndpointCount: Int
    /// Nil before selection, including incomplete/overflowed discovery. Optional
    /// mutable defaults preserve synthesized Codable decoding of older schema 2.
    var eligibleEndpointCount: Int? = nil
    var skippedEndpointCount: Int? = nil
    var endpointSelectionLimit: Int? = nil
    let tcpConnectionAttemptsStarted: Int
    let tcpAttempts: [SelfRenewalDiscoveryTCPAttempt]
    let networkError: SelfRenewalTransportNetworkError?
    let lastWaitingError: SelfRenewalTransportNetworkError?
    let tcpApplicationPayloadBytesSent: Int
    let serviceIdentityVerified: Bool
}

enum SelfRenewalDiscoveryEvent: Sendable {
    case ready
    case found(UUID)
    case resolved(UUID, SelfRenewalDiscoveredEndpoint)
    case addressRemoved(UUID, SelfRenewalNumericAddress)
    case removed(UUID)
    case waiting(SelfRenewalTransportNetworkError)
    case resolutionFailed(SelfRenewalTransportNetworkError)
    case failed(SelfRenewalTransportNetworkError)
    case windowEnded
    case limitExceeded
    case invalidated
}
