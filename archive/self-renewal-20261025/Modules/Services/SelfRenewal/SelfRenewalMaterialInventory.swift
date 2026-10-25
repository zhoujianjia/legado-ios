import Darwin
import Foundation

/// Read-only observations of a caller-owned, already unpacked and quiescent .app.
/// This is not an IPA extractor, a signature verifier or a replacement-policy
/// adapter. Never use this inventory to assert trusted signing/account identity.
enum SelfRenewalMaterialInventory {
    typealias Role = SelfRenewalReplacementPolicy.BundleRole

    enum Verification: Sendable, Equatable { case unverified }
    enum ComponentKind: String, Sendable, Equatable {
        case application = "app", appExtension = "appex", framework, xpc, bundle
    }
    enum MachOHeader: Sendable, Equatable {
        case thin32, thin64, fat32, fat64
    }
    enum Failure: Error, Sendable, Equatable {
        case invalidRoot, unreadableDirectory, unsupportedFileType, linkNotAllowed
        case pathLimit, entryLimit, depthLimit, componentLimit, codeFileLimit
        case fileSizeLimit, totalSizeLimit, plistSizeLimit, totalReadLimit
        case unreadableFile, fileChangedDuringRead, missingApplicationInfo
        case malformedInfoPlist, invalidInfoMetadata
    }
    enum Issue: Sendable, Equatable {
        case missingRole(Role), duplicateRole(Role)
        case missingOrInvalidInfo(String), unexpectedComponent(String)
        case invalidRoleLocation(String), invalidParentIdentifier(String)
        case duplicateBundleIdentifier, missingExecutable(String)
        case unrecognizedExecutableHeader(String)
    }
    struct Metadata: Sendable, Equatable {
        let bundleIdentifier: String
        let executableName: String
        let version: String
        let build: String
        let packageType: String
        let extensionPointIdentifier: String?
    }
    struct FileFact: Sendable, Equatable {
        let relativePath: String
        let byteCount: Int64
    }
    struct CodeFile: Sendable, Equatable {
        let file: FileFact
        /// A magic-byte observation only; load commands/signature are unparsed.
        let header: MachOHeader?
    }
    struct Component: Sendable, Equatable {
        /// "." denotes the supplied root; other paths are relative to it.
        let relativePath: String
        let kind: ComponentKind
        let metadata: Metadata?
        let role: Role?
        /// Derived from directory containment, never from signed entitlements.
        let parentBundleIdentifier: String?
        let executable: CodeFile?
        let embeddedProvisioningProfile: FileFact?
        let codeResources: FileFact?
        /// Bounded BNDL metadata and the complete inventory establish absence
        /// of native code; the containing signed resource seal still applies.
        let resourceOnly: Bool
    }
    struct Inventory: Sendable, Equatable {
        let components: [Component]
        /// Includes header-recognized Mach-O files at arbitrary relative paths,
        /// and .dylib files even when their header cannot be recognized.
        let codeFiles: [CodeFile]
        /// The same bounded enumeration used above; consumers must not rescan
        /// the tree to discover resources. Paths are relative to the app root.
        let files: [FileFact]
        let directories: [String]
        let issues: [Issue]
        let entriesVisited: Int
        let declaredFileBytes: Int64
        let bytesRead: Int
        var verification: Verification { .unverified }
        var cryptographicVerificationPerformed: Bool { false }
        var accountIdentityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
    }

    // These are hard limits, not caller-increasable tuning values. The inventory
    // never reads profile/CMS contents or whole executables/resource files.
    enum Limits {
        // The shipped 13-module Java home alone has 17,856 names. This
        // permits its measured tree plus ordinary app resources, while staying
        // below classic ZIP's 65,535-entry sentinel.
        static let entries = 32_768
        static let depth = 24
        static let pathBytes = 1_024
        static let components = 64
        static let codeFiles = 128
        static let fileBytes: Int64 = 1_073_741_824
        static let totalFileBytes: Int64 = 2_147_483_648
        static let plistBytes = 262_144
        static let totalReadBytes = 2_162_688
    }

