// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Small values that must survive an app relaunch: the opt-out deletion cutoff and the upload
/// back-off. Nothing stored here is ever sent; everything is removed when the user opts out
/// (the cutoff only once the deletion it guards has succeeded).
public protocol StateStore: Sendable {
    func data(forKey key: String) -> Data?
    /// `nil` removes the value.
    func set(_ data: Data?, forKey key: String)
}

extension StateStore {
    func value<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    func setValue(_ value: (some Encodable)?, forKey key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

/// Keeps state for the lifetime of the object only (tests, and the default).
public final class InMemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.withLock { values[key] = data }
    }
}

/// `UserDefaults.standard`, with every key under a prefix. App-only data (required reason CA92.1).
public struct UserDefaultsStateStore: StateStore {
    public let prefix: String

    public init(prefix: String = "fieldData.") {
        self.prefix = prefix
    }

    public func data(forKey key: String) -> Data? {
        UserDefaults.standard.data(forKey: prefix + key)
    }

    public func set(_ data: Data?, forKey key: String) {
        if let data {
            UserDefaults.standard.set(data, forKey: prefix + key)
        } else {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        }
    }
}
