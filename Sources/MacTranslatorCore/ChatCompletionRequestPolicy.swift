import Foundation

/// Builds the advanced parameters shared by every OpenAI-compatible backend.
///
/// Backend URLs intentionally do not participate in this policy. A configured
/// AI backend promises to implement the OpenAI Chat Completions contract, so
/// the same field names must be sent through direct, proxied, and local URLs.
public enum ChatCompletionRequestPolicy {
    public static func parameters(
        model: String,
        reasoning: String
    ) -> [String: Any] {
        var parameters: [String: Any] = [:]

        if supportsTemperature(model: model, reasoning: reasoning) {
            parameters["temperature"] = 0.2
        }

        switch reasoning {
        case "off":
            parameters["reasoning_effort"] = "none"
        case "low", "medium", "high", "xhigh", "max":
            parameters["reasoning_effort"] = reasoning
        default:
            break
        }

        return parameters
    }

    private static func supportsTemperature(model: String, reasoning: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? trimmed

        if normalized.hasPrefix("gpt-5") {
            // GPT-5.5 and GPT-5.6 no longer document the sampling restriction
            // that applies to earlier GPT-5 models.
            if belongsToModelFamily(normalized, family: "gpt-5.5")
                || belongsToModelFamily(normalized, family: "gpt-5.6") {
                return true
            }

            // GPT-5.1, GPT-5.2, and GPT-5.4 accept sampling parameters only
            // with an explicit reasoning effort of `none`.
            if belongsToModelFamily(normalized, family: "gpt-5.1")
                || belongsToModelFamily(normalized, family: "gpt-5.2")
                || belongsToModelFamily(normalized, family: "gpt-5.4") {
                return reasoning == "off"
            }

            // Original GPT-5 models and Codex variants reject temperature.
            return false
        }

        guard normalized.first == "o" else { return true }
        return normalized.dropFirst().first?.isNumber != true
    }

    private static func belongsToModelFamily(_ model: String, family: String) -> Bool {
        model == family || model.hasPrefix(family + "-")
    }
}
