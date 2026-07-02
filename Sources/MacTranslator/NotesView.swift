import AppKit
import SwiftUI

struct NotesView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var selection: UUID?

    private var selectedNote: TranslationNote? {
        store.note(id: selection) ?? store.notes.first
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 280)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            if selection == nil {
                selection = store.notes.first?.id
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("笔记")
                    .font(.headline)
                Spacer()
                Text("\(store.notes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if store.notes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无笔记")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(store.notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.sourceText)
                                .font(.callout.weight(.medium))
                                .lineLimit(2)
                            if let translated = note.translatedText, !translated.isEmpty {
                                Text(translated)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .tag(note.id)
                    }
                    .onDelete { offsets in
                        store.delete(at: offsets)
                        selection = store.notes.first?.id
                    }
                }
                .listStyle(.sidebar)
            }

            if let error = store.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let note = selectedNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.createdAt.formatted(date: .complete, time: .shortened))
                                .font(.headline)
                            if let backend = note.backendName, !backend.isEmpty {
                                Text(backend)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            copy(note.sourceText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("复制原文")
                        Button(role: .destructive) {
                            store.delete(id: note.id)
                            selection = store.notes.first?.id
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("删除笔记")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("原文")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(note.sourceText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let translated = note.translatedText, !translated.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("译文")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    copy(translated)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("复制译文")
                            }
                            Text(translated)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: Binding(
                            get: { store.note(id: note.id)?.userNote ?? "" },
                            set: { store.updateUserNote(id: note.id, text: $0) }
                        ))
                        .font(.body)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("选择一条笔记")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