    /// The detached worker is deliberate: tests enable approachable concurrency
    /// and must not accidentally move directory I/O onto their caller's actor.
    /// Cancellation is linked to the worker and checked between bounded reads.
    nonisolated static func read(unpackedApplication root: URL) async throws -> Inventory {
        let worker = Task.detached(priority: .utility) {
            try readSynchronously(root)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Pure, bounded parsing. Values from Info.plist remain untrusted metadata.
    static func parseInfoPlist(_ data: Data, resourceBundle: Bool = false) throws -> Metadata {
        guard !data.isEmpty, data.count <= Limits.plistBytes else { throw Failure.plistSizeLimit }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw Failure.malformedInfoPlist }
        guard let values = object as? [String: Any],
              let identifier = values["CFBundleIdentifier"] as? String, validIdentifier(identifier),
              let build = values["CFBundleVersion"] as? String, validToken(build, maximum: 64),
              let package = values["CFBundlePackageType"] as? String, validToken(package, maximum: 8) else {
            throw Failure.invalidInfoMetadata
        }
        let resourceMetadata = resourceBundle && package == "BNDL"
            && values["CFBundleExecutable"] == nil && values["NSExtension"] == nil
        let executable: String
        let version: String
        if resourceMetadata {
            // SwiftPM resource bundles omit ShortVersionString. Empty here is
            // an absence observation, never an executable name/version claim.
            executable = ""
            if let rawVersion = values["CFBundleShortVersionString"] {
                guard let value = rawVersion as? String, validToken(value, maximum: 64) else {
                    throw Failure.invalidInfoMetadata
                }
                version = value
            } else { version = "" }
        } else {
            guard let name = values["CFBundleExecutable"] as? String, validFileName(name),
                  let value = values["CFBundleShortVersionString"] as? String,
                  validToken(value, maximum: 64) else { throw Failure.invalidInfoMetadata }
            executable = name; version = value
        }
        let extensionPoint: String?
        if let raw = values["NSExtension"] {
            guard let extensionValues = raw as? [String: Any],
                  let point = extensionValues["NSExtensionPointIdentifier"] as? String,
                  validIdentifier(point) else { throw Failure.invalidInfoMetadata }
            extensionPoint = point
        } else {
            extensionPoint = nil
        }
        return Metadata(bundleIdentifier: identifier, executableName: executable, version: version,
            build: build, packageType: package, extensionPointIdentifier: extensionPoint)
    }

    private struct Entry {
        let url: URL
        let directory: Bool
        let bytes: Int64
    }

    private static func readSynchronously(_ suppliedRoot: URL) throws -> Inventory {
        precondition(!Thread.isMainThread, "Renewal material reads must stay off main")
        try Task.checkCancellation()
        guard suppliedRoot.isFileURL, suppliedRoot.pathExtension.lowercased() == "app",
              suppliedRoot.query == nil, suppliedRoot.fragment == nil else { throw Failure.invalidRoot }
        let initial = try fileValues(suppliedRoot)
        guard initial.isSymbolicLink != true else { throw Failure.linkNotAllowed }
        guard initial.isDirectory == true else { throw Failure.invalidRoot }
        // Canonicalize the caller-owned root once, allowing system ancestors such
        // as /var -> /private/var. Descendant links are always rejected. This is
        // an observation of a quiescent staging tree, not an atomic trust seal;
        // a future signing adapter must revalidate real materials at use.
        let root = suppliedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let started = SourcePerfTrace.now
        var visited = 0
        var declaredBytes: Int64 = 0
        var readBytes = 0
        defer {
            SourcePerfTrace.record("renewal.material.inventory",
                "entries=\(visited) bytes=\(readBytes) declaredBytes=\(declaredBytes) main=\(Thread.isMainThread)",
                since: started, thresholdMs: 0)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }) else { throw Failure.unreadableDirectory }
        var entries: [String: Entry] = [:]
        var componentPaths: [(String, ComponentKind)] = [(".", .application)]
        while let value = enumerator.nextObject() {
            try Task.checkCancellation()
            guard let url = value as? URL else { throw Failure.unreadableDirectory }
            visited += 1
            guard visited <= Limits.entries else { throw Failure.entryLimit }
            let relative = try relativePath(url, within: root)
            let values = try fileValues(url)
            guard values.isSymbolicLink != true else { throw Failure.linkNotAllowed }
            let directory = values.isDirectory == true
            guard directory || values.isRegularFile == true else { throw Failure.unsupportedFileType }
            let size = directory ? 0 : Int64(values.fileSize ?? -1)
            guard size >= 0, size <= Limits.fileBytes else { throw Failure.fileSizeLimit }
            if !directory {
                var status = stat()
                guard Darwin.lstat(url.path, &status) == 0 else { throw Failure.unreadableFile }
                guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.unsupportedFileType }
                guard status.st_nlink == 1 else { throw Failure.linkNotAllowed }
            }
            declaredBytes += size
            guard declaredBytes <= Limits.totalFileBytes else { throw Failure.totalSizeLimit }
            entries[relative] = Entry(url: url, directory: directory, bytes: size)
            if directory, let kind = ComponentKind(rawValue: url.pathExtension.lowercased()) {
                componentPaths.append((relative, kind))
                guard componentPaths.count <= Limits.components else { throw Failure.componentLimit }
            }
        }
        guard !enumerationFailed else { throw Failure.unreadableDirectory }
        guard let mainInfo = entries["Info.plist"], !mainInfo.directory else {
            throw Failure.missingApplicationInfo
        }
        var metadata: [String: Metadata] = [:]
        var issues: [Issue] = []
        for (path, kind) in componentPaths.sorted(by: { $0.0 < $1.0 }) {
            try Task.checkCancellation()
            let key = child("Info.plist", of: path)
            guard let entry = entries[key], !entry.directory else {
                issues.append(.missingOrInvalidInfo(path))
                continue
            }
            guard entry.bytes <= Int64(Limits.plistBytes) else { throw Failure.plistSizeLimit }
            let bytes = try readFile(entry, maximum: Limits.plistBytes, full: true, budget: &readBytes)
            do { metadata[path] = try parseInfoPlist(bytes, resourceBundle: kind == .bundle) }
            catch let error as Failure {
                if path == "." { throw error }
                issues.append(.missingOrInvalidInfo(path))
            }
        }
        guard let main = metadata["."] else { throw Failure.missingApplicationInfo }
        var codes: [String: CodeFile] = [:]
        // Eight bytes distinguish the shipped Java class version from the
        // shared CAFEBABE universal-Mach-O magic. This is classification only;
        // resource seals still bind every class byte and native code still goes
        // through the existing structural/hash/CMS verifiers.
        // CMS/profile and CodeResources files are presence-only observations.
        for path in entries.keys.sorted() {
            try Task.checkCancellation()
            guard let entry = entries[path], !entry.directory else { continue }
            guard !path.hasSuffix("/Info.plist"), path != "Info.plist",
                  !path.hasSuffix(".mobileprovision"), !path.hasSuffix("/_CodeSignature/CodeResources"),
                  path != "_CodeSignature/CodeResources" else { continue }
            let header = try readFile(entry, maximum: 8, full: false, budget: &readBytes)
            let observed = machOHeader(header)
            if observed != nil || entry.url.pathExtension.lowercased() == "dylib" {
                codes[path] = CodeFile(file: FileFact(relativePath: path, byteCount: entry.bytes), header: observed)
                guard codes.count <= Limits.codeFiles else { throw Failure.codeFileLimit }
            }
        }
        var components: [Component] = []
        var roleCounts: [Role: Int] = [:]
        var identifiers = Set<String>()
        for (path, kind) in componentPaths.sorted(by: { $0.0 < $1.0 }) {
            let info = metadata[path]
            let prefix = path + "/"
            let resourceOnly = kind == .bundle && info?.packageType == "BNDL"
                && info?.executableName == "" && info?.extensionPointIdentifier == nil
                && entries[child("embedded.mobileprovision", of: path)] == nil
                && entries[child("_CodeSignature/CodeResources", of: path)] == nil
                && !codes.keys.contains(where: { $0.hasPrefix(prefix) })
                && !componentPaths.contains(where: { $0.0.hasPrefix(prefix) && $0.1 != .bundle })
            let role = role(for: info, kind: kind, root: path == ".")
            if let role {
                roleCounts[role, default: 0] += 1
                if role != .application {
                    let pieces = path.split(separator: "/")
                    if pieces.count != 2 || pieces.first != "PlugIns" { issues.append(.invalidRoleLocation(path)) }
                    if info?.bundleIdentifier.hasPrefix(main.bundleIdentifier + ".") != true {
                        issues.append(.invalidParentIdentifier(path))
                    }
                }
            } else if !resourceOnly {
                issues.append(.unexpectedComponent(path))
            }
            // Resource IDs are not code-signing identities; parent seals bind
            // their exact Info bytes even when two resources share an ID.
            if !resourceOnly, let info, !identifiers.insert(info.bundleIdentifier).inserted { issues.append(.duplicateBundleIdentifier) }
            let executablePath = info.flatMap { $0.executableName.isEmpty ? nil : child($0.executableName, of: path) }
            let executable: CodeFile?
            if let executablePath, let entry = entries[executablePath], !entry.directory {
                executable = codes[executablePath] ?? CodeFile(
                    file: FileFact(relativePath: executablePath, byteCount: entry.bytes), header: nil)
                if executable?.header == nil { issues.append(.unrecognizedExecutableHeader(path)) }
            } else {
                executable = nil
                if !resourceOnly { issues.append(.missingExecutable(path)) }
            }
            let pieces = path.split(separator: "/")
            let directChild = pieces.count == 2 && pieces.first == "PlugIns" && kind == .appExtension
            components.append(Component(relativePath: path, kind: kind, metadata: info, role: role,
                parentBundleIdentifier: directChild ? main.bundleIdentifier : nil, executable: executable,
                embeddedProvisioningProfile: fact("embedded.mobileprovision", in: path, entries: entries),
                codeResources: fact("_CodeSignature/CodeResources", in: path, entries: entries), resourceOnly: resourceOnly))
        }
        for role in Role.allCases {
            if roleCounts[role, default: 0] == 0 { issues.append(.missingRole(role)) }
            if roleCounts[role, default: 0] > 1 { issues.append(.duplicateRole(role)) }
        }
        return Inventory(components: components, codeFiles: codes.values.sorted { $0.file.relativePath < $1.file.relativePath },
            files: entries.compactMap { path, entry in
                entry.directory ? nil : FileFact(relativePath: path, byteCount: entry.bytes)
            }.sorted { $0.relativePath < $1.relativePath },
            directories: entries.compactMap { $0.value.directory ? $0.key : nil }.sorted(),
            issues: issues, entriesVisited: visited, declaredFileBytes: declaredBytes, bytesRead: readBytes)
    }

    private static func readFile(_ entry: Entry, maximum: Int, full: Bool, budget: inout Int) throws -> Data {
        try Task.checkCancellation()
        let expected = Int(min(entry.bytes, Int64(maximum)))
        guard !full || entry.bytes <= Int64(maximum) else { throw Failure.plistSizeLimit }
        guard budget <= Limits.totalReadBytes - expected else { throw Failure.totalReadLimit }
        // O_NOFOLLOW rejects a leaf swapped for a symlink; O_NONBLOCK prevents a
        // raced FIFO from blocking before fstat rejects non-regular files. The
        // caller must still keep the enclosing staging directory quiescent.
        let descriptor = Darwin.open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadableFile }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else { throw Failure.unreadableFile }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.unsupportedFileType }
        guard before.st_nlink == 1 else { throw Failure.linkNotAllowed }
        guard before.st_size == entry.bytes else { throw Failure.fileChangedDuringRead }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        do {
            while data.count < expected {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: expected - data.count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw Failure.unreadableFile }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else { throw Failure.unreadableFile }
        guard data.count == expected, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.fileChangedDuringRead }
        budget += data.count
        return data
    }

    private static func fileValues(_ url: URL) throws -> URLResourceValues {
        do { return try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw Failure.unreadableFile }
    }
    private static func relativePath(_ url: URL, within root: URL) throws -> String {
        let prefix = root.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw Failure.invalidRoot }
        let relative = String(path.dropFirst(prefix.count))
        guard relative.utf8.count <= Limits.pathBytes else { throw Failure.pathLimit }
        guard relative.split(separator: "/").count <= Limits.depth else { throw Failure.depthLimit }
        return relative
    }
    private static func child(_ name: String, of path: String) -> String { path == "." ? name : path + "/" + name }
    private static func fact(_ name: String, in path: String, entries: [String: Entry]) -> FileFact? {
        let key = child(name, of: path)
        guard let entry = entries[key], !entry.directory else { return nil }
        return FileFact(relativePath: key, byteCount: entry.bytes)
    }
    private static func role(for metadata: Metadata?, kind: ComponentKind, root: Bool) -> Role? {
        guard let metadata else { return nil }
        if root, kind == .application, metadata.packageType == "APPL", metadata.extensionPointIdentifier == nil { return .application }
        guard kind == .appExtension, metadata.packageType == "XPC!" else { return nil }
        switch metadata.extensionPointIdentifier {
        case "com.apple.widgetkit-extension": return .widgetExtension
        case "com.apple.share-services": return .shareExtension
        default: return nil
        }
    }
    private static func machOHeader(_ bytes: Data) -> MachOHeader? {
        // The pinned native runtime has 16,614 CAFEBABE/0/72 class files.
        // A supported universal Mach-O has at most 16 architectures; 72 can
        // never describe an accepted native container. Do not use a filename
        // extension to exclude native code. Unknown versions/malformed headers
        // retain the native-code candidate and fail in the strong verifier.
        if bytes.count == 8, Array(bytes) == [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 72] { return nil }
        switch Array(bytes.prefix(4)) {
        case [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE]: return .thin32
        case [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE]: return .thin64
        case [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]: return .fat32
        case [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA]: return .fat64
        default: return nil
        }
    }
    private static func validToken(_ value: String, maximum: Int) -> Bool {
        let bytes = value.utf8.prefix(maximum + 1)
        return !bytes.isEmpty && bytes.count <= maximum && bytes.allSatisfy { (33...126).contains($0) }
    }
    private static func validFileName(_ value: String) -> Bool {
        let bytes = value.utf8.prefix(256)
        return !bytes.isEmpty && bytes.count <= 255 && value != "." && value != ".."
            && bytes.allSatisfy { (32...126).contains($0) && $0 != 47 && $0 != 92 }
    }
    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8.prefix(256)
        return !bytes.isEmpty && bytes.count <= 255 && bytes.first != 46 && bytes.last != 46
            && !value.contains("..") && bytes.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
            }
    }
}
