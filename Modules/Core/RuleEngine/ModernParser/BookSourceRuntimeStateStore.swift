import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted only after a user-facing source-variable editor saves a change.
    ///
    /// Rule JS also calls `source.setVariable(...)` while discover/content is
    /// running. Broadcasting those internal writes would cancel and restart the
    /// same discover evaluation indefinitely, so runtime bridges continue to use
    /// `setSourceVariableJSON` while editors use `setUserSourceVariableJSON`.
    static let bookSourceUserVariableDidChange = Notification.Name(
        "bookSourceUserVariableDidChange"
    )
}

/// Persistent runtime state owned by an imported Legado book source.
///
/// Source variables are intentionally kept outside `BookSource`: imported rule
/// JSON remains immutable, while settings changed by `source.setVariable(...)`
/// survive search/detail/toc/content sessions and app relaunches.
/// All mutable `UserDefaults` access is serialized by `queue`; the remaining
/// stored properties are immutable after initialization. This makes the shared
/// instance safe to call from the detached search-presentation worker.
final class BookSourceRuntimeStateStore: @unchecked Sendable {
    static let shared = BookSourceRuntimeStateStore()

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.yuedu.bookSourceRuntimeState")
    private var runtimeRevisions: [String: UInt64] = [:]

    private convenience init() {
        self.init(defaults: UserDefaults(suiteName: "com.yuedu.bookSourceRuntimeState") ?? .standard)
    }

