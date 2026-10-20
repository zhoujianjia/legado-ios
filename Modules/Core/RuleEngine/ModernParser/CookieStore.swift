import Foundation
import JavaScriptCore

/// One existing Cookie file/native storage owner. Source-script APIs stay
/// synchronous on their dedicated worker only; App/network callbacks await it.
/// This does not grant the original JVM a rich Cookie CAS snapshot.
final class CookieStore: @unchecked Sendable {
    static let shared = CookieStore()
    private let owner: CookiePersistenceOwner

    private convenience init() {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        self.init(fileURL: directory.appendingPathComponent("legado_cookies.json"), storage: .shared)
    }

    /// The fixture uses this identical owner, with its own actual directory and
    /// native storage. Construction performs no I/O and never waits on main.
    init(fileURL: URL, storage: HTTPCookieStorage, beforeWrite: (@Sendable () throws -> Void)? = nil) {
        self.owner = CookiePersistenceOwner(fileURL: fileURL, storage: storage, beforeWrite: beforeWrite)
    }

    func prepare() async throws { try await owner.prepare() }
    func requestHeader(url: URL) async throws -> String? { try await owner.requestHeader(url: url) }
    func nativeCookies(url: URL) async throws -> [HTTPCookie] { try await owner.nativeCookies(url: url) }
    func snapshot() async throws -> CookiePersistenceOwner.Document { try await owner.snapshot() }
    func originalRawText(domain: String) async throws -> String { try await owner.originalRawText(domain: domain) }
    func clearOriginalOkHttp(validate: @escaping @Sendable () throws -> Void = {}) async throws {
        try await owner.clearOriginalOkHttp(validate: validate)
    }
    func originalText(domain: String) async throws -> String { try await owner.originalText(domain: domain) }
    func originalSession(domain: String) async throws -> String { try await owner.originalSession(domain: domain) }
    func mutateOriginalText(domain: String, action: String, raw: String?,
                            validate: @escaping @Sendable () throws -> Void = {}) async throws {
        try await owner.mutateOriginalText(domain: domain, action: action, raw: raw, validate: validate)
    }
    func ingestOriginalResponse(_ records: [CookiePersistenceOwner.Record], domain: String, persistentText: String, sessionText: String,
                                validate: @escaping @Sendable () throws -> Void = {}) async throws {
        try await owner.ingestOriginalResponse(records, domain: domain, persistentText: persistentText, sessionText: sessionText, validate: validate)
    }
    func getOwned(url: String) async throws -> String { try await owner.get(url: url) }
    func getKeyOwned(url: String, key: String) async throws -> String {
        Self.value(try await owner.get(url: Self.normalizedURLString(url)), key: key)
    }
    func setOwned(url: String, cookie: String) async throws { try await owner.set(url: url, raw: cookie) }
    func ingest(_ cookies: [HTTPCookie], provenance: CookiePersistenceOwner.Provenance, originURL: URL? = nil,
                validate: @escaping @Sendable () throws -> Void = {}) async throws {
        try await owner.ingest(cookies, provenance: provenance, originURL: originURL, validate: validate)
    }
    func beginWebKitObservation() async throws -> CookiePersistenceOwner.WebKitObservation {
        try await owner.beginWebKitObservation()
    }
    func validateWebKitObservation(_ observation: CookiePersistenceOwner.WebKitObservation,
                                  validate: @escaping @Sendable () throws -> Void = {}) async throws {
        try await owner.validateWebKitObservation(observation, validate: validate)
    }
    func ingestWebKitSnapshot(_ cookies: [HTTPCookie], observation: CookiePersistenceOwner.WebKitObservation,
                             confirming scope: URL? = nil, requireCurrent: Bool = true,
                             preservingOriginalRaw: Bool = false, authoritativeCookies: [HTTPCookie] = [],
                             validate: @escaping @Sendable () throws -> Void = {}) async throws {
        try await owner.ingestWebKitSnapshot(cookies, observation: observation, confirming: scope,
            requireCurrent: requireCurrent, preservingOriginalRaw: preservingOriginalRaw,
            authoritativeCookies: authoritativeCookies, validate: validate)
    }
    func removeOwned(url: String, key: String? = nil, includingRelatedDomains: Bool = false) async throws {
        try await owner.remove(url: url, key: key, includingRelatedDomains: includingRelatedDomains)
    }
    func clearAllOwned() async throws { try await owner.clearAll() }

