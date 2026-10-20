import Foundation
import Security

// MARK: - KeychainHelper
// Minimal thread-safe wrapper around Keychain Services.
// Used by LoginManager to store sensitive login credentials instead of UserDefaults.

enum KeychainHelper {
    enum ReadFailure: Error, Sendable, Equatable {
        case lookup(OSStatus), unexpectedResult, invalidUTF8, valueLimit
        case accessibilityMigration(OSStatus)
    }
    enum WriteFailure: Error, Sendable, Equatable { case insert(OSStatus) }
    private struct ReadValue {
        let value: String?
        let migrationStatus: OSStatus?
    }

    /// Book-source logins. Callers that store something else pass their own service so two
    /// unrelated secrets can never collide on one account name — there is deliberately no
    /// second Keychain wrapper in this project.
    static let loginService = "com.yuedu.loginCredentials"
    /// BYOK AI API keys. Separate service so clearing one never clears the other.
    static let aiService = "com.yuedu.aiCredentials"

    /// Persist a string value in the Keychain, creating or updating the item as needed.
    @discardableResult
    static func save(
        account: String,
        data: String,
        service: String = loginService,
        accessibility: CFString? = nil,
        synchronizable: Bool? = nil
    ) -> Bool {
        guard let dataBytes = data.data(using: .utf8) else { return false }

        var baseQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let synchronizable {
            baseQuery[kSecAttrSynchronizable as String] = synchronizable as CFBoolean
        }

        var attributes: [String: Any] = [kSecValueData as String: dataBytes]
        if let accessibility {
            attributes[kSecAttrAccessible as String] = accessibility
        }
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            logFailure(operation: "update", status: status)
            return false
        }

        // Item not found — add new
        var addQuery = baseQuery
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess { logFailure(operation: "add", status: addStatus) }
        return addStatus == errSecSuccess
    }

    /// Add exactly one new owned item. Duplicate, locked and failed writes are
    /// explicit errors; this boundary never falls back to an update/upsert.
    static func insertChecked(account: String, data: String, service: String,
        accessibility: CFString, synchronizable: Bool) throws {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.keychain.checked-insert",
            "bytes=\(data.utf8.count) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        try insertCore(account: account, data: data, service: service,
            accessibility: accessibility, synchronizable: synchronizable)
    }

    /// Existing synchronous login forms already read/migrate one item on their
    /// caller. Preserve that boundary while making migration add-only; this is
    /// not a new queue or a worker-only API called from MainActor.
    static func insertExistingLoginIfMissing(account: String, raw: String) throws -> Bool {
        do {
            try insertCore(account: account, data: raw, service: loginService,
                accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: false)
            return true
        } catch WriteFailure.insert(errSecDuplicateItem) { return false }
    }

    private static func insertCore(account: String, data: String, service: String,
        accessibility: CFString, synchronizable: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(data.utf8),
            kSecAttrAccessible as String: accessibility,
            kSecAttrSynchronizable as String: synchronizable as CFBoolean,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logFailure(operation: "checked insert", status: status)
            throw WriteFailure.insert(status)
        }
    }

    /// Load a previously saved string value from the Keychain. Returns `nil` if not found.
    static func load(
        account: String,
        service: String = loginService,
        accessibility: CFString? = nil,
        synchronizable: Bool? = nil
    ) -> String? {
        do {
            let read = try readCore(account: account, service: service, accessibility: accessibility,
                synchronizable: synchronizable, maximumBytes: nil)
            if let status = read.migrationStatus { logFailure(operation: "accessibility migration", status: status) }
            return read.value
        } catch let error as ReadFailure {
            if case .lookup(let status) = error { logFailure(operation: "read", status: status) }
            return nil
        } catch {
            AppLogger.error("Keychain read failed", context: ["errorType": String(reflecting: type(of: error))])
            return nil
        }
    }

    /// Strict users distinguish genuine missing items from locked/unreadable,
    /// malformed or failed-migration data. Uses the same one query and original
    /// attribute-only migration; it never broadens services/access groups.
    static func loadChecked(account: String, service: String = loginService,
        accessibility: CFString? = nil, synchronizable: Bool? = nil, maximumBytes: Int) throws -> String? {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw ReadFailure.valueLimit }
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.keychain.checked-read",
            "bytesLimit=\(maximumBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        let value = try checkedReadCore(account: account, service: service, accessibility: accessibility,
            synchronizable: synchronizable, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        return value
    }

    /// The original form getter cannot change signature or become async in a
    /// credential interoperation fix. One existing read now reports true missing
    /// separately from locked/malformed data instead of enabling legacy upsert.
    static func loadExistingLoginChecked(account: String, maximumBytes: Int) throws -> String? {
        guard maximumBytes > 0 else { throw ReadFailure.valueLimit }
        return try checkedReadCore(account: account, service: loginService,
            accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: nil, maximumBytes: maximumBytes)
    }

    private static func checkedReadCore(account: String, service: String, accessibility: CFString?,
        synchronizable: Bool?, maximumBytes: Int) throws -> String? {
        let read = try readCore(account: account, service: service, accessibility: accessibility,
            synchronizable: synchronizable, maximumBytes: maximumBytes)
        if let status = read.migrationStatus { throw ReadFailure.accessibilityMigration(status) }
        return read.value
    }

    private static func readCore(account: String, service: String, accessibility: CFString?,
        synchronizable: Bool?, maximumBytes: Int?) throws -> ReadValue {
        var baseQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let synchronizable {
            baseQuery[kSecAttrSynchronizable as String] = synchronizable as CFBoolean
        }
        var query = baseQuery
        query.merge([
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]) { _, new in new }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return ReadValue(value: nil, migrationStatus: nil) }
        guard status == errSecSuccess else { throw ReadFailure.lookup(status) }
        guard let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data else { throw ReadFailure.unexpectedResult }
        if let maximumBytes, data.count > maximumBytes { throw ReadFailure.valueLimit }
        guard let str = String(data: data, encoding: .utf8) else { throw ReadFailure.invalidUTF8 }

        // Existing installations already have WhenUnlocked items. Migrate their protection
        // while the item is readable, before the listener locks the device. Update only the
        // attribute: writing the value we just read could overwrite a concurrent login edit.
        var failedMigration: OSStatus?
        if let accessibility,
           item[kSecAttrAccessible as String] as? String != accessibility as String {
            let migrationStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecAttrAccessible as String: accessibility] as CFDictionary
            )
            if migrationStatus != errSecSuccess { failedMigration = migrationStatus }
        }
        return ReadValue(value: str, migrationStatus: failedMigration)
    }

    private static func logFailure(operation: String, status: OSStatus) {
        // Neither the account (which may contain a source URL) nor credential values belong
        // in diagnostics. Preserve the status so locked data isn't mistaken for no login.
        AppLogger.error("Keychain operation failed", context: [
            "operation": operation,
            "status": status,
        ])
    }

    /// Remove an item from the Keychain. Returns `true` if deleted or not found.
    @discardableResult
    static func delete(account: String, service: String = loginService, synchronizable: Bool? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let synchronizable {
            query[kSecAttrSynchronizable as String] = synchronizable as CFBoolean
        }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
