import CoreFoundation
import CryptoKit
import Foundation

/// Bounded implementation of Security/requirements.grammar's single expression
/// syntax. This is a semantic evaluator, never a source of signing authority.
/// OS trust-settings, Apple roots/trust-cache, notarization and named fragments
/// require unavailable system context and remain explicitly unresolved.
enum SelfRenewalNestedCodeRequirementsVerifier {
    typealias Value = SelfRenewalDERPropertyList.Value
    typealias CMS = SelfRenewalCMSVerifier
    enum Failure: Error, Sendable, Equatable {
        case syntax, limit, malformedCertificate, malformedAttributes, changedCodeDirectory, unboundAttributes
    }
    enum Capability: Sendable, Equatable {
        case appleAnchor, appleGenericAnchor, trustSettings
        case namedAnchor(String), namedCode(String), notarization, legacyDeveloperID
        case externalCertificateFile(String)
    }
    enum Evaluation: Sendable, Equatable {
        case matched, notMatched, unresolved([Capability])
    }
    /// Attribute values alone grant no trust. The resource adapter constructs
    /// these from the same checked FD and genuine content/CMS proof, then checks
    /// every slice before publishing a nested resource verification.
    struct Attributes: Sendable, Equatable {
        let identifier: String
        let platform: UInt8
        let cdHash: Data
        let info: Value?
        let entitlements: Value?
        let certificateChainDER: [Data]
    }
    struct LoadedSlice: Sendable, Equatable {
        let offset: UInt64
        let attributes: Attributes
        let selectedDirectorySignerAuthenticated: Bool
        let adHoc: Bool
        fileprivate init(offset: UInt64, attributes: Attributes, selectedDirectorySignerAuthenticated: Bool, adHoc: Bool) {
            self.offset = offset
            self.attributes = attributes
            self.selectedDirectorySignerAuthenticated = selectedDirectorySignerAuthenticated
            self.adHoc = adHoc
        }
    }
    struct LoadedCode: Sendable, Equatable {
        let slices: [LoadedSlice]
        let bytesRead: Int
        fileprivate init(slices: [LoadedSlice], bytesRead: Int) { self.slices = slices; self.bytesRead = bytesRead }
    }
    enum Limits {
        static let textBytes = 16_384
        static let tokens = 4_096
        static let depth = 64
        static let certificateBytes = 65_536
        static let attributeReadBytes = 67_108_864
    }

