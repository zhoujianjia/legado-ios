import CryptoKit
import Foundation

/// The process entry reads only Bundle.main's actual root. The comparison
/// consumes sealed verifier results, not caller-supplied version dictionaries.
/// Matching supported file materials is separate from kernel-loaded code,
/// installation authority and preservation of the user's data container.
enum SelfRenewalInstalledMaterialObserver {
    typealias App = SelfRenewalApplicationMaterialVerifier
    typealias Candidate = SelfRenewalIPAUnpacker.Materials
    enum Failure: Error, Sendable, Equatable {
        case invalidCandidate, missingAuthenticatedMaterial
        case componentsChanged, codeChanged, profilesChanged, identitiesChanged
    }
    struct Unavailable: Error, @unchecked Sendable { let underlying: Error }
    struct ProcessIdentity: Sendable {
        let id: UUID
        private init() { id = UUID() }
        /// One value per process, shared by every owner and foreground event.
        static let current = ProcessIdentity()
    }
    struct Match: Sendable {
        let candidateArchiveSHA256: Data
        let candidateArchiveBytes: Int
        let authenticatedMaterialSHA256: Data
        let bundleIdentifier: String
        let bundleVersion: String
        let codeFiles: Int
        let profiles: Int
        fileprivate init(candidate: Candidate, fingerprint: Data, identifier: String, version: String) {
            candidateArchiveSHA256 = candidate.archiveSHA256; candidateArchiveBytes = candidate.archiveBytes
            authenticatedMaterialSHA256 = fingerprint; bundleIdentifier = identifier; bundleVersion = version
            codeFiles = candidate.application.resources.executableMaterials.code.count
            profiles = candidate.application.profiles.profiles.count
        }
    }
    struct CurrentProcessObservation: Sendable {
        let match: Match
        let process: ProcessIdentity
        let observedAt: Date
        var kernelLoadedImageVerified: Bool { false }
        var userDataPreservationVerified: Bool { false }
        var appleInstallationAuthorityVerified: Bool { false }
        var automaticRenewalVerified: Bool { false }
        fileprivate init(match: Match, at date: Date) {
            self.match = match; process = .current; observedAt = date
        }
    }

