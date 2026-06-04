import AppKit
import Carbon.HIToolbox

/// User-facing configuration, persisted to `UserDefaults`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var apiBaseURL: String { didSet { defaults.set(apiBaseURL, forKey: Keys.apiBaseURL) } }
    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: Keys.apiKey) } }
    @Published var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: Keys.targetLanguage) } }
    @Published var customPrompt: String { didSet { defaults.set(customPrompt, forKey: Keys.customPrompt) } }
    @Published var enableHotkey: Bool { didSet { defaults.set(enableHotkey, forKey: Keys.enableHotkey) } }
    @Published var enableFloatingIcon: Bool { didSet { defaults.set(enableFloatingIcon, forKey: Keys.enableFloatingIcon) } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) } }
    @Published var hotkeyKeyCode: Int { didSet { defaults.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode) } }
    @Published var hotkeyModifiers: Int { didSet { defaults.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers) } }

    private init() {
        defaults.register(defaults: [
            Keys.apiBaseURL: "https://api.openai.com/v1",
            Keys.model: "gpt-4o-mini",
            Keys.targetLanguage: "中文",
            Keys.enableHotkey: true,
            Keys.enableFloatingIcon: true,
            Keys.restoreClipboard: true,
            Keys.hotkeyKeyCode: kVK_ANSI_D,
            Keys.hotkeyModifiers: Int(NSEvent.ModifierFlags.option.rawValue),
        ])

        apiBaseURL = defaults.string(forKey: Keys.apiBaseURL) ?? "https://api.openai.com/v1"
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        model = defaults.string(forKey: Keys.model) ?? "gpt-4o-mini"
        targetLanguage = defaults.string(forKey: Keys.targetLanguage) ?? "中文"
        customPrompt = defaults.string(forKey: Keys.customPrompt) ?? ""
        enableHotkey = defaults.bool(forKey: Keys.enableHotkey)
        enableFloatingIcon = defaults.bool(forKey: Keys.enableFloatingIcon)
        restoreClipboard = defaults.bool(forKey: Keys.restoreClipboard)
        hotkeyKeyCode = defaults.integer(forKey: Keys.hotkeyKeyCode)
        hotkeyModifiers = defaults.integer(forKey: Keys.hotkeyModifiers)
    }

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

    private enum Keys {
        static let apiBaseURL = "apiBaseURL"
        static let apiKey = "apiKey"
        static let model = "model"
        static let targetLanguage = "targetLanguage"
        static let customPrompt = "customPrompt"
        static let enableHotkey = "enableHotkey"
        static let enableFloatingIcon = "enableFloatingIcon"
        static let restoreClipboard = "restoreClipboard"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
    }
}