    /// No enumeration: all paths/facts come from the caller's single inventory.
    /// Info and DER entitlements must match the actual selected CD special slot;
    /// the complete selected raw CD must match both earlier hash/CMS proofs.
    static func load(root: URL, code: SelfRenewalMachOSignatureReader.CodeMaterial,
        component: SelfRenewalMaterialInventory.Component?, files: [SelfRenewalMaterialInventory.FileFact],
        maximumReadBytes: Int) throws -> LoadedCode? {
        precondition(!Thread.isMainThread, "Nested attributes must stay off main")
        try Task.checkCancellation()
        guard let hashProof = code.contentHashVerification, hashProof.contentDigestsVerified,
              let signedProof = code.signedCodeVerification else { return nil }
        guard (0...Limits.attributeReadBytes).contains(maximumReadBytes) else { throw Failure.limit }
        let started = SourcePerfTrace.now
        var readBytes = 0
        defer {
            SourcePerfTrace.record("renewal.resource.nested-attributes",
                "bytes=\(readBytes) fileBytes=\(code.file.byteCount) main=\(Thread.isMainThread)",
                since: started, thresholdMs: 0)
        }
        var infoData: Data?
        var info: Value?
        if let component {
            let path = component.relativePath == "." ? "Info.plist" : component.relativePath + "/Info.plist"
            guard let fact = files.first(where: { $0.relativePath == path }), fact.byteCount <= Int64(maximumReadBytes) else { throw Failure.unboundAttributes }
            let bytes = try SelfRenewalMachOSignatureReader.readOwnedMaterial(root: root, fact: fact,
                maximumBytes: min(SelfRenewalMachOSignatureReader.Limits.ownedMaterialBytes, max(1, maximumReadBytes)))
            infoData = bytes
            info = try SelfRenewalDERPropertyList.decodeXMLPropertyList(bytes)
            guard let info, case .dictionary = info else { throw Failure.malformedAttributes }
            readBytes += bytes.count
        }
        let slices = try SelfRenewalMachOSignatureReader.withOwnedFile(root: root, fact: code.file,
            maximumReadBytes: maximumReadBytes - readBytes) { read -> [LoadedSlice] in
            func bytes(_ range: SelfRenewalMachOSignatureReader.ByteRange) throws -> Data {
                guard range.byteCount >= 0, range.byteCount <= maximumReadBytes - readBytes else { throw Failure.limit }
                var data = Data()
                while data.count < range.byteCount {
                    let count = min(SelfRenewalMachOSignatureReader.Limits.ownedFileChunkBytes, range.byteCount - data.count)
                    data.append(try read(.init(offset: range.offset + UInt64(data.count), byteCount: count)))
                    readBytes += count
                }
                return data
            }
            var result: [LoadedSlice] = []
            for slice in code.structure.slices {
                try Task.checkCancellation()
                guard let signature = slice.signature,
                      let signedSlice = signedProof.slices.first(where: { $0.sliceOffset == slice.range.offset }),
                      let directory = signature.codeDirectories.first(where: { $0.slot == signedSlice.selectedDirectorySlot }),
                      let binding = signedSlice.directories.first(where: { $0.slot == directory.slot }),
                      let checked = hashProof.directories.first(where: { $0.sliceOffset == slice.range.offset && $0.directorySlot == directory.slot }) else { throw Failure.unboundAttributes }
                let raw = try bytes(.init(offset: signature.range.offset + directory.blobRange.offset,
                    byteCount: directory.blobRange.byteCount))
                let actualSHA = Data(SHA256.hash(data: raw))
                guard actualSHA == checked.codeDirectorySHA256, actualSHA == binding.rawCodeDirectorySHA256 else { throw Failure.changedCodeDirectory }
                func check(_ value: Data, slot: UInt32) throws {
                    guard checked.verifiedSpecialSlots.contains(slot), slot <= directory.specialSlotCount else { throw Failure.unboundAttributes }
                    let offset = directory.hashOffset - Int(slot) * directory.hashByteCount
                    guard offset >= 0, offset <= raw.count - directory.hashByteCount,
                          try SelfRenewalCodeDirectoryHashVerifier.digest(value, hashType: directory.hashType) == raw.subdata(in: offset..<(offset + directory.hashByteCount)) else { throw Failure.unboundAttributes }
                }
                if let infoData { try check(infoData, slot: 1) }
                var entitlements: Value?
                // Pinned StaticCode::entitlements uses CoreEntitlements DER slot7;
                // XML slot5 is not substituted for that requirement context.
                if let blob = signature.blobs.first(where: { $0.slot == 7 }) {
                    let raw = try bytes(.init(offset: signature.range.offset + blob.range.offset, byteCount: blob.range.byteCount))
                    try check(raw, slot: 7)
                    guard raw.count >= 8 else { throw Failure.malformedAttributes }
                    entitlements = try SelfRenewalDERPropertyList.decode(Data(raw.dropFirst(8)))
                    guard let entitlements, case .dictionary = entitlements else { throw Failure.malformedAttributes }
                }
                guard raw.count > 38 else { throw Failure.changedCodeDirectory }
                let attributes = Attributes(identifier: directory.identifier, platform: raw[38], cdHash: binding.cdHash,
                    info: info, entitlements: entitlements,
                    certificateChainDER: signedSlice.signers.first?.verifiedCertificateChainDER ?? [])
                result.append(LoadedSlice(offset: slice.range.offset, attributes: attributes,
                    selectedDirectorySignerAuthenticated: binding.signerAuthenticated, adHoc: signedSlice.isAdHoc))
            }
            guard !result.isEmpty, result.count == signedProof.slices.count else { throw Failure.unboundAttributes }
            return result
        }
        return LoadedCode(slices: slices, bytesRead: readBytes)
    }
    private indirect enum Expr {
        case constant(Bool), and(Expr, Expr), or(Expr, Expr), not(Expr)
        case identifier(String), cdHash(Data), platform(Int32)
        case info(String, Match), entitlement(String, Match)
        case certificateHash(Int32, CertificateHash), certificateField(Int32, String, Match)
        case capability(Capability)
    }
    private enum CertificateHash { case bytes(Data), file(String) }
    private enum Match {
        case exists, absent, equal(String), contains(String), begins(String), ends(String)
        case less(String), greater(String), lessEqual(String), greaterEqual(String)
        case on(Date), before(Date), after(Date), onOrBefore(Date), onOrAfter(Date)
    }
    private enum Token: Equatable { case word(String), string(String), integer(String), hash(Data), hex(Data), symbol(String), end }