    nonisolated static func readCurrentProcess(expected candidate: Candidate,
        codeAnchors: [Data], profileAnchors: [Data], at date: Date) async throws -> CurrentProcessObservation {
        let worker = Task.detached(priority: .utility) {
            let started = SourcePerfTrace.now
            defer { SourcePerfTrace.record("renewal.installed.current-process",
                "candidateBytes=\(candidate.archiveBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
            do {
                try Task.checkCancellation()
                let actual = try await App.read(unpackedApplication: Bundle.main.bundleURL,
                    codeAnchors: codeAnchors, profileAnchors: profileAnchors, at: date)
                let match = try compareVerifiedMaterial(actual, expected: candidate)
                try Task.checkCancellation()
                return CurrentProcessObservation(match: match, at: date)
            } catch is CancellationError { throw CancellationError() }
            catch { throw Unavailable(underlying: error) }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Controlled fixtures can compare real separately verified directory/ZIP
    /// material here, but cannot construct a CurrentProcessObservation from it.
    static func compareVerifiedMaterial(_ actual: App.Materials, expected candidate: Candidate) throws -> Match {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard candidate.archiveSHA256.count == 32, candidate.archiveBytes > 0 else { throw Failure.invalidCandidate }
        let left = try projection(actual), right = try projection(candidate.application)
        guard left.components == right.components else { throw Failure.componentsChanged }
        guard left.code == right.code else { throw Failure.codeChanged }
        guard left.profiles == right.profiles else { throw Failure.profilesChanged }
        guard left.identities == right.identities else { throw Failure.identitiesChanged }
        guard let main = actual.resources.executableMaterials.inventory.components.first(where: { $0.role == .application }),
              let info = main.metadata else { throw Failure.missingAuthenticatedMaterial }
        var hasher = SHA256()
        // Each projection is canonical JSON. Prefix each part's length to avoid
        // ambiguous concatenation without serializing or hashing files again.
        for part in [left.components, left.code, left.profiles, left.identities] {
            var count = UInt64(part.count).bigEndian
            withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
            hasher.update(data: part)
        }
        return Match(candidate: candidate, fingerprint: Data(hasher.finalize()),
            identifier: info.bundleIdentifier, version: info.build)
    }

    private struct Projection { let components: Data; let code: Data; let profiles: Data; let identities: Data }
    private static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func nullable(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }
    private static func projection(_ material: App.Materials) throws -> Projection {
        let inventory = material.resources.executableMaterials.inventory
        let components: [[String: Any]] = inventory.components.sorted { $0.relativePath < $1.relativePath }.map {
            ["path": $0.relativePath, "kind": $0.kind.rawValue,
             "role": nullable($0.role?.rawValue),
             "bundle": nullable($0.metadata?.bundleIdentifier),
             "version": nullable($0.metadata?.version),
             "build": nullable($0.metadata?.build),
             "executable": nullable($0.metadata?.executableName)]
        }
        let code: [[String: Any]] = try material.resources.executableMaterials.code.sorted { $0.file.relativePath < $1.file.relativePath }.map { file in
            try Task.checkCancellation()
            guard let verified = file.signedCodeVerification, verified.allLoadedDirectoriesAuthenticated,
                  !verified.slices.isEmpty else { throw Failure.missingAuthenticatedMaterial }
            let slices: [[String: Any]] = try verified.slices.sorted { $0.sliceOffset < $1.sliceOffset }.map { slice in
                guard !slice.isAdHoc, slice.selectedDirectoryAuthenticated, !slice.signers.isEmpty else { throw Failure.missingAuthenticatedMaterial }
                let signers = try slice.signers.map { signer -> String in
                    guard let certificate = signer.verifiedCertificateChainDER.first else { throw Failure.missingAuthenticatedMaterial }
                    return hex(Data(SHA256.hash(data: certificate)))
                }.sorted()
                let directories: [[String: Any]] = slice.directories.filter(\.loadedByOriginalAlternateOrder).sorted { $0.slot < $1.slot }.map {
                    ["slot": $0.slot, "hashType": $0.hashType, "rawSHA256": hex($0.rawCodeDirectorySHA256),
                     "cdHash": hex($0.cdHash), "fullCDHash": hex($0.fullCDHash)]
                }
                return ["offset": slice.sliceOffset, "selectedSlot": slice.selectedDirectorySlot,
                    "signerCertificateSHA256": signers, "directories": directories]
            }
            return ["path": file.file.relativePath, "slices": slices]
        }
        let profiles: [[String: Any]] = try material.profiles.profiles.sorted { $0.file.relativePath < $1.file.relativePath }.map {
            guard let hash = $0.rawFileDigests[2], hash.count == 32 else { throw Failure.missingAuthenticatedMaterial }
            return ["path": $0.file.relativePath, "uuid": $0.summary.uuid, "rawSHA256": hex(hash)]
        }
        let identities: [[String: Any]] = material.bundles.sorted { $0.componentRelativePath < $1.componentRelativePath }.map { bundle in
            let seal: Any
            switch bundle.profileResourceBinding { case .matched(let hashes): seal = hashes; case .notInResourceSeal: seal = NSNull() }
            let slices: [[String: Any]] = bundle.slices.sorted { $0.sliceOffset < $1.sliceOffset }.map {
                ["offset": $0.sliceOffset, "identifier": $0.codeSigningIdentifier,
                 "directoryTeam": nullable($0.codeDirectoryTeamIdentifier),
                 "team": $0.teamIdentifier, "prefix": $0.applicationIdentifierPrefix,
                 "appID": $0.applicationIdentifier, "signer": hex($0.codeSignerCertificateSHA256),
                 "appGroups": $0.appGroups, "keychainGroups": $0.keychainAccessGroups,
                 "unassessed": $0.unassessedEntitlementKeys.sorted()]
            }
            return ["path": bundle.componentRelativePath, "bundle": bundle.bundleIdentifier,
                "profile": bundle.profileUUID, "profileSealedHashTypes": seal, "slices": slices]
        }
        guard !code.isEmpty, !profiles.isEmpty, !identities.isEmpty else { throw Failure.missingAuthenticatedMaterial }
        return try Projection(components: canonical(components), code: canonical(code), profiles: canonical(profiles), identities: canonical(identities))
    }
}
