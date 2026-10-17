import Foundation

/// 界面语言。选择保存在键值存储（键 "language"，macOS 上就是 UserDefaults），未选择时跟随系统语言
public enum Language: String, CaseIterable, Identifiable {
    case zh, en
    public var id: Self { self }

    public static let storageKey = "language"
    /// 读语言用的存储；平台启动时设置（macOS：UserDefaults.standard）
    public nonisolated(unsafe) static var store: KeyValueStore = InMemoryStore()

    public static var systemDefault: Language {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
    }

    public static var current: Language {
        Language(rawValue: store.storedString(forKey: storageKey) ?? "") ?? systemDefault
    }

    public var label: String { self == .zh ? "中" : "EN" }
}

/// 中英对照文字：在模型层保存两种语言，显示时再按当前语言取，切换语言后立即生效
public struct Bilingual: Equatable, Codable, Sendable {
    public let zh: String
    public let en: String
    public init(zh: String, en: String) { self.zh = zh; self.en = en }
    public var text: String { Language.current == .zh ? zh : en }
}

/// 按当前语言取文字
public func L(_ zh: String, _ en: String) -> String { Language.current == .zh ? zh : en }