    static func evaluate(_ text: String, attributes: Attributes) throws -> Evaluation {
        precondition(!Thread.isMainThread, "Requirement evaluation must stay off main")
        try Task.checkCancellation()
        let started = SourcePerfTrace.now
        defer {
            SourcePerfTrace.record("renewal.resource.requirement",
                "bytes=\(text.utf8.count) certificates=\(attributes.certificateChainDER.count) main=\(Thread.isMainThread)",
                since: started, thresholdMs: 0)
        }
        var parser = try Parser(text)
        let expression = try parser.parse()
        guard attributes.certificateChainDER.count <= CMS.Limits.certificates else { throw Failure.limit }
        let certificates = try attributes.certificateChainDER.map { try Certificate($0) }
        return try evaluate(expression, attributes: attributes, certificates: certificates, depth: 0)
    }
    private static func evaluate(_ expression: Expr, attributes: Attributes, certificates: [Certificate], depth: Int) throws -> Evaluation {
        try Task.checkCancellation()
        guard depth < Limits.depth else { throw Failure.limit }
        func recurse(_ child: Expr) throws -> Evaluation {
            try evaluate(child, attributes: attributes, certificates: certificates, depth: depth + 1)
        }
        func result(_ match: Bool) -> Evaluation { match ? .matched : .notMatched }
        func certificate(_ slot: Int32) -> Certificate? {
            let index = slot < 0 ? certificates.count + Int(slot) : Int(slot)
            return certificates.indices.contains(index) ? certificates[index] : nil
        }
        switch expression {
        case .constant(let value): return result(value)
        case .and(let left, let right): return combine(try recurse(left), try recurse(right), conjunction: true)
        case .or(let left, let right): return combine(try recurse(left), try recurse(right), conjunction: false)
        case .not(let child):
            switch try recurse(child) {
            case .matched: return .notMatched
            case .notMatched: return .matched
            case .unresolved(let capabilities): return .unresolved(capabilities)
            }
        case .identifier(let value): return result(Data(attributes.identifier.utf8) == Data(value.utf8))
        case .cdHash(let value): return result(attributes.cdHash == value)
        case .platform(let value): return result(Int32(attributes.platform) == value)
        case .info(let key, let match): return result(try matches(value(attributes.info, key: key), match, depth: 0))
        case .entitlement(let key, let match): return result(try matches(value(attributes.entitlements, key: key), match, depth: 0))
        case .certificateHash(let slot, let expected):
            switch expected {
            case .bytes(let hash): return result(certificate(slot).map { Data(Insecure.SHA1.hash(data: $0.der)) == hash } ?? false)
            case .file(let path): return .unresolved([.externalCertificateFile(path)])
            }
        case .certificateField(let slot, let key, let match):
            // Original certFieldValue returns false if the slot does not exist,
            // even when the requested suffix was 'absent'.
            guard let cert = certificate(slot) else { return .notMatched }
            let value = try cert.value(for: key)
            if key.hasPrefix("subject."), value == nil { return .notMatched }
            return result(try matches(value, match, depth: 0))
        case .capability(let capability): return .unresolved([capability])
        }
    }
    private static func combine(_ left: Evaluation, _ right: Evaluation, conjunction: Bool) -> Evaluation {
        // The original interpreter evaluates both operands, including external
        // fragments. Never hide unavailable policy context with short-circuiting.
        var unknown: [Capability] = []
        for value in [left, right] { if case .unresolved(let values) = value { unknown += values } }
        if !unknown.isEmpty { return .unresolved(unknown) }
        let lhs = left == .matched
        let rhs = right == .matched
        return (conjunction ? lhs && rhs : lhs || rhs) ? .matched : .notMatched
    }
    private static func value(_ dictionary: Value?, key: String) -> Value? {
        guard let dictionary, case .dictionary(let values) = dictionary else { return nil }
        return values[key]
    }
    private static func matches(_ candidate: Value?, _ match: Match, depth: Int) throws -> Bool {
        guard depth < Limits.depth else { throw Failure.limit }
        try Task.checkCancellation()
        guard let candidate else { if case .absent = match { return true }; return false }
        if case .null = candidate { if case .absent = match { return true }; return false }
        if case .array(let values) = candidate {
            for value in values { if try matches(value, match, depth: depth + 1) { return true } }
        }
        switch match {
        case .absent: return false
        case .exists: return candidate != .boolean(false)
        case .equal(let expected):
            guard case .string(let actual) = candidate else { return false }
            return (actual as NSString).isEqual(to: expected)
        case .contains(let expected):
            guard case .string(let actual) = candidate else { return false }
            return actual.range(of: expected, options: .literal) != nil
        case .begins(let expected):
            guard case .string(let actual) = candidate else { return false }
            return actual.hasPrefix(expected)
        case .ends(let expected):
            guard case .string(let actual) = candidate else { return false }
            return actual.hasSuffix(expected)
        case .less(let expected), .greater(let expected), .lessEqual(let expected), .greaterEqual(let expected):
            guard case .string(let actual) = candidate else { return false }
            let comparison = (actual as NSString).compare(expected, options: .numeric)
            switch match {
            case .less: return comparison == .orderedAscending
            case .greater: return comparison == .orderedDescending
            case .lessEqual: return comparison != .orderedDescending
            case .greaterEqual: return comparison != .orderedAscending
            default: return false
            }
        case .on(let expected), .before(let expected), .after(let expected), .onOrBefore(let expected), .onOrAfter(let expected):
            guard case .date(let actual) = candidate else { return false }
            switch match {
            case .on: return actual == expected
            case .before: return actual < expected
            case .after: return actual > expected
            case .onOrBefore: return actual <= expected
            case .onOrAfter: return actual >= expected
            default: return false
            }
        }
    }

