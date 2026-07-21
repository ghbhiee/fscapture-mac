import Foundation

/// App UI language. `.system` follows the OS preferred language.
enum AppLanguage: String, CaseIterable {
    case system, zh, en

    var label: String {
        switch self {
        case .system: return Loc.t("跟随系统", "System")
        case .zh:     return "中文"
        case .en:     return "English"
        }
    }
}

/// Lightweight inline bilingual localization. Every UI string is written as
/// `Loc.t("中文", "English")`; the effective language decides which is returned.
/// Switching language persists to UserDefaults and takes effect on relaunch
/// (menus / the floating panel are built once at launch).
enum Loc {
    private static let key = "appLanguage"

    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    static func setLanguage(_ lang: AppLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: key)
    }

    /// True when the effective UI language is English.
    static var isEnglish: Bool {
        switch language {
        case .en: return true
        case .zh: return false
        case .system:
            let pref = Locale.preferredLanguages.first ?? "en"
            return !pref.lowercased().hasPrefix("zh")
        }
    }

    /// Pick the string for the current language.
    static func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}
