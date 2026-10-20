import CoreFoundation
import Darwin
import Foundation

struct CookieOwnerError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// The only writer for CookieStore's existing file. This actor deliberately has
/// no original-runtime CAS API: URLSession and WebKit still have independent
/// native mutations, and WebKit does not supply host-only provenance.
actor CookiePersistenceOwner {
    enum Provenance: String, Codable, Sendable {
        case scriptHeader, webKit, httpResponse, systemStorage
    }

    /// Keep Foundation's property types, including dates and URLs, rather than
    /// flattening different paths or cookie attributes into a Cookie header.
    enum Property: Codable, Sendable, Equatable {
        case text(String), number(Double), boolean(Bool), date(Date), url(URL)

        init(_ value: Any) throws {
            switch value {
            case let date as Date: self = .date(date)
            case let url as URL: self = .url(url)
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .boolean(number.boolValue) }
                else {
                    guard number.doubleValue.isFinite else {
                        throw CookieOwnerError(code: "STATE_IO", message: "Cookie property is not finite")
                    }
                    self = .number(number.doubleValue)
                }
            case let text as String: self = .text(text)
            default: throw CookieOwnerError(code: "UNSUPPORTED_CAPABILITY", message: "Unrepresentable native Cookie property")
            }
        }

        var native: Any {
            switch self {
            case .text(let value): return value
            case .number(let value): return NSNumber(value: value)
            case .boolean(let value): return NSNumber(value: value)
            case .date(let value): return value
            case .url(let value): return value
            }
        }

        static func == (lhs: Property, rhs: Property) -> Bool {
            switch (lhs, rhs) {
            case (.text(let a), .text(let b)): return a.utf8.elementsEqual(b.utf8)
            case (.number(let a), .number(let b)): return a == b
            case (.boolean(let a), .boolean(let b)): return a == b
            case (.date(let a), .date(let b)): return a == b
            case (.url(let a), .url(let b)): return a.absoluteString.utf8.elementsEqual(b.absoluteString.utf8)
            default: return false
            }
        }
    }

    struct Record: Codable, Sendable, Equatable {
        let properties: [String: Property]
        let provenance: Provenance
        let originURL: URL?
        /// Unknown remains unknown. A leading dot is not a host-only proof.
        let hostOnly: Bool?
        let expiresAt: Date?
        let originalExpiresAtMs: Int64?
        let originalDomain: String?
        let originalSetCookieHeader: String?

        init(cookie: HTTPCookie, provenance: Provenance, originURL: URL?, hostOnly: Bool?,
             originalExpiresAtMs: Int64? = nil, originalDomain: String? = nil, originalSetCookieHeader: String? = nil) throws {
            guard let original = cookie.properties else {
                throw CookieOwnerError(code: "STATE_IO", message: "Cookie has no restorable native properties")
            }
            self.properties = try Dictionary(uniqueKeysWithValues: original.map {
                ($0.key.rawValue, try Property($0.value))
            })
            self.provenance = provenance
            self.originURL = originURL
            self.hostOnly = hostOnly
            self.expiresAt = cookie.expiresDate
            self.originalExpiresAtMs = originalExpiresAtMs
            self.originalDomain = originalDomain
            self.originalSetCookieHeader = originalSetCookieHeader
            let restored = try native()
            guard restored.domain == cookie.domain, restored.path == cookie.path,
                  restored.name == cookie.name, restored.value == cookie.value,
                  restored.isSecure == cookie.isSecure, restored.isHTTPOnly == cookie.isHTTPOnly,
                  restored.expiresDate == cookie.expiresDate, restored.version == cookie.version,
                  restored.isSessionOnly == cookie.isSessionOnly else {
                throw CookieOwnerError(code: "UNSUPPORTED_CAPABILITY", message: "Native Cookie attributes cannot be restored exactly")
            }
        }

        func native() throws -> HTTPCookie {
            var original = Dictionary(uniqueKeysWithValues: properties.map {
                (HTTPCookiePropertyKey($0.key), $0.value.native)
            })
            // Max-Age must not start again at every replay. Preserve the original
            // property as provenance but restore its captured absolute deadline.
            original.removeValue(forKey: .maximumAge)
            if let expiresAt { original[.expires] = expiresAt }
            guard let cookie = HTTPCookie(properties: original) else {
                throw CookieOwnerError(code: "STATE_IO", message: "Persisted Cookie properties are invalid")
            }
            return cookie
        }

        static func == (lhs: Record, rhs: Record) -> Bool {
            func same(_ a: String?, _ b: String?) -> Bool {
                switch (a, b) {
                case (.none, .none): return true
                case (.some(let a), .some(let b)): return a.utf8.elementsEqual(b.utf8)
                default: return false
                }
            }
            return lhs.properties == rhs.properties && lhs.provenance == rhs.provenance && lhs.hostOnly == rhs.hostOnly
                && lhs.expiresAt == rhs.expiresAt && lhs.originalExpiresAtMs == rhs.originalExpiresAtMs
                && same(lhs.originURL?.absoluteString, rhs.originURL?.absoluteString)
                && same(lhs.originalDomain, rhs.originalDomain) && same(lhs.originalSetCookieHeader, rhs.originalSetCookieHeader)
        }
    }

    /// Swift Dictionary String keys equate composed/decomposed Unicode; JVM/Room
    /// raw domain keys do not. Non-ASCII original keys use rows in this same file,
    /// without duplicating the ASCII domain data in legacyHeaders.
    struct OriginalRawDomain: Codable, Sendable, Equatable {
        let domain: String
        let raw: String
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.domain.utf8.elementsEqual(rhs.domain.utf8) && lhs.raw.utf8.elementsEqual(rhs.raw.utf8)
        }
    }

    struct Document: Codable, Sendable, Equatable {
        var version = 2
        /// Original v1 strings are explicitly legacy data, never rich metadata.
        var legacyHeaders: [String: String] = [:]
        var cookies: [Record] = []
        /// Last observed WK values in this same file. They are provenance, not
        /// a second jar: an unchanged browser snapshot cannot overwrite a newer
        /// HTTP/script value or resurrect a cookie removed by this owner.
        var webKitObserved: [Record]?
        var originalRawDomains: [OriginalRawDomain]? = nil

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.version == rhs.version, lhs.cookies == rhs.cookies, lhs.webKitObserved == rhs.webKitObserved,
                  lhs.originalRawDomains == rhs.originalRawDomains, lhs.legacyHeaders.count == rhs.legacyHeaders.count else { return false }
            for (key, value) in lhs.legacyHeaders {
                guard let index = rhs.legacyHeaders.index(forKey: key) else { return false }
                let other = rhs.legacyHeaders[index]
                guard key.utf8.elementsEqual(other.key.utf8), value.utf8.elementsEqual(other.value.utf8) else { return false }
            }
            return true
        }
    }

    struct WebKitObservation: Sendable {
        fileprivate let ownerID: UUID
        fileprivate let revision: UInt64
    }

    private let ownerID = UUID()
    private var revision: UInt64 = 0
    private let fileURL: URL
    private let storage: HTTPCookieStorage
    private let beforeWrite: (@Sendable () throws -> Void)?
    private var document: Document?
    private var originalMemoryText: [Data: OriginalRawDomain] = [:]

    init(fileURL: URL, storage: HTTPCookieStorage, beforeWrite: (@Sendable () throws -> Void)? = nil) {
        self.fileURL = fileURL
        self.storage = storage
        self.beforeWrite = beforeWrite
    }

    func prepare() throws { _ = try loaded() }

    func snapshot() throws -> Document { try loaded() }

    func requestHeader(url: URL) throws -> String? {
        let visible = try nativeCookies(url: url)
        return visible.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: visible)["Cookie"]
    }

    func nativeCookies(url: URL) throws -> [HTTPCookie] {
        let current = try loaded()
        // A cold or purged native jar must still see the accepted existing file.
        // Live foreign native values are not overwritten or asserted as CAS proof.
        let live = Set((storage.cookies ?? []).map(Self.identity))
        let native = try current.cookies.map { try $0.native() }
        let rich = Set(native.map(Self.identity))
        let roots = Self.rootIndex(native)
        let legacy = current.legacyHeaders.flatMap { domain, raw -> [HTTPCookie] in
            guard let target = URL(string: "https://" + domain) else { return [] }
            let raw = Self.legacyHeader(raw, roots: roots[Self.stripped(domain)] ?? [])
            return CookieStore.makeCookies(raw, for: target).filter { !rich.contains(Self.identity($0)) }
        }
        for cookie in native + legacy where !live.contains(Self.identity(cookie)) {
            if cookie.expiresDate.map({ $0 > Date() }) ?? true { storage.setCookie(cookie) }
        }
        return storage.cookies(for: url) ?? []
    }

    func get(url: String) throws -> String {
        let current = try loaded()
        if let target = URL(string: url), let rawHost = target.host {
            let host = rawHost.lowercased()
            var collected: [String: String] = [:]
            for cookie in storage.cookies(for: target) ?? [] { collected[cookie.name] = cookie.value }
            // Retain the existing JS get/getKey contract. This broader legacy
            // lookup is never used as an RFC jar/CAS snapshot for the JVM.
            for cookie in storage.cookies ?? [] where collected[cookie.name] == nil {
                if Self.related(cookie.domain, host) { collected[cookie.name] = cookie.value }
            }
            if !collected.isEmpty { return collected.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") }
        }
        let domain = Self.domain(url)
        let roots = try current.cookies.map { try $0.native() }.filter {
            $0.path == "/" && Self.stripped($0.domain) == Self.stripped(domain)
        }
        return Self.legacyHeader(Self.originalRawText(current, domain: domain), roots: roots)
    }

    /// The original App-process CacheManager projection uses its exact keys in
    /// this existing actor. It is never reconstructed from native rich records
    /// or cleared merely because one JVM RuntimeSession closes.
    private static func originalMemoryKey(_ domain: String, session: Bool) -> Data {
        Data((domain + (session ? "_session_cookie" : "_cookie")).utf8)
    }
    private static func originalNoSession(_ document: Document, domain: String,
                                          memory: [Data: OriginalRawDomain]) -> String {
        memory[originalMemoryKey(domain, session: false)]?.raw ?? originalRawText(document, domain: domain)
    }

    func originalText(domain: String) throws -> String {
        let current = try loaded()
        let raw = Self.originalNoSession(current, domain: domain, memory: originalMemoryText)
        let session = originalMemoryText[Self.originalMemoryKey(domain, session: true)]?.raw ?? ""
        guard raw.utf8.count + session.utf8.count <= 65_536 else {
            throw CookieOwnerError(code: "STATE_LIMIT", message: "Original Cookie text exceeds its read budget")
        }
        return Self.mergeOriginalText(raw, session)
    }

    func originalSession(domain: String) throws -> String {
        _ = try loaded()
        return originalMemoryText[Self.originalMemoryKey(domain, session: true)]?.raw ?? ""
    }

    /// The raw file projection is intentionally separate from CacheManager's
    /// in-memory view, for the existing finite read-only host and diagnostics.
    func originalRawText(domain: String) throws -> String { Self.originalRawText(try loaded(), domain: domain) }

    func mutateOriginalText(domain: String, action: String, raw: String?,
                            validate: @Sendable () throws -> Void = {}) throws {
        try Task.checkCancellation(); try validate()
        var next = try loaded()
        guard domain.utf8.count <= 8_192, (raw?.utf8.count ?? 0) <= 65_536 else {
            throw CookieOwnerError(code: "STATE_LIMIT", message: "Original Cookie mutation exceeds its byte budget")
        }
        guard ["set", "replace", "remove", "removeKey"].contains(action), action == "remove" || raw != nil else {
            throw CookieOwnerError(code: "INVALID_STATE_REQUEST", message: "Unknown original Cookie text mutation")
        }
        if action == "replace", (domain.isEmpty || raw!.isEmpty) { return }
        var memory = originalMemoryText
        let cookieKey = Self.originalMemoryKey(domain, session: false)
        let sessionKey = Self.originalMemoryKey(domain, session: true)
        if action == "remove" {
            Self.setOriginalRaw(nil, domain: domain, in: &next)
            memory.removeValue(forKey: cookieKey); memory.removeValue(forKey: sessionKey)
        } else if action == "removeKey" {
            // Locked CookieManager.removeCookie(url,key): an empty map does not
            // replace old cache/DB. This differs from removeCookie(url).
            if let session = memory[sessionKey]?.raw {
                let remaining = Self.originalMap(session).filter { !$0.0.utf8.elementsEqual(raw!.utf8) }
                if !remaining.isEmpty { memory[sessionKey] = OriginalRawDomain(domain: domain, raw: Self.originalString(remaining)) }
            }
            let cookie = Self.originalNoSession(next, domain: domain, memory: memory)
            guard cookie.utf8.count <= 65_536 else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Original Cookie text exceeds its removal budget") }
            if !cookie.isEmpty {
                let remaining = Self.originalMap(cookie).filter { !$0.0.utf8.elementsEqual(raw!.utf8) }
                if !remaining.isEmpty {
                    let value = Self.originalString(remaining)
                    Self.setOriginalRaw(value, domain: domain, in: &next)
                    memory[cookieKey] = OriginalRawDomain(domain: domain, raw: value)
                }
            }
        } else {
            let old = Self.originalNoSession(next, domain: domain, memory: memory)
            guard old.utf8.count <= 65_536 else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Original Cookie text exceeds its merge budget") }
            let value = action == "replace" && !old.isEmpty ? Self.mergeOriginalText(old, raw!) : raw!
            Self.setOriginalRaw(value, domain: domain, in: &next)
            memory[cookieKey] = OriginalRawDomain(domain: domain, raw: value)
        }
        try Self.checkOriginalMemoryBudget(memory)
        let removed = action == "remove" ? (storage.cookies ?? []).filter { Self.related($0.domain, domain) } : []
        if action == "remove" { next.cookies = try next.cookies.filter { !Self.related(try $0.native().domain, domain) } }
        try accept(next, validate: validate) {
            self.originalMemoryText = memory
            removed.forEach(self.storage.deleteCookie)
        }
    }

    /// Locked CookieStore.clear -> CookieDao.deleteOkHttp SQL contains one
    /// literal ASCII pipe. Neither original CacheManager, native jar nor WK is
    /// cleared. Cached values remain visible across new RuntimeSessions until
    /// this existing App Cookie owner/process lifetime ends or removes them.
    func clearOriginalOkHttp(validate: @Sendable () throws -> Void = {}) throws {
        try Task.checkCancellation(); try validate()
        var next = try loaded()
        for key in Array(next.legacyHeaders.keys) where key.utf8.contains(124) { next.legacyHeaders.removeValue(forKey: key) }
        let rows = next.originalRawDomains?.filter { !$0.domain.utf8.contains(124) }
        next.originalRawDomains = rows?.isEmpty == true ? nil : rows
        try accept(next, validate: validate) {}
    }

    /// Original OkHttp parsed these records from this exact response. The
    /// existing actor commits rich/raw file data before publishing both original
    /// CacheManager key spaces and native values; no second RFC jar is created.
    func ingestOriginalResponse(_ records: [Record], domain: String, persistentText: String, sessionText: String,
                                validate: @Sendable () throws -> Void = {}) throws {
        guard !records.isEmpty else { return }
        guard domain.utf8.count <= 8_192, persistentText.utf8.count <= 65_536, sessionText.utf8.count <= 65_536 else {
            throw CookieOwnerError(code: "STATE_LIMIT", message: "Original response Cookie text exceeds its byte budget")
        }
        var next = try loaded()
        let native = try records.map { try $0.native() }
        guard records.allSatisfy({ $0.provenance == .httpResponse && $0.originURL != nil && $0.hostOnly != nil }) else {
            throw CookieOwnerError(code: "INVALID_STATE_REQUEST", message: "Original HTTP Cookie provenance is incomplete")
        }
        try merge(records, into: &next)
        var memory = originalMemoryText
        let cookieKey = Self.originalMemoryKey(domain, session: false), sessionKey = Self.originalMemoryKey(domain, session: true)
        let old = Self.originalNoSession(next, domain: domain, memory: memory)
        guard old.utf8.count <= 65_536 else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Original Cookie text exceeds its merge budget") }
        if !domain.isEmpty, !persistentText.isEmpty {
            let value = old.isEmpty ? persistentText : Self.mergeOriginalText(old, persistentText)
            Self.setOriginalRaw(value, domain: domain, in: &next)
            memory[cookieKey] = OriginalRawDomain(domain: domain, raw: value)
        }
        let previous = memory[sessionKey]?.raw ?? ""
        memory[sessionKey] = OriginalRawDomain(domain: domain, raw: previous.isEmpty ? sessionText : Self.mergeOriginalText(previous, sessionText))
        try Self.checkOriginalMemoryBudget(memory)
        try accept(next, validate: validate) {
            self.originalMemoryText = memory
            native.forEach(self.storage.setCookie)
        }
    }

    private static func checkOriginalMemoryBudget(_ memory: [Data: OriginalRawDomain]) throws {
        guard memory.count <= 256, memory.reduce(0, { $0 + $1.key.count + $1.value.raw.utf8.count }) <= 1_048_576 else {
            throw CookieOwnerError(code: "STATE_LIMIT", message: "Original Cookie memory exceeds its owner budget")
        }
    }

    private static func originalRawText(_ document: Document, domain: String) -> String {
        if let row = document.originalRawDomains?.first(where: { $0.domain.utf8.elementsEqual(domain.utf8) }) { return row.raw }
        guard let index = document.legacyHeaders.index(forKey: domain) else { return "" }
        let entry = document.legacyHeaders[index]
        return entry.key.utf8.elementsEqual(domain.utf8) ? entry.value : ""
    }

    private static func setOriginalRaw(_ raw: String?, domain: String, in document: inout Document) {
        if domain.utf8.allSatisfy({ $0 < 128 }) {
            if let index = document.legacyHeaders.index(forKey: domain),
               !document.legacyHeaders[index].key.utf8.elementsEqual(domain.utf8) {
                // A v1 Unicode key can canonically equal an ASCII key (Kelvin
                // sign/K). Preserve its exact original identity before insertion.
                guard raw != nil else { return }
                let previous = document.legacyHeaders.remove(at: index)
                var rows = document.originalRawDomains ?? []
                rows.append(OriginalRawDomain(domain: previous.key, raw: previous.value))
                document.originalRawDomains = rows
            }
            if let raw { document.legacyHeaders[domain] = raw }
            else { document.legacyHeaders.removeValue(forKey: domain) }
            return
        }
        if let index = document.legacyHeaders.index(forKey: domain), document.legacyHeaders[index].key.utf8.elementsEqual(domain.utf8) {
            document.legacyHeaders.remove(at: index)
        }
        var rows = document.originalRawDomains ?? []
        rows.removeAll { $0.domain.utf8.elementsEqual(domain.utf8) }
        if let raw { rows.append(OriginalRawDomain(domain: domain, raw: raw)) }
        document.originalRawDomains = rows.isEmpty ? nil : rows
    }

    private static func validateOriginalRawDomains(_ document: Document, code: String) throws {
        let rows = document.originalRawDomains ?? []
        guard rows.count + document.legacyHeaders.count <= 16_384 else {
            throw CookieOwnerError(code: code, message: "Too many original Cookie domains")
        }
        var identities = Set(document.legacyHeaders.keys.map { Data($0.utf8) })
        for row in rows {
            guard !row.domain.utf8.allSatisfy({ $0 < 128 }), row.domain.utf8.count <= 8_192, row.raw.utf8.count <= 65_536,
                  identities.insert(Data(row.domain.utf8)).inserted else {
                throw CookieOwnerError(code: code, message: "Original Cookie domain rows are duplicate or oversized")
            }
        }
    }

    private static func mergeOriginalText(_ values: String...) -> String {
        var ordered: [(String, String)] = []
        var positions: [Data: Int] = [:]
        for value in values {
            for pair in originalMap(value) {
                let identity = Data(pair.0.utf8)
                if let position = positions[identity] { ordered[position].1 = pair.1 }
                else { positions[identity] = ordered.count; ordered.append(pair) }
            }
        }
        return originalString(ordered)
    }

    private static func originalMap(_ value: String) -> [(String, String)] {
        var ordered: [(String, String)] = []
        var positions: [Data: Int] = [:]
        // Split the ASCII code units, as the original JVM regex does. Swift
        // Character splitting would miss '=' or ';' followed by a combining mark.
        for field in value.utf8.split(separator: 59, omittingEmptySubsequences: false) {
            guard let equals = field.firstIndex(of: 61) else { continue }
            let rawKey = String(decoding: field[..<equals], as: UTF8.self)
            let rawValue = String(decoding: field[field.index(after: equals)...], as: UTF8.self)
            guard !rawValue.unicodeScalars.allSatisfy({ scalar in
                // Character.isWhitespace || isSpaceChar from pinned JDK21,
                // which is Kotlin Char.isWhitespace; NEL(U+0085) is not blank.
                switch scalar.value {
                case 9...13, 28...32, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
                default: return false
                }
            }) else { continue }
            let key = asciiTrim(rawKey[...]), text = asciiTrim(rawValue[...])
            // JVM String keys use code-unit equality, not Swift's canonical
            // Unicode equality. Keep composed/decomposed Cookie names distinct.
            let identity = Data(key.utf8)
            if let position = positions[identity] { ordered[position].1 = text }
            else { positions[identity] = ordered.count; ordered.append((key, text)) }
        }
        return ordered
    }

    private static func originalString(_ values: [(String, String)]) -> String {
        values.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func asciiTrim(_ value: Substring) -> String {
        let scalars = value.unicodeScalars
        var start = scalars.startIndex, end = scalars.endIndex
        while start < end, scalars[start].value <= 32 { scalars.formIndex(after: &start) }
        while start < end {
            let previous = scalars.index(before: end)
            guard scalars[previous].value <= 32 else { break }
            end = previous
        }
        return String(scalars[start..<end])
    }

    func set(url: String, raw: String) throws {
        guard !raw.isEmpty, let target = URL(string: url), target.host != nil else { return }
        var next = try loaded()
        let native = CookieStore.makeCookies(raw, for: target)
        let records = try native.map { try Record(cookie: $0, provenance: .scriptHeader, originURL: target, hostOnly: true) }
        next.legacyHeaders[Self.domain(url)] = CookieStore.merge(existing: next.legacyHeaders[Self.domain(url)], incoming: raw)
        try merge(records, into: &next)
        try accept(next) { native.forEach(self.storage.setCookie) }
    }

    /// Native arrays stay native. WK snapshots intentionally retain unknown
    /// hostOnly/origin rather than manufacturing them from a page's URL.
    func ingest(_ cookies: [HTTPCookie], provenance: Provenance, originURL: URL? = nil,
                validate: @Sendable () throws -> Void = {}) throws {
        guard provenance != .webKit else {
            throw CookieOwnerError(code: "INVALID_STATE_REQUEST", message: "Browser Cookies require an observed snapshot proof")
        }
        guard !cookies.isEmpty else { return }
        let records = try cookies.map { try Record(cookie: $0, provenance: provenance, originURL: originURL, hostOnly: nil) }
        var next = try loaded()
        try merge(records, into: &next)
        try accept(next, validate: validate) { cookies.forEach(self.storage.setCookie) }
    }

    func beginWebKitObservation() throws -> WebKitObservation {
        _ = try loaded()
        return WebKitObservation(ownerID: ownerID, revision: revision)
    }

    func validateWebKitObservation(_ observation: WebKitObservation,
                                  validate: @Sendable () throws -> Void = {}) throws {
        try Task.checkCancellation(); try validate()
        guard observation.ownerID == ownerID, observation.revision == revision else {
            throw CookieOwnerError(code: "STATE_CONFLICT", message: "The Cookie-store operation observation became stale")
        }
    }

    /// Called only with a freshly fetched full WK snapshot. A late IPC result
    /// cannot replace an accepted mutation. The prior observed WK values let an
    /// unchanged browser jar coexist with newer HTTP cookies without replaying it.
    func ingestWebKitSnapshot(_ cookies: [HTTPCookie], observation: WebKitObservation,
                             confirming scope: URL? = nil, requireCurrent: Bool,
                             preservingOriginalRaw: Bool = false, authoritativeCookies: [HTTPCookie] = [],
                             validate: @Sendable () throws -> Void = {}) throws {
        try Task.checkCancellation()
        try validate()
        guard observation.ownerID == ownerID, observation.revision == revision else {
            throw CookieOwnerError(code: "STATE_CONFLICT", message: "The browser Cookie snapshot became stale")
        }
        var next = try loaded()
        guard cookies.count <= 16_384 else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Too many browser Cookies") }
        let observed = try cookies.map { try Record(cookie: $0, provenance: .webKit, originURL: nil, hostOnly: nil) }
        let before = try Self.index(next.webKitObserved ?? [])
        let current = try Self.index(next.cookies)
        let incoming = try Self.index(observed)
        let authoritative = Set(authoritativeCookies.map(Self.identity))
        var changed: [Record] = []
        for record in observed {
            let native = try record.native()
            let key = Self.identity(native)
            if !authoritative.contains(key), let previous = before[key], try Self.sameCookie(previous, record) { continue }
            // An initial WK observation has no ordering proof relative to an
            // existing durable value. Preserve that value and establish only a
            // baseline. A user confirmation below reports any relevant conflict.
            if next.webKitObserved == nil, current[key] != nil, !authoritative.contains(key) { continue }
            changed.append(record)
        }
        var removed = try (next.webKitObserved ?? []).filter { previous in
            let key = Self.identity(try previous.native())
            guard incoming[key] == nil, let live = current[key] else { return false }
            return try Self.sameCookie(live, previous)
        }
        // A controlled operation can delete a Cookie before the first WK
        // baseline exists. Its exact observed identities still authorize that
        // removal; never infer deletion of unrelated native/WK identities.
        let alreadyRemoved = Set(try removed.map { Self.identity(try $0.native()) })
        for (key, record) in current where authoritative.contains(key) && incoming[key] == nil && !alreadyRemoved.contains(key) {
            removed.append(record)
        }
        // A removed root cookie may also have come from the old raw file.
        // Remove only that same legacy domain/name; retaining an older text value
        // would reseed the deleted native cookie on the next request or restart.
        for record in removed where !preservingOriginalRaw {
            let native = try record.native()
            guard native.path == "/" else { continue }
            for domain in Array(next.legacyHeaders.keys) where Self.stripped(domain) == Self.stripped(native.domain) {
                guard let raw = next.legacyHeaders[domain] else { continue }
                let remaining = CookieStore.removingCookie(named: native.name, from: raw)
                if remaining.isEmpty { next.legacyHeaders.removeValue(forKey: domain) }
                else { next.legacyHeaders[domain] = remaining }
            }
        }
        let removedIDs = Set(try removed.map { Self.identity(try $0.native()) })
        next.cookies = try next.cookies.filter { !removedIDs.contains(Self.identity(try $0.native())) }
        try merge(changed, into: &next)
        if requireCurrent {
            let accepted = try Self.index(next.cookies)
            let host = scope?.host?.lowercased()
            for record in observed {
                let native = try record.native()
                if let host, !Self.related(native.domain, host) { continue }
                guard let live = accepted[Self.identity(native)], try Self.sameCookie(live, record) else {
                    throw CookieOwnerError(code: "STATE_CONFLICT", message: "The browser still has an older Cookie value")
                }
            }
        }
        next.webKitObserved = observed
        let nativeChanged = try changed.map { try $0.native() }
        let nativeRemoved = try removed.map { try $0.native() }
        try accept(next, validate: validate) {
            nativeRemoved.forEach(self.storage.deleteCookie)
            nativeChanged.forEach(self.storage.setCookie)
        }
    }

    func remove(url: String, key: String? = nil, includingRelatedDomains: Bool = false) throws {
        var next = try loaded()
        let normalized = CookieStore.normalizedURLString(url)
        guard let target = URL(string: normalized), let host = target.host?.lowercased() else { return }
        let matchesDomain: (String) -> Bool = { raw in
            includingRelatedDomains ? Self.related(raw, host) : Self.stripped(raw) == host
        }
        let removed: [HTTPCookie]
        if let key {
            guard !key.isEmpty else { return }
            removed = (storage.cookies ?? []).filter { $0.name == key && matchesDomain($0.domain) }
            for domain in Array(next.legacyHeaders.keys) where matchesDomain(domain) {
                let raw = CookieStore.removingCookie(named: key, from: next.legacyHeaders[domain] ?? "")
                if raw.isEmpty { next.legacyHeaders.removeValue(forKey: domain) } else { next.legacyHeaders[domain] = raw }
            }
        } else {
            removed = storage.cookies(for: target) ?? []
            next.legacyHeaders.removeValue(forKey: Self.domain(url))
        }
        let identities = Set(removed.map(Self.identity))
        next.cookies = try next.cookies.filter { !identities.contains(Self.identity(try $0.native())) }
        var sessions = originalMemoryText
        for (identity, row) in sessions where Self.related(row.domain, host) {
            if let key {
                let remaining = Self.originalMap(row.raw).filter { !$0.0.utf8.elementsEqual(key.utf8) }
                sessions[identity] = OriginalRawDomain(domain: row.domain, raw: Self.originalString(remaining))
            } else { sessions.removeValue(forKey: identity) }
        }
        try accept(next) { self.originalMemoryText = sessions; removed.forEach(self.storage.deleteCookie) }
    }

    func clearAll() throws {
        let current = try loaded()
        try accept(Document(webKitObserved: current.webKitObserved)) {
            self.originalMemoryText.removeAll()
            self.storage.removeCookies(since: .distantPast)
        }
    }

    private func loaded() throws -> Document {
        try Task.checkCancellation()
        if let document { return document }
        let next: Document = try SourcePerfTrace.span("cookie.owner.load", "main=\(Thread.isMainThread)") {
            guard let data = try Self.readFile(fileURL) else { return Document() }
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                if let legacy = object as? [String: String] {
                    let value = Document(legacyHeaders: legacy)
                    try Self.validateOriginalRawDomains(value, code: "STATE_IO")
                    return value
                }
                let value = try JSONDecoder().decode(Document.self, from: data)
                guard value.version == 2, value.cookies.count <= 16_384, (value.webKitObserved?.count ?? 0) <= 16_384 else {
                    throw CookieOwnerError(code: "STATE_IO", message: "Unsupported Cookie file format or size")
                }
                try Self.validateOriginalRawDomains(value, code: "STATE_IO")
                _ = try Self.index(value.cookies)
                if let observed = value.webKitObserved { _ = try Self.index(observed) }
                return value
            } catch let error as CookieOwnerError { throw error }
            catch { throw CookieOwnerError(code: "STATE_IO", message: "Cookie file is corrupt") }
        }
        // Validate all persisted records before publishing any replayed value.
        let native = try next.cookies.map { try $0.native() }
        let identities = Set(native.map(Self.identity))
        let roots = Self.rootIndex(native)
        let legacy = next.legacyHeaders.flatMap { domain, raw -> [HTTPCookie] in
            guard let url = URL(string: "https://" + domain) else { return [] }
            let raw = Self.legacyHeader(raw, roots: roots[Self.stripped(domain)] ?? [])
            return CookieStore.makeCookies(raw, for: url).filter { !identities.contains(Self.identity($0)) }
        }
        let liveIdentities = Set((storage.cookies ?? []).map(Self.identity))
        for cookie in native + legacy where !liveIdentities.contains(Self.identity(cookie)) {
            if cookie.expiresDate.map({ $0 > Date() }) ?? true { storage.setCookie(cookie) }
        }
        document = next
        return next
    }

    /// Read the existing owner file once. Cocoa's broad "no such file" error can
    /// include ENOTDIR, which must never become an empty authenticated state.
    /// Check the descriptor and size before allocating, and close it before any
    /// decoded state can be published or used by an HTTP request.
    private static func readFile(_ url: URL) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CookieOwnerError(code: "STATE_IO", message: "Cookie file could not be opened")
        }
        var isOpen = true
        defer { if isOpen { _ = Darwin.close(descriptor) } }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CookieOwnerError(code: "STATE_IO", message: "Cookie path is not a readable regular file")
        }
        guard before.st_size >= 0, before.st_size <= 16_777_216 else {
            throw CookieOwnerError(code: "STATE_LIMIT", message: "Cookie file exceeds its budget")
        }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CookieOwnerError(code: "STATE_IO", message: "Cookie file could not be read")
                }
                guard count > 0 else {
                    throw CookieOwnerError(code: "STATE_IO", message: "Cookie file changed during its read")
                }
                offset += count
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw CookieOwnerError(code: "STATE_IO", message: "Cookie file changed during its read")
        }
        let closeStatus = Darwin.close(descriptor)
        isOpen = false
        guard closeStatus == 0 else {
            throw CookieOwnerError(code: "STATE_IO", message: "Cookie file could not be closed")
        }
        try Task.checkCancellation()
        return data
    }

    /// A rich root identity is authoritative even after it expires. Old raw text
    /// has no independent expiry proof and cannot revive that same domain/name.
    /// A bare-domain JS lookup still receives the current live root value. Leave
    /// v1-only names and other domains/paths untouched.
    private static func rootIndex(_ cookies: [HTTPCookie]) -> [String: [HTTPCookie]] {
        Dictionary(grouping: cookies.filter { $0.path == "/" }, by: { stripped($0.domain) })
    }

    private static func legacyHeader(_ raw: String, roots: [HTTPCookie]) -> String {
        var remaining = raw
        let now = Date()
        for cookie in roots {
            remaining = CookieStore.removingCookie(named: cookie.name, from: remaining)
            if cookie.expiresDate.map({ $0 > now }) ?? true {
                remaining = CookieStore.merge(existing: remaining, incoming: "\(cookie.name)=\(cookie.value)")
            }
        }
        return remaining
    }

    private func merge(_ records: [Record], into next: inout Document) throws {
        var positions: [String: Int] = [:]
        for (index, record) in next.cookies.enumerated() { positions[Self.identity(try record.native())] = index }
        for record in records {
            let identity = Self.identity(try record.native())
            if let index = positions[identity] { next.cookies[index] = record }
            else { positions[identity] = next.cookies.count; next.cookies.append(record) }
        }
        guard next.cookies.count <= 16_384 else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Too many persisted Cookies") }
    }

    private func accept(_ next: Document, validate: @Sendable () throws -> Void = {}, publish: () -> Void) throws {
        try Task.checkCancellation()
        try validate()
        try Self.validateOriginalRawDomains(next, code: "STATE_LIMIT")
        guard document != next else { publish(); return }
        guard revision < UInt64.max else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Cookie owner revision space exhausted") }
        try SourcePerfTrace.span("cookie.owner.write", "cookies=\(next.cookies.count) main=\(Thread.isMainThread)") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            guard data.count <= 16_777_216 else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Cookie file exceeds its budget") }
            try beforeWrite?()
            try Task.checkCancellation()
            try validate()
            do { try data.write(to: fileURL, options: .atomic) }
            catch { throw CookieOwnerError(code: "STATE_IO", message: "Cookie file was not replaced") }
        }
        // No accepted in-memory/native mutation or successful ack precedes the
        // atomic replacement. External URLSession writes are not CAS-protected.
        document = next
        revision += 1
        publish()
    }

    private static func index(_ records: [Record]) throws -> [String: Record] {
        var values: [String: Record] = [:]
        for record in records {
            let key = identity(try record.native())
            guard values.updateValue(record, forKey: key) == nil else {
                throw CookieOwnerError(code: "STATE_IO", message: "Duplicate persisted Cookie identity")
            }
        }
        return values
    }

    private static func sameCookie(_ lhs: Record, _ rhs: Record) throws -> Bool {
        let a = try lhs.native(), b = try rhs.native()
        return a.name == b.name && a.value == b.value && a.domain == b.domain && a.path == b.path
            && a.isSecure == b.isSecure && a.isHTTPOnly == b.isHTTPOnly && a.expiresDate == b.expiresDate
            && a.version == b.version && a.isSessionOnly == b.isSessionOnly && a.portList == b.portList
            && a.comment == b.comment && a.commentURL == b.commentURL
    }

    private static func identity(_ cookie: HTTPCookie) -> String {
        // Cookie components cannot contain NUL; do not collapse two paths/names.
        cookie.domain.lowercased() + "\u{0}" + cookie.path + "\u{0}" + cookie.name
    }
    private static func stripped(_ domain: String) -> String {
        (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain).lowercased()
    }
    private static func related(_ domain: String, _ host: String) -> Bool {
        let domain = stripped(domain)
        return domain == host || domain.hasSuffix("." + host) || host.hasSuffix("." + domain)
    }
    private static func domain(_ raw: String) -> String { (URL(string: raw)?.host ?? raw).lowercased() }
}
