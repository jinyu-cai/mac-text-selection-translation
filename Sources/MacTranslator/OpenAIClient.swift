import Foundation
import MacTranslatorCore
import OSLog

enum TranslationError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(status: Int, body: String)
    case network(code: Int, message: String, retried: Bool)
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
        case let .network(code, message, retried):
            let retryNote = retried ? "\n已自动重试 1 次，但仍未成功。" : ""
            return "网络请求失败（错误代码 \(code)）：\(message)\(retryNote)"
        case .emptyResult:
            return "没有收到翻译结果。"
        }
    }
}

/// A minimal client for any OpenAI-compatible `/chat/completions` endpoint.
struct OpenAIClient {
    private static let logger = Logger(
        subsystem: "com.example.mactranslator",
        category: "OpenAIClient"
    )

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
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        let advancedParameters = ChatCompletionRequestPolicy.parameters(
            model: model,
            reasoning: reasoning.rawValue
        )
        for (key, value) in advancedParameters {
            body[key] = value
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Streams translated text deltas as they arrive (Server-Sent Events).
    func translateStream(systemPrompt: String, text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 1
                while true {
                    var hasReceivedContent = false
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
                                hasReceivedContent = true
                                continuation.yield(text)
                            }
                        }
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        let nsError = error as NSError
                        if NetworkRetryPolicy.shouldRetry(
                            errorDomain: nsError.domain,
                            errorCode: nsError.code,
                            completedAttempts: attempt,
                            hasReceivedContent: hasReceivedContent
                        ) {
                            Self.logger.warning(
                                "Retrying model \(model, privacy: .public) after transport error \(nsError.code, privacy: .public)"
                            )
                            attempt += 1
                            do {
                                try await Task.sleep(for: .milliseconds(400))
                            } catch {
                                continuation.finish()
                                return
                            }
                            continue
                        }

                        Self.logFinalFailure(error, model: model, retried: attempt > 1)
                        continuation.finish(
                            throwing: Self.userFacingError(error, retried: attempt > 1)
                        )
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot, non-streaming request used by the "test connection" button.
    func verify() async throws -> String {
        let request = try makeRequest(systemPrompt: "You are a translation engine.", text: "ping", stream: false)
        let (data, response) = try await dataWithRetry(for: request)
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

    private func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 1
        while true {
            do {
                return try await URLSession.shared.data(for: request)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let nsError = error as NSError
                if NetworkRetryPolicy.shouldRetry(
                    errorDomain: nsError.domain,
                    errorCode: nsError.code,
                    completedAttempts: attempt,
                    hasReceivedContent: false
                ) {
                    Self.logger.warning(
                        "Retrying connection test for model \(model, privacy: .public) after transport error \(nsError.code, privacy: .public)"
                    )
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(400))
                    continue
                }

                Self.logFinalFailure(error, model: model, retried: attempt > 1)
                throw Self.userFacingError(error, retried: attempt > 1)
            }
        }
    }

    private static func userFacingError(_ error: Error, retried: Bool) -> Error {
        if error is TranslationError { return error }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error }
        return TranslationError.network(
            code: nsError.code,
            message: error.localizedDescription,
            retried: retried
        )
    }

    private static func logFinalFailure(_ error: Error, model: String, retried: Bool) {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return }
        logger.error(
            "Request failed for model \(model, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) retried=\(retried, privacy: .public)"
        )
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
