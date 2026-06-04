import SwiftUI

@main
struct MacTranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra("Text Selection Translation", systemImage: "character.bubble") {
            MenuContent()
                .environmentObject(settings)
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button("翻译剪贴板内容") {
            (NSApp.delegate as? AppDelegate)?.translateClipboard()
        }

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
}
