import Foundation

/// 界面语言。选择保存在 UserDefaults（键 "language"），未选择时跟随系统语言
enum Language: String, CaseIterable, Identifiable {
    case zh, en
    var id: Self { self }

    static let storageKey = "language"

    static var systemDefault: Language {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
    }

    static var current: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? systemDefault
    }

    var label: String { self == .zh ? "中" : "EN" }
}

/// 中英对照文字：在模型层保存两种语言，显示时再按当前语言取，切换语言后立即生效
struct Bilingual: Equatable {
    let zh: String
    let en: String
    var text: String { Language.current == .zh ? zh : en }
}

/// 按当前语言取文字
func L(_ zh: String, _ en: String) -> String { Language.current == .zh ? zh : en }
