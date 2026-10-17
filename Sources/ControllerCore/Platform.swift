import Foundation
#if canImport(os)
import os
#endif

/// 跨线程共享的一个值（单写多读）。Apple 平台用 `OSAllocatedUnfairLock`（音频线程友好），
/// 其他平台用 `NSLock`（`Synchronization.Mutex` 在 Apple 上要求 macOS 15+，本项目最低 14.2）。
public final class LockedBox<Value: Sendable>: @unchecked Sendable {
    #if canImport(os)
    private let lock: OSAllocatedUnfairLock<Value>
    public init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    public func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLockUnchecked { body(&$0) } }
    #else
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
    #endif
}

/// 键值存储：设置、语言、全局选项、可调参数都存在这里。
/// macOS / Linux 用 `UserDefaults`（已经满足本协议），Android / Windows 各自实现（SharedPreferences / 文件）。
public protocol KeyValueStore: AnyObject {
    func storedData(forKey key: String) -> Data?
    func storedNumber(forKey key: String) -> Double?
    func storedBool(forKey key: String) -> Bool?
    func storedString(forKey key: String) -> String?
    func store(data: Data?, forKey key: String)
    func store(bool: Bool?, forKey key: String)
    func store(string: String?, forKey key: String)
}

extension UserDefaults: KeyValueStore {
    public func storedData(forKey key: String) -> Data? { data(forKey: key) }
    public func storedNumber(forKey key: String) -> Double? { object(forKey: key) == nil ? nil : double(forKey: key) }
    public func storedBool(forKey key: String) -> Bool? { object(forKey: key) as? Bool }
    public func storedString(forKey key: String) -> String? { string(forKey: key) }
    public func store(data: Data?, forKey key: String) { set(data, forKey: key) }
    public func store(bool: Bool?, forKey key: String) { set(bool, forKey: key) }
    public func store(string: String?, forKey key: String) { set(string, forKey: key) }
}

/// 只在内存里的键值存储（测试、假引擎用）
public final class InMemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]
    public init() {}
    public func storedData(forKey key: String) -> Data? { values[key] as? Data }
    public func storedNumber(forKey key: String) -> Double? { values[key] as? Double }
    public func storedBool(forKey key: String) -> Bool? { values[key] as? Bool }
    public func storedString(forKey key: String) -> String? { values[key] as? String }
    public func store(data: Data?, forKey key: String) { values[key] = data }
    public func store(bool: Bool?, forKey key: String) { values[key] = bool }
    public func store(string: String?, forKey key: String) { values[key] = string }
    public func store(number: Double?, forKey key: String) { values[key] = number }
}
