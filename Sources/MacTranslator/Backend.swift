import Foundation

/// How much "thinking / reasoning" a backend's model should do.
/// `auto` sends nothing (model default); the others map to OpenRouter's unified
/// `reasoning` parameter. Most translation tasks are faster with `off`.
enum ReasoningMode: String, Codable, CaseIterable, Identifiable {
    case auto, off, low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动"
        case .off: return "关闭"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

/// One OpenAI-compatible translation backend. Several can be enabled at once;
/// a translation then runs every enabled backend in parallel for side-by-side
/// comparison. Persisted as JSON in `AppSettings`.
struct Backend: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
    var isEnabled: Bool = true
    var reasoning: ReasoningMode = .auto

    /// Enabled and has at least a base URL — i.e. worth calling.
    var isUsable: Bool {
        isEnabled && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func makeNew() -> Backend {
        Backend(name: "新后端", baseURL: "https://api.openai.com/v1", apiKey: "", model: "gpt-4o-mini")
    }

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String,
        model: String,
        isEnabled: Bool = true,
        reasoning: ReasoningMode = .auto
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.isEnabled = isEnabled
        self.reasoning = reasoning
    }

    // Custom decode so older saved backends (without the newer fields) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        reasoning = try c.decodeIfPresent(ReasoningMode.self, forKey: .reasoning) ?? .auto
    }
}