    // Existing JS call sites receive a catchable typed JS error on failed disk
    // I/O. The empty return value is not consumed when the exception escapes.
    func get(url: String) -> String { legacy("") { try await self.owner.get(url: url) } }
    func getKey(url: String, key: String) -> String {
        Self.value(get(url: Self.normalizedURLString(url)), key: key)
    }
    func set(url: String, cookie: String) { legacyVoid { try await self.owner.set(url: url, raw: cookie) } }
    func remove(url: String) { legacyVoid { try await self.owner.remove(url: url) } }
    func remove(url: String, key: String, includingRelatedDomains: Bool = false) {
        legacyVoid { try await self.owner.remove(url: url, key: key, includingRelatedDomains: includingRelatedDomains) }
    }
    func clearAll() { legacyVoid { try await self.owner.clearAll() } }

    private func legacyVoid(operation: @escaping @Sendable () async throws -> Void) {
        _ = legacy(false) { try await operation(); return true }
    }

    /// Only the existing source-script workers may wait for synchronous JS.
    /// Main cannot wait on the actor, a queue or its file I/O.
    private func legacy<T>(_ fallback: T, operation: @escaping @Sendable () async throws -> T) -> T {
        do { return try blocking(operation: operation) }
        catch { Self.raiseScriptError(error); return fallback }
    }

    func getForScript(url: String) throws -> String {
        try blocking { try await self.owner.get(url: url) }
    }

    func blocking<T>(operation: @escaping @Sendable () async throws -> T) throws -> T {
        guard !Thread.isMainThread else { throw CookieOwnerError(code: "STATE_THREAD", message: "Cookie script API requires a source-script worker") }
        let result = CookieBlockingResult<T>()
        let completed = DispatchSemaphore(value: 0)
        Task.detached {
            do { result.store(.success(try await operation())) }
            catch { result.store(.failure(error)) }
            completed.signal()
        }
        completed.wait()
        return try result.value().get()
    }

    static func raiseScriptError(_ error: Error) {
        let code = (error as? CookieOwnerError)?.code ?? "STATE_IO"
        AppLogger.error("Cookie owner rejected a source request", error: error)
        if let context = JSContext.current(), let exception = JSValue(newErrorFromMessage: "Cookie owner did not complete the request", in: context) {
            exception.setValue(code, forProperty: "code")
            context.exception = exception
        }
    }

    static func normalizedURLString(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains("://") ? value : "https://" + value
    }

    private static func value(_ text: String, key: String) -> String {
        guard !key.isEmpty else { return text }
        for segment in text.components(separatedBy: ";") {
            let parts = segment.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1] }
        }
        return ""
    }

    /// Parse a `name=value; name2=value2` string into HTTPCookie objects.
    /// Skips standard Set-Cookie attribute names (Domain, Path, Expires, etc.)
    /// so they are never treated as cookies.
    static func makeCookies(_ raw: String, for url: URL) -> [HTTPCookie] {
        guard let host = url.host else { return [] }
        let knownAttributes: Set<String> = [
            "domain", "path", "expires", "max-age", "secure", "httponly", "samesite"
        ]
        return raw.components(separatedBy: ";").compactMap { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !knownAttributes.contains(name.lowercased()) else { return nil }
            return HTTPCookie(properties: [
                .name: name,
                .value: parts[1].trimmingCharacters(in: .whitespaces),
                .domain: host,
                .path: "/"
            ])
        }
    }

    /// Merge incoming `name=value` pairs into an existing cookie string.
    /// Incoming values overwrite existing ones with the same name.
    static func merge(existing: String?, incoming: String) -> String {
        var dict: [String: String] = [:]
        // Parse existing
        for segment in (existing ?? "").components(separatedBy: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty {
                dict[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        // Overwrite with incoming
        for segment in incoming.components(separatedBy: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty {
                dict[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    static func removingCookie(named key: String, from raw: String) -> String {
        raw.components(separatedBy: ";").compactMap { segment -> String? in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return trimmed.isEmpty ? nil : trimmed }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            return name == key ? nil : trimmed
        }.joined(separator: "; ")
    }
}


/// The synchronous bridge transfers one result, never native Cookie state.
private final class CookieBlockingResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func store(_ value: Result<Value, Error>) { lock.withLock { result = value } }
    func value() -> Result<Value, Error> {
        lock.withLock { result! }
    }
}
