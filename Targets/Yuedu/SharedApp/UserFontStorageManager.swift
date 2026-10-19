import CoreText
import Foundation

struct UserFontInfo: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let displayName: String
    let familyName: String
    let postScriptName: String
    let addedAt: Date
}

enum UserFontStorageError: LocalizedError {
    case unsupportedFileType
    case invalidFontFile
    case missingDocumentsDirectory
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return localized("僅支援 TTF 或 OTF 字體")
        case .invalidFontFile:
            return localized("無法讀取字體檔案")
        case .missingDocumentsDirectory:
            return localized("無法存取文件資料夾")
        case .rollbackFailed:
            return localized("操作失敗")
        }
    }
}

final class UserFontStorageManager: @unchecked Sendable {
    static let shared = UserFontStorageManager()

    private let fileManager: FileManager
    private let ownedDirectory: URL?
    private let operations: Operations

    /// Narrow file/CoreText seams for owned-directory failure tests. Production
    /// still uses the one existing service and Documents/fonts persistence.
    struct Operations: @unchecked Sendable {
        var copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
        var metadata: @Sendable (URL) -> (familyName: String, postScriptName: String)? = UserFontStorageManager.fontMetadata
        var register: @Sendable (URL) throws -> Void = UserFontStorageManager.registerFontChecked
        var unregister: @Sendable (URL) throws -> Void = UserFontStorageManager.unregisterFontChecked
    }

    private struct FontMetadata {
        let familyName: String
        let postScriptName: String
        let styleName: String
    }

    init(fileManager: FileManager = .default, ownedDirectory: URL? = nil, operations: Operations = .init()) {
        self.fileManager = fileManager
        self.ownedDirectory = ownedDirectory
        self.operations = operations
    }

    /// Copies a font into the library. A font in `existingFonts` with the same
    /// PostScript name is the version this one replaces. Keep old bytes until the
    /// new registration and all removals succeed; restore them on any failure.
    /// The async settings entry calls this worker off main. The synchronous entry
    /// remains for existing low-level callers and launch migration tests.
    func importFont(fileURL: URL, replacing existingFonts: [UserFontInfo] = []) throws -> UserFontInfo {
        let sourceExtension = fileURL.pathExtension.lowercased()
        guard ["ttf", "otf"].contains(sourceExtension) else {
            throw UserFontStorageError.unsupportedFileType
        }

        let directory = try fontsDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID()
        let destination = directory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension(sourceExtension)

        do { try operations.copy(fileURL, destination) }
        catch { cleanUp(destination); throw error }
        guard let metadata = operations.metadata(destination) else {
            cleanUp(destination)
            throw UserFontStorageError.invalidFontFile
        }
        let replaced = existingFonts.filter { $0.postScriptName == metadata.postScriptName }
        try mutateFiles(replaced, registering: destination)
        return UserFontInfo(
            id: id,
            fileName: destination.lastPathComponent,
            displayName: metadata.familyName,
            familyName: metadata.familyName,
            postScriptName: metadata.postScriptName,
            addedAt: Date()
        )
    }

