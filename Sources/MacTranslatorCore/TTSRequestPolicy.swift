import Foundation

/// Pure request-shaping helpers shared by the app and regression tests.
public enum TTSRequestPolicy {
    /// Accepts either an OpenAI-style base URL or the complete speech URL.
    public static func openAIEndpoint(from baseURL: String) -> URL? {
        var value = normalized(baseURL)
        let lower = value.lowercased()
        if !lower.hasSuffix("/audio/speech") {
            value += lower.hasSuffix("/v1") ? "/audio/speech" : "/v1/audio/speech"
        }
        return validatedURL(value)
    }

    /// Accepts either the normal DashScope API root or its complete TTS URL.
    public static func dashScopeEndpoint(from endpoint: String) -> URL? {
        var value = normalized(endpoint)
        let lower = value.lowercased()
        if !lower.contains("/services/audio/tts/speechsynthesizer") {
            value += lower.hasSuffix("/api/v1")
                ? "/services/audio/tts/SpeechSynthesizer"
                : "/api/v1/services/audio/tts/SpeechSynthesizer"
        }
        return validatedURL(value)
    }

    /// OpenAI's speech endpoint uses a flat JSON object and returns audio bytes.
    public static func openAIBody(
        model: String,
        input: String,
        voice: String,
        responseFormat: String,
        instructions: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "input": input,
            "voice": voice.trimmingCharacters(in: .whitespacesAndNewlines),
            "response_format": responseFormat.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }
        return body
    }

    private static func normalized(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func validatedURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return url
    }
}
