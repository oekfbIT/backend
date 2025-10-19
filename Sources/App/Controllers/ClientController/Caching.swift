//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 03.09.25.
//

// SimpleCache.swift
import Foundation
import Dispatch

final class SimpleCache<Value> {
    struct Entry { let value: Value; let expiresAt: Date }
    private let queue = DispatchQueue(label: "cache.simple.\(UUID().uuidString)")
    private var store: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int

    init(ttl: TimeInterval, maxEntries: Int = 256) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    func get(_ key: String) -> Value? {
        queue.sync {
            guard let e = store[key] else { return nil }
            if e.expiresAt > Date() { return e.value }
            store.removeValue(forKey: key)
            return nil
        }
    }

    func set(_ key: String, _ value: Value) {
        queue.sync {
            store[key] = Entry(value: value, expiresAt: Date().addingTimeInterval(ttl))
            if store.count > maxEntries, let firstKey = store.keys.first {
                store.removeValue(forKey: firstKey)
            }
        }
    }

    func remove(_ key: String) { queue.sync { store.removeValue(forKey: key) } }
    func clear() { queue.sync { store.removeAll(keepingCapacity: false) } }
}

// NOTE: no `private` here so it's visible in other files of the target
enum Caches {
    static let seasons = SimpleCache<[PublicSeasonMatches]>(ttl: 30)
}
