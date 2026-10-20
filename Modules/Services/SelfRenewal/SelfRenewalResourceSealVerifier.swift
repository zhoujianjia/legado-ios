import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// Resource consistency for a caller-owned, quiescent staging app. This consumes
/// the same inventory/content-hash pipeline as the executable verifier. It
/// evaluates nested requirements against actual checked code/certificate fields;
/// unavailable system-policy context stays unresolved. No Apple install authority.
/// Rule selection follows Security/resources.cpp (POSIX ERE, weighted first
/// match), rather than treating CodeResources as a simple filename/hash map.
enum SelfRenewalResourceSealVerifier {
    typealias Reader = SelfRenewalMachOSignatureReader
    typealias Inventory = SelfRenewalMaterialInventory
    typealias Requirements = SelfRenewalNestedCodeRequirementsVerifier
    enum Failure: Error, Sendable, Equatable {
        case malformedEnvelope, envelopeLimit, ruleLimit, invalidRule, invalidPath
        case unsupportedHash, missingEnvelope(String), unboundEnvelope(String)
        case changedCodeDirectory, digestMismatch(String), addedResource(String)
        case missingResource(String), resourceTypeMismatch(String), resourceReadLimit
        case invalidDigest(String)
        case nestedRequirementFailed(String), missingNestedCode(String)
    }
    enum Limits {
        static let envelopeBytes = 2_097_152
        static let rules = 256
        static let ruleBytes = 1_024
        static let requirementBytes = 16_384
        static let totalReadBytes: Int64 = 2_147_483_648
        static let directoryReadBytes = 67_108_864
    }
    struct NestedResource: Sendable, Equatable {
        let relativePath: String
        let requirement: String
        let cdHash: Data?
    }
    struct NestedVerification: Sendable, Equatable {
        let relativePath: String
        let executableRelativePath: String
        let requirement: String
        let verifiedSlices: Int
        let signerAuthenticatedSlices: Int
        let adHocSlices: Int
        /// The nested seal's cdhash is an informational hint in the original
        /// validator. It never substitutes for evaluating its requirement.
        let cdHashHintMatchesAnySelectedDirectory: Bool?
        var allSelectedDirectoriesSignerAuthenticated: Bool { verifiedSlices > 0 && verifiedSlices == signerAuthenticatedSlices }
        fileprivate init(relativePath: String, executableRelativePath: String, requirement: String,
            verifiedSlices: Int, signerAuthenticatedSlices: Int, adHocSlices: Int, hintMatches: Bool?) {
            self.relativePath = relativePath
            self.executableRelativePath = executableRelativePath
            self.requirement = requirement
            self.verifiedSlices = verifiedSlices
            self.signerAuthenticatedSlices = signerAuthenticatedSlices
            self.adHocSlices = adHocSlices
            cdHashHintMatchesAnySelectedDirectory = hintMatches
        }
    }
    struct EnvelopeVerification: Sendable, Equatable {
        let version: Int
        let hashedFiles: Int
        let hashedBytes: Int64
        let omittedFiles: Int
        let absentOptionalFiles: Int
        /// These were encountered according to the actual traversal rules. A
        /// requirement string and optional cdhash are not proof of nested code.
        let unresolvedNestedResources: [NestedResource]
        let verifiedNestedResources: [NestedVerification]
        let unresolvedRequirementCapabilities: [Requirements.Capability]
        /// Only digests actually read and compared to this envelope's seal.
        /// Keys are relative to this component; omitted files are absent here.
        let verifiedFileDigests: [String: [UInt8: Data]]
        let hasExactCatchAll: Bool
        var resourceDigestsVerified: Bool { true }
        var resourceEnvelopeVerified: Bool { unresolvedNestedResources.isEmpty }
        var strictResourcePolicyVerified: Bool { false }
        fileprivate init(version: Int, hashedFiles: Int, hashedBytes: Int64,
            omittedFiles: Int, absentOptionalFiles: Int, nested: [NestedResource], hasExactCatchAll: Bool,
            verifiedNested: [NestedVerification] = [], unresolvedCapabilities: [Requirements.Capability] = [],
            verifiedFileDigests: [String: [UInt8: Data]] = [:]) {
            self.version = version
            self.hashedFiles = hashedFiles
            self.hashedBytes = hashedBytes
            self.omittedFiles = omittedFiles
            self.absentOptionalFiles = absentOptionalFiles
            self.unresolvedNestedResources = nested
            verifiedNestedResources = verifiedNested
            unresolvedRequirementCapabilities = unresolvedCapabilities
            self.verifiedFileDigests = verifiedFileDigests
            self.hasExactCatchAll = hasExactCatchAll
        }
    }
    struct ComponentVerification: Sendable, Equatable {
        let relativePath: String
        let envelopeSHA256: Data
        let boundCodeDirectories: Int
        let resources: EnvelopeVerification
        fileprivate init(relativePath: String, envelopeSHA256: Data,
            boundCodeDirectories: Int, resources: EnvelopeVerification) {
            self.relativePath = relativePath
            self.envelopeSHA256 = envelopeSHA256
            self.boundCodeDirectories = boundCodeDirectories
            self.resources = resources
        }
    }
    struct Materials: Sendable, Equatable {
        let executableMaterials: Reader.Materials
        let components: [ComponentVerification]
        /// Envelope and streamed resource bytes, separate from the bounded CD
        /// re-read and the executable pipeline's existing read counters.
        let bytesRead: Int64
        let codeDirectoryBytesRead: Int
        let nestedAttributeBytesRead: Int
        /// Actual selected-CD-bound Info/DER entitlement/certificate context,
        /// reused by profile composition without another inventory or decoder.
        let codeAttributes: [String: Requirements.LoadedCode]
        var resourceEnvelopesVerified: Bool {
            !components.isEmpty && components.allSatisfy { $0.resources.resourceEnvelopeVerified }
        }
        var appleSigningAuthorityVerified: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(executableMaterials: Reader.Materials, components: [ComponentVerification], bytesRead: Int64,
            codeDirectoryBytesRead: Int, nestedAttributeBytesRead: Int,
            codeAttributes: [String: Requirements.LoadedCode]) {
            self.executableMaterials = executableMaterials
            self.components = components
            self.bytesRead = bytesRead
            self.codeDirectoryBytesRead = codeDirectoryBytesRead
            self.nestedAttributeBytesRead = nestedAttributeBytesRead
            self.codeAttributes = codeAttributes
        }
    }