    /// Isolated defaults are injectable for owned fixtures; production has one owner.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func sourceVariableJSON(for sourceUrl: String) -> String? {
        queue.sync {
            defaults.string(forKey: key(sourceUrl: sourceUrl, suffix: "sourceVariableJSON"))
        }
    }

    func setSourceVariableJSON(_ json: String?, for sourceUrl: String) {
        queue.sync {
            let storageKey = key(sourceUrl: sourceUrl, suffix: "sourceVariableJSON")
            let normalized = json.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            guard defaults.string(forKey: storageKey) != normalized else { return }
            guard let normalized else {
                defaults.removeObject(forKey: storageKey)
                runtimeRevisions[sourceUrl, default: 0] &+= 1
                return
            }
            defaults.set(normalized, forKey: storageKey)
            runtimeRevisions[sourceUrl, default: 0] &+= 1
        }
    }

    /// Persists a source variable entered by the user and tells live consumers
    /// to invalidate their source-scoped presentation state.
    func setUserSourceVariableJSON(_ json: String?, for sourceUrl: String) {
        let previous = sourceVariableJSON(for: sourceUrl)
        setSourceVariableJSON(json, for: sourceUrl)
        let current = sourceVariableJSON(for: sourceUrl)
        guard previous != current else { return }
        NotificationCenter.default.post(
            name: .bookSourceUserVariableDidChange,
            object: nil,
            userInfo: ["sourceURL": sourceUrl]
        )
    }

    /// Parsed `source.setVariable(...)` payload for this source.
    ///
    /// Empty when the source has no variables yet, or when the stored payload is
    /// not a JSON object — some sources persist a JSON *array* (their rules read
    /// it as `JSON.parse(source.getVariable())[0]`), and those carry no keyed
    /// settings for callers of this method to read.
    func sourceVariables(for sourceUrl: String) -> [String: Any] {
        guard let json = sourceVariableJSON(for: sourceUrl),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    func sourceValue(for sourceUrl: String, key entryKey: String) -> String? {
        queue.sync {
            let values = defaults.dictionary(
                forKey: key(sourceUrl: sourceUrl, suffix: "sourceKeyValues")
            ) as? [String: String]
            return values?[entryKey]
        }
    }

    func setSourceValue(_ value: String, for sourceUrl: String, key entryKey: String) {
        queue.sync {
            let storageKey = key(sourceUrl: sourceUrl, suffix: "sourceKeyValues")
            var values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
            guard values[entryKey] != value else { return }
            values[entryKey] = value
            defaults.set(values, forKey: storageKey)
            runtimeRevisions[sourceUrl, default: 0] &+= 1
        }
    }

    func runtimeVariableSnapshot(for sourceURL: String) -> LegadoOwnedStateSnapshot {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return queue.sync {
            let value = defaults.string(forKey: key(sourceUrl: sourceURL, suffix: "sourceVariableJSON"))
            return .init(revision: runtimeRevisions[sourceURL] ?? 0,
                         values: value.map { ["value": Data($0.utf8)] } ?? [:])
        }
    }

    func runtimeValuesSnapshot(for sourceURL: String, keys: Set<String>) -> LegadoOwnedStateSnapshot {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return queue.sync {
            let values = defaults.dictionary(forKey: key(sourceUrl: sourceURL, suffix: "sourceKeyValues")) as? [String: String] ?? [:]
            return .init(revision: runtimeRevisions[sourceURL] ?? 0,
                values: Dictionary(uniqueKeysWithValues: keys.compactMap { name in values[name].map { (name, Data($0.utf8)) } }))
        }
    }

    func compareRuntimeVariable(for sourceURL: String, expected: LegadoOwnedStateSnapshot, value: Data?) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return queue.sync {
            let storageKey = key(sourceUrl: sourceURL, suffix: "sourceVariableJSON")
            let current = defaults.string(forKey: storageKey)
            guard (runtimeRevisions[sourceURL] ?? 0) == expected.revision,
                  current.map({ Data($0.utf8) }) == expected.values["value"] else { return false }
            let text = value.flatMap { String(data: $0, encoding: .utf8) }
            guard value == nil || text != nil else { return false }
            // CacheManager stores source.setVariable verbatim, including an
            // empty string. The user editor's empty-to-remove policy is separate.
            guard current != text else { return true }
            if let text { defaults.set(text, forKey: storageKey) }
            else { defaults.removeObject(forKey: storageKey) }
            runtimeRevisions[sourceURL, default: 0] &+= 1
            return true
        }
    }

    func compareRuntimeValues(for sourceURL: String, expected: LegadoOwnedStateSnapshot,
                              changes: [String: Data?]) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return queue.sync {
            let storageKey = key(sourceUrl: sourceURL, suffix: "sourceKeyValues")
            let current = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
            guard (runtimeRevisions[sourceURL] ?? 0) == expected.revision,
                  expected.values.allSatisfy({ current[$0.key].map { Data($0.utf8) } == $0.value }) else { return false }
            var updated = current
            for (name, bytes) in changes {
                // A missing value was also part of the read proof.
                guard current[name].map({ Data($0.utf8) }) == expected.values[name] else { return false }
                if let bytes {
                    guard let text = String(data: bytes, encoding: .utf8) else { return false }
                    updated[name] = text
                } else { updated.removeValue(forKey: name) }
            }
            guard updated != current else { return true }
            defaults.set(updated, forKey: storageKey)
            runtimeRevisions[sourceURL, default: 0] &+= 1
            return true
        }
    }

    /// One-shot cleanup of device ids this app wrote wrongly.
    ///
    /// `java.androidId()` used to return `identifierForVendor` — a 36-char uppercase
    /// UUID — where Android hands out 16 lowercase hex characters. Sources cache it in
    /// their own key/value store (知秋番茄: `source.put('androidId', …)`) and read that
    /// back before ever calling us again, so fixing `androidId()` alone would never
    /// reach a device that had already run the source once. Drops only entries whose
    /// key names a device id AND whose value is exactly that old shape — a source's own
    /// settings are never touched.
    ///
    /// Delete this (and `LegadoJSBridge.isLegacyVendorUUIDAndroidId`) once no install
    /// can still be carrying a pre-fix value.
    func purgeLegacyAndroidIds() {
        let flag = "bookSourceRuntime.didPurgeLegacyAndroidIds"
        queue.sync {
            guard !defaults.bool(forKey: flag) else { return }
            defer { defaults.set(true, forKey: flag) }
            for (storageKey, value) in defaults.dictionaryRepresentation()
            where storageKey.hasPrefix("bookSourceRuntime.")
                && storageKey.hasSuffix(".sourceKeyValues") {
                guard var entries = value as? [String: String] else { continue }
                let stale = entries.filter { entry in
                    entry.key.lowercased().contains("androidid")
                        && LegadoJSBridge.isLegacyVendorUUIDAndroidId(entry.value)
                }
                guard !stale.isEmpty else { continue }
                stale.keys.forEach { entries.removeValue(forKey: $0) }
                defaults.set(entries, forKey: storageKey)
                AppLogger.parse("⟐ purged legacy androidId", context: [
                    "keys": stale.keys.sorted().joined(separator: ",")
                ])
            }
        }
    }

    private func key(sourceUrl: String, suffix: String) -> String {
        let data = Data(sourceUrl.utf8)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "bookSourceRuntime.\(digest).\(suffix)"
    }
}
