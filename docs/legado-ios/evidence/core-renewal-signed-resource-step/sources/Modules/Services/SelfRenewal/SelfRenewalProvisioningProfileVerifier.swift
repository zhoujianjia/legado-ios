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
