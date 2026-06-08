import AVFoundation

@MainActor
final class PronunciationSpeaker {
    static let shared = PronunciationSpeaker()

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    func speak(_ text: String, language: String? = nil) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.voice(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        let requested = normalize(language ?? "")
        guard !requested.isEmpty else { return nil }
        if let direct = AVSpeechSynthesisVoice(language: requested) {
            return direct
        }
        let languagePrefix = requested.split(separator: "-").first.map(String.init)

        return AVSpeechSynthesisVoice.speechVoices().first { voice in
            let normalizedLocale = normalize(voice.language)
            if normalizedLocale == requested || normalizedLocale.hasPrefix(requested + "-") {
                return true
            }
            if let languagePrefix, normalizedLocale.hasPrefix(languagePrefix + "-") {
                return true
            }
            return false
        }
    }

    private static func normalize(_ language: String) -> String {
        language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}