    func registerAllOnLaunch() {
        guard let directory = try? fontsDirectoryURL(),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else { return }

        for url in urls where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            Self.registerFont(at: url)
        }
    }

    /// Deletes the copies that re-imports left behind before `importFont` replaced the
    /// old file. Only provable duplicates go: an unlisted file whose PostScript name a
    /// listed font already owns. An unlisted file with a name of its own stays — this
    /// directory is visible in the Files app, so it may have been put there by hand.
    ///
    /// One-time migration, run every launch because it is a directory listing once the
    /// copies are gone. Delete once no install from before 2026-10-12 is left.
    func removeSupersededCopies(keeping listedFonts: [UserFontInfo]) {
        let listedNames = Set(listedFonts.map(\.postScriptName))
        guard !listedNames.isEmpty else { return }
        let listedFiles = Set(listedFonts.map(\.fileName))

        let urls: [URL]
        do {
            let directory = try fontsDirectoryURL()
            guard fileManager.fileExists(atPath: directory.path) else { return }
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            AppLogger.error("UserFontStorage could not list the fonts directory", error: error)
            return
        }

        for url in urls
        where ["ttf", "otf"].contains(url.pathExtension.lowercased())
            && !listedFiles.contains(url.lastPathComponent) {
            guard let metadata = Self.fontMetadata(from: url),
                  listedNames.contains(metadata.postScriptName) else { continue }
            removeFile(at: url)
        }
    }

    func delete(_ font: UserFontInfo) {
        do {
            try deleteThrowing(font)
        } catch {
            AppLogger.error("UserFontStorage could not resolve \(font.fileName)", error: error)
        }
    }

    func deleteThrowing(_ font: UserFontInfo) throws {
        try mutateFiles([font], registering: nil)
    }

    /// All old bytes are copied before unregister/remove. No cancellation check
    /// splits this synchronous transaction; the caller must publish its result.
    private func mutateFiles(_ originals: [UserFontInfo], registering candidate: URL?) throws {
        let directory = try fontsDirectoryURL()
        let recovery = directory.appendingPathComponent(".font-transaction-\(UUID().uuidString)")
        var backups: [(URL, URL?)] = []
        var attemptedUnregister: [URL] = []
        do {
            try fileManager.createDirectory(at: recovery, withIntermediateDirectories: true)
            for font in originals {
                let original = try fileURL(for: font)
                let backup = recovery.appendingPathComponent(font.fileName)
                let attributes: [FileAttributeKey: Any]
                do { attributes = try fileManager.attributesOfItem(atPath: original.path) }
                catch {
                    // Files is allowed to remove a font outside this service.
                    // Only the pre-copy original lookup may establish absence;
                    // a later copy error may instead concern the recovery disk.
                    guard Self.isMissingFileError(error) else { throw error }
                    backups.append((original, nil))
                    continue
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw CocoaError(.fileReadUnknown)
                }
                try operations.copy(original, backup)
                backups.append((original, backup))
            }
        } catch {
            if let candidate { cleanUp(candidate) }
            cleanUp(recovery)
            throw error
        }
        do {
            for (original, _) in backups {
                attemptedUnregister.append(original)
                try operations.unregister(original)
            }
            if let candidate { try operations.register(candidate) }
            for (original, backup) in backups where backup != nil { try operations.remove(original) }
            cleanUp(recovery)
        } catch {
            var failed = false
            if let candidate {
                do { try operations.unregister(candidate) }
                catch { failed = true }
            }
            for (original, backup) in backups {
                guard let backup else { continue } // preserve the pre-existing absence
                do { try Self.restoreFile(backup, to: original) }
                catch { failed = true }
            }
            for original in attemptedUnregister {
                // There are no old bytes from which to recreate an already
                // missing font. This does not promise to restore system caches.
                guard backups.contains(where: { $0.0 == original && $0.1 != nil }) else { continue }
                do {
                    try operations.unregister(original)
                    try operations.register(original)
                } catch { failed = true }
            }
            if let candidate {
                do { try operations.remove(candidate) }
                catch { failed = true }
            }
            if failed {
                // Recovery copies remain in this owned directory, including when
                // restoring registration fails. Never present its internal path.
                AppLogger.error("Font rollback failed; recovery files retained")
                throw UserFontStorageError.rollbackFailed
            }
            cleanUp(recovery)
            throw error
        }
    }

    private static func restoreFile(_ backup: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".font-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: backup, to: temporary)
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            do { try FileManager.default.removeItem(at: temporary) }
            catch { AppLogger.error("Could not remove font rollback temporary file", error: error) }
            throw error
        }
    }

    private func cleanUp(_ url: URL) {
        do { try fileManager.removeItem(at: url) }
        catch {
            if !Self.isMissingFileError(error) {
                AppLogger.error("Could not remove owned font transaction material", error: error)
            }
        }
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
    }

    func fileURL(for font: UserFontInfo) throws -> URL {
        guard font.fileName == URL(fileURLWithPath: font.fileName).lastPathComponent,
              !font.fileName.hasPrefix("."), !font.fileName.contains("/"),
              !font.fileName.contains("\\") else { throw UserFontStorageError.invalidFontFile }
        return try fontsDirectoryURL().appendingPathComponent(font.fileName)
    }

    private func fontsDirectoryURL() throws -> URL {
        if let ownedDirectory { return ownedDirectory }
        guard let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw UserFontStorageError.missingDocumentsDirectory
        }
        return documentsURL.appendingPathComponent("fonts", isDirectory: true)
    }

    private func removeFile(at url: URL) {
        Self.unregisterFont(at: url)
        do {
            try fileManager.removeItem(at: url)
        } catch {
            AppLogger.error("UserFontStorage could not delete \(url.lastPathComponent)", error: error)
        }
    }

    /// Undoes `registerFont(at:)` in whichever scope it took. The other scope reports
    /// the URL as not registered, which is the expected outcome, not a failure.
    private static func unregisterFont(at url: URL) {
        CTFontManagerUnregisterFontsForURL(url as CFURL, .persistent, nil)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    }

    private static func registerFont(at url: URL) {
        do { try registerFontChecked(url) }
        catch { AppLogger.error("User font registration failed", error: error) }
    }

    private static func registerFontChecked(_ url: URL) throws {
        var persistentError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .persistent, &persistentError) {
            return
        }

        _ = persistentError?.takeRetainedValue()
        var processError: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &processError) {
            _ = processError?.takeRetainedValue()
            throw UserFontStorageError.invalidFontFile
        }
    }

    private static func unregisterFontChecked(_ url: URL) throws {
        for scope in [CTFontManagerScope.persistent, .process] {
            var failure: Unmanaged<CFError>?
            if CTFontManagerUnregisterFontsForURL(url as CFURL, scope, &failure) { continue }
            guard let error = failure?.takeRetainedValue() else { throw UserFontStorageError.invalidFontFile }
            let code = CFErrorGetCode(error)
            if code == CTFontManagerError.fileNotFound.rawValue {
                do { _ = try FileManager.default.attributesOfItem(atPath: url.path) }
                catch {
                    // A URL confirmed absent is already unusable on disk.
                    // Do not generalize this to in-use or permission errors.
                    if isMissingFileError(error) { continue }
                    throw error
                }
            }
            // An absent/unsupported scope is expected for the other registration
            // mode. In-use/permission failures must keep the old font and record.
            guard code == CTFontManagerError.notRegistered.rawValue
                || code == CTFontManagerError.unsupportedScope.rawValue else {
                throw UserFontStorageError.invalidFontFile
            }
        }
    }

    private static func fontMetadata(from url: URL) -> (familyName: String, postScriptName: String)? {
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let metadata = preferredMetadata(from: descriptors)
        else { return nil }

        return (
            familyName: metadata.familyName,
            postScriptName: metadata.postScriptName
        )
    }

    private static func preferredMetadata(from descriptors: [CTFontDescriptor]) -> FontMetadata? {
        let candidates = descriptors.compactMap { metadata(from: $0) }
        guard !candidates.isEmpty else { return nil }

        return candidates.first { $0.styleName.localizedCaseInsensitiveCompare("Regular") == .orderedSame }
            ?? candidates.first { $0.postScriptName.localizedCaseInsensitiveContains("Regular") }
            ?? candidates.first
    }

    private static func metadata(from descriptor: CTFontDescriptor) -> FontMetadata? {
        let postScriptName = CTFontDescriptorCopyAttribute(
            descriptor,
            kCTFontNameAttribute
        ) as? String ?? ""
        let familyName = CTFontDescriptorCopyAttribute(
            descriptor,
            kCTFontFamilyNameAttribute
        ) as? String ?? ""
        let styleName = CTFontDescriptorCopyAttribute(
            descriptor,
            kCTFontStyleNameAttribute
        ) as? String ?? ""

        guard !postScriptName.isEmpty || !familyName.isEmpty else {
            return nil
        }

        return FontMetadata(
            familyName: familyName.isEmpty ? postScriptName : familyName,
            postScriptName: postScriptName.isEmpty ? familyName : postScriptName,
            styleName: styleName
        )
    }
}
