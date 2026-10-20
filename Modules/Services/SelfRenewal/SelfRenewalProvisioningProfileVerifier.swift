import CryptoKit
import Foundation
import Security

/// Verifies each embedded profile's CMS envelope and chain to explicit anchors.
/// The plist is a signed observation, not modern profile authorization: Apple's
/// DER-Encoded-Profile, signer policy, entitlements and device matching still need
/// independent validation before a replacement adapter can use these materials.
enum SelfRenewalProvisioningProfileVerifier {
    enum Failure: Error, Sendable, Equatable {
        case missingProfile, totalReadLimit, malformedProfile, invalidValidityWindow
        case profileNotYetValid, profileExpired
        case missingDERProfile, invalidDERProfile
    }
    struct Summary: Sendable, Equatable {
        let uuid: String
        let createdAt: Date
        let expiresAt: Date
        let teamIdentifiers: [String]
        let applicationIdentifierPrefixes: [String]
        let applicationIdentifier: String
        let entitlementTeamIdentifier: String?
        let developerCertificateSHA256: [Data]
        let containsDEREncodedProfile: Bool
        var authorizationVerified: Bool { false }
    }
    struct Profile: Sendable, Equatable {
        let file: SelfRenewalMaterialInventory.FileFact
        let envelope: SelfRenewalCMSVerifier.VerifiedContent
        let plistSummary: Summary
        var appleProvisioningAuthorityEstablished: Bool { false }
        var entitlementAuthorizationEstablished: Bool { false }
        fileprivate init(file: SelfRenewalMaterialInventory.FileFact,
            envelope: SelfRenewalCMSVerifier.VerifiedContent, plistSummary: Summary) {
            self.file = file
            self.envelope = envelope
            self.plistSummary = plistSummary
        }
    }
    struct Materials: Sendable, Equatable {
        let inventory: SelfRenewalMaterialInventory.Inventory
        let profiles: [Profile]
        let profileBytesRead: Int
        var accountIdentityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(inventory: SelfRenewalMaterialInventory.Inventory,
            profiles: [Profile], profileBytesRead: Int) {
            self.inventory = inventory
            self.profiles = profiles
            self.profileBytesRead = profileBytesRead
        }
    }
    struct ModernProfile: Sendable, Equatable {
        let file: SelfRenewalMaterialInventory.FileFact
        let outerEnvelope: SelfRenewalCMSVerifier.VerifiedContent
        /// The DER-Encoded-Profile is its own CMS message, not unsigned ASN.1
        /// borrowed from the outer XML. Modern fields come only from this CMS.
        let derEnvelope: SelfRenewalCMSVerifier.VerifiedContent
        let summary: Summary
        let properties: SelfRenewalDERPropertyList.Value
        /// Actual outer file bytes, for binding to any resource seals that
        /// covered this profile before this later owned-file read.
        let rawFileDigests: [UInt8: Data]
        var sourceOfTruthCryptographicallyAuthenticated: Bool { true }
        var appleProvisioningAuthorityEstablished: Bool { false }
        var entitlementAuthorizationEstablished: Bool { false }
        fileprivate init(file: SelfRenewalMaterialInventory.FileFact,
            outer: SelfRenewalCMSVerifier.VerifiedContent, inner: SelfRenewalCMSVerifier.VerifiedContent,
            summary: Summary, properties: SelfRenewalDERPropertyList.Value, rawFileDigests: [UInt8: Data]) {
            self.file = file; outerEnvelope = outer; derEnvelope = inner
            self.summary = summary; self.properties = properties
            self.rawFileDigests = rawFileDigests
        }
    }
    struct ModernMaterials: Sendable, Equatable {
        let inventory: SelfRenewalMaterialInventory.Inventory
        let profiles: [ModernProfile]
        let profileBytesRead: Int
        var accountIdentityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(inventory: SelfRenewalMaterialInventory.Inventory,
            profiles: [ModernProfile], profileBytesRead: Int) {
            self.inventory = inventory; self.profiles = profiles; self.profileBytesRead = profileBytesRead
        }
    }
    enum Limits {
        static let profileBytes = 2_097_152
        static let totalReadBytes = 8_388_608
        static let plistBytes = 1_048_576
    }

