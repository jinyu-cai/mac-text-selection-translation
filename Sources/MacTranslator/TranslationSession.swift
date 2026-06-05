import SwiftUI

/// Observable state for one translation across one or more backends.
/// Each enabled backend gets its own streaming `Result`, all running in parallel.
@MainActor
final class TranslationSession: ObservableObject {
    struct Result: Identifiable {
        let id: UUID            // == backend id
        let backendName: String
        var output: String = ""
        var isLoading: Bool = true
        var errorMessage: String?
    }

    @Published var sourceText: String = ""
    @Published var results: [Result] = []
    @Published var notice: String?

    private var tasks: [Task<Void, Never>] = []

    /// True while any backend is still streaming.
    var isLoading: Bool { results.contains { $0.isLoading } }

    func start(text: String, backends: [Backend], prompt: String) {
        cancel()
        notice = nil
        sourceText = text
        results = backends.map { Result(id: $0.id, backendName: $0.name) }

        for backend in backends {
            let client = OpenAIClient(baseURL: backend.baseURL, apiKey: backend.apiKey, model: backend.model)
            let id = backend.id
            let task = Task { [weak self] in
                do {
                    for try await delta in client.translateStream(systemPrompt: prompt, text: text) {
                        self?.update(id) { $0.output += delta }
                    }
                    self?.update(id) { result in
                        if result.output.isEmpty {
                            result.errorMessage = TranslationError.emptyResult.errorDescription
                        }
                        result.isLoading = false
                    }
                } catch is CancellationError {
                    // Superseded by a newer translation — ignore.
                } catch {
                    self?.update(id) { result in
                        result.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        result.isLoading = false
                    }
                }
            }
            tasks.append(task)
        }
    }

    /// Shows a plain message instead of results (e.g. missing permission).
    func presentNotice(_ message: String) {
        cancel()
        sourceText = ""
        results = []
        notice = message
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func update(_ id: UUID, _ mutate: (inout Result) -> Void) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        mutate(&results[index])
    }
}
