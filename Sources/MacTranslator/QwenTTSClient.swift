import Foundation

/// User-facing configuration for the original-text speech button. An empty
/// API key intentionally means "use the macOS system voice".
struct QwenTTSConfig: Equatable {
    var endpoint: String
    var apiKey: String
    var model: String
    var voice: String
    var instruction: String

    var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum QwenTTSError: LocalizedError {
    case missingConfiguration
    case invalidEndpoint
    case invalidResponse
    case http(status: Int, body: String)
    case service(code: String, message: String)
    case missingAudio
    case invalidAudioURL
    case audioDownload(status: Int)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "AI 朗读未配置完整，请检查 Endpoint、API Key、模型和音色。"
        case .invalidEndpoint:
            return "AI TTS Endpoint 无效。"
        case .invalidResponse:
            return "AI TTS 返回了无法识别的响应。"
        case let .http(status, body):
            let hint: String
            switch status {
            case 401: hint = "（API Key 可能无效）"
            case 403: hint = "（没有模型权限，或 API Key 与 Endpoint 地域不匹配）"
            case 404: hint = "（Endpoint 或模型名可能不对）"
            case 429: hint = "（请求过于频繁或额度不足）"
            default: hint = ""
            }
            return "AI TTS 请求失败 HTTP \(status)\(hint)\n\(body.prefix(300))"
        case let .service(code, message):
            return "AI TTS 请求失败（\(code)）：\(message)"
        case .missingAudio:
            return "AI TTS 没有返回音频地址。"
        case .invalidAudioURL:
            return "AI TTS 返回的音频地址无效。"
        case let .audioDownload(status):
            return "AI TTS 音频下载失败 HTTP \(status)。"
        case .emptyAudio:
            return "AI TTS 返回了空音频。"
        }
    }
}

/// Minimal client for Alibaba Cloud Model Studio's Qwen-Audio-TTS HTTP API.
struct QwenTTSClient {
    var config: QwenTTSConfig

    func synthesize(text: String, language: String? = nil) async throws -> Data {
        guard config.isConfigured else { throw QwenTTSError.missingConfiguration }

        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw QwenTTSError.emptyAudio }

        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: config.model.trimmingCharacters(in: .whitespacesAndNewlines),
                input: RequestInput(
                    text: spoken,
                    voice: config.voice.trimmingCharacters(in: .whitespacesAndNewlines),
                    format: "mp3",
                    sampleRate: 24_000,
                    languageHints: Self.languageHints(for: language),
                    instruction: Self.nonEmpty(config.instruction)
                )
            )
        )

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QwenTTSError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QwenTTSError.http(
                status: http.statusCode,
                body: String(data: responseData, encoding: .utf8) ?? ""
            )
        }

        let decoded: SynthesisResponse
        do {
            decoded = try JSONDecoder().decode(SynthesisResponse.self, from: responseData)
        } catch {
            throw QwenTTSError.invalidResponse
        }
        if let code = Self.nonEmpty(decoded.code) {
            throw QwenTTSError.service(code: code, message: decoded.message ?? "未知错误")
        }
        guard let value = Self.nonEmpty(decoded.output?.audio?.url) else {
            throw QwenTTSError.missingAudio
        }
        guard let audioURL = Self.secureAudioURL(from: value) else {
            throw QwenTTSError.invalidAudioURL
        }

        var audioRequest = URLRequest(url: audioURL)
        audioRequest.timeoutInterval = 60
        let (audioData, audioResponse) = try await URLSession.shared.data(for: audioRequest)
        guard let audioHTTP = audioResponse as? HTTPURLResponse else {
            throw QwenTTSError.invalidResponse
        }
        guard (200..<300).contains(audioHTTP.statusCode) else {
            throw QwenTTSError.audioDownload(status: audioHTTP.statusCode)
        }
        guard !audioData.isEmpty else { throw QwenTTSError.emptyAudio }
        return audioData
    }

    private func endpointURL() throws -> URL {
        var value = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { throw QwenTTSError.invalidEndpoint }

        let lower = value.lowercased()
        if !lower.contains("/services/audio/tts/speechsynthesizer") {
            if lower.hasSuffix("/api/v1") {
                value += "/services/audio/tts/SpeechSynthesizer"
            } else {
                value += "/api/v1/services/audio/tts/SpeechSynthesizer"
            }
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else {
            throw QwenTTSError.invalidEndpoint
        }
        return url
    }

    /// DashScope examples may return an `http` OSS URL even though the same
    /// signed object is available over HTTPS. Upgrading it keeps playback
    /// compatible with App Transport Security.
    private static func secureAudioURL(from value: String) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        if components.scheme?.lowercased() == "http",
           components.host?.lowercased().hasSuffix(".aliyuncs.com") == true {
            components.scheme = "https"
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil
        else { return nil }
        return components.url
    }

    private static func languageHints(for language: String?) -> [String]? {
        guard let language else { return nil }
        let code = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init)
        let supported: Set<String> = [
            "zh", "en", "fr", "de", "ja", "ko", "ru", "pt", "th",
            "id", "vi", "es", "it", "ms", "fil", "ar",
        ]
        guard let code, supported.contains(code) else { return nil }
        return [code]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: RequestInput
    }

    private struct RequestInput: Encodable {
        let text: String
        let voice: String
        let format: String
        let sampleRate: Int
        let languageHints: [String]?
        let instruction: String?

        enum CodingKeys: String, CodingKey {
            case text
            case voice
            case format
            case sampleRate = "sample_rate"
            case languageHints = "language_hints"
            case instruction
        }
    }

    private struct SynthesisResponse: Decodable {
        let output: Output?
        let code: String?
        let message: String?

        struct Output: Decodable {
            let audio: Audio?
        }

        struct Audio: Decodable {
            let url: String?
        }
    }
}