    private struct Parser {
        let tokens: [Token]
        var cursor = 0
        init(_ text: String) throws { tokens = try lex(text) }
        mutating func parse() throws -> Expr {
            let result = try expression(depth: 0)
            while take(.symbol(";")) {}
            guard peek == .end else { throw Failure.syntax }
            return result
        }
        private var peek: Token { tokens[cursor] }
        private mutating func take(_ token: Token) -> Bool {
            if peek == token { cursor += 1; return true }; return false
        }
        private mutating func require(_ token: Token) throws {
            guard take(token) else { throw Failure.syntax }
        }
        private mutating func string() throws -> String {
            switch peek {
            case .string(let value): cursor += 1; return value
            case .word(let value):
                guard !Self.keywords.contains(value), value.range(of: "^[A-Za-z][A-Za-z0-9]*(?:\\.(?:[A-Za-z][A-Za-z0-9]*|[0-9]+))*$", options: .regularExpression) != nil else { throw Failure.syntax }
                cursor += 1; return value
            default: throw Failure.syntax
            }
        }
        private mutating func pathString() throws -> String {
            if case .word(let path) = peek, path.hasPrefix("/") {
                guard path.range(of: "^/[A-Za-z][A-Za-z0-9]*(?:/[A-Za-z][A-Za-z0-9]*)+$", options: .regularExpression) != nil else { throw Failure.syntax }
                cursor += 1; return path
            }
            return try string()
        }
        private static let keywords: Set<String> = ["guest", "host", "designated", "library", "plugin", "or", "and", "always", "true", "never", "false", "identifier", "cdhash", "platform", "notarized", "legacy", "anchor", "apple", "generic", "certificate", "cert", "trusted", "info", "entitlement", "exists", "absent", "leaf", "root", "timestamp"]
        private mutating func integer() throws -> Int32 {
            guard case .integer(let value) = peek, let parsed = Int32(value) else { throw Failure.syntax }
            cursor += 1; return parsed
        }
        private mutating func equality() throws {
            // requirements.grammar's eql production also accepts empty.
            _ = take(.symbol("=")) || take(.symbol("=="))
        }
        private mutating func bracket() throws -> String {
            try require(.symbol("[")); let key = try string(); try require(.symbol("]")); return key
        }
        private mutating func expression(depth: Int) throws -> Expr {
            var result = try term(depth: depth)
            while take(.word("or")) { result = .or(result, try term(depth: depth)) }
            return result
        }
        private mutating func term(depth: Int) throws -> Expr {
            var result = try primary(depth: depth)
            while take(.word("and")) { result = .and(result, try primary(depth: depth)) }
            return result
        }
        private mutating func primary(depth: Int) throws -> Expr {
            try Task.checkCancellation()
            guard depth < Limits.depth else { throw Failure.limit }
            if take(.symbol("!")) { return .not(try primary(depth: depth + 1)) }
            if take(.symbol("(")) {
                if cursor + 1 < tokens.count, tokens[cursor + 1] == .symbol(")") {
                    switch peek {
                    case .string(let name): cursor += 2; return .capability(.namedCode(name))
                    case .word(let name) where !Self.keywords.contains(name):
                        cursor += 2; return .capability(.namedCode(name))
                    default: break
                    }
                }
                let result = try expression(depth: depth + 1); try require(.symbol(")")); return result
            }
            if take(.word("true")) || take(.word("always")) { return .constant(true) }
            if take(.word("false")) || take(.word("never")) { return .constant(false) }
            if take(.word("identifier")) { try equality(); return .identifier(try string()) }
            if take(.word("cdhash")) {
                try equality(); guard case .hash(let hash) = peek, hash.count == 20 else { throw Failure.syntax }
                cursor += 1; return .cdHash(hash)
            }
            if take(.word("platform")) { try equality(); return .platform(try integer()) }
            if take(.word("info")) { let key = try bracket(); return .info(key, try suffix()) }
            if take(.word("entitlement")) { let key = try bracket(); return .entitlement(key, try suffix()) }
            if take(.word("notarized")) { return .capability(.notarization) }
            if take(.word("legacy")) { return .capability(.legacyDeveloperID) }
            if take(.word("anchor")) {
                if take(.word("apple")) {
                    if take(.word("generic")) { return .capability(.appleGenericAnchor) }
                    if case .string(let name) = peek { cursor += 1; return .capability(.namedAnchor(name)) }
                    if case .word(let name) = peek, !["and", "or"].contains(name) {
                        return .capability(.namedAnchor(try string()))
                    }
                    return .capability(.appleAnchor)
                }
                if take(.word("generic")) { try require(.word("apple")); return .capability(.appleGenericAnchor) }
                if take(.word("trusted")) { return .capability(.trustSettings) }
                return try certificate(slot: -1)
            }
            if take(.word("certificate")) || take(.word("cert")) {
                if take(.word("trusted")) { return .capability(.trustSettings) }
                let slot: Int32
                if take(.word("leaf")) { slot = 0 }
                else if take(.word("root")) { slot = -1 }
                else if take(.symbol("-")) { slot = -(try integer()) }
                else { slot = try integer() }
                if take(.word("trusted")) { return .capability(.trustSettings) }
                return try certificate(slot: slot)
            }
            throw Failure.syntax
        }
        private mutating func certificate(slot: Int32) throws -> Expr {
            if peek == .symbol("[") {
                let key = try bracket()
                guard ["subject.", "field.", "extension.", "policy.", "timestamp."].contains(where: key.hasPrefix) else { throw Failure.syntax }
                if !key.hasPrefix("subject."), let separator = key.firstIndex(of: ".") {
                    _ = try Certificate.oid(String(key[key.index(after: separator)...]))
                }
                return .certificateField(slot, key, try suffix())
            }
            try equality()
            if case .hash(let bytes) = peek {
                guard bytes.count == 20 else { throw Failure.syntax }; cursor += 1
                return .certificateHash(slot, .bytes(bytes))
            }
            return .certificateHash(slot, .file(try pathString()))
        }
        private mutating func suffix() throws -> Match {
            if take(.word("exists")) { return .exists }
            if take(.word("absent")) { return .absent }
            let operation: String
            switch peek {
            case .symbol(let value) where ["=", "==", "~", "<", ">", "<=", ">="].contains(value): operation = value; cursor += 1
            default: return .exists
            }
            if take(.word("timestamp")) {
                guard case .string(let value) = peek else { throw Failure.syntax }
                let date = try date(value)
                cursor += 1
                switch operation {
                case "=", "==": return .on(date)
                case "<": return .before(date)
                case ">": return .after(date)
                case "<=": return .onOrBefore(date)
                case ">=": return .onOrAfter(date)
                default: throw Failure.syntax
                }
            }
            let leadingStar = take(.symbol("*"))
            let value: String
            if case .hex(let bytes) = peek {
                guard let decoded = String(data: bytes, encoding: .utf8) else { throw Failure.syntax }
                value = decoded; cursor += 1
            } else { value = try string() }
            let trailingStar = take(.symbol("*"))
            if leadingStar || trailingStar {
                guard operation == "=" || operation == "==" else { throw Failure.syntax }
                if leadingStar && trailingStar { return .contains(value) }
                return leadingStar ? .ends(value) : .begins(value)
            }
            switch operation {
            case "=", "==": return .equal(value)
            case "~": return .contains(value)
            case "<": return .less(value)
            case ">": return .greater(value)
            case "<=": return .lessEqual(value)
            case ">=": return .greaterEqual(value)
            default: throw Failure.syntax
            }
        }
        private func date(_ value: String) throws -> Date {
            let body = Data(value.utf8)
            var der = Data([0x18])
            if body.count < 128 { der.append(UInt8(body.count)) }
            else if body.count < 256 { der.append(contentsOf: [0x81, UInt8(body.count)]) }
            else { der.append(contentsOf: [0x82, UInt8(body.count >> 8), UInt8(body.count & 255)]) }
            der.append(body)
            do {
                guard case .date(let date) = try SelfRenewalDERPropertyList.decode(der) else { throw Failure.syntax }
                return date
            } catch is CancellationError { throw CancellationError() }
            catch { throw Failure.syntax }
        }
    }