    nonisolated static func read(unpackedApplication root: URL) async throws -> Materials {
        let materials = try await SelfRenewalCodeDirectoryHashVerifier.read(unpackedApplication: root)
        return try await verify(unpackedApplication: root, executableMaterials: materials)
    }

    /// Also accepts the signed-code reader's genuine content-hash results, so
    /// composing CMS and resource checks needs neither a second inventory nor a
    /// second full executable hash pass. Its trust scope is retained unchanged.
    nonisolated static func verify(unpackedApplication root: URL,
        executableMaterials: Reader.Materials) async throws -> Materials {
        let worker = Task.detached(priority: .utility) {
            try verifySynchronously(root: root, materials: executableMaterials)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func verifySynchronously(root: URL, materials: Reader.Materials) throws -> Materials {
        precondition(!Thread.isMainThread, "Resource hashing must stay off main")
        try Task.checkCancellation()
        let started = SourcePerfTrace.now
        var bytesRead: Int64 = 0
        var directoryBytes = 0
        var attributeBytes = 0
        var components: [ComponentVerification] = []
        defer {
            SourcePerfTrace.record("renewal.material.resources",
                "components=\(components.count) bytes=\(bytesRead) directoryBytes=\(directoryBytes) attributeBytes=\(attributeBytes) main=\(Thread.isMainThread)",
                since: started, thresholdMs: 0)
        }
        for component in materials.inventory.components {
            try Task.checkCancellation()
            // Unsigned resource bundles are sealed by their containing bundle.
            guard let executable = component.executable else {
                if component.codeResources != nil { throw Failure.unboundEnvelope(component.relativePath) }
                continue
            }
            guard let fact = component.codeResources else { throw Failure.missingEnvelope(component.relativePath) }
            guard let code = materials.code.first(where: { $0.file == executable.file }),
                  let proof = code.contentHashVerification, proof.contentDigestsVerified else {
                throw Failure.unboundEnvelope(component.relativePath)
            }
            guard fact.byteCount >= 0, fact.byteCount <= Limits.totalReadBytes - bytesRead else { throw Failure.resourceReadLimit }
            let envelope = try Reader.readOwnedMaterial(root: root, fact: fact, maximumBytes: Limits.envelopeBytes)
            bytesRead += Int64(envelope.count)
            guard bytesRead <= Limits.totalReadBytes else { throw Failure.resourceReadLimit }
            var hashTypes = Set<UInt8>()
            var bound = 0
            // Bind the exact envelope bytes consumed below, including when its
            // same-size file was changed since the earlier content-hash pass.
            try Reader.withOwnedFile(root: root, fact: code.file,
                maximumReadBytes: Limits.directoryReadBytes - directoryBytes) { read in
                for slice in code.structure.slices {
                    guard let signature = slice.signature else { throw Failure.unboundEnvelope(component.relativePath) }
                    for directory in signature.codeDirectories {
                        try Task.checkCancellation()
                        guard let checked = proof.directories.first(where: {
                            $0.sliceOffset == slice.range.offset && $0.directorySlot == directory.slot
                        }), checked.verifiedSpecialSlots.contains(3) else {
                            throw Failure.unboundEnvelope(component.relativePath)
                        }
                        var raw = Data()
                        var offset = 0
                        while offset < directory.blobRange.byteCount {
                            let count = min(Reader.Limits.ownedFileChunkBytes, directory.blobRange.byteCount - offset)
                            raw.append(try read(.init(offset: signature.range.offset + directory.blobRange.offset + UInt64(offset), byteCount: count)))
                            offset += count
                            directoryBytes += count
                        }
                        guard Data(SHA256.hash(data: raw)) == checked.codeDirectorySHA256 else {
                            throw Failure.changedCodeDirectory
                        }
                        let start = directory.hashOffset - 3 * directory.hashByteCount
                        guard start >= 0, start <= raw.count - directory.hashByteCount else { throw Failure.changedCodeDirectory }
                        let expected = raw.subdata(in: start..<(start + directory.hashByteCount))
                        guard try SelfRenewalCodeDirectoryHashVerifier.digest(envelope, hashType: directory.hashType) == expected else {
                            throw Failure.digestMismatch(fact.relativePath)
                        }
                        hashTypes.insert(directory.hashType)
                        bound += 1
                    }
                }
            }
            guard bound > 0, bound == proof.directories.count else { throw Failure.unboundEnvelope(component.relativePath) }
            let prefix = component.relativePath == "." ? "" : component.relativePath + "/"
            let files = materials.inventory.files.compactMap { file -> Inventory.FileFact? in
                guard file.relativePath.hasPrefix(prefix) else { return nil }
                return .init(relativePath: String(file.relativePath.dropFirst(prefix.count)), byteCount: file.byteCount)
            }
            let directories = materials.inventory.directories.compactMap { path -> String? in
                guard path.hasPrefix(prefix), path != component.relativePath else { return nil }
                return String(path.dropFirst(prefix.count))
            }
            let executablePath = String(code.file.relativePath.dropFirst(prefix.count))
            let result = try verifyEnvelope(envelope, files: files, directories: directories,
                executablePath: executablePath, hashTypes: hashTypes.sorted()) { file, types in
                guard file.byteCount <= Limits.totalReadBytes - bytesRead else { throw Failure.resourceReadLimit }
                let fact = Inventory.FileFact(relativePath: prefix + file.relativePath, byteCount: file.byteCount)
                let hashes = try Reader.withOwnedFile(root: root, fact: fact, maximumReadBytes: Int(file.byteCount)) { read in
                    try hashFile(byteCount: file.byteCount, hashTypes: types, read: read)
                }
                bytesRead += file.byteCount
                return hashes
            }
            components.append(ComponentVerification(relativePath: component.relativePath,
                envelopeSHA256: Data(SHA256.hash(data: envelope)), boundCodeDirectories: bound, resources: result))
        }
        var attributes: [String: Requirements.LoadedCode] = [:]
        for code in materials.code {
            try Task.checkCancellation()
            let component = materials.inventory.components.first { $0.executable?.file == code.file }
            if let loaded = try Requirements.load(root: root, code: code, component: component,
                files: materials.inventory.files, maximumReadBytes: Requirements.Limits.attributeReadBytes - attributeBytes) {
                attributes[code.file.relativePath] = loaded
                attributeBytes += loaded.bytesRead
            }
        }
        // Nested paths are strict descendants, so resolving deepest bundles
        // first establishes recursive resource validity without rescanning.
        var resolved: [String: ComponentVerification] = [:]
        for component in components.sorted(by: { $0.relativePath.count > $1.relativePath.count }) {
            var unresolved: [NestedResource] = []
            var verified: [NestedVerification] = []
            var capabilities: [Requirements.Capability] = []
            let prefix = component.relativePath == "." ? "" : component.relativePath + "/"
            for nested in component.resources.unresolvedNestedResources {
                try Task.checkCancellation()
                let path = prefix + nested.relativePath
                let childComponent = materials.inventory.components.first { $0.relativePath == path }
                let code = materials.code.first {
                    $0.file.relativePath == path || $0.file == childComponent?.executable?.file
                }
                guard let code else { throw Failure.missingNestedCode(path) }
                guard let context = attributes[code.file.relativePath] else { unresolved.append(nested); continue }
                if let childComponent {
                    guard let child = resolved[childComponent.relativePath] else { throw Failure.missingNestedCode(path) }
                    if !child.resources.resourceEnvelopeVerified {
                        unresolved.append(nested)
                        capabilities += child.resources.unresolvedRequirementCapabilities
                        continue
                    }
                }
                var missing: [Requirements.Capability] = []
                for slice in context.slices {
                    switch try Requirements.evaluate(nested.requirement, attributes: slice.attributes) {
                    case .matched: break
                    case .notMatched: throw Failure.nestedRequirementFailed(path)
                    case .unresolved(let values): missing += values
                    }
                }
                if !missing.isEmpty { unresolved.append(nested); capabilities += missing; continue }
                verified.append(NestedVerification(relativePath: nested.relativePath,
                    executableRelativePath: code.file.relativePath, requirement: nested.requirement,
                    verifiedSlices: context.slices.count,
                    signerAuthenticatedSlices: context.slices.filter(\.selectedDirectorySignerAuthenticated).count,
                    adHocSlices: context.slices.filter(\.adHoc).count,
                    hintMatches: nested.cdHash.map { hint in context.slices.contains { $0.attributes.cdHash == hint } }))
            }
            let value = component.resources
            let resources = EnvelopeVerification(version: value.version, hashedFiles: value.hashedFiles,
                hashedBytes: value.hashedBytes, omittedFiles: value.omittedFiles, absentOptionalFiles: value.absentOptionalFiles,
                nested: unresolved, hasExactCatchAll: value.hasExactCatchAll,
                verifiedNested: verified, unresolvedCapabilities: capabilities, verifiedFileDigests: value.verifiedFileDigests)
            resolved[component.relativePath] = ComponentVerification(relativePath: component.relativePath,
                envelopeSHA256: component.envelopeSHA256, boundCodeDirectories: component.boundCodeDirectories, resources: resources)
        }
        return Materials(executableMaterials: materials, components: components.map { resolved[$0.relativePath]! },
            bytesRead: bytesRead, codeDirectoryBytesRead: directoryBytes,
            nestedAttributeBytesRead: attributeBytes, codeAttributes: attributes)
    }

    /// Bounded semantic seam; production hashes the real regular files through
    /// the checked FD above. Test fixtures can exercise the Apple traversal
    /// contract without inventing signed executables to reach each branch.
    static func verifyEnvelope(_ data: Data, files: [Inventory.FileFact], directories: [String],
        executablePath: String?, hashTypes: [UInt8],
        hashFile: (Inventory.FileFact, [UInt8]) throws -> [UInt8: Data]) throws -> EnvelopeVerification {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= Limits.envelopeBytes else { throw Failure.envelopeLimit }
        guard files.count + directories.count <= Inventory.Limits.entries else { throw Failure.envelopeLimit }
        let types = Array(Set(hashTypes)).sorted()
        guard !types.isEmpty, types.allSatisfy({ (1...4).contains($0) }) else { throw Failure.unsupportedHash }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw Failure.malformedEnvelope }
        guard let envelope = object as? NSDictionary,
              envelope["rules"] is NSDictionary, envelope["files"] is NSDictionary else { throw Failure.malformedEnvelope }
        let version = envelope["files2"] == nil ? 1 : 2
        guard let ruleValues = envelope[version == 2 ? "rules2" : "rules"] as? NSDictionary,
              let fileValues = envelope[version == 2 ? "files2" : "files"] as? NSDictionary,
              fileValues.count <= Inventory.Limits.entries else { throw Failure.malformedEnvelope }
        guard ruleValues.count <= Limits.rules else { throw Failure.ruleLimit }
        var rules: [Rule] = []
        // NSDictionary enumeration retains the CFDictionary tie order. Sorting
        // rule keys or rebuilding a Swift Dictionary changes equal-weight wins.
        for (key, value) in ruleValues {
            guard let pattern = key as? String else { throw Failure.invalidRule }
            rules.append(try Rule(pattern: pattern, value: value))
        }
        var remaining: [String: Seal] = [:]
        for (key, value) in fileValues {
            guard let path = key as? String, validPath(path) else { throw Failure.invalidPath }
            remaining[path] = try Seal(value: value)
        }
        func selected(_ path: String) throws -> Rule? {
            var best: Rule?
            for rule in rules {
                try Task.checkCancellation()
                if try rule.matches(path), best == nil || rule.weight > best!.weight { best = rule }
            }
            return best
        }
        func excluded(_ path: String) -> Bool {
            if path == executablePath { return true }
            return ["_CodeSignature", "_MASReceipt", "CodeResources"].contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var skippedDirectories: [String] = []
        var nested: [NestedResource] = []
        func skipped(_ path: String) -> Bool { skippedDirectories.contains { path.hasPrefix($0 + "/") } }
        for path in directories.sorted() {
            try Task.checkCancellation()
            guard validPath(path) else { throw Failure.invalidPath }
            if excluded(path) || skipped(path) { continue }
            if let rule = try selected(path), rule.nested,
               path.split(separator: "/").last?.contains(".") == true {
                guard let seal = remaining.removeValue(forKey: path) else { throw Failure.addedResource(path) }
                guard case .nested(let requirement, let cdHash) = seal.kind else { throw Failure.resourceTypeMismatch(path) }
                nested.append(.init(relativePath: path, requirement: requirement, cdHash: cdHash))
                skippedDirectories.append(path)
            }
            // An ordinary omitted directory does not omit its descendants.
        }
        var hashed = 0
        var hashedBytes: Int64 = 0
        var omitted = 0
        var verifiedFileDigests: [String: [UInt8: Data]] = [:]
        var seen = Set<String>()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            try Task.checkCancellation()
            let path = file.relativePath
            guard validPath(path), seen.insert(path).inserted, file.byteCount >= 0,
                  file.byteCount <= Inventory.Limits.fileBytes else { throw Failure.invalidPath }
            if excluded(path) || skipped(path) { continue }
            guard let rule = try selected(path), !rule.omit else { omitted += 1; continue }
            guard let seal = remaining.removeValue(forKey: path) else { throw Failure.addedResource(path) }
            switch seal.kind {
            case .nested(let requirement, let cdHash):
                nested.append(.init(relativePath: path, requirement: requirement, cdHash: cdHash))
            case .symlink: throw Failure.resourceTypeMismatch(path)
            case .hashes(let values, let malformed):
                guard file.byteCount <= Limits.totalReadBytes - hashedBytes else { throw Failure.resourceReadLimit }
                var expected: [UInt8: Data] = [:]
                for type in types {
                    let key = type == 1 ? "hash" : "hash\(type)"
                    let used = values[key] != nil || malformed.contains(key) ? key : "hash"
                    let size = type == 1 || type == 3 ? 20 : (type == 2 ? 32 : 48)
                    guard !malformed.contains(used), let digest = values[used], digest.count == size else {
                        throw Failure.invalidDigest(path)
                    }
                    expected[type] = digest
                }
                let actual = try hashFile(file, types)
                guard types.allSatisfy({ actual[$0] == expected[$0] }) else { throw Failure.digestMismatch(path) }
                verifiedFileDigests[path] = Dictionary(uniqueKeysWithValues: types.map { ($0, actual[$0]!) })
                hashed += 1
                hashedBytes += file.byteCount
            }
        }
        var optional = 0
        for path in remaining.keys.sorted() {
            try Task.checkCancellation()
            guard remaining[path]!.optional else { throw Failure.missingResource(path) }
            optional += 1
        }
        let catchAll = rules.contains { $0.pattern == (version == 2 ? "^.*" : "^Resources/") && $0.isUnconditionalInclude }
        return EnvelopeVerification(version: version, hashedFiles: hashed, hashedBytes: hashedBytes,
            omittedFiles: omitted, absentOptionalFiles: optional, nested: nested, hasExactCatchAll: catchAll,
            verifiedFileDigests: verifiedFileDigests)
    }

    static func hashFile(byteCount: Int64, hashTypes: [UInt8],
        read: (Reader.ByteRange) throws -> Data) throws -> [UInt8: Data] {
        guard byteCount >= 0, byteCount <= Inventory.Limits.fileBytes else { throw Failure.resourceReadLimit }
        let types = Array(Set(hashTypes)).sorted()
        guard !types.isEmpty, types.allSatisfy({ (1...4).contains($0) }) else { throw Failure.unsupportedHash }
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var sha384 = SHA384()
        var offset: UInt64 = 0
        while offset < UInt64(byteCount) {
            try Task.checkCancellation()
            let count = Int(min(UInt64(Reader.Limits.ownedFileChunkBytes), UInt64(byteCount) - offset))
            let bytes = try read(.init(offset: offset, byteCount: count))
            guard bytes.count == count else { throw Reader.Failure.truncatedRead }
            if types.contains(1) { sha1.update(data: bytes) }
            if types.contains(2) || types.contains(3) { sha256.update(data: bytes) }
            if types.contains(4) { sha384.update(data: bytes) }
            offset += UInt64(count)
        }
        try Task.checkCancellation()
        let sha256Digest = Data(sha256.finalize())
        var result: [UInt8: Data] = [:]
        if types.contains(1) { result[1] = Data(sha1.finalize()) }
        if types.contains(2) { result[2] = sha256Digest }
        if types.contains(3) { result[3] = Data(sha256Digest.prefix(20)) }
        if types.contains(4) { result[4] = Data(sha384.finalize()) }
        return result
    }

    private static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.utf8.contains(0) && path.utf8.count <= Inventory.Limits.pathBytes &&
            parts.count <= Inventory.Limits.depth && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func boolean(_ value: Any?) throws -> Bool? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.malformedEnvelope }
        return number.boolValue
    }
    private enum SealKind {
        case hashes([String: Data], malformed: Set<String>)
        case nested(String, Data?)
        case symlink(String)
    }
    private struct Seal {
        let optional: Bool
        let kind: SealKind
        init(value: Any) throws {
            if let data = value as? Data { optional = false; kind = .hashes(["hash": data], malformed: []); return }
            guard let values = value as? NSDictionary else { throw Failure.malformedEnvelope }
            optional = try boolean(values["optional"]) ?? false
            if let raw = values["requirement"] {
                guard let requirement = raw as? String, !requirement.isEmpty,
                      requirement.utf8.count <= Limits.requirementBytes, !requirement.utf8.contains(0) else { throw Failure.malformedEnvelope }
                let cdHash: Data?
                if let rawHash = values["cdhash"] {
                    guard let data = rawHash as? Data, data.count == 20 else { throw Failure.malformedEnvelope }
                    cdHash = data
                } else { cdHash = nil }
                kind = .nested(requirement, cdHash)
            } else if let raw = values["symlink"] {
                guard let link = raw as? String, link.utf8.count <= Inventory.Limits.pathBytes,
                      !link.utf8.contains(0) else { throw Failure.malformedEnvelope }
                kind = .symlink(link)
            } else {
                var hashes: [String: Data] = [:]
                var malformed = Set<String>()
                for key in ["hash", "hash2", "hash3", "hash4"] {
                    if let raw = values[key] {
                        if let data = raw as? Data { hashes[key] = data }
                        else { malformed.insert(key) }
                    }
                }
                kind = .hashes(hashes, malformed: malformed)
            }
        }
    }
    private final class Rule {
        let pattern: String
        let weight: UInt32
        let omit: Bool
        let nested: Bool
        let isUnconditionalInclude: Bool
        private var expression = regex_t()
        private var compiled = false
        init(pattern: String, value: Any) throws {
            guard !pattern.utf8.contains(0), pattern.utf8.count <= Limits.ruleBytes else { throw Failure.invalidRule }
            self.pattern = pattern
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                weight = 1; omit = !number.boolValue; nested = false
                isUnconditionalInclude = number.boolValue
            } else if let values = value as? NSDictionary {
                if let rawWeight = values["weight"] {
                    guard let number = rawWeight as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, number.doubleValue >= 0,
                          number.doubleValue <= Double(UInt32.max), number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw Failure.invalidRule }
                    weight = number.uint32Value
                } else { weight = 1 }
                omit = try boolean(values["omit"]) ?? false
                nested = try boolean(values["nested"]) ?? false
                _ = try boolean(values["optional"])
                isUnconditionalInclude = false
            } else { throw Failure.invalidRule }
            guard regcomp(&expression, pattern, REG_EXTENDED | REG_NOSUB) == 0 else { throw Failure.invalidRule }
            compiled = true
        }
        deinit { if compiled { regfree(&expression) } }
        func matches(_ path: String) throws -> Bool {
            let result = regexec(&expression, path, 0, nil, 0)
            if result == 0 { return true }
            guard result == REG_NOMATCH else { throw Failure.invalidRule }
            return false
        }
    }
}
