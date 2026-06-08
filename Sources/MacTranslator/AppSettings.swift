import AppKit
import Carbon.HIToolbox

/// User-facing configuration, persisted to `UserDefaults`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// All configured AI backends. Each enabled one runs on every translation.
    @Published var backends: [Backend] { didSet { saveBackends() } }

    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: Keys.targetLanguage) } }
    @Published var customPrompt: String { didSet { defaults.set(customPrompt, forKey: Keys.customPrompt) } }
    @Published var enableHotkey: Bool { didSet { defaults.set(enableHotkey, forKey: Keys.enableHotkey) } }
    @Published var enableFloatingIcon: Bool { didSet { defaults.set(enableFloatingIcon, forKey: Keys.enableFloatingIcon) } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) } }
    @Published var enableMicrosoftDictionary: Bool { didSet { defaults.set(enableMicrosoftDictionary, forKey: Keys.enableMicrosoftDictionary) } }
    @Published var microsoftTranslatorEndpoint: String { didSet { defaults.set(microsoftTranslatorEndpoint, forKey: Keys.microsoftTranslatorEndpoint) } }
    @Published var microsoftTranslatorKey: String { didSet { defaults.set(microsoftTranslatorKey, forKey: Keys.microsoftTranslatorKey) } }
    @Published var microsoftTranslatorRegion: String { didSet { defaults.set(microsoftTranslatorRegion, forKey: Keys.microsoftTranslatorRegion) } }
    @Published var microsoftDictionaryFromLanguage: String { didSet { defaults.set(microsoftDictionaryFromLanguage, forKey: Keys.microsoftDictionaryFromLanguage) } }
    @Published var microsoftDictionaryToLanguage: String { didSet { defaults.set(microsoftDictionaryToLanguage, forKey: Keys.microsoftDictionaryToLanguage) } }
    @Published var hotkeyKeyCode: Int { didSet { defaults.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode) } }
    @Published var hotkeyModifiers: Int { didSet { defaults.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers) } }

    private init() {
        defaults.register(defaults: [
            Keys.targetLanguage: "中文",
            Keys.enableHotkey: true,
            Keys.enableFloatingIcon: true,
            Keys.restoreClipboard: true,
            Keys.enableMicrosoftDictionary: false,
            Keys.microsoftTranslatorEndpoint: "https://api.cognitive.microsofttranslator.com",
            Keys.microsoftDictionaryFromLanguage: "en",
            Keys.microsoftDictionaryToLanguage: "zh-Hans",
            Keys.hotkeyKeyCode: kVK_ANSI_D,
            Keys.hotkeyModifiers: Int(NSEvent.ModifierFlags.option.rawValue),
        ])

        targetLanguage = defaults.string(forKey: Keys.targetLanguage) ?? "中文"
        customPrompt = defaults.string(forKey: Keys.customPrompt) ?? ""
        enableHotkey = defaults.bool(forKey: Keys.enableHotkey)
        enableFloatingIcon = defaults.bool(forKey: Keys.enableFloatingIcon)
        restoreClipboard = defaults.bool(forKey: Keys.restoreClipboard)
        enableMicrosoftDictionary = defaults.bool(forKey: Keys.enableMicrosoftDictionary)
        microsoftTranslatorEndpoint = defaults.string(forKey: Keys.microsoftTranslatorEndpoint) ?? "https://api.cognitive.microsofttranslator.com"
        microsoftTranslatorKey = defaults.string(forKey: Keys.microsoftTranslatorKey) ?? ""
        microsoftTranslatorRegion = defaults.string(forKey: Keys.microsoftTranslatorRegion) ?? ""
        microsoftDictionaryFromLanguage = defaults.string(forKey: Keys.microsoftDictionaryFromLanguage) ?? "en"
        microsoftDictionaryToLanguage = defaults.string(forKey: Keys.microsoftDictionaryToLanguage) ?? "zh-Hans"
        hotkeyKeyCode = defaults.integer(forKey: Keys.hotkeyKeyCode)
        hotkeyModifiers = defaults.integer(forKey: Keys.hotkeyModifiers)

        backends = Self.loadBackends(from: defaults)
        // Persist the migrated/default set so it survives even without edits.
        if defaults.data(forKey: Keys.backends) == nil {
            saveBackends()
        }
    }

    // MARK: - Backends

    /// Backends that will actually be called on a translation.
    var enabledBackends: [Backend] { backends.filter { $0.isUsable } }

    var hasEnabledLookupProvider: Bool {
        !enabledBackends.isEmpty || enableMicrosoftDictionary
    }

    var microsoftDictionaryConfig: MicrosoftDictionaryConfig {
        MicrosoftDictionaryConfig(
            isEnabled: enableMicrosoftDictionary,
            endpoint: microsoftTranslatorEndpoint,
            apiKey: microsoftTranslatorKey,
            region: microsoftTranslatorRegion,
            fromLanguage: microsoftDictionaryFromLanguage,
            toLanguage: microsoftDictionaryToLanguage
        )
    }

    var targetSpeechLanguageCode: String? {
        Self.speechLanguageCode(for: targetLanguage)
    }

    func addBackend() {
        backends.append(.makeNew())
    }

    func removeBackend(_ backend: Backend) {
        backends.removeAll { $0.id == backend.id }
    }

    private func saveBackends() {
        if let data = try? JSONEncoder().encode(backends) {
            defaults.set(data, forKey: Keys.backends)
        }
    }

    /// Loads backends from JSON, or migrates the old single-backend config.
    private static func loadBackends(from defaults: UserDefaults) -> [Backend] {
        if let data = defaults.data(forKey: Keys.backends),
           let decoded = try? JSONDecoder().decode([Backend].self, from: data) {
            return decoded
        }
        // Migration: turn the old single apiBaseURL/apiKey/model into one backend.
        let url = defaults.string(forKey: "apiBaseURL") ?? "https://api.openai.com/v1"
        let key = defaults.string(forKey: "apiKey") ?? ""
        let model = defaults.string(forKey: "model") ?? "gpt-4o-mini"
        return [Backend(name: "OpenAI", baseURL: url, apiKey: key, model: model, isEnabled: true)]
    }

    // MARK: - Derived values

    /// The stored Cocoa modifier flags translated into Carbon modifier bits.
    var hotkeyCarbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiers))
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// The system prompt sent to the model. A non-empty custom prompt wins;
    /// otherwise we build a faithful translate-into-target instruction that
    /// auto-flips to English when the source is already the target language.
    func effectiveSystemPrompt() -> String {
        let custom = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }

        let target = targetLanguage.isEmpty ? "中文" : targetLanguage
        return """
        You are a professional, faithful translation engine. \
        Translate the user's text into \(target). \
        If the text is already in \(target), translate it into English instead. \
        Preserve the original meaning, tone and formatting. \
        Output ONLY the translation itself — no quotes, no explanations, no extra commentary.
        """
    }

    private static func speechLanguageCode(for language: String) -> String? {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if value.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil {
            return value
        }
        if lower.contains("中文") || lower.contains("chinese") { return "zh-Hans" }
        if lower.contains("英文") || lower.contains("英语") || lower.contains("english") { return "en" }
        if lower.contains("日文") || lower.contains("日语") || lower.contains("japanese") { return "ja" }
        if lower.contains("韩文") || lower.contains("韩语") || lower.contains("korean") { return "ko" }
        if lower.contains("法文") || lower.contains("法语") || lower.contains("french") { return "fr" }
        if lower.contains("德文") || lower.contains("德语") || lower.contains("german") { return "de" }
        if lower.contains("西班牙") || lower.contains("spanish") { return "es" }
        return nil
    }

    private enum Keys {
        static let backends = "backends"
        static let targetLanguage = "targetLanguage"
        static let customPrompt = "customPrompt"
        static let enableHotkey = "enableHotkey"
        static let enableFloatingIcon = "enableFloatingIcon"
        static let restoreClipboard = "restoreClipboard"
        static let enableMicrosoftDictionary = "enableMicrosoftDictionary"
        static let microsoftTranslatorEndpoint = "microsoftTranslatorEndpoint"
        static let microsoftTranslatorKey = "microsoftTranslatorKey"
        static let microsoftTranslatorRegion = "microsoftTranslatorRegion"
        static let microsoftDictionaryFromLanguage = "microsoftDictionaryFromLanguage"
        static let microsoftDictionaryToLanguage = "microsoftDictionaryToLanguage"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
    }
}