    nonisolated static func read(unpackedApplication root: URL,
        anchors: [Data], at date: Date) async throws -> Materials {
        let inventory = try await SelfRenewalMaterialInventory.read(unpackedApplication: root)
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            precondition(!Thread.isMainThread)
            let started = SourcePerfTrace.now
            var readBytes = 0
            defer {
                SourcePerfTrace.record("renewal.material.profile",
                    "bytes=\(readBytes) components=\(inventory.components.count) main=\(Thread.isMainThread)",
                    since: started, thresholdMs: 0)
            }
            var profiles: [Profile] = []
            for component in inventory.components {
                try Task.checkCancellation()
                guard component.kind == .application || component.kind == .appExtension else { continue }
                guard let file = component.embeddedProvisioningProfile else { throw Failure.missingProfile }
                guard file.byteCount >= 0,
                      file.byteCount <= Int64(Limits.totalReadBytes - readBytes) else { throw Failure.totalReadLimit }
                let bytes = try SelfRenewalMachOSignatureReader.readOwnedMaterial(root: root,
                    fact: file, maximumBytes: Limits.profileBytes)
                readBytes += bytes.count
                let envelope = try SelfRenewalCMSVerifier.verify(bytes, anchors: anchors, at: date)
                let summary = try parseSignedPlist(envelope.content, at: date)
                profiles.append(Profile(file: file, envelope: envelope, plistSummary: summary))
            }
            try Task.checkCancellation()
            guard !profiles.isEmpty else { throw Failure.missingProfile }
            return Materials(inventory: inventory, profiles: profiles, profileBytesRead: readBytes)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Reuses the executable/resource pipeline's one inventory. Legacy XML
    /// fields remain observations: validity, identity and certificate hashes
    /// below are taken from the independently authenticated inner DER profile.
    nonisolated static func readModern(unpackedApplication root: URL,
        inventory: SelfRenewalMaterialInventory.Inventory,
        anchors: [Data], at date: Date) async throws -> ModernMaterials {
        let worker = Task.detached(priority: .utility) {
            precondition(!Thread.isMainThread)
            try Task.checkCancellation()
            let started = SourcePerfTrace.now
            var readBytes = 0
            var profiles: [ModernProfile] = []
            defer {
                SourcePerfTrace.record("renewal.material.profile-modern",
                    "bytes=\(readBytes) profiles=\(profiles.count) main=\(Thread.isMainThread)", since: started, thresholdMs: 0)
            }
            for component in inventory.components {
                try Task.checkCancellation()
                guard component.kind == .application || component.kind == .appExtension else { continue }
                guard let file = component.embeddedProvisioningProfile else { throw Failure.missingProfile }
                guard file.byteCount >= 0, file.byteCount <= Int64(Limits.totalReadBytes - readBytes) else { throw Failure.totalReadLimit }
                let bytes = try SelfRenewalMachOSignatureReader.readOwnedMaterial(root: root, fact: file, maximumBytes: Limits.profileBytes)
                readBytes += bytes.count
                profiles.append(try verifyModern(bytes, file: file, anchors: anchors, at: date))
            }
            try Task.checkCancellation()
            guard !profiles.isEmpty else { throw Failure.missingProfile }
            return ModernMaterials(inventory: inventory, profiles: profiles, profileBytesRead: readBytes)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func verifyModern(_ bytes: Data, file: SelfRenewalMaterialInventory.FileFact,
        anchors: [Data], at date: Date) throws -> ModernProfile {
        precondition(!Thread.isMainThread, "Modern profile verification must stay off main")
        try Task.checkCancellation()
        let outer = try SelfRenewalCMSVerifier.verify(bytes, anchors: anchors, at: date)
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: outer.content, options: [], format: nil) }
        catch { throw Failure.malformedProfile }
        guard let values = object as? [String: Any], let innerBytes = values["DER-Encoded-Profile"] as? Data,
              !innerBytes.isEmpty else { throw Failure.missingDERProfile }
        // A correctly signed XML wrapper does not authenticate an invalid inner
        // signature, even when its fields happen to look like the XML summary.
        let inner = try SelfRenewalCMSVerifier.verify(innerBytes, anchors: anchors, at: date)
        let properties = try SelfRenewalDERPropertyList.decode(inner.content)
        let summary = try parseModernSummary(properties, at: date)
        let hashes = try SelfRenewalResourceSealVerifier.hashFile(byteCount: Int64(bytes.count), hashTypes: [1, 2, 3, 4]) { range in
            bytes.subdata(in: Int(range.offset)..<Int(range.end))
        }
        try Task.checkCancellation()
        return ModernProfile(file: file, outer: outer, inner: inner, summary: summary, properties: properties, rawFileDigests: hashes)
    }

    private static func parseModernSummary(_ properties: SelfRenewalDERPropertyList.Value, at date: Date) throws -> Summary {
        typealias Value = SelfRenewalDERPropertyList.Value
        guard case .dictionary(let values) = properties else { throw Failure.invalidDERProfile }
        func text(_ value: Value?, maximum: Int = 128) throws -> String {
            guard case .string(let result)? = value, validText(result, maximum: maximum) else { throw Failure.invalidDERProfile }
            return result
        }
        func texts(_ key: String) throws -> [String] {
            guard case .array(let array)? = values[key], !array.isEmpty, array.count <= 8 else { throw Failure.invalidDERProfile }
            let result = try array.map { try text($0) }
            guard Set(result).count == result.count else { throw Failure.invalidDERProfile }
            return result
        }
        let uuid = try text(values["UUID"])
        guard UUID(uuidString: uuid) != nil,
              case .date(let created)? = values["CreationDate"], case .date(let expires)? = values["ExpirationDate"],
              case .dictionary(let entitlements)? = values["Entitlements"],
              case .array(let certificates)? = values["DeveloperCertificates"],
              !certificates.isEmpty, certificates.count <= SelfRenewalCMSVerifier.Limits.certificates else { throw Failure.invalidDERProfile }
        guard created.timeIntervalSince1970.isFinite, expires.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970.isFinite, created < expires else { throw Failure.invalidValidityWindow }
        guard date >= created else { throw Failure.profileNotYetValid }
        guard date < expires else { throw Failure.profileExpired }
        let hashes: [Data] = try certificates.map {
            guard case .data(let hash) = $0, hash.count == 32 else { throw Failure.invalidDERProfile }
            return hash
        }
        guard Set(hashes).count == hashes.count else { throw Failure.invalidDERProfile }
        let appID = try text(entitlements["application-identifier"], maximum: 512)
        let team: String?
        if let value = entitlements["com.apple.developer.team-identifier"] { team = try text(value) }
        else { team = nil }
        return Summary(uuid: uuid, createdAt: created, expiresAt: expires,
            teamIdentifiers: try texts("TeamIdentifier"), applicationIdentifierPrefixes: try texts("ApplicationIdentifierPrefix"),
            applicationIdentifier: appID, entitlementTeamIdentifier: team,
            developerCertificateSHA256: hashes, containsDEREncodedProfile: true)
    }

    /// Parsing is also exposed to bounded fixture tests. This function alone
    /// never authenticates bytes; read() invokes it only after CMS verification.
    static func parseSignedPlist(_ data: Data, at date: Date) throws -> Summary {
        precondition(!Thread.isMainThread, "Profile decoding must stay off main")
        guard !data.isEmpty, data.count <= Limits.plistBytes else { throw Failure.malformedProfile }
        let value: Any
        do { value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw Failure.malformedProfile }
        guard let plist = value as? [String: Any],
              let uuid = plist["UUID"] as? String, UUID(uuidString: uuid) != nil,
              let created = plist["CreationDate"] as? Date,
              let expires = plist["ExpirationDate"] as? Date,
              let teams = plist["TeamIdentifier"] as? [String], validTokens(teams),
              let prefixes = plist["ApplicationIdentifierPrefix"] as? [String], validTokens(prefixes),
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String,
              validText(appID, maximum: 512),
              let developerCertificates = plist["DeveloperCertificates"] as? [Data],
              !developerCertificates.isEmpty,
              developerCertificates.count <= SelfRenewalCMSVerifier.Limits.certificates,
              developerCertificates.allSatisfy({ !$0.isEmpty && $0.count <= SelfRenewalCMSVerifier.Limits.certificateBytes }),
              Set(developerCertificates).count == developerCertificates.count else { throw Failure.malformedProfile }
        guard created.timeIntervalSince1970.isFinite, expires.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970.isFinite, created < expires else { throw Failure.invalidValidityWindow }
        guard date >= created else { throw Failure.profileNotYetValid }
        guard date < expires else { throw Failure.profileExpired }
        var certificateHashes: [Data] = []
        for certificate in developerCertificates {
            try Task.checkCancellation()
            guard !certificate.isEmpty, certificate.count <= SelfRenewalCMSVerifier.Limits.certificateBytes,
                  SecCertificateCreateWithData(nil, certificate as CFData) != nil else { throw Failure.malformedProfile }
            certificateHashes.append(Data(SHA256.hash(data: certificate)))
        }
        let entitlementTeam: String?
        if let team = entitlements["com.apple.developer.team-identifier"] {
            guard let value = team as? String, validText(value, maximum: 128) else { throw Failure.malformedProfile }
            entitlementTeam = value
        } else { entitlementTeam = nil }
        if let der = plist["DER-Encoded-Profile"] {
            guard let bytes = der as? Data, !bytes.isEmpty, bytes.count <= Limits.plistBytes else { throw Failure.malformedProfile }
        }
        return Summary(uuid: uuid, createdAt: created, expiresAt: expires, teamIdentifiers: teams,
            applicationIdentifierPrefixes: prefixes, applicationIdentifier: appID,
            entitlementTeamIdentifier: entitlementTeam, developerCertificateSHA256: certificateHashes,
            containsDEREncodedProfile: plist["DER-Encoded-Profile"] != nil)
    }
    private static func validTokens(_ values: [String]) -> Bool {
        !values.isEmpty && values.count <= 8 && Set(values).count == values.count &&
            values.allSatisfy { validText($0, maximum: 128) }
    }
    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
