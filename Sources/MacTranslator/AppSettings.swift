import AppKit
import Carbon.HIToolbox
import MacTranslatorCore

/// User-facing configuration, persisted to `UserDefaults`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// All configured AI backends. Each enabled one runs on every translation.
    @Published var backends: [Backend] { didSet { saveBackends() } }

    /// All configured text-to-speech backends. Enabled entries are selectable
    /// from every speech button in this stored order.
    @Published var ttsBackends: [TTSBackend] { didSet { saveTTSBackends() } }

    /// Non-persistent operational errors that need to be visible in Settings.
    @Published private(set) var credentialError: String?
    @Published var hotkeyRegistrationError: String?
    @Published var ocrHotkeyRegistrationError: String?

    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: Keys.targetLanguage) } }
    @Published var customPrompt: String { didSet { defaults.set(customPrompt, forKey: Keys.customPrompt) } }
    @Published var enableHotkey: Bool { didSet { defaults.set(enableHotkey, forKey: Keys.enableHotkey) } }
    @Published var enableOCRHotkey: Bool { didSet { defaults.set(enableOCRHotkey, forKey: Keys.enableOCRHotkey) } }
    @Published var enableFloatingIcon: Bool { didSet { defaults.set(enableFloatingIcon, forKey: Keys.enableFloatingIcon) } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) } }
    @Published var enableNotes: Bool { didSet { defaults.set(enableNotes, forKey: Keys.enableNotes) } }
    @Published var enableMicrosoftDictionary: Bool { didSet { defaults.set(enableMicrosoftDictionary, forKey: Keys.enableMicrosoftDictionary) } }
    @Published var microsoftTranslatorEndpoint: String { didSet { defaults.set(microsoftTranslatorEndpoint, forKey: Keys.microsoftTranslatorEndpoint) } }
    @Published var microsoftTranslatorKey: String {
        didSet { persistMicrosoftTranslatorKey() }
    }
    @Published var microsoftTranslatorRegion: String { didSet { defaults.set(microsoftTranslatorRegion, forKey: Keys.microsoftTranslatorRegion) } }
    @Published var microsoftDictionaryFromLanguage: String { didSet { defaults.set(microsoftDictionaryFromLanguage, forKey: Keys.microsoftDictionaryFromLanguage) } }
    @Published var microsoftDictionaryToLanguage: String { didSet { defaults.set(microsoftDictionaryToLanguage, forKey: Keys.microsoftDictionaryToLanguage) } }
    @Published var hotkeyKeyCode: Int { didSet { defaults.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode) } }
    @Published var hotkeyModifiers: Int { didSet { defaults.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers) } }
    @Published var ocrHotkeyKeyCode: Int { didSet { defaults.set(ocrHotkeyKeyCode, forKey: Keys.ocrHotkeyKeyCode) } }
    @Published var ocrHotkeyModifiers: Int { didSet { defaults.set(ocrHotkeyModifiers, forKey: Keys.ocrHotkeyModifiers) } }

    private var backendCredentialError: String?
    private var microsoftCredentialError: String?
    private var ttsBackendCredentialError: String?

    private init() {
        var startupCredentialError: String?

        defaults.register(defaults: [
            Keys.targetLanguage: "中文",
            Keys.enableHotkey: true,
            Keys.enableOCRHotkey: true,
            Keys.enableFloatingIcon: true,
            Keys.restoreClipboard: true,
            Keys.enableNotes: false,
            Keys.enableMicrosoftDictionary: false,
            Keys.microsoftTranslatorEndpoint: "https://api.cognitive.microsofttranslator.com",
            Keys.microsoftDictionaryFromLanguage: "en",
            Keys.microsoftDictionaryToLanguage: "zh-Hans",
            Keys.qwenTTSEndpoint: "https://dashscope-intl.aliyuncs.com/api/v1",
            Keys.qwenTTSModel: "qwen-audio-3.0-tts-flash",
            Keys.qwenTTSVoice: "loongjohn",
            Keys.qwenTTSInstruction: "Speak in a native American accent with relaxed, natural conversational delivery.",
            Keys.hotkeyKeyCode: DefaultHotkeys.translationKeyCode,
            Keys.hotkeyModifiers: DefaultHotkeys.translationModifiers,
            Keys.ocrHotkeyKeyCode: DefaultHotkeys.ocrKeyCode,
            Keys.ocrHotkeyModifiers: DefaultHotkeys.ocrModifiers,
        ])
        Self.migrateQwenTTSNativeAmericanDefault(in: defaults)
        Self.migrateOCRHotkeyDefault(in: defaults)

        targetLanguage = defaults.string(forKey: Keys.targetLanguage) ?? "中文"
        customPrompt = defaults.string(forKey: Keys.customPrompt) ?? ""
        enableHotkey = defaults.bool(forKey: Keys.enableHotkey)
        enableOCRHotkey = defaults.bool(forKey: Keys.enableOCRHotkey)
        enableFloatingIcon = defaults.bool(forKey: Keys.enableFloatingIcon)
        restoreClipboard = defaults.bool(forKey: Keys.restoreClipboard)
        enableNotes = defaults.bool(forKey: Keys.enableNotes)
        enableMicrosoftDictionary = defaults.bool(forKey: Keys.enableMicrosoftDictionary)
        microsoftTranslatorEndpoint = defaults.string(forKey: Keys.microsoftTranslatorEndpoint) ?? "https://api.cognitive.microsofttranslator.com"
        // One-time migration of the plaintext key out of UserDefaults. Never
        // delete the recoverable copy unless the Keychain write succeeded.
        let legacyMicrosoftKey = defaults.string(forKey: Keys.microsoftTranslatorKey)
        if let legacyMicrosoftKey, !legacyMicrosoftKey.isEmpty {
            do {
                try KeychainStore.set(
                    legacyMicrosoftKey,
                    for: KeychainStore.Account.microsoftTranslatorKey,
                    interaction: .suppress
                )
                defaults.removeObject(forKey: Keys.microsoftTranslatorKey)
                microsoftTranslatorKey = legacyMicrosoftKey
            } catch {
                startupCredentialError = Self.credentialMessage("微软 Translator Key", error)
                microsoftTranslatorKey = legacyMicrosoftKey
            }
        } else {
            do {
                microsoftTranslatorKey = try KeychainStore.string(
                    for: KeychainStore.Account.microsoftTranslatorKey,
                    interaction: .suppress
                ) ?? ""
            } catch {
                startupCredentialError = Self.credentialMessage("微软 Translator Key", error)
                microsoftTranslatorKey = ""
            }
        }
        microsoftTranslatorRegion = defaults.string(forKey: Keys.microsoftTranslatorRegion) ?? ""
        microsoftDictionaryFromLanguage = defaults.string(forKey: Keys.microsoftDictionaryFromLanguage) ?? "en"
        microsoftDictionaryToLanguage = defaults.string(forKey: Keys.microsoftDictionaryToLanguage) ?? "zh-Hans"
        hotkeyKeyCode = defaults.integer(forKey: Keys.hotkeyKeyCode)
        hotkeyModifiers = defaults.integer(forKey: Keys.hotkeyModifiers)
        ocrHotkeyKeyCode = defaults.integer(forKey: Keys.ocrHotkeyKeyCode)
        ocrHotkeyModifiers = defaults.integer(forKey: Keys.ocrHotkeyModifiers)

        let loadedBackends = Self.loadBackends(from: defaults)
        backends = loadedBackends.backends
        unavailableBackendKeyIDs = loadedBackends.unavailableKeyIDs
        let loadedTTSBackends = Self.loadTTSBackends(from: defaults)
        ttsBackends = loadedTTSBackends.backends
        unavailableTTSBackendKeyIDs = loadedTTSBackends.unavailableKeyIDs
        credentialError = nil
        hotkeyRegistrationError = nil
        ocrHotkeyRegistrationError = nil

        // Persist only migrations/defaults. Existing sanitized settings do not
        // need a launch-time rewrite, which also avoids touching a temporarily
        // unavailable Keychain item.
        if loadedBackends.needsMigration, saveBackends(interaction: .suppress) {
            defaults.removeObject(forKey: "apiKey") // legacy single-backend key
        }
        if loadedTTSBackends.needsMigration {
            _ = saveTTSBackends(interaction: .suppress)
        }
        if !unavailableBackendKeyIDs.isEmpty, backendCredentialError == nil {
            backendCredentialError = loadedBackends.readError
            refreshCredentialError()
        }
        if let startupCredentialError {
            microsoftCredentialError = startupCredentialError
            refreshCredentialError()
        }
        if !unavailableTTSBackendKeyIDs.isEmpty, ttsBackendCredentialError == nil {
            ttsBackendCredentialError = loadedTTSBackends.readError
            refreshCredentialError()
        }
    }

    // MARK: - Backends

    /// Backends that will actually be called on a translation.
    var enabledBackends: [Backend] { backends.filter { $0.isUsable } }

    var hasEnabledLookupProvider: Bool {
        !enabledBackends.isEmpty
            || (ExperimentalFeatures.microsoftDictionary && enableMicrosoftDictionary)
    }

    var microsoftDictionaryConfig: MicrosoftDictionaryConfig {
        MicrosoftDictionaryConfig(
            isEnabled: ExperimentalFeatures.microsoftDictionary && enableMicrosoftDictionary,
            endpoint: microsoftTranslatorEndpoint,
            apiKey: microsoftTranslatorKey,
            region: microsoftTranslatorRegion,
            fromLanguage: microsoftDictionaryFromLanguage,
            toLanguage: microsoftDictionaryToLanguage
        )
    }

    /// TTS choices shown by speech buttons. If this is empty, the app keeps
    /// using the zero-configuration macOS system voice.
    var enabledTTSBackends: [TTSBackend] { ttsBackends.filter { $0.isUsable } }

    var targetSpeechLanguageCode: String? {
        Self.speechLanguageCode(for: targetLanguage)
    }

    func addBackend() {
        backends.append(.makeNew())
    }

    /// Moves a backend by one or more positions. The stored array is the source
    /// of truth for both request creation and top-to-bottom result card order.
    func moveBackend(id: UUID, by offset: Int) {
        guard let sourceIndex = backends.firstIndex(where: { $0.id == id }) else { return }
        let destinationIndex = sourceIndex + offset
        guard backends.indices.contains(destinationIndex) else { return }
        backends = ListOrderingPolicy.moving(
            backends,
            from: sourceIndex,
            to: destinationIndex
        )
    }

    /// Moves a dragged backend to the row it was dropped on.
    func moveBackend(id: UUID, to destinationID: UUID) {
        guard let sourceIndex = backends.firstIndex(where: { $0.id == id }),
              let destinationIndex = backends.firstIndex(where: { $0.id == destinationID })
        else { return }
        backends = ListOrderingPolicy.moving(
            backends,
            from: sourceIndex,
            to: destinationIndex
        )
    }

    func removeBackend(_ backend: Backend) {
        do {
            try KeychainStore.delete(account: KeychainStore.Account.backendKey(backend.id))
            unavailableBackendKeyIDs.remove(backend.id)
            backends.removeAll { $0.id == backend.id }
            backendCredentialError = nil
            refreshCredentialError()
        } catch {
            backendCredentialError = Self.credentialMessage("\(backend.name) 的 API Key", error)
            refreshCredentialError()
        }
    }

    // MARK: - TTS Backends

    func addTTSBackend() {
        ttsBackends.append(.makeNew())
    }

    func moveTTSBackend(id: UUID, by offset: Int) {
        guard let sourceIndex = ttsBackends.firstIndex(where: { $0.id == id }) else { return }
        let destinationIndex = sourceIndex + offset
        guard ttsBackends.indices.contains(destinationIndex) else { return }
        ttsBackends = ListOrderingPolicy.moving(
            ttsBackends,
            from: sourceIndex,
            to: destinationIndex
        )
    }

    func moveTTSBackend(id: UUID, to destinationID: UUID) {
        guard let sourceIndex = ttsBackends.firstIndex(where: { $0.id == id }),
              let destinationIndex = ttsBackends.firstIndex(where: { $0.id == destinationID })
        else { return }
        ttsBackends = ListOrderingPolicy.moving(
            ttsBackends,
            from: sourceIndex,
            to: destinationIndex
        )
    }

    func removeTTSBackend(_ backend: TTSBackend) {
        do {
            try KeychainStore.delete(account: KeychainStore.Account.ttsBackendKey(backend.id))
            unavailableTTSBackendKeyIDs.remove(backend.id)
            ttsBackends.removeAll { $0.id == backend.id }
            ttsBackendCredentialError = nil
            refreshCredentialError()
        } catch {
            ttsBackendCredentialError = Self.credentialMessage("\(backend.name) 的 API Key", error)
            refreshCredentialError()
        }
    }

    /// Persists the backends: keys go to the Keychain, everything else to
    /// UserDefaults (with the apiKey field blanked in the stored JSON).
    @discardableResult
    private func saveBackends(
        interaction: KeychainStore.Interaction = .allow
    ) -> Bool {
        for backend in backends {
            // If a read failed at launch, an empty in-memory value does not mean
            // the user cleared the key. Preserve the existing Keychain item.
            if unavailableBackendKeyIDs.contains(backend.id), backend.apiKey.isEmpty {
                continue
            }
            do {
                try KeychainStore.set(
                    backend.apiKey,
                    for: KeychainStore.Account.backendKey(backend.id),
                    interaction: interaction
                )
                unavailableBackendKeyIDs.remove(backend.id)
            } catch {
                backendCredentialError = Self.credentialMessage("\(backend.name) 的 API Key", error)
                refreshCredentialError()
                return false
            }
        }
        var sanitized = backends
        for index in sanitized.indices {
            sanitized[index].apiKey = ""
        }
        if let data = try? JSONEncoder().encode(sanitized) {
            defaults.set(data, forKey: Keys.backends)
            backendCredentialError = nil
            refreshCredentialError()
            return true
        }
        backendCredentialError = "后端配置编码失败，修改尚未保存。"
        refreshCredentialError()
        return false
    }

    /// Loads backends from JSON, or migrates the old single-backend config.
    private static func loadBackends(from defaults: UserDefaults) -> LoadedBackends {
        if let data = defaults.data(forKey: Keys.backends),
           var decoded = try? JSONDecoder().decode([Backend].self, from: data) {
            var unavailableKeyIDs: Set<UUID> = []
            var readError: String?
            let needsMigration = decoded.contains { !$0.apiKey.isEmpty }
            for index in decoded.indices {
                // Keys live in the Keychain; JSON only carries them in the
                // pre-Keychain format, which the next save migrates over.
                do {
                    if let stored = try KeychainStore.string(
                        for: KeychainStore.Account.backendKey(decoded[index].id),
                        interaction: .suppress
                    ),
                       !stored.isEmpty {
                        decoded[index].apiKey = stored
                    }
                } catch {
                    unavailableKeyIDs.insert(decoded[index].id)
                    if readError == nil {
                        readError = credentialReadMessage("\(decoded[index].name) 的 API Key", error)
                    }
                }
            }
            return LoadedBackends(
                backends: decoded,
                unavailableKeyIDs: unavailableKeyIDs,
                needsMigration: needsMigration,
                readError: readError
            )
        }
        // Migration: turn the old single apiBaseURL/apiKey/model into one backend.
        let url = defaults.string(forKey: "apiBaseURL") ?? "https://api.openai.com/v1"
        let key = defaults.string(forKey: "apiKey") ?? ""
        let model = defaults.string(forKey: "model") ?? "gpt-4o-mini"
        return LoadedBackends(
            backends: [Backend(name: "OpenAI", baseURL: url, apiKey: key, model: model, isEnabled: true)],
            unavailableKeyIDs: [],
            needsMigration: true,
            readError: nil
        )
    }

    private var unavailableBackendKeyIDs: Set<UUID> = []

    private struct LoadedBackends {
        var backends: [Backend]
        var unavailableKeyIDs: Set<UUID>
        var needsMigration: Bool
        var readError: String?
    }

    @discardableResult
    private func saveTTSBackends(
        interaction: KeychainStore.Interaction = .allow
    ) -> Bool {
        for backend in ttsBackends {
            if unavailableTTSBackendKeyIDs.contains(backend.id), backend.apiKey.isEmpty {
                continue
            }
            do {
                try KeychainStore.set(
                    backend.apiKey,
                    for: KeychainStore.Account.ttsBackendKey(backend.id),
                    interaction: interaction
                )
                unavailableTTSBackendKeyIDs.remove(backend.id)
            } catch {
                ttsBackendCredentialError = Self.credentialMessage("\(backend.name) 的 API Key", error)
                refreshCredentialError()
                return false
            }
        }

        var sanitized = ttsBackends
        for index in sanitized.indices {
            sanitized[index].apiKey = ""
        }
        if let data = try? JSONEncoder().encode(sanitized) {
            defaults.set(data, forKey: Keys.ttsBackends)
            ttsBackendCredentialError = nil
            refreshCredentialError()
            return true
        }
        ttsBackendCredentialError = "TTS 后端配置编码失败，修改尚未保存。"
        refreshCredentialError()
        return false
    }

    /// Loads the multi-backend format, or migrates the former single Qwen TTS
    /// configuration and Keychain item without exposing its key in UserDefaults.
    private static func loadTTSBackends(from defaults: UserDefaults) -> LoadedTTSBackends {
        if let data = defaults.data(forKey: Keys.ttsBackends),
           var decoded = try? JSONDecoder().decode([TTSBackend].self, from: data) {
            var unavailableKeyIDs: Set<UUID> = []
            var readError: String?
            let needsMigration = decoded.contains { !$0.apiKey.isEmpty }
            for index in decoded.indices {
                do {
                    if let stored = try KeychainStore.string(
                        for: KeychainStore.Account.ttsBackendKey(decoded[index].id),
                        interaction: .suppress
                    ), !stored.isEmpty {
                        decoded[index].apiKey = stored
                    }
                } catch {
                    unavailableKeyIDs.insert(decoded[index].id)
                    if readError == nil {
                        readError = credentialReadMessage("\(decoded[index].name) 的 API Key", error)
                    }
                }
            }
            return LoadedTTSBackends(
                backends: decoded,
                unavailableKeyIDs: unavailableKeyIDs,
                needsMigration: needsMigration,
                readError: readError
            )
        }

        let legacyKey: String
        var unavailableKeyIDs: Set<UUID> = []
        var readError: String?
        let id = UUID()
        do {
            legacyKey = try KeychainStore.string(
                for: KeychainStore.Account.qwenTTSAPIKey,
                interaction: .suppress
            ) ?? ""
        } catch {
            legacyKey = ""
            unavailableKeyIDs.insert(id)
            readError = credentialReadMessage("Qwen TTS API Key", error)
        }

        guard !legacyKey.isEmpty || readError != nil else {
            return LoadedTTSBackends(
                backends: [],
                unavailableKeyIDs: [],
                needsMigration: true,
                readError: nil
            )
        }

        let migrated = TTSBackend(
            id: id,
            name: "Qwen AI TTS",
            apiKind: .dashScope,
            endpoint: defaults.string(forKey: Keys.qwenTTSEndpoint)
                ?? "https://dashscope-intl.aliyuncs.com/api/v1",
            apiKey: legacyKey,
            model: defaults.string(forKey: Keys.qwenTTSModel)
                ?? "qwen-audio-3.0-tts-flash",
            voice: defaults.string(forKey: Keys.qwenTTSVoice) ?? "loongjohn",
            responseFormat: "mp3",
            instruction: defaults.string(forKey: Keys.qwenTTSInstruction)
                ?? "Speak in a native American accent with relaxed, natural conversational delivery.",
            isEnabled: true
        )
        return LoadedTTSBackends(
            backends: [migrated],
            unavailableKeyIDs: unavailableKeyIDs,
            needsMigration: true,
            readError: readError
        )
    }

    private var unavailableTTSBackendKeyIDs: Set<UUID> = []

    private struct LoadedTTSBackends {
        var backends: [TTSBackend]
        var unavailableKeyIDs: Set<UUID>
        var needsMigration: Bool
        var readError: String?
    }

    private func persistMicrosoftTranslatorKey() {
        do {
            try KeychainStore.set(
                microsoftTranslatorKey,
                for: KeychainStore.Account.microsoftTranslatorKey
            )
            microsoftCredentialError = nil
            refreshCredentialError()
        } catch {
            microsoftCredentialError = Self.credentialMessage("微软 Translator Key", error)
            refreshCredentialError()
        }
    }

    private func refreshCredentialError() {
        credentialError = ttsBackendCredentialError ?? microsoftCredentialError ?? backendCredentialError
    }

    private static func credentialMessage(_ label: String, _ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\(label) 未能保存。\(detail)"
    }

    private static func credentialReadMessage(_ label: String, _ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\(label) 无法读取。\(detail)"
    }

    // MARK: - Derived values

    /// The stored Cocoa modifier flags translated into Carbon modifier bits.
    var hotkeyCarbonModifiers: UInt32 {
        Self.carbonModifiers(from: hotkeyModifiers)
    }

    var ocrHotkeyCarbonModifiers: UInt32 {
        Self.carbonModifiers(from: ocrHotkeyModifiers)
    }

    private static func carbonModifiers(from modifiers: Int) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    private static func migrateOCRHotkeyDefault(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: Keys.didMigrateOCRHotkeyDefault) else { return }

        let hasStoredKeyCode = defaults.object(forKey: Keys.ocrHotkeyKeyCode) != nil
        let hasStoredModifiers = defaults.object(forKey: Keys.ocrHotkeyModifiers) != nil
        if hasStoredKeyCode,
           hasStoredModifiers,
           defaults.integer(forKey: Keys.ocrHotkeyKeyCode) == DefaultHotkeys.legacyOCRKeyCode,
           defaults.integer(forKey: Keys.ocrHotkeyModifiers) == DefaultHotkeys.legacyOCRModifiers {
            defaults.set(DefaultHotkeys.ocrKeyCode, forKey: Keys.ocrHotkeyKeyCode)
            defaults.set(DefaultHotkeys.ocrModifiers, forKey: Keys.ocrHotkeyModifiers)
        }

        defaults.set(true, forKey: Keys.didMigrateOCRHotkeyDefault)
    }

    /// Replaces the original bilingual Plus preset with Qwen's dedicated
    /// American-English male voice, while preserving any custom model/voice.
    private static func migrateQwenTTSNativeAmericanDefault(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: Keys.didMigrateQwenTTSNativeAmericanDefault) else { return }

        let model = defaults.string(forKey: Keys.qwenTTSModel)
        let voice = defaults.string(forKey: Keys.qwenTTSVoice)
        if model == "qwen-audio-3.0-tts-plus", voice == "longanlufeng" {
            defaults.set("qwen-audio-3.0-tts-flash", forKey: Keys.qwenTTSModel)
            defaults.set("loongjohn", forKey: Keys.qwenTTSVoice)
        }

        let oldInstruction = "Speak in a natural, conversational American English accent with a warm, relaxed tone."
        if defaults.string(forKey: Keys.qwenTTSInstruction) == oldInstruction {
            defaults.set(
                "Speak in a native American accent with relaxed, natural conversational delivery.",
                forKey: Keys.qwenTTSInstruction
            )
        }

        defaults.set(true, forKey: Keys.didMigrateQwenTTSNativeAmericanDefault)
    }

    /// The system prompt sent to the model. A non-empty custom prompt wins;
    /// otherwise we build a faithful translate-into-target instruction that
    /// auto-flips to English when the source is already the target language.
    func effectiveSystemPrompt() -> String {
        TranslationPromptPolicy.systemPrompt(
            targetLanguage: targetLanguage,
            customPrompt: customPrompt
        )
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
        static let enableOCRHotkey = "enableOCRHotkey"
        static let enableFloatingIcon = "enableFloatingIcon"
        static let restoreClipboard = "restoreClipboard"
        static let enableNotes = "enableNotes"
        static let enableMicrosoftDictionary = "enableMicrosoftDictionary"
        static let microsoftTranslatorEndpoint = "microsoftTranslatorEndpoint"
        static let microsoftTranslatorKey = "microsoftTranslatorKey"
        static let microsoftTranslatorRegion = "microsoftTranslatorRegion"
        static let microsoftDictionaryFromLanguage = "microsoftDictionaryFromLanguage"
        static let microsoftDictionaryToLanguage = "microsoftDictionaryToLanguage"
        static let qwenTTSEndpoint = "qwenTTSEndpoint"
        static let qwenTTSModel = "qwenTTSModel"
        static let qwenTTSVoice = "qwenTTSVoice"
        static let qwenTTSInstruction = "qwenTTSInstruction"
        static let ttsBackends = "ttsBackends"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let ocrHotkeyKeyCode = "ocrHotkeyKeyCode"
        static let ocrHotkeyModifiers = "ocrHotkeyModifiers"
        static let didMigrateOCRHotkeyDefault = "didMigrateOCRHotkeyDefaultToOptionShiftO"
        static let didMigrateQwenTTSNativeAmericanDefault = "didMigrateQwenTTSNativeAmericanDefault"
    }

    private enum DefaultHotkeys {
        static let translationKeyCode = kVK_ANSI_D
        static let translationModifiers = Int(NSEvent.ModifierFlags.option.rawValue)
        static let ocrKeyCode = kVK_ANSI_O
        static let ocrModifiers = Int(NSEvent.ModifierFlags([.option, .shift]).rawValue)

        static let legacyOCRKeyCode = kVK_ANSI_D
        static let legacyOCRModifiers = Int(NSEvent.ModifierFlags([.option, .shift]).rawValue)
    }
}
