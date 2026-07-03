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
    @Published var dictionaryLookup: MicrosoftDictionaryLookup?
    @Published var dictionaryErrorMessage: String?
    @Published var isDictionaryLoading = false
    @Published var sourceSpeechLanguage: String?
    @Published var targetSpeechLanguage: String?
    @Published var translationSpeechLanguage: String?

    private var tasks: [Task<Void, Never>] = []
    private var dictionaryTask: Task<Void, Never>?

    /// True while any backend is still streaming.
    var isLoading: Bool { results.contains { $0.isLoading } || isDictionaryLoading }

    var showsDictionary: Bool {
        isDictionaryLoading || dictionaryLookup != nil || dictionaryErrorMessage != nil
    }

    func start(
        text: String,
        backends: [Backend],
        prompt: String,
        dictionary: MicrosoftDictionaryConfig,
        translationSpeechLanguage: String?
    ) {
        cancel()
        notice = nil
        sourceText = text
        results = backends.map { Result(id: $0.id, backendName: $0.name) }
        dictionaryLookup = nil
        dictionaryErrorMessage = nil
        isDictionaryLoading = false
        sourceSpeechLanguage = dictionary.isEnabled ? dictionary.fromLanguage : nil
        targetSpeechLanguage = dictionary.isEnabled ? dictionary.toLanguage : nil
        self.translationSpeechLanguage = translationSpeechLanguage

        if dictionary.isEnabled {
            startDictionaryLookup(text: text, config: dictionary)
        }

        for backend in backends {
            let client = OpenAIClient(baseURL: backend.baseURL, apiKey: backend.apiKey, model: backend.model, reasoning: backend.reasoning)
            let id = backend.id
            let task = Task { [weak self] in
                // A superseded task can still resume here after `start()` has
                // reset state for a newer translation, and result ids (backend
                // ids) are stable across translations — so never write state
                // once cancelled, or it lands on the new translation's card.
                do {
                    for try await delta in client.translateStream(systemPrompt: prompt, text: text) {
                        guard !Task.isCancelled else { return }
                        self?.update(id) { $0.output += delta }
                    }
                    guard !Task.isCancelled else { return }
                    self?.update(id) { result in
                        if result.output.isEmpty {
                            result.errorMessage = TranslationError.emptyResult.errorDescription
                        }
                        result.isLoading = false
                    }
                } catch is CancellationError {
                    // Superseded by a newer translation — ignore.
                } catch {
                    guard !Task.isCancelled else { return }
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
        dictionaryLookup = nil
        dictionaryErrorMessage = nil
        isDictionaryLoading = false
        sourceSpeechLanguage = nil
        targetSpeechLanguage = nil
        translationSpeechLanguage = nil
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        dictionaryTask?.cancel()
        dictionaryTask = nil
    }

    private func startDictionaryLookup(text: String, config: MicrosoftDictionaryConfig) {
        isDictionaryLoading = true
        let task = Task { [weak self] in
            do {
                let client = MicrosoftDictionaryClient(
                    endpoint: config.endpoint,
                    apiKey: config.apiKey,
                    region: config.region
                )
                let lookup = try await client.lookup(
                    text: text,
                    from: config.fromLanguage,
                    to: config.toLanguage
                )
                try Task.checkCancellation()
                self?.dictionaryLookup = lookup
                self?.isDictionaryLoading = false
            } catch is CancellationError {
                // Superseded by a newer lookup — ignore.
            } catch {
                // Cancellation can also surface as URLError(.cancelled).
                guard !Task.isCancelled else { return }
                self?.dictionaryErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.isDictionaryLoading = false
            }
        }
        dictionaryTask = task
    }

    private func update(_ id: UUID, _ mutate: (inout Result) -> Void) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        mutate(&results[index])
    }
}
