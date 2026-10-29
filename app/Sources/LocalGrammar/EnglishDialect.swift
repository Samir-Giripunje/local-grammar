import Foundation

enum EnglishDialect: String, CaseIterable, Identifiable, Sendable {
    case American, British, Indian, Canadian, Australian

    var id: String { rawValue }

    var spellLanguage: String {
        switch self {
        case .American: "en"
        case .British: "en_GB"
        case .Indian: "en_IN"
        case .Canadian: "en_CA"
        case .Australian: "en_AU"
        }
    }

    static var current: EnglishDialect {
        if let saved = UserDefaults.standard.string(forKey: "dialect"), let dialect = EnglishDialect(rawValue: saved) {
            return dialect
        }
        switch Locale.current.region?.identifier {
        case "IN": return .Indian
        case "GB", "IE": return .British
        case "CA": return .Canadian
        case "AU", "NZ": return .Australian
        default: return .American
        }
    }
}
