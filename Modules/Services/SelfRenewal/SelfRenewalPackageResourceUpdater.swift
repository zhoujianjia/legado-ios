import CryptoKit
import Foundation

/// Changes only already verified resource seal payloads. It never invents an
/// include rule, changes a designated requirement or treats a cdhash as proof.
enum SelfRenewalPackageResourceUpdater {
    typealias Resources = SelfRenewalResourceSealVerifier
    enum Failure: Error, Sendable, Equatable {
        case malformedEnvelope, unsupportedSeal, missingSeal(String)
        case unresolvedRequirement, missingNestedSignature(String), changedRules, unsupportedEncoding
    }
    struct Result: Sendable {
        let bytes: Data
        let changedProfileSeals: Int
        let changedNestedHints: Int
        fileprivate init(bytes: Data, profiles: Int, nested: Int) {
            self.bytes = bytes; changedProfileSeals = profiles; changedNestedHints = nested
        }
    }

    static func update(_ original: Data, component: Resources.ComponentVerification,
        freshProfiles: [String: Data], nestedCDHashes: [String: Data]) throws -> Result {
        precondition(!Thread.isMainThread, "Package resource updates must stay off main")
        try Task.checkCancellation()
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.package.resources", "bytes=\(original.count) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        guard original.count <= Resources.Limits.envelopeBytes,
              Data(SHA256.hash(data: original)) == component.envelopeSHA256 else { throw Failure.malformedEnvelope }
        guard component.resources.resourceEnvelopeVerified,
              component.resources.unresolvedNestedResources.isEmpty,
              component.resources.unresolvedRequirementCapabilities.isEmpty else { throw Failure.unresolvedRequirement }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let parsed = try PropertyListSerialization.propertyList(from: original, options: [], format: &format) as? NSDictionary else {
            throw Failure.malformedEnvelope
        }
        var root: [String: Any] = [:]
        for (key, value) in parsed {
            guard let name = key as? String else { throw Failure.malformedEnvelope }; root[name] = value
        }
        guard format == .xml else { throw Failure.unsupportedEncoding }
        let originalRuleRanges = try ruleElementRanges(original)
        let preservedRules = [parsed["rules"], parsed["rules2"]]
        var profileChanges = 0
        var nestedChanges = 0
        for table in ["files", "files2"] {
            guard let value = root[table] else { continue }
            guard var seals = value as? [String: Any] else { throw Failure.malformedEnvelope }
            for (path, bytes) in freshProfiles {
                try Task.checkCancellation()
                // Original policy may intentionally omit a profile. Its new
                // CMS still authenticates it; do not silently change that rule.
                guard let raw = seals[path] else {
                    if table == (component.resources.version == 2 ? "files2" : "files"),
                       component.resources.verifiedFileDigests[path] != nil { throw Failure.missingSeal(path) }
                    continue
                }
                if raw is Data {
                    seals[path] = try SelfRenewalCodeDirectoryHashVerifier.digest(bytes, hashType: 1)
                } else if var attributes = raw as? [String: Any] {
                    guard attributes["requirement"] == nil, attributes["symlink"] == nil,
                          Set(attributes.keys).isSubset(of: ["hash", "hash2", "hash3", "hash4", "optional"]) else { throw Failure.unsupportedSeal }
                    var changed = false
                    for (name, type) in [("hash", UInt8(1)), ("hash2", 2), ("hash3", 3), ("hash4", 4)] where attributes[name] != nil {
                        guard attributes[name] is Data else { throw Failure.unsupportedSeal }
                        attributes[name] = try SelfRenewalCodeDirectoryHashVerifier.digest(bytes, hashType: type)
                        changed = true
                    }
                    guard changed else { throw Failure.unsupportedSeal }
                    seals[path] = attributes
                } else { throw Failure.unsupportedSeal }
                profileChanges += 1
            }
            for nested in component.resources.verifiedNestedResources {
                try Task.checkCancellation()
                guard let raw = seals[nested.relativePath] else {
                    if table == (component.resources.version == 2 ? "files2" : "files") { throw Failure.missingSeal(nested.relativePath) }
                    continue
                }
                guard var attributes = raw as? [String: Any],
                      attributes["requirement"] as? String == nested.requirement,
                      Set(attributes.keys).isSubset(of: ["requirement", "cdhash", "optional"]),
                      let hash = nestedCDHashes[nested.relativePath], hash.count == 20 else {
                    throw Failure.missingNestedSignature(nested.relativePath)
                }
                attributes["cdhash"] = hash
                seals[nested.relativePath] = attributes
                nestedChanges += 1
            }
            root[table] = seals
        }
        var encoded = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        let newRanges = try ruleElementRanges(encoded)
        guard Set(originalRuleRanges.keys) == Set(newRanges.keys) else { throw Failure.changedRules }
        for (key, range) in newRanges.sorted(by: { $0.value.lowerBound > $1.value.lowerBound }) {
            guard let originalRange = originalRuleRanges[key] else { throw Failure.changedRules }
            encoded.replaceSubrange(range, with: original.subdata(in: originalRange))
        }
        guard encoded.count <= Resources.Limits.envelopeBytes,
              let reparsed = try PropertyListSerialization.propertyList(from: encoded, options: [], format: nil) as? NSDictionary else { throw Failure.malformedEnvelope }
        for (index, key) in ["rules", "rules2"].enumerated() {
            switch (preservedRules[index], reparsed[key]) {
            case (nil, nil): break
            case (let old?, let new?):
                guard let left = old as? NSDictionary, let right = new as? NSDictionary, left.isEqual(right),
                      try orderedKeys(left) == orderedKeys(right) else { throw Failure.changedRules }
            default: throw Failure.changedRules
            }
        }
        return Result(bytes: encoded, profiles: profileChanges, nested: nestedChanges)
    }
    private static func orderedKeys(_ dictionary: NSDictionary) throws -> [String] {
        var keys: [String] = []
        for (key, _) in dictionary {
            guard let value = key as? String else { throw Failure.changedRules }; keys.append(value)
        }
        return keys
    }
    /// Preserve exact raw rule element bytes, including original insertion/tie
    /// order. This is a bounded XML element scanner after Foundation has already
    /// validated the plist. It does not resolve entities or reinterpret rules.
    /// Binary/UTF16/DTD internal subsets/CDATA/comments are explicit unsupported.
    private static func ruleElementRanges(_ bytes: Data) throws -> [String: Range<Int>] {
        guard String(data: bytes, encoding: .utf8) != nil else { throw Failure.unsupportedEncoding }
        let raw = [UInt8](bytes)
        var cursor = 0; var stack: [String] = []; var ranges: [String: Range<Int>] = [:]
        var keyStart: Int?; var pending: String?; var capture: (key: String, offset: Int, depth: Int)?
        func prefix(_ string: String, _ at: Int) -> Bool {
            let needle = Array(string.utf8)
            return at <= raw.count - needle.count && Array(raw[at..<(at + needle.count)]) == needle
        }
        func trim(_ range: Range<Int>) -> String {
            String(decoding: raw[range], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while cursor < raw.count {
            try Task.checkCancellation()
            guard raw[cursor] == 60 else { cursor += 1; continue }
            let start = cursor
            if prefix("<!--", cursor) || prefix("<![", cursor) { throw Failure.unsupportedEncoding }
            if prefix("<?", cursor) {
                guard stack.isEmpty else { throw Failure.unsupportedEncoding }
                cursor += 2
                while cursor + 1 < raw.count && !prefix("?>", cursor) { cursor += 1 }
                guard cursor + 1 < raw.count else { throw Failure.malformedEnvelope }; cursor += 2; continue
            }
            if prefix("<!DOCTYPE", cursor) {
                guard stack.isEmpty else { throw Failure.unsupportedEncoding }
                var quote: UInt8?; cursor += 9
                while cursor < raw.count {
                    let byte = raw[cursor]
                    if let delimiter = quote { if byte == delimiter { quote = nil } }
                    else if byte == 34 || byte == 39 { quote = byte }
                    else if byte == 91 { throw Failure.unsupportedEncoding }
                    else if byte == 62 { break }
                    cursor += 1
                }
                guard cursor < raw.count else { throw Failure.malformedEnvelope }; cursor += 1; continue
            }
            cursor += 1; var quote: UInt8?
            while cursor < raw.count {
                let byte = raw[cursor]
                if let delimiter = quote { if byte == delimiter { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                cursor += 1
            }
            guard cursor < raw.count else { throw Failure.malformedEnvelope }
            var token = trim((start + 1)..<cursor)
            let closing = token.hasPrefix("/"); let empty = token.hasSuffix("/")
            if closing { token.removeFirst() }; if empty { token.removeLast() }
            let name = String(token.prefix { !$0.isWhitespace })
            guard ["plist", "dict", "key", "data", "string", "integer", "real", "date", "array", "true", "false"].contains(name) else { throw Failure.unsupportedEncoding }
            if closing {
                guard !empty, stack.last == name else { throw Failure.malformedEnvelope }
                if name == "key", stack == ["plist", "dict", "key"], let keyStart {
                    let key = String(decoding: raw[keyStart..<start], as: UTF8.self)
                    pending = ["rules", "rules2"].contains(key) ? key : nil
                }
                if let value = capture, value.depth == stack.count {
                    guard ranges[value.key] == nil else { throw Failure.changedRules }
                    ranges[value.key] = value.offset..<(cursor + 1); capture = nil
                }
                stack.removeLast()
            } else {
                if stack == ["plist", "dict"] {
                    if name == "key" { keyStart = cursor + 1 }
                    else {
                        if let key = pending {
                            guard name == "dict", capture == nil else { throw Failure.changedRules }
                            capture = (key, start, stack.count + 1)
                        }
                        pending = nil
                    }
                }
                if empty {
                    if let value = capture, value.depth == stack.count + 1 {
                        guard ranges[value.key] == nil else { throw Failure.changedRules }
                        ranges[value.key] = value.offset..<(cursor + 1); capture = nil
                    }
                } else { stack.append(name) }
            }
            cursor += 1
        }
        guard stack.isEmpty, capture == nil, ranges["rules"] != nil else { throw Failure.changedRules }
        return ranges
    }

}
