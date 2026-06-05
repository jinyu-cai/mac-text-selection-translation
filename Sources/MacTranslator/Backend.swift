import Foundation

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

    /// Enabled and has at least a base URL — i.e. worth calling.
    var isUsable: Bool {
        isEnabled && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func makeNew() -> Backend {
        Backend(name: "新后端", baseURL: "https://api.openai.com/v1", apiKey: "", model: "gpt-4o-mini", isEnabled: true)
    }
}
