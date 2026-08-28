import Foundation
import MacTranslatorCore

/// Wire format used by a text-to-speech service.
enum TTSAPIKind: String, Codable, CaseIterable, Identifiable {
    case openAI
    case dashScope

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: return "OpenAI 兼容"
        case .dashScope: return "阿里云 DashScope"
        }
    }
}

/// One selectable speech backend. API keys are stripped before this value is
/// persisted to UserDefaults and are stored separately in the Keychain.
struct TTSBackend: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var apiKind: TTSAPIKind
    var endpoint: String
    var apiKey: String
    var model: String
    var voice: String
    var responseFormat: String
    var instruction: String
    var isEnabled: Bool = true

    var isConfigured: Bool {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !responseFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        // Local OpenAI-compatible servers commonly do not require a key.
        return apiKind == .openAI
            || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isUsable: Bool { isEnabled && isConfigured }

    static func makeNew() -> TTSBackend {
        TTSBackend(
            name: "OpenAI TTS",
            apiKind: .openAI,
            endpoint: "http://localhost:8000/v1",
            apiKey: "",
            model: "tts-1",
            voice: "alloy",
            responseFormat: "mp3",
            instruction: "",
            isEnabled: true
        )
    }
}

enum TTSError: LocalizedError {
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
            return "TTS 配置不完整，请检查 Endpoint、模型、音色和音频格式。DashScope 还需要 API Key。"
        case .invalidEndpoint:
            return "TTS Endpoint 无效。"
        case .invalidResponse:
            return "TTS 返回了无法识别的响应。"
        case let .http(status, body):
            let hint: String
            switch status {
            case 401: hint = "（API Key 可能无效）"
            case 403: hint = "（没有模型权限，或 API Key 与 Endpoint 地域不匹配）"
            case 404: hint = "（Endpoint、协议类型或模型名可能不对）"
            case 429: hint = "（请求过于频繁或额度不足）"
            default: hint = ""
            }
            return "TTS 请求失败 HTTP \(status)\(hint)\n\(body.prefix(300))"
        case let .service(code, message):
            return "TTS 请求失败（\(code)）：\(message)"
        case .missingAudio:
            return "TTS 没有返回音频。"
        case .invalidAudioURL:
            return "TTS 返回的音频地址无效。"
        case let .audioDownload(status):
            return "TTS 音频下载失败 HTTP \(status)。"
        case .emptyAudio:
            return "TTS 返回了空音频。"
        }
    }
}

/// Client for OpenAI-compatible `/audio/speech` services and Alibaba Cloud's
/// DashScope Qwen-Audio-TTS API.
struct TTSClient {
    var backend: TTSBackend

    func synthesize(text: String, language: String? = nil) async throws -> Data {
        guard backend.isConfigured else { throw TTSError.missingConfiguration }

        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw TTSError.emptyAudio }

        switch backend.apiKind {
        case .openAI:
            return try await synthesizeOpenAI(text: spoken)
        case .dashScope:
            return try await synthesizeDashScope(text: spoken, language: language)
        }
    }

    private func synthesizeOpenAI(text: String) async throws -> Data {
        var request = URLRequest(url: try openAIEndpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuthorization(on: &request)

        let body = TTSRequestPolicy.openAIBody(
            model: backend.model,
            input: text,
            voice: backend.voice,
            responseFormat: backend.responseFormat,
            instructions: backend.instruction
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TTSError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard !data.isEmpty else { throw TTSError.emptyAudio }
        return data
    }

    private func synthesizeDashScope(text: String, language: String?) async throws -> Data {
        var request = URLRequest(url: try dashScopeEndpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuthorization(on: &request)
        request.httpBody = try JSONEncoder().encode(
            DashScopeRequestBody(
                model: trimmed(backend.model),
                input: DashScopeRequestInput(
                    text: text,
                    voice: trimmed(backend.voice),
                    format: trimmed(backend.responseFormat),
                    sampleRate: 24_000,
                    languageHints: Self.languageHints(for: language),
                    instruction: nonEmpty(backend.instruction)
                )
            )
        )

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TTSError.http(
                status: http.statusCode,
                body: String(data: responseData, encoding: .utf8) ?? ""
            )
        }

        let decoded: DashScopeResponse
        do {
            decoded = try JSONDecoder().decode(DashScopeResponse.self, from: responseData)
        } catch {
            throw TTSError.invalidResponse
        }
        if let code = nonEmpty(decoded.code) {
            throw TTSError.service(code: code, message: decoded.message ?? "未知错误")
        }
        guard let value = nonEmpty(decoded.output?.audio?.url) else {
            throw TTSError.missingAudio
        }
        guard let audioURL = Self.secureAudioURL(from: value) else {
            throw TTSError.invalidAudioURL
        }

        var audioRequest = URLRequest(url: audioURL)
        audioRequest.timeoutInterval = 60
        let (audioData, audioResponse) = try await URLSession.shared.data(for: audioRequest)
        guard let audioHTTP = audioResponse as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        guard (200..<300).contains(audioHTTP.statusCode) else {
            throw TTSError.audioDownload(status: audioHTTP.statusCode)
        }
        guard !audioData.isEmpty else { throw TTSError.emptyAudio }
        return audioData
    }

    private func openAIEndpointURL() throws -> URL {
        guard let url = TTSRequestPolicy.openAIEndpoint(from: backend.endpoint) else {
            throw TTSError.invalidEndpoint
        }
        return url
    }

    private func dashScopeEndpointURL() throws -> URL {
        guard let url = TTSRequestPolicy.dashScopeEndpoint(from: backend.endpoint) else {
            throw TTSError.invalidEndpoint
        }
        return url
    }

    private func setAuthorization(on request: inout URLRequest) {
        if let apiKey = nonEmpty(backend.apiKey) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// DashScope examples may return an HTTP OSS URL even though the same
    /// signed object is available over HTTPS.
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

    private struct DashScopeRequestBody: Encodable {
        let model: String
        let input: DashScopeRequestInput
    }

    private struct DashScopeRequestInput: Encodable {
        let text: String
        let voice: String
        let format: String
        let sampleRate: Int
        let languageHints: [String]?
        let instruction: String?

        enum CodingKeys: String, CodingKey {
            case text, voice, format, instruction
            case sampleRate = "sample_rate"
            case languageHints = "language_hints"
        }
    }

    private struct DashScopeResponse: Decodable {
        let output: Output?
        let code: String?
        let message: String?

        struct Output: Decodable { let audio: Audio? }
        struct Audio: Decodable { let url: String? }
    }
}
