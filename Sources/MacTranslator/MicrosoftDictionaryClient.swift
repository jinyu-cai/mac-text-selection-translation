import Foundation

/// User-facing Microsoft Translator Dictionary configuration.
struct MicrosoftDictionaryConfig: Equatable {
    var isEnabled: Bool
    var endpoint: String
    var apiKey: String
    var region: String
    var fromLanguage: String
    var toLanguage: String
}

enum MicrosoftDictionaryError: LocalizedError {
    case missingConfiguration
    case invalidURL
    case invalidResponse
    case http(status: Int, body: String)
    case emptyResult
    case textTooLong(limit: Int)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "微软词典未配置完整，请填写 Endpoint、Key 和语言代码。"
        case .invalidURL:
            return "微软词典 Endpoint 无效。"
        case .invalidResponse:
            return "微软词典返回了无法识别的响应。"
        case let .http(status, body):
            let hint: String
            switch status {
            case 401: hint = "（Key 或 Region 可能无效）"
            case 403: hint = "（没有访问权限或资源区域不匹配）"
            case 429: hint = "（请求过于频繁或额度不足）"
            default: hint = ""
            }
            let snippet = body.prefix(300)
            return "微软词典请求失败 HTTP \(status)\(hint)\n\(snippet)"
        case .emptyResult:
            return "没有收到微软词典结果。"
        case let .textTooLong(limit):
            return "微软词典适合查询单词或短语，选中文本不能超过 \(limit) 个字符。"
        }
    }
}

struct MicrosoftDictionaryLookup: Decodable {
    let normalizedSource: String
    let displaySource: String
    let translations: [MicrosoftDictionaryTranslation]
}

struct MicrosoftDictionaryTranslation: Decodable, Identifiable {
    let normalizedTarget: String
    let displayTarget: String
    let posTag: String
    let confidence: Double
    let prefixWord: String
    let backTranslations: [MicrosoftDictionaryBackTranslation]

    var id: String { "\(normalizedTarget)|\(posTag)|\(confidence)" }

    var displayText: String {
        prefixWord.isEmpty ? displayTarget : "\(prefixWord) \(displayTarget)"
    }

    var posLabel: String {
        switch posTag.uppercased() {
        case "ADJ": return "形容词"
        case "ADV": return "副词"
        case "CONJ": return "连词"
        case "DET": return "限定词"
        case "MODAL": return "情态动词"
        case "NOUN": return "名词"
        case "PREP": return "介词"
        case "PRON": return "代词"
        case "VERB": return "动词"
        default: return "其他"
        }
    }
}

struct MicrosoftDictionaryBackTranslation: Decodable, Identifiable {
    let normalizedText: String
    let displayText: String
    let numExamples: Int
    let frequencyCount: Int

    var id: String { "\(normalizedText)|\(frequencyCount)|\(numExamples)" }
}

/// Minimal client for Azure AI Translator Dictionary Lookup.
struct MicrosoftDictionaryClient {
    var endpoint: String
    var apiKey: String
    var region: String

    private let maxTextLength = 100

    func lookup(text: String, from: String, to: String) async throws -> MicrosoftDictionaryLookup {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !from.isEmpty,
              !to.isEmpty
        else {
            throw MicrosoftDictionaryError.missingConfiguration
        }
        guard !term.isEmpty else { throw MicrosoftDictionaryError.emptyResult }
        guard term.count <= maxTextLength else {
            throw MicrosoftDictionaryError.textTooLong(limit: maxTextLength)
        }

        var request = URLRequest(url: try lookupURL(from: from, to: to))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRegion.isEmpty {
            request.setValue(trimmedRegion, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        }
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-ClientTraceId")
        request.httpBody = try JSONEncoder().encode([LookupInput(text: term)])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftDictionaryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MicrosoftDictionaryError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        do {
            let decoded = try JSONDecoder().decode([MicrosoftDictionaryLookup].self, from: data)
            guard let first = decoded.first else { throw MicrosoftDictionaryError.emptyResult }
            return first
        } catch let error as MicrosoftDictionaryError {
            throw error
        } catch {
            throw MicrosoftDictionaryError.invalidResponse
        }
    }

    private func lookupURL(from: String, to: String) throws -> URL {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.lowercased().contains("/dictionary/lookup") {
            trimmed += "/dictionary/lookup"
        }

        guard var components = URLComponents(string: trimmed) else {
            throw MicrosoftDictionaryError.invalidURL
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "api-version", value: "3.0"))
        items.append(URLQueryItem(name: "from", value: from))
        items.append(URLQueryItem(name: "to", value: to))
        components.queryItems = items
        guard let url = components.url else { throw MicrosoftDictionaryError.invalidURL }
        return url
    }

    private struct LookupInput: Encodable {
        let text: String

        enum CodingKeys: String, CodingKey {
            case text = "Text"
        }
    }
}
