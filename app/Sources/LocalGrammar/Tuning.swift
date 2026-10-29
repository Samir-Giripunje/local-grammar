import Foundation

/// How a model is asked to proofread. Kept per model, because what works for one model (no thinking, a
/// short answer budget) can cut another off. The defaults were tuned for Qwen3.5 2B.
struct ModelSettings: Codable, Equatable {
    /// 0 gives the same answer every time; higher lets the model vary its wording.
    var temperature = 0.0
    /// Lets reasoning models think before answering. Slower, and the answer budget grows to fit.
    var thinking = false
    /// Answer budget as a multiple of the selection's length (plus a little headroom).
    var answerLength = 2.0
    /// Seconds before a correction is abandoned.
    var timeLimit = 45
    /// Longest selection ⌥⌘G sends to the model, in characters.
    var maxSelection = 8000
    /// Keeps Markdown, code and links exactly as they were, correcting line by line if the model breaks them.
    var keepStructure = true
    /// Replaces the built-in proofreading instructions when set.
    var instructions = ""

    static let standard = ModelSettings()

    /// Fields the server reads, in its own names.
    var request: [String: Any] {
        [
            "temperature": temperature, "thinking": thinking, "answer_length": answerLength,
            "keep_structure": keepStructure, "instructions": instructions,
        ]
    }
}

@MainActor
final class ModelSettingsStore: ObservableObject {
    @Published private var all: [String: ModelSettings]

    init() {
        let data = UserDefaults.standard.data(forKey: "modelSettings")
        all = data.flatMap { try? JSONDecoder().decode([String: ModelSettings].self, from: $0) } ?? [:]
    }

    func settings(for modelID: String) -> ModelSettings {
        all[modelID] ?? Self.defaults(for: modelID)
    }

    /// Apple's model has a ~4,000-token context, so it takes shorter selections than Qwen.
    static func defaults(for modelID: String) -> ModelSettings {
        guard modelID == AppleProofreader.settingsID else { return .standard }
        var settings = ModelSettings.standard
        settings.maxSelection = 6000
        return settings
    }

    func set(_ settings: ModelSettings, for modelID: String) {
        all[modelID] = settings == Self.defaults(for: modelID) ? nil : settings
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: "modelSettings") }
    }

    func isCustomized(_ modelID: String) -> Bool {
        all[modelID] != nil
    }
}

/// Timing for live underlines and autocorrect. These don't involve the AI model (spelling comes from macOS
/// and grammar from Harper), so they're the same whichever model is selected.
enum CheckingTiming {
    struct Value {
        let key: String
        let standard: Double
        var current: Double {
            UserDefaults.standard.object(forKey: key) as? Double ?? standard
        }
    }

    /// How often the focused text box is re-read.
    static let interval = Value(key: "checkInterval", standard: 0.2)
    /// How long the word you're still typing stays unflagged after your last keystroke.
    static let typingPause = Value(key: "typingPause", standard: 1.0)
    /// How long the mouse rests on an underline before its card opens.
    static let hoverDelay = Value(key: "hoverDelay", standard: 0.3)
    /// Longest text checked live, in characters.
    static let liveLimit = Value(key: "liveLimit", standard: 20000)
}