    private static func lex(_ text: String) throws -> [Token] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= Limits.textBytes, !bytes.contains(0) else { throw Failure.limit }
        var tokens: [Token] = []
        var cursor = 0
        func asciiLetter(_ value: UInt8) -> Bool { (65...90).contains(value) || (97...122).contains(value) }
        func digit(_ value: UInt8) -> Bool { (48...57).contains(value) }
        func hex(_ value: UInt8) -> Bool { digit(value) || (65...70).contains(value) || (97...102).contains(value) }
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func hexData(_ range: Range<Int>) throws -> Data {
            guard range.count % 2 == 0 else { throw Failure.syntax }
            var data = Data()
            for offset in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                guard let value = UInt8(string(offset..<(offset + 2)), radix: 16) else { throw Failure.syntax }
                data.append(value)
            }
            return data
        }
        while cursor < bytes.count {
            try Task.checkCancellation()
            guard tokens.count < Limits.tokens else { throw Failure.limit }
            let current = bytes[cursor]
            if [9, 10, 32].contains(current) { cursor += 1; continue }
            if current == 35 || (current == 47 && cursor + 1 < bytes.count && bytes[cursor + 1] == 47) {
                while cursor < bytes.count && bytes[cursor] != 10 { cursor += 1 }; continue
            }
            if current == 47 && cursor + 1 < bytes.count && bytes[cursor + 1] == 42 {
                cursor += 2
                while cursor + 1 < bytes.count && !(bytes[cursor] == 42 && bytes[cursor + 1] == 47) { cursor += 1 }
                guard cursor + 1 < bytes.count else { throw Failure.syntax }; cursor += 2; continue
            }
            if current == 72 && cursor + 1 < bytes.count && bytes[cursor + 1] == 34 {
                cursor += 2; let start = cursor
                while cursor < bytes.count && hex(bytes[cursor]) { cursor += 1 }
                guard cursor > start, cursor < bytes.count, bytes[cursor] == 34 else { throw Failure.syntax }
                tokens.append(.hash(try hexData(start..<cursor))); cursor += 1; continue
            }
            if current == 48 && cursor + 1 < bytes.count && bytes[cursor + 1] == 120 {
                cursor += 2; let start = cursor
                while cursor < bytes.count && hex(bytes[cursor]) { cursor += 1 }
                guard cursor > start else { throw Failure.syntax }
                tokens.append(.hex(try hexData(start..<cursor))); continue
            }
            if current == 34 {
                cursor += 1; var value: [UInt8] = []
                while cursor < bytes.count && bytes[cursor] != 34 {
                    if bytes[cursor] == 92 {
                        cursor += 1; guard cursor < bytes.count, bytes[cursor] == 34 else { throw Failure.syntax }
                    }
                    value.append(bytes[cursor]); cursor += 1
                }
                guard cursor < bytes.count, let decoded = String(bytes: value, encoding: .utf8) else { throw Failure.syntax }
                tokens.append(.string(decoded)); cursor += 1; continue
            }
            if asciiLetter(current) || digit(current) || current == 47 {
                let start = cursor
                if digit(current) {
                    while cursor < bytes.count && digit(bytes[cursor]) { cursor += 1 }
                    tokens.append(.integer(string(start..<cursor))); continue
                }
                while cursor < bytes.count && (asciiLetter(bytes[cursor]) || digit(bytes[cursor]) || bytes[cursor] == 46 || bytes[cursor] == 47) { cursor += 1 }
                tokens.append(.word(string(start..<cursor))); continue
            }
            let start = cursor; cursor += 1
            if cursor < bytes.count, [60, 62, 61].contains(current), bytes[cursor] == 61 { cursor += 1 }
            let symbol = string(start..<cursor)
            guard [";", "(", ")", "[", "]", "<", ">", "<=", ">=", "=", "==", "~", "-", "!", "*"].contains(symbol) else { throw Failure.syntax }
            tokens.append(.symbol(symbol))
        }
        tokens.append(.end)
        return tokens
    }

    private struct Certificate {
        let der: Data
        let subject: [String: Value]
        let extensions: [Data: Data]
        let policies: [Data]
        init(_ data: Data) throws {
            guard !data.isEmpty, data.count <= Limits.certificateBytes else { throw Failure.limit }
            der = data
            let root = try CMS.parseDER(data)
            let fields = try CMS.children(of: root)
            guard root.tag == 0x30, fields.count == 3 else { throw Failure.malformedCertificate }
            let tbs = try CMS.children(of: fields[0])
            let start = tbs.first?.tag == 0xa0 ? 1 : 0
            guard tbs.count >= start + 6 else { throw Failure.malformedCertificate }
            var names: [String: Value] = [:]
            for set in try CMS.children(of: tbs[start + 4]) {
                for name in try CMS.children(of: set) {
                    let pair = try CMS.children(of: name)
                    guard pair.count == 2, pair[0].tag == 6 else { throw Failure.malformedCertificate }
                    if let key = Self.subjectKeys[pair[0].body], names[key] == nil {
                        if let text = Self.string(pair[1]) { names[key] = .string(text) }
                    }
                }
            }
            subject = names
            var extensions: [Data: Data] = [:]
            if let node = tbs.dropFirst(start + 6).first(where: { $0.tag == 0xa3 }) {
                let outer = try CMS.children(of: node)
                guard outer.count == 1, outer[0].tag == 0x30 else { throw Failure.malformedCertificate }
                for ext in try CMS.children(of: outer[0]) {
                    let pair = try CMS.children(of: ext)
                    guard pair.count == 2 || pair.count == 3, pair[0].tag == 6,
                          let last = pair.last, last.tag == 4, extensions[pair[0].body] == nil else { throw Failure.malformedCertificate }
                    extensions[pair[0].body] = last.body
                }
            }
            self.extensions = extensions
            var policies: [Data] = []
            if let raw = extensions[Data([0x55,0x1d,0x20])] {
                let sequence = try CMS.parseDER(raw)
                for node in try CMS.children(of: sequence) {
                    let values = try CMS.children(of: node)
                    guard let first = values.first, first.tag == 6 else { throw Failure.malformedCertificate }
                    policies.append(first.body)
                }
            }
            self.policies = policies
        }
        func value(for key: String) throws -> Value? {
            if key.hasPrefix("subject.") { return subject[key] }
            let prefix: String
            if key.hasPrefix("field.") { prefix = "field." }
            else if key.hasPrefix("extension.") { prefix = "extension." }
            else if key.hasPrefix("policy.") { prefix = "policy." }
            else if key.hasPrefix("timestamp.") { prefix = "timestamp." }
            else { return nil }
            let oid = try Self.oid(String(key.dropFirst(prefix.count)))
            if prefix == "policy." { return policies.contains(oid) ? .boolean(true) : nil }
            guard let bytes = extensions[oid] else { return nil }
            if prefix == "timestamp." {
                // csutilities.cpp certificateCopyFieldDate decodes an extension
                // UTF8String whose contents are GeneralizedTime, not a DER date
                // tag. An absent/unrecognized date returns CFNull to the matcher.
                do {
                    let node = try CMS.parseDER(bytes)
                    guard node.tag == 0x0c else { return nil }
                    var dateDER = node.originalDER
                    dateDER[dateDER.startIndex] = 0x18
                    let value = try SelfRenewalDERPropertyList.decode(dateDER)
                    guard case .date(let date) = value, date.timeIntervalSinceReferenceDate != 0 else { return nil }
                    return value
                } catch is CancellationError { throw CancellationError() }
                catch { return nil }
            }
            return .boolean(true)
        }
        private static func string(_ node: CMS.SignedAttribute.Value) -> String? {
            switch node.tag {
            case 0x0c: return String(data: node.body, encoding: .utf8)
            case 0x12, 0x13, 0x16, 0x1a: return String(data: node.body, encoding: .ascii)
            case 0x14: return String(data: node.body, encoding: .isoLatin1)
            case 0x1e: return String(data: node.body, encoding: .utf16BigEndian)
            case 0x1c: return String(data: node.body, encoding: .utf32BigEndian)
            default: return nil
            }
        }
        private static let subjectKeys: [Data: String] = [
            Data([0x55,0x04,0x06]): "subject.C", Data([0x55,0x04,0x03]): "subject.CN",
            Data([0x55,0x04,0x0d]): "subject.D", Data([0x55,0x04,0x07]): "subject.L",
            Data([0x55,0x04,0x0a]): "subject.O", Data([0x55,0x04,0x0b]): "subject.OU",
            Data([0x55,0x04,0x08]): "subject.ST", Data([0x55,0x04,0x09]): "subject.STREET",
            Data([0x55,0x04,0x0a,0x01]): "subject.C-O", Data([0x55,0x04,0x0b,0x01]): "subject.C-OU",
            Data([0x55,0x04,0x08,0x01]): "subject.C-ST", Data([0x55,0x04,0x09,0x01]): "subject.C-STREET",
            Data([0x09,0x92,0x26,0x89,0x93,0xf2,0x2c,0x64,0x01,0x01]): "subject.UID",
        ]
        static func oid(_ text: String) throws -> Data {
            let arcs = text.split(separator: ".", omittingEmptySubsequences: false)
            guard arcs.count >= 2, arcs.count <= 32 else { throw Failure.syntax }
            let numbers = try arcs.map { part -> UInt64 in
                guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = UInt64(part) else { throw Failure.syntax }
                return number
            }
            guard numbers[0] <= 2, numbers[0] == 2 || numbers[1] < 40, numbers[1] <= UInt64.max - 80 else { throw Failure.syntax }
            var bytes = Data()
            for number in [numbers[0] * 40 + numbers[1]] + numbers.dropFirst(2) {
                var value = number
                var encoded = [UInt8(value & 127)]; value >>= 7
                while value > 0 { encoded.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
                bytes.append(contentsOf: encoded)
            }
            return bytes
        }
    }
}
