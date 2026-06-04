import SwiftUI

/// Observable state for one translation, driving the popup UI.
@MainActor
final class TranslationSession: ObservableObject {
    @Published var sourceText: String = ""
    @Published var output: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?

    func start(text: String, settings: AppSettings) {
        task?.cancel()
        sourceText = text
        output = ""
        errorMessage = nil
        isLoading = true

        let client = OpenAIClient(baseURL: settings.apiBaseURL, apiKey: settings.apiKey, model: settings.model)
        let prompt = settings.effectiveSystemPrompt()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in client.translateStream(systemPrompt: prompt, text: text) {
                    self.output += delta
                }
                if self.output.isEmpty {
                    self.errorMessage = TranslationError.emptyResult.errorDescription
                }
            } catch is CancellationError {
                // A newer translation superseded this one — ignore.
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.isLoading = false
        }
    }

    /// Shows a plain message in the popup without making any network request
    /// (used for "missing permission" / "nothing selected" notices).
    func presentNotice(_ message: String) {
        task?.cancel()
        task = nil
        sourceText = ""
        output = ""
        isLoading = false
        errorMessage = message
    }

    func cancel() {
        task?.cancel()
        task = nil
        isLoading = false
    }
}
