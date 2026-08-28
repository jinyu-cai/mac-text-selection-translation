import AVFoundation
import Combine

private enum PronunciationSpeakerError: LocalizedError {
    case playbackFailed

    var errorDescription: String? {
        "AI TTS 音频无法播放。"
    }
}

@MainActor
final class PronunciationSpeaker: ObservableObject {
    static let shared = PronunciationSpeaker()

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    private var activeRequestID: UUID?

    @Published private(set) var isPreparingAI = false
    @Published private(set) var errorMessage: String?

    private init() {}

    func speak(
        _ text: String,
        language: String? = nil,
        ttsBackend: TTSBackend? = nil
    ) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }

        stop()
        errorMessage = nil

        if let ttsBackend {
            speakWithAI(spoken, language: language, backend: ttsBackend)
            return
        }

        speakWithSystemVoice(spoken, language: language)
    }

    private func speakWithSystemVoice(_ spoken: String, language: String?) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.voice(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        activeRequestID = nil
        synthesisTask?.cancel()
        synthesisTask = nil
        isPreparingAI = false
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func clearError() {
        errorMessage = nil
    }

    /// Plays audio produced by the Settings connection test.
    func playPreview(_ data: Data) throws {
        stop()
        errorMessage = nil
        try startAudioPlayback(data)
    }

    private func speakWithAI(_ spoken: String, language: String?, backend: TTSBackend) {
        let requestID = UUID()
        activeRequestID = requestID
        isPreparingAI = true

        synthesisTask = Task { [weak self] in
            do {
                let data = try await TTSClient(backend: backend).synthesize(
                    text: spoken,
                    language: language
                )
                try Task.checkCancellation()
                guard let self, self.activeRequestID == requestID else { return }

                try self.startAudioPlayback(data)
                self.activeRequestID = nil
                self.isPreparingAI = false
                self.synthesisTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeRequestID == requestID else { return }
                self.isPreparingAI = false
                self.synthesisTask = nil
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func startAudioPlayback(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        guard player.play() else { throw PronunciationSpeakerError.playbackFailed }
        audioPlayer = player
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
