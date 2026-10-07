import Foundation

/// Languages Sideboard ships with. `.system` follows the Mac's language settings.
///
/// Switching is live for Sideboard's own window (through the SwiftUI locale).
/// Menus and system dialogs follow from the next launch, via `AppleLanguages`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case russian = "ru"
    case spanish = "es"
    case hindi = "hi"

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    /// Each language is written in itself, so people can find theirs
    /// whatever language the app is currently showing.
    var nativeName: String {
        switch self {
        case .system: ""
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .russian: "Русский"
        case .spanish: "Español"
        case .hindi: "हिन्दी"
        }
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    func persistForNextLaunch() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
