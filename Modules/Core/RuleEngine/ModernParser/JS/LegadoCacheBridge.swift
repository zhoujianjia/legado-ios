import Foundation
import JavaScriptCore

// MARK: - JSExport Protocol

/// JS-callable interface for Legado's `cache.*` object.
/// Mirrors Legado's `CacheManager`: persistent key-value store + memory cache.
@objc protocol LegadoCacheBridgeExport: JSExport {
    func get(_ key: String) -> String?
    func put(_ key: String, _ value: String)
    func delete(_ key: String)
    func getFromMemory(_ key: String) -> String?
    func putMemory(_ key: String, _ value: String)
    func deleteMemory(_ key: String)
}

/// Internal categories share this exact cache owner, lock, suite and revision.
/// Ordinary JS keys never select a category or collide with the shareJs records.
enum LegadoRuntimeCacheNamespace: Sendable {
    case userText, sharedJsLibrary
}

// MARK: - Bridge Implementation

@objc class LegadoCacheBridge: NSObject, LegadoCacheBridgeExport {

    private let memoryCache = LRUCache<String, String>(capacity: 128)
    private let persistentStore: UserDefaults
    private let keyPrefix: String
    private let sourceId: String
    private var memoryOnlyKeys = Set<String>()
    private static let storageLock = NSLock()
    private static var revisions: [String: UInt64] = [:]

    init(sourceId: String) {
        self.sourceId = sourceId
        self.keyPrefix = "cache_\(sourceId)"
        self.persistentStore = UserDefaults(suiteName: "com.yuedu.cache.\(sourceId)") ?? .standard
        super.init()
    }

    func get(_ key: String) -> String? {
        if memoryOnlyKeys.contains(key), let value = memoryCache.get(key) { return value }
        // Persistent writes can also arrive through the explicitly owned JVM
        // host. Only explicit putMemory values may shadow that shared owner.
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        do {
            guard let entry = try Self.entry(store: persistentStore, storageKey: "\(keyPrefix)_\(key)"),
                  entry.deadline == 0 || entry.deadline > Int64(Date().timeIntervalSince1970 * 1_000) else { return nil }
            return try entry.text()
        } catch {
            AppLogger.error("Source cache entry could not be read", error: error)
            return nil
        }
    }

    func put(_ key: String, _ value: String) {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        let storageKey = "\(keyPrefix)_\(key)"
        do {
            if try Self.entry(store: persistentStore, storageKey: storageKey) != LegadoRuntimeCacheEntry(text: value) {
                persistentStore.set(value, forKey: storageKey)
                Self.revisions[sourceId, default: 0] &+= 1
            }
            memoryCache.put(key, value: value)
            memoryOnlyKeys.remove(key)
        } catch {
            AppLogger.error("Source cache entry could not be changed", error: error)
        }
    }

    func delete(_ key: String) {
        memoryCache.remove(key)
        memoryOnlyKeys.remove(key)
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        let storageKey = "\(keyPrefix)_\(key)"
        guard persistentStore.object(forKey: storageKey) != nil else { return }
        persistentStore.removeObject(forKey: storageKey)
        Self.revisions[sourceId, default: 0] &+= 1
    }

    func getFromMemory(_ key: String) -> String? {
        return memoryCache.get(key)
    }

    func putMemory(_ key: String, _ value: String) {
        memoryCache.put(key, value: value)
        memoryOnlyKeys.insert(key)
    }

    func deleteMemory(_ key: String) {
        memoryCache.remove(key)
        memoryOnlyKeys.remove(key)
    }

    static func runtimeSnapshot(sourceId: String, key: String,
                                namespace: LegadoRuntimeCacheNamespace = .userText) throws -> LegadoOwnedStateSnapshot {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let store = UserDefaults(suiteName: "com.yuedu.cache.\(sourceId)") ?? .standard
        storageLock.lock()
        defer { storageLock.unlock() }
        let value = try entry(store: store, storageKey: runtimeStorageKey(sourceId: sourceId, key: key, namespace: namespace))
        return .init(revision: revisions[sourceId] ?? 0,
            values: try value.map { ["value": try $0.encoded()] } ?? [:])
    }

    static func compareRuntimeEntry(sourceId: String, key: String, expected: LegadoOwnedStateSnapshot,
                                   value: Data?, namespace: LegadoRuntimeCacheNamespace = .userText) throws -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let store = UserDefaults(suiteName: "com.yuedu.cache.\(sourceId)") ?? .standard
        storageLock.lock()
        defer { storageLock.unlock() }
        let storageKey = runtimeStorageKey(sourceId: sourceId, key: key, namespace: namespace)
        let current = try entry(store: store, storageKey: storageKey)
        let bytes = try current.map { try $0.encoded() }
        guard (revisions[sourceId] ?? 0) == expected.revision, bytes == expected.values["value"] else { return false }
        guard bytes != value else { return true }
        if let value {
            let decoded = try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: value)
            _ = try decoded.text()
            // The existing UserDefaults key remains the sole backing record.
            // Data preserves the original TTL alongside the text atomically;
            // legacy plain String records remain readable with deadline zero.
            store.set(value, forKey: storageKey)
        } else { store.removeObject(forKey: storageKey) }
        revisions[sourceId, default: 0] &+= 1
        return true
    }

    private static func runtimeStorageKey(sourceId: String, key: String,
                                          namespace: LegadoRuntimeCacheNamespace) -> String {
        switch namespace {
        case .userText: return "cache_\(sourceId)_\(key)"
        case .sharedJsLibrary: return "shareJs_\(sourceId)_\(key)"
        }
    }

    private static func entry(store: UserDefaults, storageKey: String) throws -> LegadoRuntimeCacheEntry? {
        guard let raw = store.object(forKey: storageKey) else { return nil }
        if let text = raw as? String { return .init(text: text) }
        guard let data = raw as? Data, data.count <= 1_048_576 else {
            throw CocoaError(.coderReadCorrupt)
        }
        let value = try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: data)
        _ = try value.text()
        return value
    }
}
