import SwiftUI

@main
struct MacTranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var notes = NoteStore.shared

    var body: some Scene {
        MenuBarExtra("Text Selection Translation", systemImage: "character.bubble") {
            MenuContent()
                .environmentObject(settings)
                .environmentObject(notes)
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
        .windowResizability(.contentMinSize)

        WindowGroup("笔记", id: "notes") {
            NotesView()
                .environmentObject(notes)
        }
        .defaultSize(width: 760, height: 520)
    }
}

private struct MenuContent: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var notes: NoteStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appVersionLabel)
            .foregroundStyle(.secondary)

        Divider()

        Button("翻译剪贴板内容") {
            (NSApp.delegate as? AppDelegate)?.translateClipboard()
        }

        Button("截图 OCR 翻译…") {
            (NSApp.delegate as? AppDelegate)?.translateScreenshotOCR()
        }

        Button("笔记…") {
            openWindow(id: "notes")
        }
        .disabled(!settings.enableNotes && notes.notes.isEmpty)

        Divider()

        SettingsLink {
            Text("设置…")
        }
        .keyboardShortcut(",")

        Button("退出 Text Selection Translation") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "版本 \(version) (\(build))"
    }
}
