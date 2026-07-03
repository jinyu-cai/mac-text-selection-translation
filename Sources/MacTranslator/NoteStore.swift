import Foundation

struct TranslationNote: Identifiable, Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var sourceText: String
    var translatedText: String?
    var backendName: String?
    var userNote: String
}

@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published private(set) var notes: [TranslationNote] = []
    @Published var lastError: String?

    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = support.appendingPathComponent("Text Selection Translation", isDirectory: true)
        fileURL = directory.appendingPathComponent("notes.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        notes = Self.load(from: fileURL)
    }

    var notesFilePath: String { fileURL.path }

    @discardableResult
    func add(sourceText: String, translatedText: String?, backendName: String?) -> TranslationNote {
        let translation = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let note = TranslationNote(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            sourceText: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            translatedText: translation?.isEmpty == true ? nil : translation,
            backendName: backendName,
            userNote: ""
        )
        notes.insert(note, at: 0)
        save()
        return note
    }

    func note(id: UUID?) -> TranslationNote? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    func updateUserNote(id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].userNote = text
        notes[index].updatedAt = Date()
        // Called on every keystroke of the note editor — debounce the disk
        // write instead of rewriting the whole file per character.
        scheduleSave()
    }

    func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            notes.remove(at: index)
        }
        save()
    }

    /// Writes any pending debounced edit to disk immediately (e.g. on quit).
    func flush() {
        guard pendingSave != nil else { return }
        save()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(notes)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func load(from url: URL) -> [TranslationNote] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([TranslationNote].self, from: data) else { return [] }
        return decoded.sorted { $0.createdAt > $1.createdAt }
    }
}
