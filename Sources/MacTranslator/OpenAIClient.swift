import Foundation

enum TranslationError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(status: Int, body: String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "接口地址无效，请检查 Base URL。"
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case let .http(status, body):
            let hint: String
            switch status {
            case 401: hint = "（API Key 可能无效）"
            case 403: hint = "（没有访问权限）"
            case 404: hint = "（Base URL 或模型名可能不对）"
            case 429: hint = "（请求过于频繁或额度不足）"
            default: hint = ""
            }
            let snippet = body.prefix(300)
            return "请求失败 HTTP \(status)\(hint)\n\(snippet)"
        case .emptyResult:
            return "没有收到翻译结果。"
        }
    }
}

/// A minimal client for any OpenAI-compatible `/chat/completions` endpoint.
struct OpenAIClient {
    var baseURL: String
    var apiKey: String
    var model: String
    var reasoning: ReasoningMode = .auto

    private func endpoint() throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + "/chat/completions") else {
            throw TranslationError.invalidURL
        }
        return url
    }

    private func makeRequest(systemPrompt: String, text: String, stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        // OpenRouter's unified reasoning control. `.auto` sends nothing so
        // backends that don't understand it are unaffected.
        switch reasoning {
        case .auto: break
        case .off: body["reasoning"] = ["enabled": false]
        case .low: body["reasoning"] = ["effort": "low"]
        case .medium: body["reasoning"] = ["effort": "medium"]
        case .high: body["reasoning"] = ["effort": "high"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Streams translated text deltas as they arrive (Server-Sent Events).
    func translateStream(systemPrompt: String, text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(systemPrompt: systemPrompt, text: text, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw TranslationError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n" }
                        throw TranslationError.http(
                            status: http.statusCode,
                            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch Self.parse(line: line) {
                        case .none:
                            continue
                        case .done:
                            continuation.finish()
                            return
                        case let .delta(text):
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot, non-streaming request used by the "test connection" button.
    func verify() async throws -> String {
        let request = try makeRequest(systemPrompt: "You are a translation engine.", text: "ping", stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TranslationError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = object["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        throw TranslationError.emptyResult
    }

    private enum Chunk {
        case delta(String)
        case done
        case none
    }

    private static func parse(line: String) -> Chunk {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .none }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return .none }
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty
        else { return .none }
        return .delta(content)
    }
}
